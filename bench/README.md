# bench/

Measurement scripts. Everything reads `config.sh`, and every value in it can be
overridden from the environment.

The systems under test, in report order, are `prometheus`, `mimir`, `vm`,
and `o2-parquet` (reported as OpenObserve) — `SYSTEMS` in `config.sh`. Those labels are what
`SYSTEMS_FILTER`, `drop-caches.sh` and the results use. Remove a line from
`SYSTEMS` to leave a system out; nothing else depends on the count.

## Order of operations

```bash
./run-in-cluster.sh --script cardinality.sh   # do this FIRST
./run-in-cluster.sh                           # the benchmark
```

Both run from a pod inside the cluster; no port-forward and no second terminal.
`run-in-cluster.sh` is the one to use for timings. `run-benchmark.sh` is the
driver it runs by default; call it directly only when you already reach the
systems under test without a port-forward. See [Measure from inside the
cluster](#measure-from-inside-the-cluster) — a port-forwarded run has a ~1-2
second floor under every number.

`--script` takes any `bench/` script that talks to the systems under test over HTTP,
plus its own arguments:

```bash
./run-in-cluster.sh --script cardinality.sh paths
```

`resources.sh` and `drop-caches.sh` are not among them — they drive `kubectl`
rather than HTTP, and the runner pod has neither the binary nor the RBAC. Run
those from your workstation, where they never needed a port-forward either.

`cardinality.sh` is not optional. If the systems disagree on how many
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
limits **every** system refuses it outright; `deploy/` raises those limits so
they actually run it — see [deploy/README.md](../deploy/README.md#query-limits). `run-benchmark.sh` records any error text and
`summarize.py` renders an all-error cell as `error ×N`.

Queries 3 and 4 exist as a pair to show that the *filter type* barely matters —
scan volume does.

## Knobs

| Variable | Default | Notes |
| --- | --- | --- |
| `END_TIME` | 5 minutes ago | unix timestamp. **Pin it** when comparing runs across days |
| `WINDOWS` | `1800 3600 10800 21600` | Seconds: 30m, 1h, 3h, 6h |
| `STEP` | empty → per window | Empty means Grafana's rule, `max(15s, range/1000)` rounded up. See the warning below |
| `MAX_DATA_POINTS` / `MIN_INTERVAL` | `1000` / `15` | The two inputs to that rule |
| `RUNS` | `5` | Repeats per (system, query, window) |
| `WARMUP` | `1` | One warm-up request per cell, recorded as run 0, excluded from medians |
| `SINGLE_RUN_CELLS` | empty | Cells to record once instead of `RUNS`, e.g. `histogram-unfiltered:6h` |
| `PATH_FILTER` | `/api/bar` | The `$path` in queries 3 and 4. One of the four heavy paths — see `config.sh` |
| `CURL_TIMEOUT` | `700` | Must exceed the servers' own 600s query timeout |
| `SYSTEMS_FILTER` | — | Substring; run one system only |
| `QUERY_FILTER` | — | Substring; run one query only |
| `O2_USER` / `O2_PASS` | `root@example.com` / `Complexpass#123` | Must match the OpenObserve values files |

> **About `STEP`.** `query_range` requires one, and it is the largest single
> lever on absolute latency here — so state yours whenever you publish numbers.
> The default is not a fixed value: it is computed per window the way Grafana
> computes it, `max(15s, range/1000)` rounded up to a tidy interval, which caps
> the response at roughly a panel's width in points. Under that rule 30m/1h/3h
> all land on 15s (the scrape interval floors them) and only 6h widens, to 30s.
> Set `STEP` explicitly to pin one value for every window instead.

Examples:

```bash
# The backfilled dataset's window (2026-09-28 10:00 UTC), five recorded runs
RUNS=5 END_TIME=1790589600 ./run-in-cluster.sh

# Just the headline query, just one system
QUERY_FILTER=histogram-regex SYSTEMS_FILTER=o2-parquet ./run-benchmark.sh

# A generated path -- about half the bucket series of /api/bar, so about half
# the filtered-histogram numbers
PATH_FILTER=/api/service-1 ./run-benchmark.sh

# What paths exist?
./cardinality.sh paths
```

## Output

Each run creates `results/<UTC timestamp>/`:

- `raw.csv` — one row per request: `query,window,system,run,http_code,latency_ms,series,error` (`run=0` is the discarded warm-up request)
- `summary.md` — the article's tables, regenerated from `raw.csv`
- `run-metadata.txt` — the exact parameters used, so a CSV is never orphaned

Re-render a summary at any time:

```bash
./summarize.py ../results/<stamp>/raw.csv
```

Latency is `curl`'s `%{time_total}` — full client-observed wall time, which is
what a dashboard actually waits for.

### Measure from inside the cluster

**Do not publish numbers from a port-forwarded run.** Every request then goes
through the Kubernetes API server, which adds about a second, and more for
larger responses — it swamps a fast system and barely dents a slow one, so the
ratios between systems are lost.

`run-in-cluster.sh` starts a runner pod on a node that is *not* under test (no
`perf` toleration, so it cannot steal CPU from what it measures), pinned to the
systems' AZ, runs the driver against ClusterIP DNS, and copies
`results/<stamp>/` back with a `measured_from` line in `run-metadata.txt`.

```bash
RUNS=5 WINDOWS="1800 3600" ./run-in-cluster.sh
O2_PARQUET_NS=my-parquet-ns ./run-in-cluster.sh
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
> its workset can be several times its rss. **Compare on rss**, and say so
> when you publish. (rss excludes file-backed mmap pages, so it undercounts
> engines that mmap their chunk files.) CPU is an instantaneous rate — take several snapshots during
steady-state ingestion rather than trusting one reading. Disk only means
something after ingestion has run long enough to compact.
