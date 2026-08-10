#!/usr/bin/env bash
# Series counts and label values, per system.
#
# Run this BEFORE comparing latencies. If the systems disagree on cardinality,
# they did not receive the same data and the latency numbers mean nothing.
#
#   ./cardinality.sh          # series counts for the metrics under test
#   ./cardinality.sh paths    # list the `path` label values in use
#
# The counts are taken at END_TIME (default: 5 minutes ago), not at "now". On a
# frozen dataset -- ingestion stopped, which is when the benchmark actually runs
# -- an instant query at "now" falls outside every lookback window and every
# system correctly answers zero. Point END_TIME inside the data:
#
#   END_TIME=1786276800 ./cardinality.sh
#   END_TIME=2026-08-09T20:00:00+08:00 ./cardinality.sh
set -uo pipefail

cd "$(dirname "$0")"
# shellcheck source=config.sh
source ./config.sh

command -v python3 >/dev/null || die "python3 not found"

AT_TS="$(resolve_end_time)"

# Instant query against one system; prints the scalar result or an error.
q() {
  local base="$1" auth="$2" promql="$3"
  local auth_args=()
  [[ -n "${auth}" ]] && auth_args=(--user "${auth}")
  # ${arr[@]+"${arr[@]}"} expands a possibly-empty array safely under `set -u`.
  curl -sS --max-time "${CURL_TIMEOUT}" ${auth_args[@]+"${auth_args[@]}"} \
    --data-urlencode "query=${promql}" \
    --data-urlencode "time=${AT_TS}" \
    "${base}/api/v1/query" 2>/dev/null \
  | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("(no/invalid response)"); raise SystemExit
if d.get("status") != "success":
    print("ERROR: " + " ".join(str(d.get("error") or d.get("message") or "?").split())[:90]); raise SystemExit
r = (d.get("data") or {}).get("result") or []
if not r:
    print("(empty)"); raise SystemExit
first = r[0]
# Instant queries return "value": [ts, "n"]. Some backends answer a range
# instead, in which case take the last point.
if "value" in first:
    n = first["value"][1]
elif first.get("values"):
    n = first["values"][-1][1]
else:
    print("(unrecognised result shape)"); raise SystemExit
print(f"{int(float(n)):,}")
'
}

if [[ "${1:-}" == "paths" ]]; then
  IFS='|' read -r sys base auth <<< "${SYSTEMS[0]}"
  echo "==> distinct \`path\` label values on ${sys}"
  auth_args=()
  [[ -n "${auth}" ]] && auth_args=(--user "${auth}")
  curl -sS --max-time "${CURL_TIMEOUT}" ${auth_args[@]+"${auth_args[@]}"} \
    "${base}/api/v1/label/path/values" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); v=d.get("data") or []; print(f"count: {len(v)}"); [print(" ", x) for x in sorted(v)]'
  exit 0
fi

METRICS=(
  "codelab_api_request_duration_seconds_bucket"
  "codelab_api_request_duration_seconds_count"
  "codelab_api_requests_total"
)

echo "==> counts as of ${AT_TS} ($(python3 -c "import datetime,sys;print(datetime.datetime.fromtimestamp(int(sys.argv[1])).isoformat())" "${AT_TS}") local)"
echo
printf '%-14s %s\n' "system" "series count"
for metric in "${METRICS[@]}"; do
  echo
  echo "### ${metric}"
  for entry in "${SYSTEMS[@]}"; do
    IFS='|' read -r sys base auth <<< "${entry}"
    printf '  %-14s ' "${sys}"
    q "${base}" "${auth}" "count(${metric})"
  done
done

echo
echo "### total active series (all metrics)"
for entry in "${SYSTEMS[@]}"; do
  IFS='|' read -r sys base auth <<< "${entry}"
  printf '  %-14s ' "${sys}"
  q "${base}" "${auth}" 'count({__name__=~".+"})'
done

cat <<'EOF'

For reference, the published run measured:
  codelab_api_request_duration_seconds_bucket   1,085,760 series
  codelab_api_request_duration_seconds_count       41,760 series
The bucket count is exactly 26x the _count -- the histogram has 25 explicit
buckets plus +Inf. If your ratio is not 26, your load generator differs.

Cardinality scales linearly with fake-webserver replicas: measured at ~45,220
bucket and ~1,739 _count series per pod. deploy/fake-webserver/deploy.yaml ships
24 replicas, which is what puts the bucket metric over a million series. Scale
that value for a different series count -- the same cluster at 20 replicas
measured 904,410 bucket and 1,013,150 total active series.
EOF
