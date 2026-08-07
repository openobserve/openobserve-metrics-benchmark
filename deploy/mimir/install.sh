#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

kubectl apply -f deploy.yaml
kubectl -n perf-mimir rollout status sts/mimir-standalone --timeout=10m

cat <<'EOF'

perf-mimir is up.
  write: http://perf-mimir-standalone.perf-mimir.svc.cluster.local:9009/api/v1/push
  query: http://perf-mimir-standalone.perf-mimir.svc.cluster.local:9009/prometheus/api/v1/query_range
EOF
