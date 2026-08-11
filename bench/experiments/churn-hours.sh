#!/usr/bin/env bash
# Round-hour re-measurement of the churn dataset (run-b).
#
# The first pass anchored its windows to when the load generator came up
# (:03:42 past the hour). That put the batch boundaries INSIDE the windows and
# straddled Prometheus/Mimir TSDB block boundaries, which are cut on
# epoch-aligned 2h marks. Both are removed here by using round hours.
#
# Ingestion ran 14:03:42 -> 20:03:42 CST with the load generator restarted on
# the hour+3:42, so each clock hour holds either two batches or one:
#
#   15:00-16:00  batches 1+2   ~900k series
#   16:00-17:00  batches 2+3   ~900k
#   17:00-18:00  batches 3+4   ~900k
#   18:00-19:00  batch 4 only  ~452k
#   19:00-20:00  batch 4 only  ~452k
#
# Two things fall out of that:
#
#   CONTROL      18:00-19:00 vs 19:00-20:00 -- same width, step, series and
#                samples, differing only in position. This is the control the
#                first pass failed to build. It must read ~1.00x.
#   SERIES TEST  16:00-17:00 vs 18:00-19:00 -- ~2x the series at the same width,
#                step and per-series depth.
set -uo pipefail
cd "$(dirname "$0")"
# shellcheck source=../config.sh
source ../config.sh

: "${STEP_FIXED:=15}"
: "${RUNS:=5}"
: "${WARMUP_RUNS:=1}"

QUERY='histogram_quantile(0.9, sum by(le, path) (rate(codelab_api_request_duration_seconds_bucket{path=~"/api/service-1"}[5m])))'
METRIC='codelab_api_request_duration_seconds_bucket'
H14=1786341600      # 14:00:00 CST 2026-08-10

WINDOWS_SPEC=()
for hh in 15 16 17 18 19; do
  s=$(( H14 + (hh - 14) * 3600 ))
  WINDOWS_SPEC+=( "${hh}:00-$((hh+1)):00|${s}|$(( s + 3600 ))|3600" )
done

scalar_at() {
  local base="$1" auth="$2" promql="$3" at="$4"
  local a=(); [[ -n "${auth}" ]] && a=(--user "${auth}")
  curl -sS --max-time 600 ${a[@]+"${a[@]}"} \
    --data-urlencode "query=${promql}" --data-urlencode "time=${at}" \
    "${base}/api/v1/query" 2>/dev/null \
  | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print(-1); raise SystemExit
if d.get("status")!="success": print(-1); raise SystemExit
r=(d.get("data") or {}).get("result") or []
print(int(float(r[0]["value"][1])) if r else 0)' 2>/dev/null || echo -1
}

timed() {
  local base="$1" auth="$2" s="$3" e="$4"
  local a=() out code secs
  [[ -n "${auth}" ]] && a=(--user "${auth}")
  out="$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time "${CURL_TIMEOUT}" \
    ${a[@]+"${a[@]}"} --data-urlencode "query=${QUERY}" \
    --data-urlencode "start=${s}" --data-urlencode "end=${e}" \
    --data-urlencode "step=${STEP_FIXED}" \
    "${base}/api/v1/query_range" 2>/dev/null)" || true
  [[ "${out}" == *" "* ]] || { echo err; return; }
  code="${out%% *}"; secs="${out##* }"
  [[ "${code}" == "200" ]] || { echo err; return; }
  python3 -c "import sys;print(round(float(sys.argv[1])*1000))" "${secs}"
}

med() { python3 -c '
import sys,statistics
v=[int(x) for x in sys.argv[1:] if x.isdigit()]
print(round(statistics.median(v)) if v else "err")' "$@"; }

echo "round-hour churn re-measurement -- step=${STEP_FIXED}s, runs=${RUNS}"
echo
echo "=== series and samples per clock hour ==="
printf '%-13s %-12s %12s %14s\n' "hour (CST)" "system" "series" "samples"
for spec in "${WINDOWS_SPEC[@]}"; do
  IFS='|' read -r lbl s e w <<< "${spec}"
  for entry in "${SYSTEMS[@]}"; do
    IFS='|' read -r sys base auth <<< "${entry}"
    ser="$(scalar_at "${base}" "${auth}" "count(count_over_time(${METRIC}[${w}s]))" "${e}")"
    smp="$(scalar_at "${base}" "${auth}" "sum(count_over_time(${METRIC}[${w}s]))" "${e}")"
    printf '%-13s %-12s %12s %14s\n' "${lbl}" "${sys}" "${ser}" "${smp}"
  done
done

echo
echo "=== latency, median of ${RUNS} warm runs (ms) ==="
printf '%-13s %-12s %8s   %s\n' "hour (CST)" "system" "median" "runs"
declare -a S=()
for spec in "${WINDOWS_SPEC[@]}"; do
  IFS='|' read -r lbl s e w <<< "${spec}"
  for entry in "${SYSTEMS[@]}"; do
    IFS='|' read -r sys base auth <<< "${entry}"
    for (( i=0; i<WARMUP_RUNS; i++ )); do timed "${base}" "${auth}" "${s}" "${e}" >/dev/null; done
    r=(); for (( i=0; i<RUNS; i++ )); do r+=("$(timed "${base}" "${auth}" "${s}" "${e}")"); done
    m="$(med "${r[@]}")"
    printf '%-13s %-12s %8s   %s\n' "${lbl}" "${sys}" "${m}" "${r[*]}"
    S+=("${lbl}|${sys}|${m}")
  done
done

echo
echo "=== the two ratios that matter ==="
printf '%-12s %10s %10s %9s   %10s %10s %9s\n' \
  "system" "16:00-17" "18:00-19" "SERIES" "18:00-19" "19:00-20" "CONTROL"
for entry in "${SYSTEMS[@]}"; do
  IFS='|' read -r sys base auth <<< "${entry}"
  g() { local k="$1" x; for x in "${S[@]}"; do [[ "${x}" == "${k}|${sys}|"* ]] && { echo "${x##*|}"; return; }; done; echo err; }
  a="$(g '16:00-17:00')"; b="$(g '18:00-19:00')"; c="$(g '19:00-20:00')"
  rt() { python3 -c '
import sys
x,y=sys.argv[1:3]
print(f"{int(x)/int(y):.2f}x" if x.isdigit() and y.isdigit() and int(y) else "-")' "$1" "$2"; }
  printf '%-12s %10s %10s %9s   %10s %10s %9s\n' \
    "${sys}" "${a}" "${b}" "$(rt "${a}" "${b}")" "${b}" "${c}" "$(rt "${b}" "${c}")"
done

cat <<'EOF2'

CONTROL (18:00-19:00 vs 19:00-20:00) must read ~1.00x: both windows sit wholly
inside batch 4 and are identical in width, step, series and samples. If it does
not, position alone is moving the numbers and the SERIES column means nothing.

SERIES (16:00-17:00 vs 18:00-19:00) is ~2x the series at equal width, step and
per-series depth -- the comparison the first pass failed to isolate.
EOF2
