#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

helm repo add vm https://victoriametrics.github.io/helm-charts/ >/dev/null 2>&1 || true
helm repo update vm

kubectl create ns perf-vm --dry-run=client -o yaml | kubectl apply -f -

helm --namespace perf-vm -f values.yaml \
  upgrade --install vms vm/victoria-metrics-single

kubectl -n perf-vm rollout status sts/vms-victoria-metrics-single-server --timeout=10m

cat <<'EOF'

perf-vm is up.
  write: http://vms-victoria-metrics-single-server.perf-vm.svc.cluster.local:8428/api/v1/write
  query: http://vms-victoria-metrics-single-server.perf-vm.svc.cluster.local:8428/api/v1/query_range

Confirm it is storing on the instance store and not the root volume -- the
mount must be /dev/nvme*, and /storage (the chart's unused emptyDir) must stay
empty:
  kubectl -n perf-vm exec sts/vms-victoria-metrics-single-server -- \
    sh -c 'df -h /nvme; ls /nvme'
EOF
