# bench/

Measurement scripts. Everything reads `config.sh`, and every value in it can be
overridden from the environment.

## Order of operations

```bash
./run-in-cluster.sh --script cardinality.sh   # do this FIRST
./run-in-cluster.sh                           # the benchmark
```

Both run from a pod inside the cluster; no port-forward and no second terminal.
`run-in-cluster.sh` is the one to use for timings. `run-benchmark.sh` is the
driver it runs by default; call it directly only when you already reach the four
systems without a port-forward. See [Measure from inside the
cluster](#measure-from-inside-the-cluster) — a port-forwarded run has a ~1-2
second floor under every number.

`--script` takes any `bench/` script that talks to the four systems over HTTP,
plus its own arguments:

```bash
./run-in-cluster.sh --script cardinality.sh paths
```

`resources.sh` and `drop-caches.sh` are not among them — they drive `kubectl`
rather than HTTP, and the runner pod has neither the binary nor the RBAC. Run
those from your workstation, where they never needed a port-forward either.

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

Query 2 is the stress test — it touches all ~1.08M bucket series. At stock
limits Prometheus and Mimir *refuse* it outright; `deploy/` raises those limits
so all four actually run it. `run-benchmark.sh` records any error text and
`summarize.py` renders an all-error cell as `error ×N`.

Queries 3 and 4 exist as a pair to show that the *filter type* barely matters —
scan volume does.

## Knobs

| Variable | Default | Notes |
| --- | --- | --- |
| `END_TIME` | 5 minutes ago | RFC3339 or unix ts. **Pin it** when comparing runs across days |
| `WINDOWS` | `1800 3600 10800` | Seconds: 30m, 1h, 3h |
| `STEP` | `15s` | Resolution for `query_range`. See the warning below |
| `RUNS` | `3` | Repeats per (system, query, window) |
| `WARMUP` | `1` | Cold first-touch request, recorded as run 0, excluded from medians |
| `SINGLE_RUN_CELLS` | `histogram-unfiltered:3h` | Cells recorded once instead of `RUNS` |
| `PATH_FILTER` | `/api/service-1` | The `$path` in queries 3 and 4 |
| `CURL_TIMEOUT` | `700` | Must exceed the servers' own 600s query timeout |
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

- `raw.csv` — one row per request: `query,window,system,run,http_code,latency_ms,series,error` (`run=0` is the cold request)
- `summary.md` — the article's tables, regenerated from `raw.csv`
- `run-metadata.txt` — the exact parameters used, so a CSV is never orphaned

Re-render a summary at any time:

```bash
./summarize.py ../results/<stamp>/raw.csv
```

Latency is `curl`'s `%{time_total}` — full client-observed wall time, which is
what a dashboard actually waits for.

### Measure from inside the cluster

**Do not publish numbers from a port-forwarded run.** The API-server hop cost
**~1,070ms** for a trivial `query=1` that Prometheus answers in microseconds;
the same request from an in-cluster pod cost **~5ms**.

The overhead is not a constant you can subtract — it grows with response size,
so it swamps a fast system and barely dents a slow one. Same `irate` query, same
`END_TIME`:

| System | via port-forward | in-cluster |
| --- | --- | --- |
| Prometheus | 3445 ms | 1287 ms |
| Mimir | 4181 ms | 1319 ms |
| OpenObserve · Parquet | 2122 ms | 158 ms |
| OpenObserve · Vortex | 1953 ms | 297 ms |

A real 8.1× gap reads as 1.6× through the tunnel. The fastest system is punished
hardest.

`run-in-cluster.sh` starts a runner pod on a node that is *not* under test (no
`perf` toleration, so it cannot steal CPU from what it measures), pinned to the
systems' AZ, runs the driver against ClusterIP DNS, and copies
`results/<stamp>/` back with a `measured_from` line in `run-metadata.txt`.

```bash
RUNS=5 WINDOWS="1800 3600" ./run-in-cluster.sh
O2_PARQUET_NS=my-parquet-ns O2_VORTEX_NS=my-vortex-ns ./run-in-cluster.sh
./run-in-cluster.sh --delete     # remove the runner pod
```

The pod is left running between invocations so repeat runs skip setup.

`port-forward.sh` survives only for what a pod cannot do: opening a UI in your
browser. Reaching a system that way is fine; *timing* one that way is not.

## Resource usage

```bash
./resources.sh            # one snapshot
./resources.sh 12 300     # 12 snapshots, 5 minutes apart
```

CPU and PVC usage come from one kubelet `/stats/summary` call per node, so no
metrics-server is needed.

> **Two memory columns, and they disagree.** `rss` is anonymous pages only;
> `workset` is cgroup `workingSetBytes` = rss + active page cache + kernel
> memory. A system writing data files continuously accumulates page cache, so
> OpenObserve reads ~1.5GB rss against ~10GB workset — by workset it looks like
> the heaviest of the four, by rss it is the lightest. **Compare on rss**, and
> say so when you publish. (rss excludes file-backed mmap pages, so it
> undercounts Prometheus and Mimir; they still land above OpenObserve.) CPU is an instantaneous rate — take several snapshots during
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
