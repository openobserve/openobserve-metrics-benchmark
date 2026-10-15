#!/usr/bin/env bash
# Runs the backfill Job and follows it. Overrides: BACKFILL_START, BACKFILL_HOURS,
# BACKFILL_STEP, BACKFILL_SEED (defaults: 2026-09-28T03:00:00Z, 7, 15s, 1).
set -euo pipefail
cd "$(dirname "$0")"

: "${BACKFILL_START:=2026-09-28T03:00:00Z}"
: "${BACKFILL_HOURS:=7}"
: "${BACKFILL_STEP:=15s}"
: "${BACKFILL_SEED:=1}"

if kubectl -n perf-fakeserver get job backfill >/dev/null 2>&1; then
  echo "error: job/backfill already exists in perf-fakeserver; a second run would duplicate every sample." >&2
  exit 1
fi

sed -e "s|-backfill-start=.*|-backfill-start=${BACKFILL_START}|" \
    -e "s|-backfill-hours=.*|-backfill-hours=${BACKFILL_HOURS}|" \
    -e "s|-backfill-step=.*|-backfill-step=${BACKFILL_STEP}|" \
    -e "s|-backfill-seed=.*|-backfill-seed=${BACKFILL_SEED}|" \
    backfill-job.yaml | kubectl apply -f -

kubectl -n perf-fakeserver wait --for=condition=ready pod -l job-name=backfill --timeout=5m
kubectl -n perf-fakeserver logs -f job/backfill

if [[ "$(kubectl -n perf-fakeserver get job backfill -o jsonpath='{.status.succeeded}')" != "1" ]]; then
  echo "error: the backfill did not complete; wipe the systems and start over." >&2
  exit 1
fi

cat <<'MSG'

Backfill complete. Before measuring (deploy/README.md#after-the-backfill):

  1. Every system must hold the "samples ... generated" count above. On both
     OpenObserves that takes ~1 min more (ZO_MAX_FILE_RETENTION_TIME=60):
       SELECT SUM(records) FROM file_list WHERE deleted=0
  2. Set ZO_COMPACT_ENABLED=true in both O2 values files and re-run their
     install.sh; compaction starts within a minute.
  3. Wait until every system has settled: O2 with no pending deletes, as many
     .midx files as data files and no merge for 10 minutes; VictoriaMetrics
     with no active merges; Prometheus and Mimir done compacting (and Mimir
     shipped).
  4. bench/run-in-cluster.sh --script cardinality.sh   # all four must agree
MSG
