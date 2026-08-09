/*
 * llmbench -- measure TTFT and token throughput against any OpenAI-compatible endpoint.
 *
 * Reports distributions, not means. A mean TTFT hides exactly what a proxy benchmark is
 * looking for: the tail where one blocked request stalled twenty others. p50 tells you the
 * common case, p99 tells you whether the event loop ever stopped turning.
 *
 * The same binary points at fakellm directly or at a proxy in front of it, which is the whole
 * method -- the number that means anything is the delta between those two runs.
 *
 * See docs/adr/0007-benchmarks-use-a-deterministic-fake-model.md.
 */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define RESP_BUF_SIZE (1 << 20)

static struct {
    const char *host;
    int port;
    const char *path;
    const char *model;
    const char *api_key;
    const char *key_id;
    int concurrency;
    int requests;
    int tokens;
    int stream;
    int warmup;
    int json_out;
    const char *label;
} cfg = {
    .host = "127.0.0.1",
    .port = 18080,
    .path = "/v1/chat/completions",
    .model = "fakellm",
    .api_key = NULL,
    .key_id = NULL,
    .concurrency = 1,
    .requests = 100,
    .tokens = 64,
    .stream = 0,
    .warmup = 5,
    .json_out = 0,
    .label = "",
};

typedef struct {
    double ttft_ms;      /* request write -> first content byte */
    double total_ms;     /* request write -> last byte */
    int tokens;          /* content chunks seen (streaming) or reported completion tokens */
    int status;
    int ok;
} sample;

static sample *samples;
static int sample_count;
static pthread_mutex_t sample_lock = PTHREAD_MUTEX_INITIALIZER;
static int next_request;
static pthread_mutex_t work_lock = PTHREAD_MUTEX_INITIALIZER;

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

static int claim_request(void) {
    pthread_mutex_lock(&work_lock);
    int i = next_request < cfg.requests ? next_request++ : -1;
    pthread_mutex_unlock(&work_lock);
    return i;
}

static void record(sample s) {
    pthread_mutex_lock(&sample_lock);
    samples[sample_count++] = s;
    pthread_mutex_unlock(&sample_lock);
}

static int connect_target(void) {
    char port_str[16];
    snprintf(port_str, sizeof(port_str), "%d", cfg.port);

    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(cfg.host, port_str, &hints, &res) != 0) return -1;

    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) {
        freeaddrinfo(res);
        return -1;
    }
    if (connect(fd, res->ai_addr, res->ai_addrlen) != 0) {
        close(fd);
        freeaddrinfo(res);
        return -1;
    }
    freeaddrinfo(res);

    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    return fd;
}

static int write_all(int fd, const char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n > 0) { off += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        return -1;
    }
    return 0;
}

/* True once the response carries something a user could see. For a stream that is the first
 * SSE frame with non-empty delta content; for a plain JSON response it is the whole body, so
 * TTFT and total coincide. Counting headers as "first token" would flatter every proxy. */
static int has_content(const char *buf, size_t len, int stream) {
    if (stream) {
        const char *p = memmem(buf, len, "\"content\":\"", 11);
        if (!p) return 0;
        return p[11] != '"';
    }
    return memmem(buf, len, "\"content\"", 9) != NULL;
}

static int parse_status(const char *buf, size_t len) {
    if (len < 12 || strncmp(buf, "HTTP/1.", 7) != 0) return 0;
    return atoi(buf + 9);
}

static int count_stream_tokens(const char *buf, size_t len) {
    int count = 0;
    const char *p = buf;
    const char *end = buf + len;
    while (p < end) {
        const char *hit = memmem(p, (size_t)(end - p), "\"content\":\"", 11);
        if (!hit) break;
        if (hit[11] != '"') count++;
        p = hit + 11;
    }
    return count;
}

static int parse_completion_tokens(const char *buf, size_t len) {
    const char *p = memmem(buf, len, "\"completion_tokens\":", 20);
    if (!p) return 0;
    return atoi(p + 20);
}

static void run_one(int record_it) {
    sample s = {0};
    int fd = connect_target();
    if (fd < 0) {
        s.ok = 0;
        if (record_it) record(s);
        return;
    }

    char body[1024];
    int blen = snprintf(body, sizeof(body),
                        "{\"model\":\"%s\",\"max_tokens\":%d,\"stream\":%s,"
                        "\"messages\":[{\"role\":\"user\",\"content\":\"benchmark\"}]}",
                        cfg.model, cfg.tokens, cfg.stream ? "true" : "false");

    char req[2048];
    int rlen = snprintf(req, sizeof(req),
                        "POST %s HTTP/1.1\r\n"
                        "Host: %s:%d\r\n"
                        "Content-Type: application/json\r\n"
                        "Content-Length: %d\r\n"
                        "%s%s%s"
                        "%s%s%s"
                        "Connection: close\r\n"
                        "\r\n%s",
                        cfg.path, cfg.host, cfg.port, blen,
                        cfg.api_key ? "Authorization: Bearer " : "", cfg.api_key ? cfg.api_key : "",
                        cfg.api_key ? "\r\n" : "",
                        cfg.key_id ? "x-skeid-key-id: " : "", cfg.key_id ? cfg.key_id : "",
                        cfg.key_id ? "\r\n" : "",
                        body);

    double start = now_ms();
    if (write_all(fd, req, (size_t)rlen) != 0) {
        close(fd);
        s.ok = 0;
        if (record_it) record(s);
        return;
    }

    char *buf = malloc(RESP_BUF_SIZE);
    if (!buf) {
        close(fd);
        return;
    }
    size_t len = 0;
    double first_content = 0;

    for (;;) {
        ssize_t n = read(fd, buf + len, RESP_BUF_SIZE - 1 - len);
        if (n <= 0) break;
        len += (size_t)n;
        if (first_content == 0 && has_content(buf, len, cfg.stream)) {
            first_content = now_ms();
        }
        if (len >= RESP_BUF_SIZE - 1) break;
    }
    double end = now_ms();
    close(fd);

    s.status = parse_status(buf, len);
    s.ttft_ms = (first_content > 0 ? first_content : end) - start;
    s.total_ms = end - start;
    s.tokens = cfg.stream ? count_stream_tokens(buf, len) : parse_completion_tokens(buf, len);
    s.ok = (s.status == 200 && first_content > 0) ? 1 : 0;

    free(buf);
    if (record_it) record(s);
}

static void *worker(void *arg) {
    (void)arg;
    for (;;) {
        int i = claim_request();
        if (i < 0) break;
        run_one(1);
    }
    return NULL;
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static double percentile(double *sorted, int n, double p) {
    if (n <= 0) return 0;
    double idx = p * (double)(n - 1);
    int lo = (int)idx;
    int hi = lo + 1 < n ? lo + 1 : lo;
    double frac = idx - (double)lo;
    return sorted[lo] * (1.0 - frac) + sorted[hi] * frac;
}

static void usage(const char *prog) {
    fprintf(stderr,
            "usage: %s [options]\n"
            "\n"
            "  --host ADDR          target host (default 127.0.0.1)\n"
            "  --port N             target port (default 18080)\n"
            "  --path PATH          endpoint (default /v1/chat/completions)\n"
            "  --model NAME         model to request (default fakellm)\n"
            "  --tokens N           max_tokens per request (default 64)\n"
            "  --requests N         total requests (default 100)\n"
            "  --concurrency N      concurrent connections (default 1)\n"
            "  --stream             use SSE streaming\n"
            "  --warmup N           unmeasured requests first (default 5)\n"
            "  --api-key KEY        Authorization: Bearer KEY\n"
            "  --key-id ID          x-skeid-key-id header\n"
            "  --label TEXT         label for the report\n"
            "  --json               machine-readable output\n"
            "\n"
            "Measure the upstream directly first, then through the proxy with identical\n"
            "flags. The delta is the answer; a single run in isolation is not.\n",
            prog);
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        int has_next = (i + 1 < argc);
        if (!strcmp(a, "--host") && has_next) cfg.host = argv[++i];
        else if (!strcmp(a, "--port") && has_next) cfg.port = atoi(argv[++i]);
        else if (!strcmp(a, "--path") && has_next) cfg.path = argv[++i];
        else if (!strcmp(a, "--model") && has_next) cfg.model = argv[++i];
        else if (!strcmp(a, "--tokens") && has_next) cfg.tokens = atoi(argv[++i]);
        else if (!strcmp(a, "--requests") && has_next) cfg.requests = atoi(argv[++i]);
        else if (!strcmp(a, "--concurrency") && has_next) cfg.concurrency = atoi(argv[++i]);
        else if (!strcmp(a, "--stream")) cfg.stream = 1;
        else if (!strcmp(a, "--warmup") && has_next) cfg.warmup = atoi(argv[++i]);
        else if (!strcmp(a, "--api-key") && has_next) cfg.api_key = argv[++i];
        else if (!strcmp(a, "--key-id") && has_next) cfg.key_id = argv[++i];
        else if (!strcmp(a, "--label") && has_next) cfg.label = argv[++i];
        else if (!strcmp(a, "--json")) cfg.json_out = 1;
        else if (!strcmp(a, "--help") || !strcmp(a, "-h")) { usage(argv[0]); return 0; }
        else { fprintf(stderr, "unknown option: %s\n", a); usage(argv[0]); return 2; }
    }

    if (cfg.requests < 1 || cfg.concurrency < 1) {
        fprintf(stderr, "--requests and --concurrency must be >= 1\n");
        return 2;
    }

    signal(SIGPIPE, SIG_IGN);

    samples = calloc((size_t)cfg.requests, sizeof(sample));
    if (!samples) return 1;

    /* Warm-up requests are discarded: the first connection to a freshly started proxy pays for
     * lazy initialisation that no later request repeats, and leaving it in the sample makes
     * p99 a story about startup. */
    for (int i = 0; i < cfg.warmup; i++) run_one(0);

    double wall_start = now_ms();

    pthread_t *threads = calloc((size_t)cfg.concurrency, sizeof(pthread_t));
    if (!threads) return 1;
    for (int i = 0; i < cfg.concurrency; i++) pthread_create(&threads[i], NULL, worker, NULL);
    for (int i = 0; i < cfg.concurrency; i++) pthread_join(threads[i], NULL);

    double wall_ms = now_ms() - wall_start;
    free(threads);

    int ok = 0, failed = 0, total_tokens = 0;
    double *ttft = calloc((size_t)sample_count, sizeof(double));
    double *total = calloc((size_t)sample_count, sizeof(double));
    int n = 0;
    for (int i = 0; i < sample_count; i++) {
        if (!samples[i].ok) { failed++; continue; }
        ok++;
        total_tokens += samples[i].tokens;
        ttft[n] = samples[i].ttft_ms;
        total[n] = samples[i].total_ms;
        n++;
    }

    qsort(ttft, (size_t)n, sizeof(double), cmp_double);
    qsort(total, (size_t)n, sizeof(double), cmp_double);

    double rps = wall_ms > 0 ? (double)ok / (wall_ms / 1000.0) : 0;
    double tps = wall_ms > 0 ? (double)total_tokens / (wall_ms / 1000.0) : 0;

    if (cfg.json_out) {
        printf("{\"label\":\"%s\",\"target\":\"%s:%d%s\",\"stream\":%s,\"concurrency\":%d,"
               "\"requests\":%d,\"ok\":%d,\"failed\":%d,\"wall_ms\":%.1f,"
               "\"ttft_ms\":{\"p50\":%.2f,\"p95\":%.2f,\"p99\":%.2f,\"min\":%.2f,\"max\":%.2f},"
               "\"total_ms\":{\"p50\":%.2f,\"p95\":%.2f,\"p99\":%.2f},"
               "\"requests_per_second\":%.1f,\"tokens_per_second\":%.1f,\"tokens\":%d}\n",
               cfg.label, cfg.host, cfg.port, cfg.path, cfg.stream ? "true" : "false",
               cfg.concurrency, cfg.requests, ok, failed, wall_ms,
               percentile(ttft, n, 0.50), percentile(ttft, n, 0.95), percentile(ttft, n, 0.99),
               n ? ttft[0] : 0, n ? ttft[n - 1] : 0,
               percentile(total, n, 0.50), percentile(total, n, 0.95), percentile(total, n, 0.99),
               rps, tps, total_tokens);
    } else {
        printf("\n");
        if (cfg.label[0]) printf("  %s\n", cfg.label);
        printf("  target        http://%s:%d%s\n", cfg.host, cfg.port, cfg.path);
        printf("  mode          %s, concurrency %d, %d requests, %d max_tokens\n",
               cfg.stream ? "stream" : "json", cfg.concurrency, cfg.requests, cfg.tokens);
        printf("  ok / failed   %d / %d\n", ok, failed);
        printf("  wall          %.0f ms\n", wall_ms);
        printf("  TTFT ms       p50 %.2f   p95 %.2f   p99 %.2f   min %.2f   max %.2f\n",
               percentile(ttft, n, 0.50), percentile(ttft, n, 0.95), percentile(ttft, n, 0.99),
               n ? ttft[0] : 0, n ? ttft[n - 1] : 0);
        printf("  total ms      p50 %.2f   p95 %.2f   p99 %.2f\n",
               percentile(total, n, 0.50), percentile(total, n, 0.95), percentile(total, n, 0.99));
        printf("  throughput    %.1f req/s   %.0f tok/s   (%d tokens)\n", rps, tps, total_tokens);
        printf("\n");
    }

    free(ttft);
    free(total);
    free(samples);
    return failed > 0 ? 1 : 0;
}
