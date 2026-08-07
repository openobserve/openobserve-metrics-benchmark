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

# The `$path` in the article's filtered queries. fake-webserver generates
# /api/service-1 .. /api/service-50 plus /api/foo, /api/bar, /api/baz, /api/boom
# -- 54 paths, so one path selects roughly 1/54 of the bucket series.
# `./cardinality.sh paths` lists what your deployment actually produced.
: "${PATH_FILTER:=/api/service-1}"

# Query windows, in seconds: 30m, 1h, 3h.
: "${WINDOWS:=1800 3600 10800}"

# Resolution step for query_range.
#
# NOT pinned by the published article. 15s matches the scrape interval, so the
# number of returned points scales linearly with the window -- which is what the
# article's near-linear latency growth implies was used. If you change it,
# change it for every system and say so when you publish numbers: step is the
# single biggest lever on absolute latency in this whole benchmark.
: "${STEP:=15s}"

# Runs per (system, query, window). The article reports all three raw values.
: "${RUNS:=3}"

# End of the query range, RFC3339 or a unix timestamp. Default: 5 minutes ago,
# so the newest data is already flushed everywhere. Pin an absolute value when
# comparing across systems on different days.
#   END_TIME=2026-08-06T03:00:00+08:00 ./run-benchmark.sh
: "${END_TIME:=}"

# Per-request timeout. Mimir's unfiltered histogram legitimately runs >60s.
: "${CURL_TIMEOUT:=300}"

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
    *)     echo "$(( $1 / 60 ))m" ;;
  esac
}
