#!/usr/bin/env bash
# NVMe + the four systems, then stops; INSTALL_LOAD=1 adds the backfill.
set -euo pipefail
cd "$(dirname "$0")"

: "${STABILIZE_SECS:=120}"
: "${INSTALL_LOAD:=0}"

echo "======================================================================"
echo "==> local-nvme"
echo "======================================================================"
kubectl apply -f local-nvme/mount-nvme.yaml
kubectl -n kube-system rollout status ds/mount-nvme --timeout=5m

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

for step in prometheus mimir victoriametrics openobserve-parquet; do
  echo
  echo "======================================================================"
  echo "==> ${step}"
  echo "======================================================================"
  "./${step}/install.sh"
done

echo
echo "======================================================================"
echo "==> the systems under test are installed"
echo "======================================================================"
for ns in perf-prometheus perf-mimir perf-vm perf-o2-parquet; do
  kubectl -n "${ns}" get pods --no-headers 2>/dev/null | sed 's/^/    /'
done

if [[ "${INSTALL_LOAD}" != "1" ]]; then
  cat <<'EOF'

======================================================================
STOPPING HERE. No load is running yet.

Confirm they are all healthy, then start the load:

  # pods Ready, no restarts
  kubectl get pods -A | grep perf-

  # each answers a query (nothing to return yet -- it should not error)
  bench/run-in-cluster.sh --script cardinality.sh

  # writing to NVMe, not the root volume
  kubectl -n kube-system exec ds/mount-nvme -- \
    nsenter -t 1 -m -- df -h /mnt/k8s-disks/0

OpenObserve must have ZO_COMPACT_ENABLED=false for the backfill (see its
values files). Then:

  INSTALL_LOAD=1 ./install-all.sh     # re-runs the above as no-ops, runs the backfill
  # or just:
  ./fake-webserver/install.sh         # BACKFILL_START / _HOURS / _STEP / _SEED
======================================================================
EOF
  exit 0
fi

echo
echo "==> letting the systems settle for ${STABILIZE_SECS}s before load"
sleep "${STABILIZE_SECS}"

echo
echo "======================================================================"
echo "==> fake-webserver backfill (the load)"
echo "======================================================================"
./fake-webserver/install.sh

cat <<'EOF'

======================================================================
Loaded. Follow the steps fake-webserver/install.sh printed above (flush,
switch O2 compaction on, wait for it to settle), then check that all four
agree on cardinality -- if they do not, no latency comparison means anything:

  bench/run-in-cluster.sh --script cardinality.sh

The instance store is EPHEMERAL. If a node is replaced, that system's
dataset is gone and the run starts over.
======================================================================
EOF
