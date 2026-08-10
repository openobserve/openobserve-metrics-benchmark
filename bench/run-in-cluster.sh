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
#   O2_PARQUET_NS=my-parquet-ns O2_VORTEX_NS=my-vortex-ns ./run-in-cluster.sh
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

# Same, but retried: `kubectl exec` against this API server intermittently dies
# with `error: EOF` or `websocket: close 1006` on perfectly good calls. Use this
# for setup steps that must succeed and are idempotent (rm, mkdir, chmod, tar).
#
# NEVER use it to launch the benchmark. A launch that actually succeeded but
# reported EOF would be retried into a SECOND concurrent run, and two runs
# contending for CPU corrupt both sets of timings invisibly. The launch is
# instead issued once and confirmed by polling.
kexec_ok() {
  local i
  for (( i = 1; i <= 5; i++ )); do
    if kubectl -n "${BENCH_NS}" exec "${BENCH_POD}" -- "$@" 2>/dev/null; then
      return 0
    fi
    sleep 3
  done
  echo "error: 'kubectl exec ... $1' failed 5 times against ${BENCH_NS}/${BENCH_POD}" >&2
  return 1
}

# Container restart state for the systems under test. Sampled before and after
# the run: a pod that was OOMKilled mid-benchmark shows up as a changed restart
# count, and `curl` alone cannot tell that apart from a network failure -- both
# surface as http_code 000. The benchmark itself runs in a pod with no kubectl
# and no RBAC, so this has to happen out here.
pod_states() {
  local ns sts
  for entry in "${PROM_NS}|prometheus-standalone-0" \
               "${MIMIR_NS}|mimir-standalone-0" \
               "${O2_PARQUET_NS}|o2-openobserve-standalone-0" \
               "${O2_VORTEX_NS}|o2-openobserve-standalone-0"; do
    IFS='|' read -r ns sts <<< "${entry}"
    kubectl -n "${ns}" get pod "${sts}" -o jsonpath="${ns} restarts={.status.containerStatuses[0].restartCount} lastReason={.status.containerStatuses[0].lastState.terminated.reason} lastExit={.status.containerStatuses[0].lastState.terminated.exitCode} finishedAt={.status.containerStatuses[0].lastState.terminated.finishedAt}{'\n'}" 2>/dev/null \
      || echo "${ns} (unavailable)"
  done
}

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
kexec_ok sh -c "rm -rf ${REMOTE_DIR}/bench && mkdir -p ${REMOTE_DIR}/bench ${REMOTE_DIR}/results"
# experiments/ carries the one-off studies and is shipped too, so that
# `--script experiments/foo.sh` works the same way as a top-level script.
tar cf - ./*.sh ./summarize.py $([[ -d ./experiments ]] && echo ./experiments) \
  | kubectl -n "${BENCH_NS}" exec -i "${BENCH_POD}" -- tar xf - -C "${REMOTE_DIR}/bench"
kexec_ok sh -c "chmod +x ${REMOTE_DIR}/bench/*.sh ${REMOTE_DIR}/bench/summarize.py; \
  [ -d ${REMOTE_DIR}/bench/experiments ] && chmod +x ${REMOTE_DIR}/bench/experiments/*.sh || true"

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
#
# PASS_ENV carries anything else a --script needs; the experiments under
# bench/experiments/ take their own knobs and would otherwise be unreachable
# from out here:
#
#   START=... HOUR=300 PASS_ENV="START HOUR" ./run-in-cluster.sh --script ...
for v in O2_USER O2_PASS PATH_FILTER WINDOWS STEP RUNS WARMUP SINGLE_RUN_CELLS \
         END_TIME CURL_TIMEOUT SYSTEMS_FILTER QUERY_FILTER ${PASS_ENV:-}; do
  if [[ -n "${!v:-}" ]]; then envs+=("${v}=${!v}"); fi
done

# Remember what was already there, so step 4 can tell a fresh results directory
# from one an earlier run left behind in a reused pod.
before="$(kexec sh -c "ls -1 ${REMOTE_DIR}/results 2>/dev/null | sort | tail -1" | tr -d '\r')"

# Run DETACHED inside the pod, then poll.
#
# Driving a long run through `kubectl exec` directly does not survive: the
# unfiltered histogram can spend minutes on a single request producing no
# stdout, and the idle exec stream gets torn down with
# `websocket: close 1006 (abnormal closure)`, killing the benchmark partway.
# Detaching means the run owns its own lifetime -- a dropped connection, a
# laptop lid, or a Ctrl-C costs you the log tail, not the results.
LOG="${REMOTE_DIR}/run.log"
EXITF="${REMOTE_DIR}/run.exit"

# A previous run that lost its connection can still be alive in the pod, and a
# second benchmark racing the first silently corrupts BOTH sets of timings --
# they contend for the same CPU. (Seen in practice: a clean 145/123/121ms cell
# reading 458/328/1867ms with an orphan running.) Reap before starting.
# busybox `ps -o args` prints only a COMMAND header plus truncated entries and
# does not reliably show the script name; `ps aux` does. `grep -c` also exits 1
# on zero matches, which would trip `set -e`, hence the inner `|| true`.
count_running() {
  kexec sh -c "ps aux 2>/dev/null | grep -c '[r]un-benchmark' || true" 2>/dev/null \
    | tr -d ' \r' | head -1 || echo 0
}

stale="$(kexec sh -c "ps -o pid,args 2>/dev/null | grep '[r]un-benchmark' | awk '{print \$1}'" 2>/dev/null | tr -d '\r' || true)"
if [[ -n "${stale}" ]]; then
  echo "==> reaping stale benchmark process(es) in pod: $(echo ${stale} | tr '\n' ' ')"
  for p in ${stale}; do kexec kill -9 "${p}" >/dev/null 2>&1 || true; done
  sleep 3
fi

# Assert quiescence rather than assume the reap worked. Starting on top of a
# survivor is worse than not starting: both runs produce plausible-looking
# numbers that are silently inflated by CPU contention, and nothing in the CSV
# says so.
remaining="$(count_running)"
if [[ "${remaining}" =~ ^[0-9]+$ ]] && (( remaining > 0 )); then
  echo "error: ${remaining} benchmark process(es) still running in ${BENCH_NS}/${BENCH_POD}." >&2
  echo "  Concurrent runs contend for CPU and corrupt both sets of timings." >&2
  echo "  Inspect with: kubectl -n ${BENCH_NS} exec ${BENCH_POD} -- ps aux" >&2
  exit 1
fi

# Build a properly quoted command line for the pod's shell.
remote_cmd="cd ${REMOTE_DIR}/bench && env"
for kv in "${envs[@]}"; do
  remote_cmd+=" $(printf '%q' "${kv}")"
done
remote_cmd+=" ./${SCRIPT}"
for arg in ${SCRIPT_ARGS[@]+"${SCRIPT_ARGS[@]}"}; do
  remote_cmd+=" $(printf '%q' "${arg}")"
done

PODS_BEFORE="$(pod_states)"

echo "==> running ${SCRIPT} in-cluster (detached; safe to Ctrl-C this tail)"
echo

# Clear prior state in its OWN call, and require it to succeed. Folding this
# into the launch is how a failed launch masquerades as a running job: the
# poller finds a leftover run.log, tails a dead run's output, and reports
# progress for something that never started.
kexec_ok sh -c "rm -f ${LOG} ${EXITF}"

# `kubectl exec` frequently reports `error: EOF` when the remote shell exits
# while its backgrounded child still holds the stream. That is not a launch
# failure, so tolerate it and confirm by polling instead of trusting the exit
# code. The trailing `sleep 1` also gives the child time to create the log.
#
# Retry only after confirming NOTHING is running -- a blind retry of a launch
# that actually succeeded would put two benchmarks on the same CPU and silently
# inflate both. Hence: launch, verify, and re-launch only from a proven-idle
# pod.
started=0
for attempt in 1 2 3; do
  kexec sh -c "( ${remote_cmd} > ${LOG} 2>&1; echo \$? > ${EXITF} ) </dev/null >/dev/null 2>&1 & sleep 1" || true

  for _ in $(seq 1 10); do
    if kexec sh -c "test -f ${LOG}" >/dev/null 2>&1; then started=1; break; fi
    sleep 2
  done
  [[ "${started}" == "1" ]] && break

  live="$(count_running)"
  if [[ "${live}" =~ ^[0-9]+$ ]] && (( live > 0 )); then
    echo "==> launch reported an error but ${live} process(es) are running; watching those" >&2
    started=1
    break
  fi
  echo "==> launch attempt ${attempt} produced nothing (pod idle); retrying" >&2
done
if [[ "${started}" != "1" ]]; then
  echo "error: ${SCRIPT} did not start in ${BENCH_NS}/${BENCH_POD} after 3 attempts" >&2
  exit 1
fi

# Poll, echoing only the newly appended lines.
#
# Every kexec here is `|| true`: this loop only WATCHES the run, so a transient
# API-server hiccup -- or `cat` on the not-yet-created exit file, which exits 1
# and under `set -e` + `pipefail` would abort the whole script -- must never
# take down the watcher. The benchmark itself is detached and unaffected either
# way; losing the tail is cosmetic, aborting here looks like a failed run.
seen=0
while true; do
  total="$(kexec sh -c "wc -l < ${LOG} 2>/dev/null || echo 0" 2>/dev/null | tr -d ' \r' || true)"
  if [[ "${total}" =~ ^[0-9]+$ ]] && (( total > seen )); then
    kexec sh -c "tail -n +$((seen+1)) ${LOG} | head -n $((total - seen))" 2>/dev/null || true
    seen="${total}"
  fi
  code="$(kexec sh -c "cat ${EXITF} 2>/dev/null || true" 2>/dev/null | tr -d ' \r' || true)"
  if [[ -n "${code}" ]]; then
    # Flush anything written between the last tail and the exit marker.
    kexec sh -c "tail -n +$((seen+1)) ${LOG} 2>/dev/null || true" 2>/dev/null || true
    if [[ "${code}" != "0" ]]; then
      echo
      echo "==> ${SCRIPT} exited ${code}; results below are whatever it managed to write" >&2
    fi
    break
  fi
  sleep 10
done

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

# Anything that restarted during the run gets recorded next to the CSV. An
# OOMKill is a result -- "this system cannot answer that query in this memory
# envelope" -- and must not be filed as a connection error.
{
  echo "# container state before / after the run"
  echo "## before"; echo "${PODS_BEFORE}"
  echo "## after";  pod_states
} > "../results/${stamp}/pod-state.txt"

# `|| true` on every branch: under `set -e` + `pipefail` a diff that finds
# differences exits 1 and would abort the script HERE -- after the benchmark
# succeeded and the results were copied back, but before the closing messages.
# A restart is something to report, not a reason to fail the run.
if ! diff <(echo "${PODS_BEFORE}") <(pod_states) >/dev/null 2>&1; then
  {
    echo
    echo "==> WARNING: a system under test restarted during this run"
    diff <(echo "${PODS_BEFORE}") <(pod_states) 2>/dev/null | grep '^>' \
      | sed 's/^> /    /' || true
    echo "    see results/${stamp}/pod-state.txt -- correlate finishedAt with"
    echo "    started_unix in raw.csv to find which request killed it."
  } >&2 || true
fi

# Record how this run was measured. A CSV that does not say where it was run
# from is not comparable to one that does -- that is the whole point here.
{
  echo "measured_from   in-cluster pod ${BENCH_NS}/${BENCH_POD}"
  echo "runner_node     $(kubectl -n "${BENCH_NS}" get pod "${BENCH_POD}" -o jsonpath='{.spec.nodeName}')"
  echo "runner_zone     ${BENCH_ZONE:-unpinned}"
  echo "transport       ClusterIP Service DNS (no port-forward)"
  # The memory envelope is the variable between benchmark rounds, so a CSV that
  # does not carry it cannot be told apart from one run at a different limit.
  for e in "prometheus|${PROM_NS}|prometheus-standalone-0" \
           "mimir|${MIMIR_NS}|mimir-standalone-0" \
           "o2-parquet|${O2_PARQUET_NS}|o2-openobserve-standalone-0" \
           "o2-vortex|${O2_VORTEX_NS}|o2-openobserve-standalone-0"; do
    IFS='|' read -r lbl ns pd <<< "${e}"
    echo "mem_limit_${lbl}  $(kubectl -n "${ns}" get pod "${pd}" \
      -o jsonpath='{.spec.containers[0].resources.limits.memory}' 2>/dev/null || echo '?')"
  done
} >> "../results/${stamp}/run-metadata.txt"

echo
echo "==> results: results/${stamp}/"
echo "==> runner pod left running; ./run-in-cluster.sh --delete to remove it"
