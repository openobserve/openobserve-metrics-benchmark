#!/usr/bin/env bash
# Measures the churn dataset produced by churn-run.sh.
#
#   START=<START_UNIX from churn-run.log> ./churn-compare.sh
#   START=... HOUR=300 ./churn-compare.sh      # to read a rehearsal
#
# THE QUESTION
#
# When a query window holds far fewer series than the index holds, does a
# system pay for what is in the window, or for what is in the index?
#
# churn-run.sh restarts the load generator every hour for the first three
# hours, so each batch of pods contributes a distinct ~450k series that never
# reappears:
#
#   batch 1  t=0..1h    ~450k series
#   batch 2  t=1..2h    ~450k
#   batch 3  t=2..3h    ~450k
#   batch 4  t=3..6h    ~450k, alive for the last three hours
#
# THE COMPARISON
#
#   A = [0h,3h]   3 batches   ~1.35M series in window, ~1h of samples each
#   B = [3h,6h]   1 batch      ~450k series in window, ~3h of samples
#
# Both windows are three hours wide, take the same step, and therefore produce
# the same number of output points. Critically they also hold roughly the SAME
# TOTAL NUMBER OF SAMPLES -- 1.35M series x 1h against 450k series x 3h. That
# is what makes the comparison worth running:
#
#   B ~3x faster than A   ->  cost follows the SERIES count in the window
#   B ~equal to A         ->  cost follows the SAMPLE count, or the whole index
#
# An equal result does not distinguish "pays for the index" from "pays per
# sample", because this pair holds both roughly constant. Read it as "does not
# follow series count" and treat the two explanations as still open.
#
# THE CONTROLS
#
#   C = [1h,2h]   batch 2 alone
#   D = [4h,5h]   batch 4's middle hour
#
# Same width, same step, same series count, same sample count -- they differ
# only in where they sit on the timeline. C and D should measure the same. If
# they do not, something about position (compaction state, block boundaries,
# how recently the data was written) is moving the numbers, and the A/B result
# cannot be read cleanly.
#
# The step is pinned at 15s for every window here rather than taken from the
# Grafana rule, so that each comparison holds output points constant within
# itself. A and B produce 720 points each; C and D produce 240 each.
set -uo pipefail

cd "$(dirname "$0")"
# shellcheck source=../config.sh
source ../config.sh

: "${START:?set START to the START_UNIX printed in churn-run.log}"
: "${HOUR:=3600}"          # must match the churn-run.sh that built the data
: "${STEP_FIXED:=15}"
: "${RUNS:=3}"
: "${WARMUP_RUNS:=1}"

QUERY='histogram_quantile(0.9, sum by(le, path) (rate(codelab_api_request_duration_seconds_bucket{path=~"/api/service-1"}[5m])))'
METRIC='codelab_api_request_duration_seconds_bucket'

# label|start|end|width_seconds
WINDOWS_SPEC=(
  "A [0h,3h]|$(( START ))|$(( START + 3 * HOUR ))|$(( 3 * HOUR ))"
  "B [3h,6h]|$(( START + 3 * HOUR ))|$(( START + 6 * HOUR ))|$(( 3 * HOUR ))"
  "C [1h,2h]|$(( START + 1 * HOUR ))|$(( START + 2 * HOUR ))|$(( 1 * HOUR ))"
  "D [4h,5h]|$(( START + 4 * HOUR ))|$(( START + 5 * HOUR ))|$(( 1 * HOUR ))"
)

# Instant query, printing a bare integer (0 when there is no result).
scalar_at() {
  local base="$1" auth="$2" promql="$3" at="$4" timeout="$5"
  local auth_args=()
  [[ -n "${auth}" ]] && auth_args=(--user "${auth}")
  curl -sS --max-time "${timeout}" ${auth_args[@]+"${auth_args[@]}"} \
    --data-urlencode "query=${promql}" \
    --data-urlencode "time=${at}" \
    "${base}/api/v1/query" 2>/dev/null \
  | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(-1); raise SystemExit
if d.get("status") != "success":
    print(-1); raise SystemExit
r = (d.get("data") or {}).get("result") or []
print(int(float(r[0]["value"][1])) if r else 0)
' 2>/dev/null || echo -1
}

# One range query; prints elapsed milliseconds, or "err" if it did not answer.
timed_range() {
  local base="$1" auth="$2" s="$3" e="$4"
  local auth_args=() out code secs
  [[ -n "${auth}" ]] && auth_args=(--user "${auth}")
  out="$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' \
    --max-time "${CURL_TIMEOUT}" ${auth_args[@]+"${auth_args[@]}"} \
    --data-urlencode "query=${QUERY}" \
    --data-urlencode "start=${s}" --data-urlencode "end=${e}" \
    --data-urlencode "step=${STEP_FIXED}" \
    "${base}/api/v1/query_range" 2>/dev/null)" || true
  [[ "${out}" == *" "* ]] || { echo "err"; return; }
  code="${out%% *}"; secs="${out##* }"
  [[ "${code}" == "200" ]] || { echo "err"; return; }
  python3 -c "import sys;print(round(float(sys.argv[1])*1000))" "${secs}"
}

median() {
  python3 -c '
import sys, statistics
vals = [int(v) for v in sys.argv[1:] if v.isdigit()]
print(round(statistics.median(vals)) if vals else "err")
' "$@"
}

echo "churn comparison -- START=${START}, HOUR=${HOUR}s, step=${STEP_FIXED}s, runs=${RUNS}"
echo

# ---------------------------------------------------------------------------
# 1 - did the experiment actually produce the intended shape?
#
# count(count_over_time(m[width])) at the window end counts every series with
# at least one sample inside the window, which is the quantity the experiment
# turns on. Counting at the window's last instant instead would report only
# whichever batch happened to be alive then.
# ---------------------------------------------------------------------------
echo "=== series and samples inside each window ==="
printf '%-11s %-12s %14s %16s\n' "window" "system" "series" "samples"
for spec in "${WINDOWS_SPEC[@]}"; do
  IFS='|' read -r lbl s e width <<< "${spec}"
  for entry in "${SYSTEMS[@]}"; do
    IFS='|' read -r sys base auth <<< "${entry}"
    ser="$(scalar_at "${base}" "${auth}" "count(count_over_time(${METRIC}[${width}s]))" "${e}" 600)"
    smp="$(scalar_at "${base}" "${auth}" "sum(count_over_time(${METRIC}[${width}s]))" "${e}" 600)"
    printf '%-11s %-12s %14s %16s\n' "${lbl}" "${sys}" "${ser}" "${smp}"
  done
done

# ---------------------------------------------------------------------------
# 2 - latency. Warm first: a cold page cache moves these numbers by more than
# the effect being measured.
# ---------------------------------------------------------------------------
echo
echo "=== query latency, median of ${RUNS} warm runs (ms) ==="
printf '%-11s %-12s %10s   %s\n' "window" "system" "median" "runs"
declare -a summary=()
for spec in "${WINDOWS_SPEC[@]}"; do
  IFS='|' read -r lbl s e width <<< "${spec}"
  for entry in "${SYSTEMS[@]}"; do
    IFS='|' read -r sys base auth <<< "${entry}"
    for (( w = 0; w < WARMUP_RUNS; w++ )); do timed_range "${base}" "${auth}" "${s}" "${e}" >/dev/null; done
    runs=()
    for (( r = 0; r < RUNS; r++ )); do runs+=("$(timed_range "${base}" "${auth}" "${s}" "${e}")"); done
    med="$(median "${runs[@]}")"
    printf '%-11s %-12s %10s   %s\n' "${lbl}" "${sys}" "${med}" "${runs[*]}"
    summary+=("${lbl%% *}|${sys}|${med}")
  done
done

# ---------------------------------------------------------------------------
# 3 - the ratios that answer the question
# ---------------------------------------------------------------------------
echo
echo "=== ratios ==="
printf '%-12s %10s %10s %8s   %10s %10s %8s\n' \
  "system" "A [0h,3h]" "B [3h,6h]" "A/B" "C [1h,2h]" "D [4h,5h]" "C/D"
for entry in "${SYSTEMS[@]}"; do
  IFS='|' read -r sys base auth <<< "${entry}"
  get() { local k="$1"; local x; for x in "${summary[@]}"; do
            [[ "${x}" == "${k}|${sys}|"* ]] && { echo "${x##*|}"; return; }; done; echo err; }
  a="$(get A)"; b="$(get B)"; c="$(get C)"; d="$(get D)"
  ab="$(python3 -c 'import sys
a,b=sys.argv[1:3]
print(f"{int(a)/int(b):.2f}x" if a.isdigit() and b.isdigit() and int(b) else "-")' "${a}" "${b}")"
  cd_="$(python3 -c 'import sys
c,d=sys.argv[1:3]
print(f"{int(c)/int(d):.2f}x" if c.isdigit() and d.isdigit() and int(d) else "-")' "${c}" "${d}")"
  printf '%-12s %10s %10s %8s   %10s %10s %8s\n' "${sys}" "${a}" "${b}" "${ab}" "${c}" "${d}" "${cd_}"
done

cat <<'EOF'

Reading A/B:
  ~3x   cost follows the series count in the window
  ~1x   cost does not follow series count -- it follows samples scanned, or
        the size of the whole index. This pair cannot tell those two apart.

Reading C/D: should be ~1x. C and D are identical in width, step, series and
samples, differing only in position on the timeline. Anything far from 1x means
position is moving the numbers and A/B cannot be read cleanly.
EOF
