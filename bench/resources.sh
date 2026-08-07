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
# ingestion has been running long enough to compact -- the published run
# measured after multiple hours.
set -uo pipefail

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }

SNAPSHOTS="${1:-1}"
INTERVAL="${2:-60}"

# label|namespace|statefulset
TARGETS=(
  "prometheus|perf-prometheus|prometheus-standalone"
  "mimir|perf-mimir|mimir-standalone"
  "o2-parquet|perf-o2-parquet|o2-openobserve-standalone"
  "o2-vortex|perf-o2-vortex|o2-openobserve-standalone"
)

snapshot() {
  printf '%-12s %10s %12s %12s   %s\n' "system" "cpu(cores)" "memory" "disk" "pod"
  for entry in "${TARGETS[@]}"; do
    IFS='|' read -r label ns sts <<< "${entry}"
    pod="${sts}-0"

    node="$(kubectl -n "${ns}" get pod "${pod}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
    if [[ -z "${node}" ]]; then
      printf '%-12s %10s %12s %12s   %s\n' "${label}" "-" "-" "-" "(pod not found)"
      continue
    fi

    kubectl get --raw "/api/v1/nodes/${node}/proxy/stats/summary" 2>/dev/null \
      | python3 - "${label}" "${ns}" "${pod}" <<'PY'
import json, sys

label, ns, pod_name = sys.argv[1], sys.argv[2], sys.argv[3]

def human(n):
    if n is None:
        return "-"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.1f} {unit}"
        n /= 1024

try:
    summary = json.load(sys.stdin)
except Exception:
    print(f"{label:<12} {'-':>10} {'-':>12} {'-':>12}   (kubelet stats unavailable)")
    raise SystemExit

for pod in summary.get("pods", []):
    ref = pod.get("podRef", {})
    if ref.get("name") != pod_name or ref.get("namespace") != ns:
        continue

    cpu = (pod.get("cpu") or {}).get("usageNanoCores")
    cpu_s = f"{cpu / 1e9:.2f}" if cpu is not None else "-"
    mem = (pod.get("memory") or {}).get("workingSetBytes")

    # The data PVC is always named data-<statefulset>-N.
    disk = None
    for vol in pod.get("volume", []):
        pvc = (vol.get("pvcRef") or {}).get("name", "")
        if pvc.startswith("data-"):
            disk = vol.get("usedBytes")
            break

    print(f"{label:<12} {cpu_s:>10} {human(mem):>12} {human(disk):>12}   {pod_name}")
    break
else:
    print(f"{label:<12} {'-':>10} {'-':>12} {'-':>12}   (pod not in kubelet summary)")
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
For reference, the published run measured at steady state:

  system                  CPU (cores)   Memory   Disk
  Prometheus              0.6           2.0 GB   19.9 GB
  Mimir                   0.4           2.8 GB   34 GB
  OpenObserve (Parquet)   1.0           0.9 GB   95 GB
  OpenObserve (Vortex)    1.0           0.9 GB   95 GB
EOF
