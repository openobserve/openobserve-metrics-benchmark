#!/usr/bin/env bash
# Manual verification of the O2 series-saturation table (dataset run-b).
#
#   kubectl -n perf-bench exec bench -- sh -c 'cat > /tmp/v.sh' < verify.sh
#   kubectl -n perf-bench exec bench -- sh /tmp/v.sh
#
# Or set BASE to a port-forwarded address and run it anywhere.
BASE="${BASE:-http://o2-openobserve-standalone.perf-o2-parquet.svc.cluster.local:5080/api/default/prometheus}"
AUTH="${AUTH:-root@example.com:Complexpass#123}"
RUNS="${RUNS:-5}"
Q='histogram_quantile(0.9, sum by(le, path) (rate(codelab_api_request_duration_seconds_bucket{path=~"/api/service-1"}[5m])))'

# label|start|end|step|width|expected_series|expected_ms
CASES='
1h  452k|1786356000|1786359600|15|3600|452400|496
1h  905k|1786345200|1786348800|15|3600|904800|937
2h  452k|1786356000|1786363200|30|7200|452400|918
2h  905k|1786352400|1786359600|30|7200|904800|1758
2h 1357k|1786348800|1786356000|30|7200|1357200|1781
3h  905k|1786352400|1786363200|15|10800|904800|2652
3h 1810k|1786345200|1786356000|15|10800|1809600|2617
'

printf '%-9s %10s %10s   %8s %8s   %s\n' "case" "series" "expected" "median" "expect" "runs"
echo "$CASES" | while IFS='|' read -r lbl s e st w xser xms; do
  [ -z "$lbl" ] && continue
  ser=$(curl -sS -u "$AUTH" --max-time 900 \
        --data-urlencode "query=count(count_over_time(codelab_api_request_duration_seconds_bucket[${w}s]))" \
        --data-urlencode "time=$e" "$BASE/api/v1/query" \
      | python3 -c 'import json,sys;r=(json.load(sys.stdin).get("data") or {}).get("result") or [];print(int(float(r[0]["value"][1])) if r else 0)')
  t=""
  i=0; while [ "$i" -lt "$RUNS" ]; do
    ms=$(curl -sS -u "$AUTH" -o /dev/null -w '%{time_total}' --max-time 900 \
         --data-urlencode "query=$Q" --data-urlencode "start=$s" \
         --data-urlencode "end=$e" --data-urlencode "step=$st" \
         "$BASE/api/v1/query_range" \
       | python3 -c 'import sys;print(round(float(sys.stdin.read())*1000))')
    t="$t $ms"; i=$((i+1))
  done
  med=$(python3 -c 'import sys,statistics;v=[int(x) for x in sys.argv[1:]];print(round(statistics.median(v)))' $t)
  printf '%-9s %10s %10s   %8s %8s   %s\n' "$lbl" "$ser" "$xser" "$med" "$xms" "$t"
done

cat <<'EOF2'

Ratios to check:
  linear     1h  905k / 1h  452k  ~ 1.89x
             2h  905k / 2h  452k  ~ 1.92x
  saturated  2h 1357k / 2h  905k  ~ 1.01x
             3h 1810k / 3h  905k  ~ 0.99x
EOF2
