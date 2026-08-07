#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

kubectl apply -f deploy.yaml
kubectl -n perf-prometheus rollout status sts/prometheus-standalone --timeout=10m

cat <<'EOF'

perf-prometheus is up.
  write: http://perf-prometheus-standalone.perf-prometheus.svc.cluster.local:9090/api/v1/write
  query: http://perf-prometheus-standalone.perf-prometheus.svc.cluster.local:9090/api/v1/query_range
EOF
