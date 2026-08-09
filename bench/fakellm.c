/*
 * fakellm -- an OpenAI-compatible server that simulates a model with a known timing envelope.
 *
 * The point is reproducibility. A real model's generation time swamps a proxy's overhead by
 * two to three orders of magnitude and varies run to run, so measuring a router against one
 * measures the GPU. Here the timing is a parameter: --ttft-ms is how long the first token
 * takes, --tokens-per-second is how fast the rest arrive, and both hold exactly across runs.
 *
 * Threaded, one thread per connection, keep-alive supported. That is not the fastest possible
 * design, but it is small enough to read in one sitting and fast enough that the thing under
 * test stays the bottleneck -- which is the only property that matters for a load target.
 *
 * See docs/adr/0007-benchmarks-use-a-deterministic-fake-model.md.
 */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define REQ_BUF_SIZE (1 << 20)
#define OUT_BUF_SIZE (1 << 16)

/* One vocabulary of short, plausible tokens. Content does not matter to the measurement, but
 * varying token length does: a fixed single character would make every SSE frame the same
 * size and hide framing costs that a real stream has. */
static const char *TOKENS[] = {
    "The ", "model ", "returns ", "a ",   "steady ",  "stream ", "of ",     "tokens ",
    "so ",  "that ",  "timing ", "can ",  "be ",      "held ",   "still ",  "while ",
    "the ", "proxy ", "in ",     "front ", "of ",     "it ",     "is ",     "measured ",
    "under ", "load ", "with ",  "known ", "latency ", "and ",   "known ",  "throughput ",
};
static const int TOKEN_COUNT = (int)(sizeof(TOKENS) / sizeof(TOKENS[0]));

static struct {
    int port;
    const char *host;
    double ttft_ms;
    double tokens_per_second;
    int tokens;
    const char *model;
    int verbose;
    int prompt_tokens;
} cfg = {
    .port = 18080,
    .host = "127.0.0.1",
    .ttft_ms = 20.0,
    .tokens_per_second = 1000.0,
    .tokens = 64,
    .model = "fakellm",
    .verbose = 0,
    .prompt_tokens = 16,
};

static volatile sig_atomic_t running = 1;

static void on_signal(int sig) {
    (void)sig;
    running = 0;
}

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* Sleep until an absolute deadline on the monotonic clock. Sleeping for a duration accumulates
 * drift across N tokens; sleeping until a deadline does not, which is what keeps the advertised
 * token rate honest over a long response. */
static void sleep_until(double deadline) {
    for (;;) {
        double remaining = deadline - now_seconds();
        if (remaining <= 0) return;
        struct timespec ts;
        ts.tv_sec = (time_t)remaining;
        ts.tv_nsec = (long)((remaining - (double)ts.tv_sec) * 1e9);
        if (nanosleep(&ts, NULL) == 0) return;
        if (errno != EINTR) return;
    }
}

static int write_all(int fd, const char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n > 0) {
            off += (size_t)n;
            continue;
        }
        if (n < 0 && (errno == EINTR)) continue;
        return -1;
    }
    return 0;
}

static int write_fmt(int fd, const char *fmt, ...) {
    char buf[OUT_BUF_SIZE];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n < 0 || (size_t)n >= sizeof(buf)) return -1;
    return write_all(fd, buf, (size_t)n);
}

/* Per-request overrides let one running server serve several scenarios: a benchmark can sweep
 * token counts without a restart, and a client can prove that the server, not the proxy,
 * decided the timing. */
typedef struct {
    double ttft_ms;
    double tokens_per_second;
    int tokens;
    int stream;
    char model[128];
} req_params;

static const char *find_header(const char *req, const char *name) {
    size_t nlen = strlen(name);
    const char *p = req;
    while ((p = strchr(p, '\n')) != NULL) {
        p++;
        if (strncasecmp(p, name, nlen) == 0 && p[nlen] == ':') {
            p += nlen + 1;
            while (*p == ' ') p++;
            return p;
        }
    }
    return NULL;
}

/* Minimal JSON scalar extraction: enough for the handful of numeric and boolean keys this
 * server understands, and deliberately not a JSON parser -- the request body is ours to
 * define, and a parser here would be a second thing that can be wrong. */
static int json_number(const char *body, const char *key, double *out) {
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    const char *p = strstr(body, pattern);
    if (!p) return 0;
    p = strchr(p + strlen(pattern), ':');
    if (!p) return 0;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    char *end = NULL;
    double v = strtod(p, &end);
    if (end == p) return 0;
    *out = v;
    return 1;
}

static int json_true(const char *body, const char *key) {
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    const char *p = strstr(body, pattern);
    if (!p) return 0;
    p = strchr(p + strlen(pattern), ':');
    if (!p) return 0;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    return strncmp(p, "true", 4) == 0;
}

static void json_string(const char *body, const char *key, char *out, size_t out_len) {
    out[0] = '\0';
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    const char *p = strstr(body, pattern);
    if (!p) return;
    p = strchr(p + strlen(pattern), ':');
    if (!p) return;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    if (*p != '"') return;
    p++;
    size_t i = 0;
    while (*p && *p != '"' && i + 1 < out_len) out[i++] = *p++;
    out[i] = '\0';
}

static void parse_params(const char *body, req_params *rp) {
    rp->ttft_ms = cfg.ttft_ms;
    rp->tokens_per_second = cfg.tokens_per_second;
    rp->tokens = cfg.tokens;
    rp->stream = 0;
    snprintf(rp->model, sizeof(rp->model), "%s", cfg.model);

    if (!body) return;

    double v;
    if (json_number(body, "max_tokens", &v) && v > 0) rp->tokens = (int)v;
    if (json_number(body, "fake_tokens", &v) && v > 0) rp->tokens = (int)v;
    if (json_number(body, "fake_ttft_ms", &v) && v >= 0) rp->ttft_ms = v;
    if (json_number(body, "fake_tokens_per_second", &v) && v > 0) rp->tokens_per_second = v;
    if (json_true(body, "stream")) rp->stream = 1;

    char model[128];
    json_string(body, "model", model, sizeof(model));
    if (model[0]) snprintf(rp->model, sizeof(rp->model), "%s", model);
}

static void build_text(const req_params *rp, char *out, size_t out_len) {
    size_t off = 0;
    for (int i = 0; i < rp->tokens && off + 32 < out_len; i++) {
        const char *tok = TOKENS[i % TOKEN_COUNT];
        size_t tlen = strlen(tok);
        if (off + tlen >= out_len) break;
        memcpy(out + off, tok, tlen);
        off += tlen;
    }
    out[off] = '\0';
}

static void send_json(int fd, int status, const char *status_text, const char *body, int keep_alive) {
    write_fmt(fd,
              "HTTP/1.1 %d %s\r\n"
              "Content-Type: application/json\r\n"
              "Content-Length: %zu\r\n"
              "Connection: %s\r\n"
              "\r\n%s",
              status, status_text, strlen(body), keep_alive ? "keep-alive" : "close", body);
}

static void handle_completion(int fd, const req_params *rp, int keep_alive) {
    double start = now_seconds();
    double first_at = start + rp->ttft_ms / 1000.0;
    double per_token = 1.0 / rp->tokens_per_second;

    if (rp->stream) {
        /* Headers go out immediately: TTFT is measured from the first *content* byte, and a
         * client that cannot see headers early cannot distinguish a slow model from a slow
         * proxy. */
        write_fmt(fd,
                  "HTTP/1.1 200 OK\r\n"
                  "Content-Type: text/event-stream\r\n"
                  "Cache-Control: no-cache\r\n"
                  "Connection: keep-alive\r\n"
                  "Transfer-Encoding: chunked\r\n"
                  "\r\n");

        char chunk[OUT_BUF_SIZE];
        char frame[OUT_BUF_SIZE];

        for (int i = 0; i < rp->tokens; i++) {
            sleep_until(first_at + (double)i * per_token);
            const char *tok = TOKENS[i % TOKEN_COUNT];
            int flen = snprintf(frame, sizeof(frame),
                                "data: {\"id\":\"chatcmpl-fake\",\"object\":\"chat.completion.chunk\","
                                "\"model\":\"%s\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"%s\"},"
                                "\"finish_reason\":null}]}\n\n",
                                rp->model, tok);
            int clen = snprintf(chunk, sizeof(chunk), "%x\r\n%s\r\n", flen, frame);
            if (write_all(fd, chunk, (size_t)clen) != 0) return;
        }

        int flen = snprintf(frame, sizeof(frame),
                            "data: {\"id\":\"chatcmpl-fake\",\"object\":\"chat.completion.chunk\","
                            "\"model\":\"%s\",\"choices\":[{\"index\":0,\"delta\":{},"
                            "\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":%d,"
                            "\"completion_tokens\":%d,\"total_tokens\":%d}}\n\n",
                            rp->model, cfg.prompt_tokens, rp->tokens, cfg.prompt_tokens + rp->tokens);
        int clen = snprintf(chunk, sizeof(chunk), "%x\r\n%s\r\n", flen, frame);
        if (write_all(fd, chunk, (size_t)clen) != 0) return;

        const char *done = "data: [DONE]\n\n";
        clen = snprintf(chunk, sizeof(chunk), "%zx\r\n%s\r\n0\r\n\r\n", strlen(done), done);
        write_all(fd, chunk, (size_t)clen);
        return;
    }

    /* Non-streaming: the whole response lands after the model would have finished, so the
     * client sees one latency covering TTFT plus generation. */
    sleep_until(first_at + (double)(rp->tokens > 0 ? rp->tokens - 1 : 0) * per_token);

    char text[REQ_BUF_SIZE];
    build_text(rp, text, sizeof(text));

    char body[REQ_BUF_SIZE + 512];
    int blen = snprintf(body, sizeof(body),
                        "{\"id\":\"chatcmpl-fake\",\"object\":\"chat.completion\",\"created\":%ld,"
                        "\"model\":\"%s\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\","
                        "\"content\":\"%s\"},\"finish_reason\":\"stop\"}],"
                        "\"usage\":{\"prompt_tokens\":%d,\"completion_tokens\":%d,\"total_tokens\":%d}}",
                        (long)time(NULL), rp->model, text, cfg.prompt_tokens, rp->tokens,
                        cfg.prompt_tokens + rp->tokens);
    if (blen < 0) return;
    send_json(fd, 200, "OK", body, keep_alive);
}

static void handle_models(int fd, int keep_alive) {
    char body[512];
    snprintf(body, sizeof(body),
             "{\"object\":\"list\",\"data\":[{\"id\":\"%s\",\"object\":\"model\",\"created\":%ld,"
             "\"owned_by\":\"fakellm\"}]}",
             cfg.model, (long)time(NULL));
    send_json(fd, 200, "OK", body, keep_alive);
}

static void handle_embeddings(int fd, const req_params *rp, int keep_alive) {
    sleep_until(now_seconds() + rp->ttft_ms / 1000.0);
    char body[1024];
    snprintf(body, sizeof(body),
             "{\"object\":\"list\",\"data\":[{\"object\":\"embedding\",\"index\":0,"
             "\"embedding\":[0.01,0.02,0.03,0.04]}],\"model\":\"%s\","
             "\"usage\":{\"prompt_tokens\":%d,\"total_tokens\":%d}}",
             rp->model, cfg.prompt_tokens, cfg.prompt_tokens);
    send_json(fd, 200, "OK", body, keep_alive);
}

static void *connection_thread(void *arg) {
    int fd = (int)(intptr_t)arg;
    char *req = malloc(REQ_BUF_SIZE);
    if (!req) {
        close(fd);
        return NULL;
    }

    for (;;) {
        size_t len = 0;
        const char *header_end = NULL;

        /* Read until the headers are complete, then until Content-Length is satisfied.
         * Keep-alive means a connection can carry many requests, so this loop is per request,
         * not per connection. */
        for (;;) {
            ssize_t n = read(fd, req + len, REQ_BUF_SIZE - 1 - len);
            if (n <= 0) goto done;
            len += (size_t)n;
            req[len] = '\0';
            header_end = strstr(req, "\r\n\r\n");
            if (header_end) break;
            if (len >= REQ_BUF_SIZE - 1) goto done;
        }

        size_t header_len = (size_t)(header_end - req) + 4;
        long content_length = 0;
        const char *cl = find_header(req, "Content-Length");
        if (cl) content_length = strtol(cl, NULL, 10);

        while (len < header_len + (size_t)content_length) {
            ssize_t n = read(fd, req + len, REQ_BUF_SIZE - 1 - len);
            if (n <= 0) goto done;
            len += (size_t)n;
            req[len] = '\0';
        }

        const char *body = req + header_len;
        req_params rp;
        parse_params(content_length > 0 ? body : NULL, &rp);

        if (cfg.verbose) {
            fprintf(stderr, "[fakellm] %.40s ttft=%.1fms rate=%.0ftok/s tokens=%d stream=%d\n",
                    req, rp.ttft_ms, rp.tokens_per_second, rp.tokens, rp.stream);
        }

        /* Honour the client's Connection header. A client that says "close" reads until EOF,
         * so holding the socket open would hang it -- and a hang under load looks exactly like
         * the latency bug a benchmark is meant to find. */
        const char *conn = find_header(req, "Connection");
        int keep_alive = !(conn && strncasecmp(conn, "close", 5) == 0);

        if (strncmp(req, "GET /health", 11) == 0) {
            send_json(fd, 200, "OK", "{\"status\":\"ok\",\"server\":\"fakellm\"}", keep_alive);
        } else if (strncmp(req, "GET /v1/models", 14) == 0) {
            handle_models(fd, keep_alive);
        } else if (strncmp(req, "POST /v1/chat/completions", 25) == 0) {
            handle_completion(fd, &rp, keep_alive);
        } else if (strncmp(req, "POST /v1/embeddings", 19) == 0) {
            handle_embeddings(fd, &rp, keep_alive);
        } else {
            send_json(fd, 404, "Not Found", "{\"error\":{\"message\":\"unknown route\"}}", keep_alive);
        }

        /* A streamed response ends the connection: re-using it would require tracking chunked
         * framing state that buys nothing for a load target. */
        if (rp.stream || !keep_alive) goto done;
    }

done:
    free(req);
    close(fd);
    return NULL;
}

static void usage(const char *prog) {
    fprintf(stderr,
            "usage: %s [options]\n"
            "\n"
            "  --port N                 listen port (default 18080)\n"
            "  --host ADDR              bind address (default 127.0.0.1)\n"
            "  --ttft-ms MS             simulated time to first token (default 20)\n"
            "  --tokens-per-second N    simulated token rate (default 1000)\n"
            "  --tokens N               tokens per response (default 64)\n"
            "  --model NAME             model id to advertise (default fakellm)\n"
            "  --prompt-tokens N        prompt_tokens to report (default 16)\n"
            "  --verbose                log each request\n"
            "\n"
            "Per-request overrides in the JSON body: fake_ttft_ms, fake_tokens_per_second,\n"
            "fake_tokens. max_tokens also sets the token count, so an ordinary OpenAI client\n"
            "controls response length without knowing this is a fake.\n"
            "\n"
            "Binds to localhost by default and has no authentication. Do not expose it.\n",
            prog);
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        int has_next = (i + 1 < argc);
        if (!strcmp(a, "--port") && has_next) cfg.port = atoi(argv[++i]);
        else if (!strcmp(a, "--host") && has_next) cfg.host = argv[++i];
        else if (!strcmp(a, "--ttft-ms") && has_next) cfg.ttft_ms = atof(argv[++i]);
        else if (!strcmp(a, "--tokens-per-second") && has_next) cfg.tokens_per_second = atof(argv[++i]);
        else if (!strcmp(a, "--tokens") && has_next) cfg.tokens = atoi(argv[++i]);
        else if (!strcmp(a, "--model") && has_next) cfg.model = argv[++i];
        else if (!strcmp(a, "--prompt-tokens") && has_next) cfg.prompt_tokens = atoi(argv[++i]);
        else if (!strcmp(a, "--verbose")) cfg.verbose = 1;
        else if (!strcmp(a, "--help") || !strcmp(a, "-h")) { usage(argv[0]); return 0; }
        else { fprintf(stderr, "unknown option: %s\n", a); usage(argv[0]); return 2; }
    }

    if (cfg.tokens_per_second <= 0) {
        fprintf(stderr, "--tokens-per-second must be > 0\n");
        return 2;
    }

    signal(SIGPIPE, SIG_IGN);
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) {
        perror("socket");
        return 1;
    }
    int one = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)cfg.port);
    if (inet_pton(AF_INET, cfg.host, &addr.sin_addr) != 1) {
        fprintf(stderr, "bad --host: %s\n", cfg.host);
        return 2;
    }

    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        perror("bind");
        return 1;
    }
    if (listen(listen_fd, 512) != 0) {
        perror("listen");
        return 1;
    }

    fprintf(stderr, "[fakellm] http://%s:%d model=%s ttft=%.1fms rate=%.0ftok/s tokens=%d\n",
            cfg.host, cfg.port, cfg.model, cfg.ttft_ms, cfg.tokens_per_second, cfg.tokens);

    while (running) {
        int fd = accept(listen_fd, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR) continue;
            if (!running) break;
            perror("accept");
            continue;
        }
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

        pthread_t tid;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        if (pthread_create(&tid, &attr, connection_thread, (void *)(intptr_t)fd) != 0) {
            close(fd);
        }
        pthread_attr_destroy(&attr);
    }

    close(listen_fd);
    return 0;
}
