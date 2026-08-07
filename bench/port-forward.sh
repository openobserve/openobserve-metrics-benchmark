#!/usr/bin/env bash
# Opens local ports for all four systems and holds them until you Ctrl-C.
# Ports match the defaults in config.sh.
#
#   terminal 1:  ./port-forward.sh
#   terminal 2:  ./run-benchmark.sh
#
# Port-forward adds a hop through the API server. It is the same hop for every
# system, so it does not bias the comparison, but it does add a few ms to every
# number -- run from inside the cluster if you want the cleanest absolutes.
set -euo pipefail

pids=()
cleanup() {
  echo
  echo "==> closing port-forwards"
  for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done
}
trap cleanup EXIT INT TERM

fwd() {
  local ns="$1" target="$2" local_port="$3" remote_port="$4"
  kubectl -n "$ns" port-forward "$target" "${local_port}:${remote_port}" >/dev/null 2>&1 &
  pids+=("$!")
  echo "  ${ns}/${target} -> localhost:${local_port}"
}

echo "==> forwarding"
fwd perf-prometheus  svc/perf-prometheus-standalone 19090 9090
fwd perf-mimir       svc/perf-mimir-standalone      19009 9009
fwd perf-o2-parquet  svc/o2-openobserve-standalone  15081 5080
fwd perf-o2-vortex   svc/o2-openobserve-standalone  15082 5080

sleep 3
echo
echo "==> ready. Ctrl-C to stop."
wait
