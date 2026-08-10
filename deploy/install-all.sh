#!/usr/bin/env bash
# Installs the benchmark in dependency order, stopping after the four systems
# under test so you can confirm they are healthy before any load arrives.
#
#   ./install-all.sh                                    # NVMe + the four systems
#   INSTALL_LOAD=1 ./install-all.sh                     # ... + fake-webserver
#   INSTALL_LOAD=1 INSTALL_COLLECTOR=1 ./install-all.sh # ... + the collector
#
# Two components are opt-in on purpose:
#
#   fake-webserver  is the load. Once it is up, every system is being written
#                   to and the run has effectively started -- so it is worth
#                   confirming all four are healthy first. Ready is also not
#                   steady: WAL replay, block loading and the first compaction
#                   happen after the readiness probe passes, and load applied
#                   during that window hits each system in a different state.
#
#   otel-collector  otel-collector/install.sh runs `helm upgrade --install -f
#                   collector-values.yaml`, which replaces the release's values
#                   wholesale. On a cluster whose collector also carries other
#                   telemetry, that silently deletes those pipelines. Enable it
#                   only for a collector dedicated to this benchmark.
#
# local-nvme always runs first: a system that starts before the mount exists
# binds its hostPath to the directory underneath and keeps that view, writing
# to the root EBS volume while appearing to use NVMe.
set -euo pipefail
cd "$(dirname "$0")"

: "${STABILIZE_SECS:=120}"
: "${INSTALL_LOAD:=0}"
: "${INSTALL_COLLECTOR:=0}"

echo "======================================================================"
echo "==> local-nvme"
echo "======================================================================"
kubectl apply -f local-nvme/mount-nvme.yaml
kubectl -n kube-system rollout status ds/mount-nvme --timeout=5m

# Refuse to continue on a missing mount. This failure mode is silent at
# runtime: the benchmark would run to completion and report numbers for the
# root EBS volume.
echo
echo "==> verifying the instance store is mounted on every node"
bad=0
for pod in $(kubectl -n kube-system get pods -l app=mount-nvme -o name); do
  node="$(kubectl -n kube-system get "${pod}" -o jsonpath='{.spec.nodeName}')"
  line="$(kubectl -n kube-system exec "${pod}" -- \
    nsenter -t 1 -m -- df -h --output=source,size,target /mnt/k8s-disks/0 2>/dev/null | tail -1)"
  case "${line}" in
    /dev/nvme*) echo "    ok   ${node%%.*}  ${line}" ;;
    *)          echo "    FAIL ${node%%.*}  ${line:-no output}"; bad=1 ;;
  esac
done
if [[ "${bad}" != "0" ]]; then
  echo
  echo "error: at least one node is not backed by its instance store." >&2
  echo "  Installing now would benchmark the root EBS volume instead." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 1 · the four systems under test. Each install.sh waits for its rollout.
# ---------------------------------------------------------------------------
for step in prometheus mimir openobserve-parquet openobserve-vortex; do
  echo
  echo "======================================================================"
  echo "==> ${step}"
  echo "======================================================================"
  "./${step}/install.sh"
done

echo
echo "======================================================================"
echo "==> the four systems are installed"
echo "======================================================================"
for ns in perf-prometheus perf-mimir perf-o2-parquet perf-o2-vortex; do
  kubectl -n "${ns}" get pods --no-headers 2>/dev/null | sed 's/^/    /'
done

if [[ "${INSTALL_LOAD}" != "1" ]]; then
  cat <<'EOF'

======================================================================
STOPPING HERE. No load is running yet.

Confirm all four are healthy, then start the load:

  # pods Ready, no restarts
  kubectl get pods -A | grep perf-

  # each answers a query (nothing to return yet -- it should not error)
  bench/run-in-cluster.sh --script cardinality.sh

  # writing to NVMe, not the root volume
  kubectl -n kube-system exec ds/mount-nvme -- \
    nsenter -t 1 -m -- df -h /mnt/k8s-disks/0

Then:

  INSTALL_LOAD=1 ./install-all.sh     # re-runs the above as no-ops, adds load
  # or just:
  ./fake-webserver/install.sh
======================================================================
EOF
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 2 · the load
# ---------------------------------------------------------------------------
echo
echo "==> letting the four systems settle for ${STABILIZE_SECS}s before load"
sleep "${STABILIZE_SECS}"

echo
echo "======================================================================"
echo "==> fake-webserver (the load)"
echo "======================================================================"
./fake-webserver/install.sh

# ---------------------------------------------------------------------------
# Step 3 · the collector (optional)
# ---------------------------------------------------------------------------
if [[ "${INSTALL_COLLECTOR}" == "1" ]]; then
  echo
  echo "======================================================================"
  echo "==> otel-collector"
  echo "======================================================================"
  ./otel-collector/install.sh
else
  cat <<'EOF'

======================================================================
==> otel-collector SKIPPED
======================================================================
Nothing reaches the four systems until a collector scrapes perf-fakeserver
and writes to them.

Dedicated collector:

  INSTALL_COLLECTOR=1 ./otel-collector/install.sh

Shared collector -- do NOT run that, it drops every pipeline not in
otel-collector/collector-values.yaml. Edit the live values instead:

  helm -n openobserve-collector get values o2c > /tmp/o2c.yaml
  # add the four exporters + the metrics/perf_fakeserver pipeline
  helm -n openobserve-collector upgrade o2c openobserve/openobserve-collector -f /tmp/o2c.yaml
EOF
fi

cat <<'EOF'

======================================================================
Installed.

Now wait. The widest query window needs at least that much data on top of
the cardinality ramp-up, so a 6-hour window wants ~7 hours of ingestion.

The four must agree on cardinality, or they did not receive the same input
and no latency comparison means anything:

  bench/run-in-cluster.sh --script cardinality.sh

Confirm it is landing on NVMe. `Used` should climb:

  kubectl -n kube-system exec ds/mount-nvme -- \
    nsenter -t 1 -m -- df -h /mnt/k8s-disks/0

The instance store is EPHEMERAL. If a node is replaced, that system's
dataset is gone and the run starts over.
======================================================================
EOF
