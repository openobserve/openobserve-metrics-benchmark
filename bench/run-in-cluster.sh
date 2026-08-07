#!/usr/bin/env bash
# Runs the benchmark from INSIDE the cluster, so what gets measured is the
# query and not the network.
#
# Why this exists
# ---------------
# port-forward.sh tunnels every request through the Kubernetes API server.
# Measured against the EKS cluster from a workstation, a trivial `query=1` --
# which Prometheus answers in microseconds -- costs ~1,070ms round trip. The
# identical request from a pod in the cluster costs ~5ms.
#
# So port-forward puts a ~1-2s floor under every number. That floor is NOT a
# constant you can subtract: it grows with response size, because the tunnel is
# also a throughput bottleneck. It therefore swamps a fast system and barely
# dents a slow one, compressing the systems together and destroying the ratios.
# Measured on the same irate query at the same END_TIME:
#
#              port-forward   in-cluster
#   Prometheus      3445ms       1287ms
#   Mimir           4181ms       1319ms
#   O2/Parquet      2122ms        158ms
#   O2/Vortex       1953ms        297ms
#
# A real 8.1x gap (Prometheus vs Parquet) reads as 1.6x through the tunnel. So
# neither the absolutes NOR the ordering survive a port-forwarded run.
#
# What this script does instead
#   1. starts a small pod on a node that is NOT under test -- it carries no
#      `perf` toleration, so it cannot land on the four tainted benchmark nodes
#      and steal CPU from the system it is measuring -- pinned to the same AZ
#      as the systems under test so the hop is intra-AZ (~0.3ms) for all four;
#   2. copies bench/ into it;
#   3. runs run-benchmark.sh there, against in-cluster Service DNS;
#   4. copies any results/<stamp>/ it produced back here, same layout as a
#      local run.
#
# Usage:
#   ./run-in-cluster.sh
#   RUNS=5 WINDOWS="1800 3600" ./run-in-cluster.sh
#   END_TIME=2026-08-06T03:00:00+08:00 ./run-in-cluster.sh
#   O2_PARQUET_NS=perf-o21 O2_VORTEX_NS=perf-o22 ./run-in-cluster.sh
#
#   ./run-in-cluster.sh --script cardinality.sh         # any bench/ script
#   ./run-in-cluster.sh --script cardinality.sh paths   # ...with its own args
#   ./run-in-cluster.sh --delete                        # tear the pod down
#
# --script only suits scripts that talk to the four systems over HTTP, i.e.
# run-benchmark.sh and cardinality.sh. resources.sh and drop-caches.sh drive
# kubectl instead, and the runner pod has neither the binary nor the RBAC --
# run those from your workstation, where they never needed a port-forward.
#
# The pod is left running on purpose so the next run skips setup. Delete it
# when you are done.
set -euo pipefail

cd "$(dirname "$0")"

# -----------------------------------------------------------------------------
# Where the systems under test live. Defaults match deploy/*/install.sh.
# -----------------------------------------------------------------------------
: "${PROM_NS:=perf-prometheus}";      : "${PROM_SVC:=perf-prometheus-standalone}";  : "${PROM_PORT:=9090}"
: "${MIMIR_NS:=perf-mimir}";          : "${MIMIR_SVC:=perf-mimir-standalone}";      : "${MIMIR_PORT:=9009}"
: "${O2_PARQUET_NS:=perf-o2-parquet}"
: "${O2_VORTEX_NS:=perf-o2-vortex}"
: "${O2_SVC:=o2-openobserve-standalone}"; : "${O2_PORT:=5080}"

# -----------------------------------------------------------------------------
# The runner pod itself.
# -----------------------------------------------------------------------------
: "${BENCH_NS:=perf-bench}"
: "${BENCH_POD:=bench}"
: "${BENCH_IMAGE:=alpine:3.20}"
: "${BENCH_ARCH:=arm64}"    # the perf nodes are Graviton; empty string = any
: "${BENCH_ZONE:=}"         # empty = auto-detect from the systems under test
: "${REMOTE_DIR:=/opt/mb}"

command -v kubectl >/dev/null || { echo "error: kubectl not found" >&2; exit 1; }

kexec() { kubectl -n "${BENCH_NS}" exec "${BENCH_POD}" -- "$@"; }

SCRIPT="run-benchmark.sh"
SCRIPT_ARGS=()
DELETE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete) DELETE=1; shift ;;
    --script)
      [[ -n "${2:-}" ]] || { echo "error: --script needs a script name" >&2; exit 1; }
      SCRIPT="$2"
      # Everything after the script name belongs to the script, not to us.
      shift 2
      SCRIPT_ARGS=("$@")
      break
      ;;
    -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "error: unknown argument '$1' (see --help)" >&2; exit 1 ;;
  esac
done

[[ -f "${SCRIPT}" ]] || { echo "error: bench/${SCRIPT} does not exist" >&2; exit 1; }

if [[ "${DELETE}" == "1" ]]; then
  # Delete the pod first and don't block on the namespace. Namespace teardown
  # stalls indefinitely on any cluster with an unhealthy aggregated APIService
  # (`kubectl get apiservice | grep False` to check) -- that has nothing to do
  # with this benchmark, and the pod is the part that actually consumes
  # resources.
  echo "==> deleting ${BENCH_NS}/${BENCH_POD}"
  kubectl -n "${BENCH_NS}" delete pod "${BENCH_POD}" --ignore-not-found
  kubectl delete ns "${BENCH_NS}" --ignore-not-found --wait=false
  exit 0
fi

# A namespace stuck in Terminating silently rejects everything applied into it.
phase="$(kubectl get ns "${BENCH_NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
if [[ "${phase}" == "Terminating" ]]; then
  echo "error: ns/${BENCH_NS} is stuck Terminating, so the runner cannot be created." >&2
  echo "  Usually an unhealthy aggregated APIService blocks namespace GC cluster-wide:" >&2
  echo "    kubectl get apiservice | grep False" >&2
  echo "  Delete the stale APIService, or just run against another namespace:" >&2
  echo "    BENCH_NS=${BENCH_NS}2 $0" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# 1. Runner pod
# -----------------------------------------------------------------------------

# Put the runner in the same AZ as the systems under test. They are all on one
# node pool in one AZ, so this is both symmetric (no system is closer than
# another) and minimal. If they are spread across AZs there is no placement
# that is fair to all four, so stay unpinned and say so.
if [[ -z "${BENCH_ZONE}" ]]; then
  zones=$(
    for ns in "${PROM_NS}" "${MIMIR_NS}" "${O2_PARQUET_NS}" "${O2_VORTEX_NS}"; do
      for node in $(kubectl -n "${ns}" get pods \
            -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null); do
        kubectl get node "${node}" \
          -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}' 2>/dev/null
      done
    done | sort -u | grep -v '^$' || true
  )
  # Exactly one zone == non-empty and containing no newline. Deliberately not
  # `wc -l`: BSD/macOS wc pads its output ("       1"), so a string compare
  # against "1" silently never matches and the runner lands anywhere.
  if [[ -n "${zones}" && "${zones}" != *$'\n'* ]]; then
    BENCH_ZONE="${zones}"
    echo "==> systems under test are all in ${BENCH_ZONE}; pinning runner there"
  else
    echo "==> systems under test span multiple AZs; leaving runner unpinned"
    echo "    (add ~1-2ms cross-AZ to some systems and not others -- note it when publishing)"
  fi
fi

if ! kubectl -n "${BENCH_NS}" get pod "${BENCH_POD}" >/dev/null 2>&1; then
  echo "==> creating ${BENCH_NS}/${BENCH_POD}"
  {
    cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${BENCH_NS}
---
apiVersion: v1
kind: Pod
metadata:
  name: ${BENCH_POD}
  namespace: ${BENCH_NS}
spec:
  # Deliberately NO toleration for the \`perf\` taint: this pod must not be
  # schedulable onto the four nodes under test.
  restartPolicy: Never
  nodeSelector:
EOF
    # Plain `[[ ... ]] && echo` would abort the script under `set -e` whenever
    # the test is false, so spell these out.
    if [[ -n "${BENCH_ARCH}" ]]; then echo "    kubernetes.io/arch: ${BENCH_ARCH}"; fi
    if [[ -n "${BENCH_ZONE}" ]]; then echo "    topology.kubernetes.io/zone: ${BENCH_ZONE}"; fi
    cat <<EOF
  containers:
    - name: bench
      image: ${BENCH_IMAGE}
      command: ["sleep", "infinity"]
      resources:
        requests: {cpu: "1", memory: 1Gi}
        limits:   {cpu: "4", memory: 8Gi}
EOF
  } | kubectl apply -f -
fi

echo "==> waiting for pod"
kubectl -n "${BENCH_NS}" wait --for=condition=Ready "pod/${BENCH_POD}" --timeout=180s

# bash: run-benchmark.sh uses arrays and herestrings. python3: it parses the
# response bodies. Idempotent, so a reused pod skips the download.
if ! kexec sh -c 'command -v bash >/dev/null && command -v curl >/dev/null && command -v python3 >/dev/null' 2>/dev/null; then
  echo "==> installing bash curl python3"
  kexec sh -c 'apk add --no-cache bash curl python3 >/dev/null'
fi

echo "==> runner: $(kubectl -n "${BENCH_NS}" get pod "${BENCH_POD}" \
  -o jsonpath='{.spec.nodeName}') ($(kubectl -n "${BENCH_NS}" get pod "${BENCH_POD}" \
  -o jsonpath='{.status.podIP}'))"

# -----------------------------------------------------------------------------
# 2. Ship bench/ into the pod
#
# tar over exec rather than `kubectl cp`: no leading-slash warnings, no
# surprises about whether the destination directory already exists.
# -----------------------------------------------------------------------------
echo "==> copying bench/ to ${REMOTE_DIR}/bench"
kexec sh -c "rm -rf ${REMOTE_DIR}/bench && mkdir -p ${REMOTE_DIR}/bench ${REMOTE_DIR}/results"
tar cf - ./*.sh ./summarize.py \
  | kubectl -n "${BENCH_NS}" exec -i "${BENCH_POD}" -- tar xf - -C "${REMOTE_DIR}/bench"
kexec sh -c "chmod +x ${REMOTE_DIR}/bench/*.sh ${REMOTE_DIR}/bench/summarize.py"

# -----------------------------------------------------------------------------
# 3. Run
# -----------------------------------------------------------------------------
envs=(
  "PROM_BASE=http://${PROM_SVC}.${PROM_NS}.svc.cluster.local:${PROM_PORT}"
  "MIMIR_BASE=http://${MIMIR_SVC}.${MIMIR_NS}.svc.cluster.local:${MIMIR_PORT}/prometheus"
  "O2_PARQUET_BASE=http://${O2_SVC}.${O2_PARQUET_NS}.svc.cluster.local:${O2_PORT}/api/default/prometheus"
  "O2_VORTEX_BASE=http://${O2_SVC}.${O2_VORTEX_NS}.svc.cluster.local:${O2_PORT}/api/default/prometheus"
)
# Forward the knobs from config.sh, but only the ones actually set here, so the
# defaults in config.sh stay in charge of everything else.
for v in O2_USER O2_PASS PATH_FILTER WINDOWS STEP RUNS END_TIME CURL_TIMEOUT \
         SYSTEMS_FILTER QUERY_FILTER; do
  if [[ -n "${!v:-}" ]]; then envs+=("${v}=${!v}"); fi
done

# Remember what was already there, so step 4 can tell a fresh results directory
# from one an earlier run left behind in a reused pod.
before="$(kexec sh -c "ls -1 ${REMOTE_DIR}/results 2>/dev/null | sort | tail -1" | tr -d '\r')"

echo "==> running ${SCRIPT} in-cluster"
echo
kubectl -n "${BENCH_NS}" exec "${BENCH_POD}" -- \
  env "${envs[@]}" "${REMOTE_DIR}/bench/${SCRIPT}" \
  ${SCRIPT_ARGS[@]+"${SCRIPT_ARGS[@]}"}

# -----------------------------------------------------------------------------
# 4. Bring the results home
#
# Only run-benchmark.sh writes a results directory. cardinality.sh and friends
# just print, so there is nothing to copy and that is not an error.
# -----------------------------------------------------------------------------
stamp="$(kexec sh -c "ls -1 ${REMOTE_DIR}/results 2>/dev/null | sort | tail -1" | tr -d '\r')"
if [[ -z "${stamp}" || "${stamp}" == "${before}" ]]; then
  echo
  echo "==> ${SCRIPT} produced no results directory (nothing to copy back)"
  echo "==> runner pod left running; ./run-in-cluster.sh --delete to remove it"
  exit 0
fi

mkdir -p ../results
kexec tar cf - -C "${REMOTE_DIR}/results" "${stamp}" | tar xf - -C ../results

# Record how this run was measured. A CSV that does not say where it was run
# from is not comparable to one that does -- that is the whole point here.
cat >> "../results/${stamp}/run-metadata.txt" <<EOF
measured_from   in-cluster pod ${BENCH_NS}/${BENCH_POD}
runner_node     $(kubectl -n "${BENCH_NS}" get pod "${BENCH_POD}" -o jsonpath='{.spec.nodeName}')
runner_zone     ${BENCH_ZONE:-unpinned}
transport       ClusterIP Service DNS (no port-forward)
EOF

echo
echo "==> results: results/${stamp}/"
echo "==> runner pod left running; ./run-in-cluster.sh --delete to remove it"
