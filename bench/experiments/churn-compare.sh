#!/usr/bin/env bash
# 对比两个 3h 窗口：[0h,3h] 含 3 个批次，[3h,6h] 只含 1 个批次。
# 先实测各窗口内有数据的 series 数，确认实验确实生效，再比耗时。
set -uo pipefail
: "${START:?需要 churn-run.log 里的 START_UNIX}"
Q='histogram_quantile(0.9, sum by(le, path) (rate(codelab_api_request_duration_seconds_bucket{path=~"/api/service-1"}[5m])))'
NAMES="prometheus mimir o2-parquet o2-vortex"
BASES="http://perf-prometheus-standalone.perf-prometheus.svc.cluster.local:9090
http://perf-mimir-standalone.perf-mimir.svc.cluster.local:9009/prometheus
http://o2-openobserve-standalone.perf-o2-parquet.svc.cluster.local:5080/api/default/prometheus
http://o2-openobserve-standalone.perf-o2-vortex.svc.cluster.local:5080/api/default/prometheus"

for phase in "0h-3h|$START|$(( START + 10800 ))" "3h-6h|$(( START + 10800 ))|$(( START + 21600 ))"; do
  IFS='|' read -r lbl s e <<< "$phase"
  echo "=== 窗口 $lbl ==="
  i=0
  echo "$BASES" | while read -r b; do
    i=$((i+1)); n=$(echo $NAMES | cut -d' ' -f$i); A=""
    case $i in 3|4) A="--user root@example.com:Complexpass#123";; esac
    card=$(curl -sS --max-time 120 $A --data-urlencode 'query=count(codelab_api_request_duration_seconds_bucket)' \
      --data-urlencode "start=$(( e - 120 ))" --data-urlencode "end=$e" --data-urlencode 'step=60s' \
      "$b/api/v1/query_range" 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);r=(d.get("data") or {}).get("result") or [];v=(r[0].get("values") if r else None) or [];print(int(float(v[-1][1])) if v else 0)')
    t=$(curl -sS --max-time 300 -o /dev/null -w '%{time_total}' $A \
      --data-urlencode "query=$Q" --data-urlencode "start=$s" --data-urlencode "end=$e" \
      --data-urlencode 'step=15s' "$b/api/v1/query_range" 2>/dev/null)
    printf '  %-12s 窗口末基数=%9s  耗时=%8.2fs\n' "$n" "$card" "$t"
  done
done
