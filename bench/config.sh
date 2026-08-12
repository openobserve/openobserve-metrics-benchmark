#!/usr/bin/env bash
# Shared configuration. Sourced by every script in bench/.
# Every value can be overridden from the environment:
#   PATH_FILTER=/api/foo ./run-benchmark.sh

# -----------------------------------------------------------------------------
# Endpoints
#
# Defaults assume `./port-forward.sh` is running in another terminal. That is
# fine for cardinality.sh, but NOT for timing queries: the API-server hop puts a
# ~1-2s floor under every request. `./run-in-cluster.sh` overrides these four
# with in-cluster Service DNS and is what you want for any number you intend to
# publish. (resources.sh and drop-caches.sh ignore these endpoints entirely --
# they go through kubectl.)
#
# If you reach the systems some other way (ingress, LoadBalancer, a host in the
# same VPC), point these at those URLs instead -- everything else still works.
#
# Note the path prefixes: Prometheus serves the API at the root, Mimir under
# /prometheus, OpenObserve under /api/{org}/prometheus.
# -----------------------------------------------------------------------------
: "${PROM_BASE:=http://localhost:19090}"
: "${MIMIR_BASE:=http://localhost:19009/prometheus}"
: "${O2_PARQUET_BASE:=http://localhost:15081/api/default/prometheus}"
: "${O2_VORTEX_BASE:=http://localhost:15082/api/default/prometheus}"

# OpenObserve basic auth -- must match `auth:` in the two values.yaml files.
: "${O2_USER:=root@example.com}"
: "${O2_PASS:=Complexpass#123}"

# The four systems under test, in report order. Format: label|base_url|auth
# (auth is empty for the systems that need none).
SYSTEMS=(
  "prometheus|${PROM_BASE}|"
  "mimir|${MIMIR_BASE}|"
  "o2-parquet|${O2_PARQUET_BASE}|${O2_USER}:${O2_PASS}"
  "o2-vortex|${O2_VORTEX_BASE}|${O2_USER}:${O2_PASS}"
)

# -----------------------------------------------------------------------------
# Query parameters
# -----------------------------------------------------------------------------

# The `$path` in the filtered queries. fake-webserver produces 54 paths, but
# NOT of equal weight -- they come in two classes:
#
#   /api/service-1 .. /api/service-50   25,740 bucket series each
#   /api/foo /api/bar /api/baz /api/boom   51,480 each  (exactly 2x)
#
# So the filtered-histogram numbers roughly double depending on which class you
# pick. RESULTS uses /api/bar; a generated path measures about half of what is
# published there. `./cardinality.sh paths` lists what your deployment produced.
: "${PATH_FILTER:=/api/bar}"

# Query windows, in seconds: 30m, 1h, 3h, 6h.
: "${WINDOWS:=1800 3600 10800 21600}"

# Resolution step for query_range.
#
# Empty (the default) means "compute it per window the way Grafana does":
#
#   step = max(MIN_INTERVAL, range / MAX_DATA_POINTS), rounded up to a tidy
#   interval
#
# A fixed 15s makes the point count grow linearly with the window -- 1440
# points at 6h -- which no dashboard would ever ask for, because Grafana caps
# requests at roughly the panel width in pixels. Under this rule 30m/1h/3h all
# still land on 15s (the scrape interval floors them) and only 6h widens to
# 30s, holding the response at 720 points.
#
# Set STEP explicitly to pin one value for every window instead. Step is the
# single biggest lever on absolute latency here, so publish whichever you used.
: "${STEP:=}"
: "${MAX_DATA_POINTS:=1000}"
: "${MIN_INTERVAL:=15}"

# Runs per (system, query, window). The article reports all three raw values.
: "${RUNS:=3}"

# Cold first-touch request per cell, recorded as run 0 and kept OUT of the
# medians -- summarize.py reports it separately. It measures file opens, index
# loads and page cache misses, not steady-state query cost; measured up to 10x
# the warm value. WARMUP=0 folds it into the recorded runs instead.
: "${WARMUP:=1}"

# Cells getting ONE recorded run instead of RUNS, as `query-id:window`. A 3h
# unfiltered request costs minutes (Mimir: 351s) and its spread is dominated by
# scan volume, not run-to-run noise. Run 0 still happens.
: "${SINGLE_RUN_CELLS:=histogram-unfiltered:3h histogram-unfiltered:6h}"

# End of the query range, RFC3339 or a unix timestamp. Default: 5 minutes ago,
# so the newest data is already flushed everywhere. Pin an absolute value when
# comparing across systems on different days.
#   END_TIME=2026-08-06T03:00:00+08:00 ./run-benchmark.sh
: "${END_TIME:=}"

# Per-request timeout. MUST exceed the servers' own query timeout (600s, see
# deploy/README.md#query-limits) or curl cuts a query off first and the CSV
# records our threshold as if it were the system's. Mimir's 3h unfiltered
# histogram measured 351s.
: "${CURL_TIMEOUT:=700}"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

die() { echo "error: $*" >&2; exit 1; }

# Resolve END_TIME to a unix timestamp. GNU date and BSD/macOS date disagree on
# flags, so try both.
resolve_end_time() {
  if [[ -z "${END_TIME}" ]]; then
    echo $(( $(date +%s) - 300 ))
    return
  fi
  if [[ "${END_TIME}" =~ ^[0-9]+$ ]]; then
    echo "${END_TIME}"
    return
  fi
  date -d "${END_TIME}" +%s 2>/dev/null && return
  date -j -f "%Y-%m-%dT%H:%M:%S%z" "${END_TIME}" +%s 2>/dev/null && return
  die "cannot parse END_TIME='${END_TIME}' (use a unix timestamp or RFC3339 like 2026-08-06T03:00:00+08:00)"
}

human_window() {
  case "$1" in
    1800)  echo "30m" ;;
    3600)  echo "1h"  ;;
    10800) echo "3h"  ;;
    21600) echo "6h"  ;;
    *)     echo "$(( $1 / 60 ))m" ;;
  esac
}

# The intervals Grafana will actually round up to.
TIDY_INTERVALS="1 2 5 10 15 20 30 60 120 300 600 900 1200 1800 3600 7200 10800 21600 43200 86400"

# step_for_window <range_seconds> -> e.g. "15s"
step_for_window() {
  if [[ -n "${STEP}" ]]; then echo "${STEP}"; return; fi
  local raw=$(( $1 / MAX_DATA_POINTS ))
  (( raw < MIN_INTERVAL )) && raw="${MIN_INTERVAL}"
  local i
  for i in ${TIDY_INTERVALS}; do
    (( i >= raw )) && { echo "${i}s"; return; }
  done
  echo "86400s"
}
