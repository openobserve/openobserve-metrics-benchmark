#!/usr/bin/env bash
# Installs every component in dependency order.
#
# The collector runs LAST: its exporters address the four Services above it, and
# starting it first just spends the opening minutes retrying against nothing.
set -euo pipefail
cd "$(dirname "$0")"

for step in \
  prometheus \
  mimir \
  openobserve-parquet \
  openobserve-vortex \
  fake-webserver \
  otel-collector
do
  echo
  echo "======================================================================"
  echo "==> ${step}"
  echo "======================================================================"
  "./${step}/install.sh"
done

cat <<'EOF'

======================================================================
All components installed.

Now wait. A 3-hour query window needs at least 3 hours of data, and the
published run had been ingesting for roughly 30 hours before it was measured.

While waiting, confirm data is actually arriving everywhere:

  bench/port-forward.sh     # terminal 1
  bench/cardinality.sh      # terminal 2

The four systems must agree on cardinality. If they do not, they did not
receive the same data, and any latency comparison is meaningless.
======================================================================
EOF
