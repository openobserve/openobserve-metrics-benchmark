#!/usr/bin/env bash
# Does OpenObserve's query time depend on samples, output points, or series?
#
# Every window here sits wholly inside batch 4 (17:03:42-20:03:42 CST), so the
# series count is pinned at 452,400 throughout and cannot confound anything.
# That leaves samples and output points, which are varied independently by
# changing the width and the step together:
#
#   window        step   points   samples    isolates
#   18:00-19:00    15s      240    108.6M    baseline
#   18:00-20:00    30s      240    217.2M    2x SAMPLES at constant points
#   18:00-20:00    15s      480    217.2M    2x POINTS  at constant samples
#   19:00-20:00    15s      240    108.6M    position control vs baseline
#
# If time tracks samples:  row2 = 2x row1, row3 = row2.
# If time tracks points:   row2 = row1,    row3 = 2x row2.
set -uo pipefail
cd "$(dirname "$0")"
# shellcheck source=../config.sh
source ../config.sh

: "${RUNS:=9}"
: "${WARMUP_RUNS:=1}"
QUERY='histogram_quantile(0.9, sum by(le, path) (rate(codelab_api_request_duration_seconds_bucket{path=~"/api/service-1"}[5m])))'
METRIC='codelab_api_request_duration_seconds_bucket'

# label|start|end|step|width_seconds
CASES=(
  "18-19 @15s|1786356000|1786359600|15|3600"
  "18-20 @30s|1786356000|1786363200|30|7200"
  "18-20 @15s|1786356000|1786363200|15|7200"
  "19-20 @15s|1786359600|1786363200|15|3600"
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
  local base="$1" auth="$2" s="$3" e="$4" st="$5"
  local a=() out code secs
  [[ -n "$auth" ]] && a=(--user "$auth")
  out="$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time "${CURL_TIMEOUT}" \
    ${a[@]+"${a[@]}"} --data-urlencode "query=${QUERY}" \
    --data-urlencode "start=${s}" --data-urlencode "end=${e}" --data-urlencode "step=${st}" \
    "${base}/api/v1/query_range" 2>/dev/null)" || true
  [[ "$out" == *" "* ]] || { echo err; return; }
  code="${out%% *}"; secs="${out##* }"
  [[ "$code" == "200" ]] || { echo err; return; }
  python3 -c "import sys;print(round(float(sys.argv[1])*1000))" "$secs"
}

med() { python3 -c '
import sys,statistics
v=[int(x) for x in sys.argv[1:] if x.isdigit()]
print(round(statistics.median(v)) if v else "err")' "$@"; }

echo "series pinned at 452,400 (all windows inside batch 4); runs=${RUNS}"
echo
printf '%-12s %-12s %8s %8s %12s\n' "case" "system" "points" "step" "samples"
for c in "${CASES[@]}"; do
  IFS='|' read -r lbl s e st w <<< "$c"
  for entry in "${SYSTEMS[@]}"; do
    IFS='|' read -r sys base auth <<< "$entry"
    [[ "$sys" == o2-* ]] || continue
    smp="$(scalar_at "$base" "$auth" "sum(count_over_time(${METRIC}[${w}s]))" "$e")"
    ser="$(scalar_at "$base" "$auth" "count(count_over_time(${METRIC}[${w}s]))" "$e")"
    printf '%-12s %-12s %8s %8s %12s   series=%s\n' "$lbl" "$sys" "$(( w / st ))" "${st}s" "$smp" "$ser"
  done
done

echo
echo "=== latency (ms) ==="
printf '%-12s %-12s %8s   %s\n' "case" "system" "median" "runs"
declare -a R=()
for c in "${CASES[@]}"; do
  IFS='|' read -r lbl s e st w <<< "$c"
  for entry in "${SYSTEMS[@]}"; do
    IFS='|' read -r sys base auth <<< "$entry"
    [[ "$sys" == o2-* ]] || continue
    for (( i=0; i<WARMUP_RUNS; i++ )); do timed "$base" "$auth" "$s" "$e" "$st" >/dev/null; done
    r=(); for (( i=0; i<RUNS; i++ )); do r+=("$(timed "$base" "$auth" "$s" "$e" "$st")"); done
    m="$(med "${r[@]}")"
    printf '%-12s %-12s %8s   %s\n' "$lbl" "$sys" "$m" "${r[*]}"
    R+=("${lbl}|${sys}|${m}")
  done
done

echo
echo "=== verdict ==="
for entry in "${SYSTEMS[@]}"; do
  IFS='|' read -r sys base auth <<< "$entry"
  [[ "$sys" == o2-* ]] || continue
  g() { local k="$1" x; for x in "${R[@]}"; do [[ "$x" == "${k}|${sys}|"* ]] && { echo "${x##*|}"; return; }; done; echo err; }
  b="$(g '18-19 @15s')"; s2="$(g '18-20 @30s')"; p2="$(g '18-20 @15s')"; ctl="$(g '19-20 @15s')"
  python3 - "$sys" "$b" "$s2" "$p2" "$ctl" <<'PY'
import sys
name,b,s2,p2,ctl = sys.argv[1:6]
b,s2,p2,ctl = (int(x) for x in (b,s2,p2,ctl))
print(f"  {name}")
print(f"    control  (same everything, later hour) {ctl:>6} vs {b:<6} = {ctl/b:.2f}x  <- noise floor")
print(f"    2x SAMPLES at constant points          {s2:>6} vs {b:<6} = {s2/b:.2f}x")
print(f"    2x POINTS  at constant samples         {p2:>6} vs {s2:<6} = {p2/s2:.2f}x")
PY
done
