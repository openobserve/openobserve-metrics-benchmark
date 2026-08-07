#!/usr/bin/env bash
# Opens local ports for all four systems and holds them until you Ctrl-C.
# Ports match the defaults in config.sh.
#
#   terminal 1:  ./port-forward.sh
#   terminal 2:  ./cardinality.sh   /   a browser
#
# DO NOT TIME QUERIES THROUGH THIS. Every request is tunnelled through the
# Kubernetes API server, which measured ~1,070ms for a trivial `query=1` that
# Prometheus answers in microseconds -- ~5ms from inside the cluster.
#
# The overhead is not a constant that cancels out of a comparison: it grows with
# response size, so it swamps a fast system and barely dents a slow one. On the
# same irate query, OpenObserve/Parquet measured 158ms in-cluster and 2122ms
# through here, while Prometheus went 1287ms -> 3445ms. The real 8.1x gap reads
# as 1.6x through the tunnel.
#
# Use ./run-in-cluster.sh for anything you intend to publish -- including
# `--script cardinality.sh`, which needs no port-forward either. This script is
# now only for opening a UI in a browser and ad-hoc poking. (resources.sh and
# drop-caches.sh never needed it: they drive kubectl, not these ports.)
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
