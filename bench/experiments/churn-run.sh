#!/usr/bin/env bash
# Churn experiment (dataset run-b).
#
# Question: when a query window contains far fewer series than the index holds,
# does a system pay for what is in the window, or for what is in the index?
#
# Design: 10 replicas, rollout-restarted at t=1h, 2h and 3h. Each restart mints
# new pod identities, so each batch is a fresh ~450k bucket series that never
# reappears. Ingestion stops at t=6h.
#
#   batch 1  t=0..1h    ~450k series
#   batch 2  t=1..2h    ~450k
#   batch 3  t=2..3h    ~450k
#   batch 4  t=3..6h    ~450k, and the only one alive for the last three hours
#
# Cumulative unique series reaches ~1.8M, but the window [3h,6h] holds only
# batch 4's ~450k. Comparing [0h,3h] (three batches, ~1.35M in window) against
# [3h,6h] (~450k) on each system separates the two cost models:
#
#   cost ∝ series in window  ->  [3h,6h] is ~3x faster
#   cost ∝ series in index   ->  the two are about equal
#
# rollout restart rather than scale 0/10: it keeps the sample stream continuous,
# so the batch boundary is a ~30s overlap rather than a hole in the data. A hole
# would change how much data each window holds, which is the thing being
# measured.
set -uo pipefail

: "${NS:=perf-fakeserver}"
: "${DEPLOY:=fake-webserver}"
: "${REPLICAS:=10}"
: "${HOUR:=3600}"          # seconds per phase; lower it to rehearse
: "${RESTARTS:=3}"         # at t=1h, 2h, 3h
: "${TOTAL_HOURS:=6}"
LOG="$(cd "$(dirname "$0")" && pwd)/churn-run.log"

say() { echo "$(date -u +%H:%M:%SZ) $*" | tee -a "$LOG"; }

say "=== churn run starting: ${REPLICAS} replicas, restart x${RESTARTS}, stop at ${TOTAL_HOURS}h ==="
kubectl -n "${NS}" scale deploy "${DEPLOY}" --replicas="${REPLICAS}" 2>&1 | tee -a "$LOG"
kubectl -n "${NS}" rollout status deploy/"${DEPLOY}" --timeout=10m 2>&1 | tail -1 | tee -a "$LOG"
START="$(date +%s)"
say "t=0  batch 1 up.  START_UNIX=${START}"

for i in $(seq 1 "${RESTARTS}"); do
  target=$(( START + i * HOUR ))
  while [ "$(date +%s)" -lt "${target}" ]; do sleep 20; done
  say "t=${i}h  rollout restart -> batch $(( i + 1 ))"
  kubectl -n "${NS}" rollout restart deploy/"${DEPLOY}" 2>&1 | tee -a "$LOG"
  kubectl -n "${NS}" rollout status deploy/"${DEPLOY}" --timeout=10m 2>&1 | tail -1 | tee -a "$LOG"
done

stop=$(( START + TOTAL_HOURS * HOUR ))
while [ "$(date +%s)" -lt "${stop}" ]; do sleep 30; done
say "t=${TOTAL_HOURS}h  stopping ingestion"
kubectl -n "${NS}" scale deploy "${DEPLOY}" --replicas=0 2>&1 | tee -a "$LOG"

cat >> "$LOG" <<EOF

=== windows to compare (unix) ===
START      ${START}
0h-3h      ${START} .. $(( START + 3 * HOUR ))
3h-6h      $(( START + 3 * HOUR )) .. $(( START + 6 * HOUR ))
END_TIME for the 3h-6h window: $(( START + 6 * HOUR ))

Wait ~2h for OpenObserve's compaction to settle before querying.
EOF
say "=== done. windows recorded in ${LOG} ==="
