#!/usr/bin/env bash
# Steady-state CPU / memory / disk for each system under test.
#
# Everything comes from one kubelet endpoint per node
# (/stats/summary), so this needs no metrics-server and no `exec` into
# containers -- the pod CPU, pod memory and PVC usage all come from the same
# snapshot, which keeps the three numbers consistent with each other.
#
#   ./resources.sh              # one snapshot
#   ./resources.sh 12 300       # 12 snapshots, 300s apart (1 hour)
#
# CPU is an instantaneous rate, so take several snapshots during steady-state
# ingestion rather than trusting a single reading. Disk only makes sense once
# ingestion has been running long enough to compact.
#
# Two memory columns, because they answer different questions:
#
#   rss       anonymous pages only -- what the process itself allocated
#   workset   cgroup workingSetBytes = anon + ACTIVE PAGE CACHE + kernel memory
#
# For these systems the gap is page cache from writing data files, and it is
# enormous: OpenObserve measures ~1.5GB rss against ~10GB workset, which would
# make it look like the heaviest of the four when by rss it is the lightest.
# Compare on rss. (Caveat: rss excludes file-backed mmap pages, so it somewhat
# undercounts Prometheus/Mimir, which mmap their chunk files -- they still come
# out higher than OpenObserve.)
set -uo pipefail

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }

SNAPSHOTS="${1:-1}"
INTERVAL="${2:-60}"

# Namespaces default to what deploy/ installs, but are overridable for a
# deployment that drifted:
#   O2_PARQUET_NS=perf-o21 O2_VORTEX_NS=perf-o22 ./resources.sh
: "${PROM_NS:=perf-prometheus}"
: "${MIMIR_NS:=perf-mimir}"
: "${O2_PARQUET_NS:=perf-o2-parquet}"
: "${O2_VORTEX_NS:=perf-o2-vortex}"

# label|namespace|statefulset
TARGETS=(
  "prometheus|${PROM_NS}|prometheus-standalone"
  "mimir|${MIMIR_NS}|mimir-standalone"
  "o2-parquet|${O2_PARQUET_NS}|o2-openobserve-standalone"
  "o2-vortex|${O2_VORTEX_NS}|o2-openobserve-standalone"
)

STATS="$(mktemp)"
trap 'rm -f "${STATS}"' EXIT

snapshot() {
  printf '%-12s %10s %11s %11s %11s   %s\n' "system" "cpu(cores)" "rss" "workset" "disk" "pod"
  for entry in "${TARGETS[@]}"; do
    IFS='|' read -r label ns sts <<< "${entry}"
    pod="${sts}-0"

    node="$(kubectl -n "${ns}" get pod "${pod}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
    if [[ -z "${node}" ]]; then
      printf '%-12s %10s %11s %11s %11s   %s\n' "${label}" "-" "-" "-" "-" "(pod not found)"
      continue
    fi

    # Land the kubelet response in a file and pass its PATH to python.
    # `kubectl ... | python3 - args <<'PY'` does NOT work: the heredoc becomes
    # python's stdin and silently overrides the pipe, so json.load(sys.stdin)
    # sees an exhausted stream and every row reads "kubelet stats unavailable".
    kubectl get --raw "/api/v1/nodes/${node}/proxy/stats/summary" \
      > "${STATS}" 2>/dev/null
    python3 - "${label}" "${ns}" "${pod}" "${STATS}" <<'PY'
import json, sys

label, ns, pod_name, stats_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def human(n):
    if n is None:
        return "-"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.1f} {unit}"
        n /= 1024

try:
    with open(stats_path) as fh:
        summary = json.load(fh)
except Exception:
    print(f"{label:<12} {'-':>10} {'-':>11} {'-':>11} {'-':>11}   (kubelet stats unavailable)")
    raise SystemExit

for pod in summary.get("pods", []):
    ref = pod.get("podRef", {})
    if ref.get("name") != pod_name or ref.get("namespace") != ns:
        continue

    cpu = (pod.get("cpu") or {}).get("usageNanoCores")
    cpu_s = f"{cpu / 1e9:.2f}" if cpu is not None else "-"
    memstats = pod.get("memory") or {}
    rss = memstats.get("rssBytes")
    workset = memstats.get("workingSetBytes")

    # The data PVC is always named data-<statefulset>-N.
    disk = None
    for vol in pod.get("volume", []):
        pvc = (vol.get("pvcRef") or {}).get("name", "")
        if pvc.startswith("data-"):
            disk = vol.get("usedBytes")
            break

    print(f"{label:<12} {cpu_s:>10} {human(rss):>11} {human(workset):>11} "
          f"{human(disk):>11}   {pod_name}")
    break
else:
    print(f"{label:<12} {'-':>10} {'-':>11} {'-':>11} {'-':>11}   (pod not in kubelet summary)")
PY
  done
}

for i in $(seq 1 "${SNAPSHOTS}"); do
  echo "==> snapshot ${i}/${SNAPSHOTS}  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  snapshot
  echo
  [[ "${i}" -lt "${SNAPSHOTS}" ]] && sleep "${INTERVAL}"
done

cat <<'EOF'
For reference, measured at steady state (CPU typical, memory as rss, disk
after compaction fully settled):

  system                  CPU (cores)   RSS      Disk
  Prometheus              1.25          4.3 GB   4.5 GB
  Mimir                   0.9           5.2 GB   7.4 GB
  OpenObserve (Parquet)   2.4           1.5 GB   15.5 GB
  OpenObserve (Vortex)    2.0           1.8 GB   15.1 GB

DISK SETTLES AT DIFFERENT TIMES PER SYSTEM -- measure late:

  OpenObserve   ~2h    ZO_COMPACT_DELETE_FILES_DELAY_HOURS=2
  Prometheus    ~2-3h  source blocks dropped right after compaction
  Mimir         ~14h   ingester keeps a local copy for retention_period=13h,
                       on top of the bucket copy the compactor manages

Read too early and Prometheus/Mimir come out ~26%/~31% high, which understates
OpenObserve's disk disadvantage. Two readings 30s apart prove nothing. See
RESULTS.md. Disk covers ~4.8h of ingestion; the ratio travels, the absolute
figures do not.
EOF
