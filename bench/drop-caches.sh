#!/usr/bin/env bash
# Drops the OS page cache on the node hosting a system under test, so the next
# query is genuinely COLD.
#
#   ./drop-caches.sh o2-vortex
#   ./drop-caches.sh o2-vortex && QUERY_FILTER=histogram-regex SYSTEMS_FILTER=o2-vortex RUNS=1 ./run-benchmark.sh
#
# This is what produced the article's cold-vs-hot observation: the 3h histogram
# runs ~2s hot and ~30s cold on gp3 at its default 125 MB/s, because the query
# has to pull ~3.6GB of compressed data off the disk and 3.6GB / 125 MB/s ~= 29s.
# On io2 the same cold query dropped to ~3.5s.
#
# WARNING: this evicts the page cache for EVERYTHING on that node, not just the
# system you name. Only run it on a dedicated benchmark node.
set -euo pipefail

# Namespaces default to what deploy/ installs, but are overridable for a
# deployment that drifted:
#   O2_PARQUET_NS=perf-o21 O2_VORTEX_NS=perf-o22 ./drop-caches.sh o2-parquet
: "${PROM_NS:=perf-prometheus}"
: "${MIMIR_NS:=perf-mimir}"
: "${O2_PARQUET_NS:=perf-o2-parquet}"
: "${O2_VORTEX_NS:=perf-o2-vortex}"

case "${1:-}" in
  prometheus) NS="${PROM_NS}";       POD=prometheus-standalone-0 ;;
  mimir)      NS="${MIMIR_NS}";      POD=mimir-standalone-0 ;;
  o2-parquet) NS="${O2_PARQUET_NS}"; POD=o2-openobserve-standalone-0 ;;
  o2-vortex)  NS="${O2_VORTEX_NS}";  POD=o2-openobserve-standalone-0 ;;
  all)        NS=""; POD="" ;;
  *) echo "usage: $0 {prometheus|mimir|o2-parquet|o2-vortex|all}" >&2; exit 1 ;;
esac

# `all` drops the cache on every benchmark node, which is what you want between
# rounds of a cold comparison -- dropping only one node's cache would leave the
# other three warm and make the comparison meaningless.
if [[ "${1}" == "all" ]]; then
  for sys in prometheus mimir o2-parquet o2-vortex; do
    "$0" "${sys}"
  done
  exit 0
fi

NODE="$(kubectl -n "${NS}" get pod "${POD}" -o jsonpath='{.spec.nodeName}')"
[[ -n "${NODE}" ]] || { echo "could not resolve node for ${NS}/${POD}" >&2; exit 1; }

echo "==> dropping page cache on ${NODE} (host of ${NS}/${POD})"

# --profile=sysadmin gives the debug pod host namespaces and the privileges
# needed to write to /proc/sys. It leaves a pod behind on the node; it is
# removed below.
DEBUG_POD="drop-caches-$(date +%s)"
kubectl debug "node/${NODE}" \
  --image=public.ecr.aws/docker/library/busybox:1.36.1 \
  --profile=sysadmin \
  -q --attach=false \
  --container=drop-caches \
  "--" sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches; echo dropped' \
  >/dev/null 2>&1 || true

# kubectl debug names the pod node-debug-<node>-xxxxx; find and follow the newest.
POD_NAME="$(kubectl -n default get pods --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep '^node-debug-' | tail -1)"

if [[ -n "${POD_NAME}" ]]; then
  kubectl -n default wait --for=condition=Ready "pod/${POD_NAME}" --timeout=60s >/dev/null 2>&1 || true
  kubectl -n default logs "${POD_NAME}" 2>/dev/null || true
  kubectl -n default delete pod "${POD_NAME}" --wait=false >/dev/null 2>&1 || true
fi

echo "==> done. The next query against ${NS} reads from disk, not page cache."
echo "    If your cluster blocks 'kubectl debug --profile=sysadmin', run this on"
echo "    the node instead:  sync; echo 3 > /proc/sys/vm/drop_caches"
