#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

helm repo add openobserve https://charts.openobserve.ai >/dev/null 2>&1 || true
helm repo update openobserve

kubectl create ns perf-o2-parquet --dry-run=client -o yaml | kubectl apply -f -

# Release name `o2` is load-bearing: it makes the Service
# o2-openobserve-standalone, which is what the collector's exporter endpoint
# points at.
helm --namespace perf-o2-parquet -f values.yaml \
  upgrade --install o2 openobserve/openobserve-standalone

kubectl -n perf-o2-parquet rollout status sts/o2-openobserve-standalone --timeout=10m

cat <<'EOF'

perf-o2-parquet is up.
  write: http://o2-openobserve-standalone.perf-o2-parquet.svc.cluster.local:5080/api/default/prometheus/api/v1/write
  query: http://o2-openobserve-standalone.perf-o2-parquet.svc.cluster.local:5080/api/default/prometheus/api/v1/query_range

Confirm the file format actually took effect:
  kubectl -n perf-o2-parquet exec sts/o2-openobserve-standalone -- printenv ZO_FILE_FORMAT
EOF
