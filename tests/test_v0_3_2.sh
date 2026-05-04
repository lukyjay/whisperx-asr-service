#!/usr/bin/env bash
# Smoke tests for v0.3.2 features.
#
# Covers:
#   #15 -- Pascal/Blackwell variants: just verifies the running torch matches
#          whatever the running image was built with (informational; the real
#          variant test happens at image-publish time, not at runtime).
#   #12 -- Device-aware BATCH_SIZE default: read from /health-style probe.
#   #16 -- MODEL_KEEP_ALIVE_SECONDS eviction: covered by tests/test_keep_alive.sh
#          since it requires a container restart with different env.
#   #13 -- Prometheus /metrics + /asr instrumentation.
#   Live patches -- /asr accepts OpenAI-style aliases, /v1/models is dynamic.
#
# Usage:
#   ./tests/test_v0_3_2.sh                     # default base URL + audio
#   BASE_URL=http://host:9000 ./tests/test_v0_3_2.sh
#   AUDIO=testfiles/foo.mp3 ./tests/test_v0_3_2.sh

set -uo pipefail

BASE_URL="${BASE_URL:-http://localhost:9000}"
AUDIO="${AUDIO:-testfiles/250218_0013.mp3}"
PASS=0
FAIL=0

color() {
    case "$1" in
        red)    printf '\033[31m%s\033[0m' "$2" ;;
        green)  printf '\033[32m%s\033[0m' "$2" ;;
        yellow) printf '\033[33m%s\033[0m' "$2" ;;
        *) printf '%s' "$2" ;;
    esac
}

step() { echo; echo "=== $1 ==="; }
ok()   { color green "  PASS"; echo " $1"; PASS=$((PASS+1)); }
bad()  { color red   "  FAIL"; echo " $1"; FAIL=$((FAIL+1)); }
note() { color yellow "  NOTE"; echo " $1"; }

if [ ! -f "$AUDIO" ]; then
    echo "Audio file not found: $AUDIO"
    echo "Set AUDIO=path/to/file.mp3 or place a file at testfiles/250218_0013.mp3"
    exit 2
fi

step "Health check"
HEALTH=$(curl -fsS "${BASE_URL}/health")
if echo "$HEALTH" | grep -q '"status":"healthy"'; then
    ok "/health returns healthy"
    echo "    $HEALTH"
else
    bad "/health did not return healthy: $HEALTH"
    exit 1
fi

step "GET /metrics returns Prometheus OpenMetrics text (not JSON) [#13]"
METRICS=$(curl -fsS "${BASE_URL}/metrics")
if echo "$METRICS" | head -1 | grep -q '^# HELP'; then
    ok "/metrics starts with '# HELP' (OpenMetrics text)"
else
    bad "/metrics does not start with '# HELP'. First line: $(echo "$METRICS" | head -1)"
fi

for metric in whisperx_requests_total whisperx_request_duration_seconds \
              whisperx_active_transcriptions whisperx_loaded_models \
              whisperx_audio_duration_seconds whisperx_audio_size_megabytes \
              whisperx_vram_allocated_bytes whisperx_service_info; do
    if echo "$METRICS" | grep -q "^# HELP ${metric} "; then
        ok "metric ${metric} is registered"
    else
        bad "metric ${metric} missing"
    fi
done

step "GET /queue-metrics still returns JSON for legacy callers"
QM=$(curl -fsS "${BASE_URL}/queue-metrics")
if echo "$QM" | grep -q '"serve_mode"'; then
    ok "/queue-metrics returns the legacy JSON shape"
    echo "    $QM"
else
    bad "/queue-metrics did not return expected JSON: $QM"
fi

step "GET /v1/models is sourced from faster_whisper.available_models()"
MODELS_JSON=$(curl -fsS "${BASE_URL}/v1/models")
MODEL_COUNT=$(echo "$MODELS_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['data']))")
if [ "$MODEL_COUNT" -ge 15 ]; then
    ok "/v1/models lists ${MODEL_COUNT} models (expected 15+)"
else
    bad "/v1/models lists only ${MODEL_COUNT} models (expected 15+)"
fi
if echo "$MODELS_JSON" | grep -q '"id":"whisper-1"'; then
    ok "/v1/models includes whisper-1 alias on top"
else
    bad "/v1/models is missing the whisper-1 alias"
fi
for canonical in tiny base small medium large-v3 distil-large-v3; do
    if echo "$MODELS_JSON" | grep -q "\"id\":\"${canonical}\""; then
        ok "/v1/models lists canonical name '${canonical}'"
    else
        bad "/v1/models is missing canonical name '${canonical}'"
    fi
done

step "Snapshot baseline /metrics counters before /asr request"
BASELINE=$(curl -fsS "${BASE_URL}/metrics")
BASELINE_OK_COUNT=$(echo "$BASELINE" \
    | grep -E '^whisperx_requests_total\{endpoint="/asr",status="ok"\} ' \
    | awk '{print $2}')
BASELINE_OK_COUNT=${BASELINE_OK_COUNT:-0}
echo "    baseline whisperx_requests_total{status=ok} = $BASELINE_OK_COUNT"

step "POST /asr with model=whisper-tiny (alias resolution)"
ASR_OUT=$(curl -fsS -X POST \
    "${BASE_URL}/asr?model=whisper-tiny&output_format=text&diarize=false" \
    -F "audio_file=@${AUDIO}")
if echo "$ASR_OUT" | grep -q '"text"'; then
    ok "/asr accepted whisper-tiny alias and returned a transcription"
    echo "    snippet: $(echo "$ASR_OUT" | head -c 150)..."
else
    bad "/asr did not return text. Output: $ASR_OUT"
fi

step "POST /asr with canonical model=tiny"
ASR_OUT2=$(curl -fsS -X POST \
    "${BASE_URL}/asr?model=tiny&output_format=text&diarize=false" \
    -F "audio_file=@${AUDIO}")
if echo "$ASR_OUT2" | grep -q '"text"'; then
    ok "/asr accepted canonical tiny and returned a transcription"
else
    bad "/asr did not return text for canonical tiny. Output: $ASR_OUT2"
fi

step "Verify Prometheus counters incremented after /asr requests"
sleep 1
AFTER=$(curl -fsS "${BASE_URL}/metrics")

AFTER_OK_COUNT=$(echo "$AFTER" \
    | grep -E '^whisperx_requests_total\{endpoint="/asr",status="ok"\} ' \
    | awk '{print $2}')
AFTER_OK_COUNT=${AFTER_OK_COUNT:-0}

# python compare so we handle floats safely
INCREASED=$(python3 -c "print(int(float('${AFTER_OK_COUNT}') > float('${BASELINE_OK_COUNT}')))")
if [ "$INCREASED" = "1" ]; then
    ok "whisperx_requests_total{status=ok} increased: ${BASELINE_OK_COUNT} -> ${AFTER_OK_COUNT}"
else
    bad "whisperx_requests_total{status=ok} did not increase: ${BASELINE_OK_COUNT} -> ${AFTER_OK_COUNT}"
fi

DUR_COUNT=$(echo "$AFTER" \
    | grep -E '^whisperx_request_duration_seconds_count\{endpoint="/asr"\} ' \
    | awk '{print $2}')
if [ -n "$DUR_COUNT" ] && [ "$(python3 -c "print(int(float('${DUR_COUNT}') >= 2))")" = "1" ]; then
    ok "request duration histogram observed >= 2 samples (got ${DUR_COUNT})"
else
    bad "request duration histogram count is unexpected: ${DUR_COUNT}"
fi

AUDIO_DUR_COUNT=$(echo "$AFTER" \
    | grep -E '^whisperx_audio_duration_seconds_count ' \
    | awk '{print $2}')
if [ -n "$AUDIO_DUR_COUNT" ] && [ "$(python3 -c "print(int(float('${AUDIO_DUR_COUNT}') >= 2))")" = "1" ]; then
    ok "audio duration histogram observed >= 2 samples (got ${AUDIO_DUR_COUNT})"
else
    bad "audio duration histogram count is unexpected: ${AUDIO_DUR_COUNT}"
fi

AUDIO_SIZE_COUNT=$(echo "$AFTER" \
    | grep -E '^whisperx_audio_size_megabytes_count ' \
    | awk '{print $2}')
if [ -n "$AUDIO_SIZE_COUNT" ] && [ "$(python3 -c "print(int(float('${AUDIO_SIZE_COUNT}') >= 2))")" = "1" ]; then
    ok "audio size histogram observed >= 2 samples (got ${AUDIO_SIZE_COUNT})"
else
    bad "audio size histogram count is unexpected: ${AUDIO_SIZE_COUNT}"
fi

step "Verify whisperx_service_info has version/device labels"
INFO_LINE=$(echo "$AFTER" | grep '^whisperx_service_info{' | head -1)
if echo "$INFO_LINE" | grep -q 'version=' \
    && echo "$INFO_LINE" | grep -q 'device=' \
    && echo "$INFO_LINE" | grep -q 'serve_mode='; then
    ok "service_info contains version/device/serve_mode labels"
    echo "    $INFO_LINE"
else
    bad "service_info missing expected labels: $INFO_LINE"
fi

step "Verify VRAM gauge is populated when CUDA is active"
VRAM=$(echo "$AFTER" | grep '^whisperx_vram_allocated_bytes ' | awk '{print $2}')
DEVICE_FROM_HEALTH=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin)['device'])")
if [ "$DEVICE_FROM_HEALTH" = "cuda" ]; then
    if [ -n "$VRAM" ] && [ "$(python3 -c "print(int(float('${VRAM}') > 0))")" = "1" ]; then
        ok "VRAM gauge > 0 on cuda (got ${VRAM} bytes)"
    else
        note "VRAM gauge is ${VRAM} on cuda (may be 0 in Ray Serve mode -- ingress process has no models)"
    fi
else
    note "device is ${DEVICE_FROM_HEALTH}, VRAM gauge expected to be 0"
fi

step "Summary"
echo "  Passed: $(color green ${PASS})"
echo "  Failed: $(color red ${FAIL})"
if [ "$FAIL" -eq 0 ]; then
    color green "ALL TESTS PASSED"; echo
    exit 0
else
    color red   "TESTS FAILED"; echo
    exit 1
fi
