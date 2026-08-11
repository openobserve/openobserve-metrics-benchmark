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
# All 2h wide, all step 30s -> 240 output points, all ~217M samples.
# Only the series count changes. Two pairs carry identical series at different
# positions and act as controls.
CASES=(
  "18-20  452k|1786356000|1786363200|30|7200"
  "17-19  905k|1786352400|1786359600|30|7200"
  "14-16  905k|1786341600|1786348800|30|7200"
  "16-18 1357k|1786348800|1786356000|30|7200"
  "15-17 1357k|1786345200|1786352400|30|7200"
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
echo "=== series scaling at constant 2h width / 240 points / ~217M samples ==="
for entry in "${SYSTEMS[@]}"; do
  IFS='|' read -r sys base auth <<< "$entry"
  [[ "$sys" == o2-* ]] || continue
  g() { local k="$1" x; for x in "${R[@]}"; do [[ "$x" == "${k}|${sys}|"* ]] && { echo "${x##*|}"; return; }; done; echo err; }
  python3 - "$sys" "$(g '18-20  452k')" "$(g '17-19  905k')" "$(g '14-16  905k')" "$(g '16-18 1357k')" "$(g '15-17 1357k')" <<'PY2'
import sys
n,b,a1,a2,c1,c2 = sys.argv[1:7]
b,a1,a2,c1,c2 = (int(x) for x in (b,a1,a2,c1,c2))
print(f"  {n}")
print(f"    452,400 series   {b:>6} ms   1.00x")
print(f"    904,800 series   {a1:>6} / {a2:<6} ms   {a1/b:.2f}x / {a2/b:.2f}x   (control {a1/a2:.2f}x)")
print(f"  1,357,200 series   {c1:>6} / {c2:<6} ms   {c1/b:.2f}x / {c2/b:.2f}x   (control {c1/c2:.2f}x)")
print(f"    if cost tracked series: 1.00x / 2.00x / 3.00x")
PY2
done
