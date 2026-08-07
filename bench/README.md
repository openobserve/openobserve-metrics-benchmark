# bench/

Measurement scripts. Everything reads `config.sh`, and every value in it can be
overridden from the environment.

## Order of operations

```bash
./port-forward.sh      # terminal 1, leave running
./cardinality.sh       # terminal 2 — do this FIRST
./run-benchmark.sh
```

`cardinality.sh` is not optional. If the four systems disagree on how many
series they hold, they did not receive the same data and the latency numbers
compare nothing. Fix that before you measure anything.

## The four queries

Defined in `queries.sh`, verbatim from the article:

```promql
# 1. irate — the everyday "request rate by endpoint" panel
sum by (path) (irate(codelab_api_request_duration_seconds_count[1m]))

# 2. unfiltered histogram — every bucket series, no filter at all
histogram_quantile(0.9, sum by(le, path) (
  rate(codelab_api_request_duration_seconds_bucket{}[5m])))

# 3. filtered histogram, regex match
histogram_quantile(0.9, sum by(le, path) (
  rate(codelab_api_request_duration_seconds_bucket{path=~"$path"}[5m])))

# 4. filtered histogram, equality match
histogram_quantile(0.9, sum by(le, path) (
  rate(codelab_api_request_duration_seconds_bucket{path="$path"}[5m])))
```

Query 2 is the stress test — it touches all ~1.08M bucket series. **Prometheus
and Mimir are expected to return errors on it.** That is the finding, not a
failed run; `run-benchmark.sh` records the error text and `summarize.py` renders
those cells as `error ×3`.

Queries 3 and 4 exist as a pair to show that the *filter type* barely matters —
scan volume does.

## Knobs

| Variable | Default | Notes |
| --- | --- | --- |
| `END_TIME` | 5 minutes ago | RFC3339 or unix ts. **Pin it** when comparing runs across days |
| `WINDOWS` | `1800 3600 10800` | Seconds: 30m, 1h, 3h |
| `STEP` | `15s` | Resolution for `query_range`. See the warning below |
| `RUNS` | `3` | Repeats per (system, query, window) |
| `PATH_FILTER` | `/api/service-1` | The `$path` in queries 3 and 4 |
| `CURL_TIMEOUT` | `300` | Mimir's unfiltered histogram legitimately runs >60s |
| `SYSTEMS_FILTER` | — | Substring; run one system only |
| `QUERY_FILTER` | — | Substring; run one query only |
| `O2_USER` / `O2_PASS` | `root@example.com` / `Complexpass#123` | Must match the OpenObserve values files |

> **About `STEP`.** The published article does not record the step it used, and
> `query_range` requires one. `15s` matches the scrape interval, so the point
> count scales linearly with the window — consistent with the near-linear
> latency growth the article reports. It is still an assumption. Step is the
> largest single lever on absolute latency in this benchmark, so state yours
> whenever you publish numbers.

Examples:

```bash
# Reproduce the article's exact window
END_TIME=2026-08-06T03:00:00+08:00 ./run-benchmark.sh

# Just the headline query, just Vortex
QUERY_FILTER=histogram-regex SYSTEMS_FILTER=o2-vortex ./run-benchmark.sh

# A different endpoint, in case /api/service-1 is unusually quiet
PATH_FILTER=/api/foo ./run-benchmark.sh

# What paths exist?
./cardinality.sh paths
```

## Output

Each run creates `results/<UTC timestamp>/`:

- `raw.csv` — one row per request: `query,window,system,run,http_code,latency_ms,series,error`
- `summary.md` — the article's tables, regenerated from `raw.csv`
- `run-metadata.txt` — the exact parameters used, so a CSV is never orphaned

Re-render a summary at any time:

```bash
./summarize.py ../results/<stamp>/raw.csv
```

Latency is `curl`'s `%{time_total}` — full client-observed wall time, which is
what a dashboard actually waits for. With `port-forward.sh` that includes a hop
through the API server. It is the same hop for every system, so it does not bias
the comparison, but it does inflate absolutes by a few ms; run from inside the
cluster if you want the cleanest numbers.

## Resource usage

```bash
./resources.sh            # one snapshot
./resources.sh 12 300     # 12 snapshots, 5 minutes apart
```

CPU, memory and PVC usage all come from one kubelet `/stats/summary` call per
node, so the three numbers are consistent with each other and no metrics-server
is needed. CPU is an instantaneous rate — take several snapshots during
steady-state ingestion rather than trusting one reading. Disk only means
something after ingestion has run long enough to compact.

## Cold queries

```bash
./drop-caches.sh o2-vortex
SYSTEMS_FILTER=o2-vortex QUERY_FILTER=histogram-regex RUNS=1 ./run-benchmark.sh
```

This evicts the OS page cache on the node hosting that system, so the next query
reads from disk. The article's cold/hot gap (~30s vs ~2s on the 3h histogram) is
disk bandwidth, not query engine: the query pulls ~3.6GB of compressed data, and
3.6GB ÷ 125 MB/s ≈ 29s on gp3's default throughput. The same query took ~3.5s on
io2. Expect your own numbers to track your own disk.

`drop-caches.sh` affects everything on that node, not just the system named.
Only run it against dedicated benchmark nodes.
