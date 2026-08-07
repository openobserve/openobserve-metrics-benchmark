#!/usr/bin/env bash
# Installs the OTel Collector that feeds all four systems under test.
#
# Prerequisites installed here if missing:
#   - cert-manager               (required by the OpenTelemetry Operator manifest)
#   - opentelemetry-operator     (this chart renders OpenTelemetryCollector CRs)
#
# Run this LAST, after prometheus/, mimir/, openobserve-parquet/ and
# openobserve-vortex/ are up -- the exporters point at their Services, and a
# collector started against missing backends just spends its first minutes
# retrying.
set -euo pipefail
cd "$(dirname "$0")"

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.16.1}"

if ! kubectl get ns cert-manager >/dev/null 2>&1; then
  echo "==> installing cert-manager ${CERT_MANAGER_VERSION}"
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
  kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=5m
else
  echo "==> cert-manager already present, skipping"
fi

if ! kubectl get crd opentelemetrycollectors.opentelemetry.io >/dev/null 2>&1; then
  echo "==> installing opentelemetry-operator"
  kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
  kubectl -n opentelemetry-operator-system rollout status deploy/opentelemetry-operator-controller-manager --timeout=5m
else
  echo "==> opentelemetry-operator already present, skipping"
fi

helm repo add openobserve https://charts.openobserve.ai >/dev/null 2>&1 || true
helm repo update openobserve

kubectl create ns openobserve-collector --dry-run=client -o yaml | kubectl apply -f -

helm --namespace openobserve-collector \
  -f collector-values.yaml \
  upgrade --install o2c openobserve/openobserve-collector

cat <<'EOF'

Collector installed. Confirm the rendered config has exactly ONE pipeline
(metrics/perf_fakeserver) on each collector:

  kubectl -n openobserve-collector get otelcol -o yaml | grep -A 12 'pipelines:'

Then watch for scrape/export errors:

  kubectl -n openobserve-collector logs -l app.kubernetes.io/name=openobserve-collector --tail=100 -f
EOF
