#!/usr/bin/env bash
# Does OpenObserve's query cost track the series count in the window?
#
# Four 3-hour round-hour windows over the churn dataset (run-b). All are the
# same width, take the same 15s step and therefore return the same 720 output
# points; only the number of distinct series inside them changes:
#
#   17:00-20:00   batches 3,4        ~904,800 series   1.0x
#   14:00-17:00   batches 1,2,3    ~1,357,200 series   1.5x
#   16:00-19:00   batches 2,3,4    ~1,357,200 series   1.5x
#   15:00-18:00   batches 1,2,3,4  ~1,809,600 series   2.0x
#
# 14:00-17:00 and 16:00-19:00 carry the SAME series count at different points on
# the timeline, so the pair is a free control: it must read ~1.00x, and whatever
# it does read is the noise floor the other ratios have to clear.
#
# Runs are reported in full, not just the median. O2 Parquet was the one cell in
# the previous pass that came back bimodal (2611-4113 ms on an otherwise <2%
# system), and a median would hide that.
set -uo pipefail
cd "$(dirname "$0")"
# shellcheck source=../config.sh
source ../config.sh

: "${STEP_FIXED:=15}"
: "${RUNS:=9}"
: "${WARMUP_RUNS:=1}"

QUERY='histogram_quantile(0.9, sum by(le, path) (rate(codelab_api_request_duration_seconds_bucket{path=~"/api/service-1"}[5m])))'
METRIC='codelab_api_request_duration_seconds_bucket'

WINDOWS_SPEC=(
  "17:00-20:00|1786352400|1786363200"
  "14:00-17:00|1786341600|1786352400"
  "16:00-19:00|1786348800|1786359600"
  "15:00-18:00|1786345200|1786356000"
)

scalar_at() {
  local base="$1" auth="$2" q="$3" at="$4"
  local a=(); [[ -n "$auth" ]] && a=(--user "$auth")
  curl -sS --max-time 900 ${a[@]+"${a[@]}"} \
    --data-urlencode "query=${q}" --data-urlencode "time=${at}" \
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
  [[ -n "$auth" ]] && a=(--user "$auth")
  out="$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time "${CURL_TIMEOUT}" \
    ${a[@]+"${a[@]}"} --data-urlencode "query=${QUERY}" \
    --data-urlencode "start=${s}" --data-urlencode "end=${e}" \
    --data-urlencode "step=${STEP_FIXED}" \
    "${base}/api/v1/query_range" 2>/dev/null)" || true
  [[ "$out" == *" "* ]] || { echo err; return; }
  code="${out%% *}"; secs="${out##* }"
  [[ "$code" == "200" ]] || { echo err; return; }
  python3 -c "import sys;print(round(float(sys.argv[1])*1000))" "$secs"
}

stats() { python3 -c '
import sys,statistics
v=[int(x) for x in sys.argv[1:] if x.isdigit()]
if not v: print("err err err"); raise SystemExit
print(f"{round(statistics.median(v))} {min(v)} {max(v)}")' "$@"; }

echo "series sensitivity -- four 3h round-hour windows, step=${STEP_FIXED}s, 720 points each, runs=${RUNS}"
echo
echo "=== what is actually in each window ==="
printf '%-13s %-12s %12s %14s\n' "window (CST)" "system" "series" "samples"
for spec in "${WINDOWS_SPEC[@]}"; do
  IFS='|' read -r lbl s e <<< "$spec"
  for entry in "${SYSTEMS[@]}"; do
    IFS='|' read -r sys base auth <<< "$entry"
    ser="$(scalar_at "$base" "$auth" "count(count_over_time(${METRIC}[10800s]))" "$e")"
    smp="$(scalar_at "$base" "$auth" "sum(count_over_time(${METRIC}[10800s]))" "$e")"
    printf '%-13s %-12s %12s %14s\n' "$lbl" "$sys" "$ser" "$smp"
  done
done

echo
echo "=== latency (ms): median, min, max, then every run ==="
printf '%-13s %-12s %8s %7s %7s   %s\n' "window (CST)" "system" "median" "min" "max" "runs"
declare -a R=()
for spec in "${WINDOWS_SPEC[@]}"; do
  IFS='|' read -r lbl s e <<< "$spec"
  for entry in "${SYSTEMS[@]}"; do
    IFS='|' read -r sys base auth <<< "$entry"
    for (( i=0; i<WARMUP_RUNS; i++ )); do timed "$base" "$auth" "$s" "$e" >/dev/null; done
    r=(); for (( i=0; i<RUNS; i++ )); do r+=("$(timed "$base" "$auth" "$s" "$e")"); done
    read -r m lo hi <<< "$(stats "${r[@]}")"
    printf '%-13s %-12s %8s %7s %7s   %s\n' "$lbl" "$sys" "$m" "$lo" "$hi" "${r[*]}"
    R+=("${lbl}|${sys}|${m}")
  done
done

echo
echo "=== series scaling, normalised to the 904,800-series window ==="
printf '%-12s %12s %12s %12s %12s   %s\n' \
  "system" "904,800" "1,357,200a" "1,357,200b" "1,809,600" "CONTROL a/b"
for entry in "${SYSTEMS[@]}"; do
  IFS='|' read -r sys base auth <<< "$entry"
  g() { local k="$1" x; for x in "${R[@]}"; do [[ "$x" == "${k}|${sys}|"* ]] && { echo "${x##*|}"; return; }; done; echo err; }
  b1="$(g '17:00-20:00')"; a1="$(g '14:00-17:00')"; a2="$(g '16:00-19:00')"; c1="$(g '15:00-18:00')"
  rel() { python3 -c '
import sys
x,y=sys.argv[1:3]
print(f"{int(x)} ({int(x)/int(y):.2f}x)" if x.isdigit() and y.isdigit() and int(y) else "-")' "$1" "$2"; }
  rt() { python3 -c '
import sys
x,y=sys.argv[1:3]
print(f"{int(x)/int(y):.2f}x" if x.isdigit() and y.isdigit() and int(y) else "-")' "$1" "$2"; }
  printf '%-12s %12s %12s %12s %12s   %s\n' "$sys" \
    "$b1" "$(rel "$a1" "$b1")" "$(rel "$a2" "$b1")" "$(rel "$c1" "$b1")" "$(rt "$a1" "$a2")"
done

cat <<'EOF2'

CONTROL a/b compares two windows holding the SAME 1,357,200 series at different
positions. It must read ~1.00x; whatever it does read is the noise floor, and a
series-scaling ratio only means something if it clears that floor.

If cost tracked series count proportionally, the columns would read
1.00x / 1.50x / 1.50x / 2.00x.
EOF2
