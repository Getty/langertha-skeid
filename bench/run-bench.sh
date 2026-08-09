#!/usr/bin/env bash
#
# One benchmark run: baseline against fakellm, then the same client through a proxy.
# The delta is the answer -- a proxy number alone says nothing.
#
#   ./run-bench.sh                        # measure Skeid, starting it for you
#   ./run-bench.sh --proxy-port 4000 --no-start   # measure something already running
#
# Anything that speaks the OpenAI API can be the target, so comparing against LiteLLM, a vLLM
# router or any other gateway is this same script with --no-start and their port. Point that
# gateway at fakellm on --upstream-port and every system sees an identical model.
#
# Resource discipline: this saturates a machine. One run at a time, never in the background,
# and write the concurrency you used into whatever you report.

set -euo pipefail

cd "$(dirname "$0")"

UPSTREAM_PORT=18080
PROXY_PORT=18090
REQUESTS=200
CONCURRENCY=8
TOKENS=64
TTFT_MS=20
RATE=1000
START_PROXY=1
LABEL="Skeid"
JSON_OUT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --upstream-port) UPSTREAM_PORT="$2"; shift 2 ;;
    --proxy-port)    PROXY_PORT="$2"; shift 2 ;;
    --requests)      REQUESTS="$2"; shift 2 ;;
    --concurrency)   CONCURRENCY="$2"; shift 2 ;;
    --tokens)        TOKENS="$2"; shift 2 ;;
    --ttft-ms)       TTFT_MS="$2"; shift 2 ;;
    --rate)          RATE="$2"; shift 2 ;;
    --label)         LABEL="$2"; shift 2 ;;
    --no-start)      START_PROXY=0; shift ;;
    --json)          JSON_OUT=1; shift ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

make --no-print-directory >/dev/null

REV="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
DIRTY=""
git diff --quiet 2>/dev/null || DIRTY=" +dirty"

cleanup() {
  [ -n "${FAKE_PID:-}" ] && kill "$FAKE_PID" 2>/dev/null || true
  [ -n "${PROXY_PID:-}" ] && kill "$PROXY_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Wait for a port to answer instead of sleeping a guessed amount. A fixed sleep is how a run
# ends up reporting "0 ok, 5ms" -- which reads like a catastrophic result rather than a server
# that had not finished binding.
wait_for_health() {
  local port="$1" name="$2" i
  for i in $(seq 1 100); do
    if curl -sf -m 1 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  echo "$name did not become healthy on port $port" >&2
  exit 1
}

echo "== fakellm: ttft=${TTFT_MS}ms rate=${RATE}tok/s tokens=${TOKENS} =="
./fakellm --port "$UPSTREAM_PORT" --ttft-ms "$TTFT_MS" --tokens-per-second "$RATE" \
          --tokens "$TOKENS" >/dev/null 2>&1 &
FAKE_PID=$!
wait_for_health "$UPSTREAM_PORT" fakellm

if [ "$START_PROXY" = "1" ]; then
  echo "== skeid: git ${REV}${DIRTY} =="
  ( cd .. && exec perl -Ilib bin/skeid serve --listen "127.0.0.1:$PROXY_PORT" \
      --config bench/skeid.bench.yaml ) >/dev/null 2>&1 &
  PROXY_PID=$!
  wait_for_health "$PROXY_PORT" skeid
fi

FLAGS="--requests $REQUESTS --concurrency $CONCURRENCY --tokens $TOKENS"
[ "$JSON_OUT" = "1" ] && FLAGS="$FLAGS --json"

for mode in "" "--stream"; do
  mode_name="json"
  [ -n "$mode" ] && mode_name="stream"

  nice -n 19 ionice -c3 ./llmbench --port "$UPSTREAM_PORT" $FLAGS $mode \
    --label "baseline fakellm direct | $mode_name | c=$CONCURRENCY"
  nice -n 19 ionice -c3 ./llmbench --port "$PROXY_PORT" $FLAGS $mode \
    --label "$LABEL | $mode_name | c=$CONCURRENCY | git $REV$DIRTY"
done
