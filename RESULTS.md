# Published results

The numbers from *"One Dataset, Four Systems — Benchmarking Prometheus, Mimir,
and OpenObserve on Metrics Ingestion and Queries"*, reproduced here so a local
run has something to compare against.

**All latencies are milliseconds. Each cell shows all three runs.** `error ×3`
means the system refused the query on every attempt — a result in its own right.

## Conditions

| | |
| --- | --- |
| Hardware | one EC2 `c7g.2xlarge` per system: 7 CPU / 14GB / gp3 500GB, single-node |
| Prometheus | `quay.io/prometheus/prometheus:v3.6.0` |
| Mimir | `grafana/mimir:latest` (pulled 2026-08) |
| OpenObserve | `0.92.0-rc3`, two deployments differing only in `ZO_FILE_FORMAT` |
| Load | `openobserve/fake-webserver:v2` × 24 pods, scraped every 15s |
| Total ingested | 7.1 billion samples |
| Query range | 2026-08-06 00:00–03:00 (CST), 3 runs per query |
| Caches | all query caches disabled |
| Pushdown | `ZO_FEATURE_PUSHDOWN_FILTER_ENABLED=false` (parquet only; ~20% slower when on) |

Cardinality of the two metrics under test:

| Metric | Series | Used by |
| --- | --- | --- |
| `codelab_api_request_duration_seconds_bucket` | 1,085,760 | the histogram queries |
| `codelab_api_request_duration_seconds_count` | 41,760 | the irate query |

The bucket count is exactly 26× the `_count` count: the histogram has 25
explicit buckets plus `+Inf`. `bench/cardinality.sh` checks this ratio — if
yours is not 26, your load generator differs from the published one.

Both figures are 24× what one fake-webserver pod contributes (~45,220 bucket /
~1,739 `_count`, measured), matching the `replicas: 24` in
`deploy/fake-webserver/deploy.yaml`.

## Ingestion: resource usage at steady state

| System | CPU (cores) | Memory | Disk |
| --- | --- | --- | --- |
| Prometheus | 0.6 | 2.0 GB | 19.9 GB |
| Mimir | 0.4 | 2.8 GB | 34 GB |
| OpenObserve (Parquet) | 1.0 | **0.9 GB** | 95 GB |
| OpenObserve (Vortex) | 1.0 | **0.9 GB** | 95 GB |

OpenObserve uses about a third of Mimir's memory and roughly double the CPU. Its
disk usage is the largest by a wide margin — a general-purpose columnar format
keeps full detail instead of applying TSDB-style XOR/delta compression tuned
specifically for time series. In production that data typically lives on object
storage rather than a local disk.

## 1 · irate

```promql
sum by (path) (irate(codelab_api_request_duration_seconds_count[1m]))
```

| Window | Prometheus | Mimir | O2 · Parquet | O2 · Vortex |
| --- | --- | --- | --- | --- |
| 30m | 913<br>710<br>713 | 801<br>812<br>773 | **80<br>89<br>82** | 94<br>97<br>102 |
| 1h | 1317<br>1553<br>1331 | 2501<br>2478<br>2467 | **144<br>156<br>156** | 149<br>163<br>173 |
| 3h | 3482<br>3450<br>3441 | 8745<br>8700<br>8649 | **408<br>415<br>409** | 437<br>433<br>435 |

At 3h, Parquet's 409ms median is ~8.4× faster than Prometheus and ~21× faster
than Mimir. Widening the window 6× (30m → 3h) costs Prometheus 4.8×, Mimir
10.9×, and OpenObserve 5× — but OpenObserve stays under half a second in
absolute terms.

## 2 · Unfiltered histogram

```promql
histogram_quantile(0.9, sum by(le, path) (
  rate(codelab_api_request_duration_seconds_bucket{}[5m])))
```

No label filter: `rate` + aggregation over all 1,085,760 series.

| Window | Prometheus | Mimir | O2 · Parquet | O2 · Vortex |
| --- | --- | --- | --- | --- |
| 30m | error ×3 | 21845<br>21655<br>21632 | 2037<br>2068<br>2054 | **2140<br>1966<br>1968** |
| 1h | error ×3 | 67674<br>66736<br>67011 | **6871<br>4176<br>4127** | 4200<br>4798<br>4824 |
| 3h | error ×3 | error ×3 | **16080<br>12272<br>12286** | 14090<br>13862<br>13875 |

Prometheus, on every window:

```
execution: query processing would load too many samples
into memory in query execution
```

Mimir, at 3h:

```
execution: the query exceeded the maximum number of chunks
(limit: 2000000 chunks) (err-mimir-max-chunks-per-query).
Consider reducing the time range and/or number of series
selected by the query.
```

Both are protective limits, and both can be raised — at the cost of letting a
single query consume far more memory on a 14GB machine. Left at defaults, only
OpenObserve answers on all three windows.

## 3 · Filtered histogram (regex match)

```promql
histogram_quantile(0.9, sum by(le, path) (
  rate(codelab_api_request_duration_seconds_bucket{path=~"$path"}[5m])))
```

| Window | Prometheus | Mimir | O2 · Parquet | O2 · Vortex |
| --- | --- | --- | --- | --- |
| 30m | 650<br>650<br>648 | 728<br>731<br>731 | 341<br>353<br>347 | **152<br>172<br>169** |
| 1h | 1199<br>1204<br>1201 | 2195<br>2189<br>2201 | 698<br>699<br>721 | **319<br>322<br>330** |
| 3h | 3178<br>3184<br>3272 | 8031<br>8010<br>8008 | 2192<br>2213<br>2200 | **944<br>915<br>887** |

## 4 · Filtered histogram (equality match)

```promql
histogram_quantile(0.9, sum by(le, path) (
  rate(codelab_api_request_duration_seconds_bucket{path="$path"}[5m])))
```

| Window | Prometheus | Mimir | O2 · Parquet | O2 · Vortex |
| --- | --- | --- | --- | --- |
| 30m | 651<br>646<br>651 | 804<br>729<br>724 | 352<br>354<br>343 | **154<br>164<br>175** |
| 1h | 1188<br>1187<br>1169 | 2187<br>2208<br>2234 | 744<br>713<br>713 | **328<br>317<br>325** |
| 3h | 3251<br>3141<br>3159 | 7993<br>8016<br>8085 | 2202<br>2197<br>2204 | **937<br>939<br>956** |

Regex and equality matching cost essentially the same on all four systems. The
filter *type* is not the variable; scan volume is.

## 3-hour medians, all queries

| Query | Prometheus | Mimir | O2 · Parquet | O2 · Vortex |
| --- | --- | --- | --- | --- |
| irate | 3450 | 8700 | **409** | 435 |
| Unfiltered histogram | error | error | **12286** | 13875 |
| Histogram, regex filter | 3184 | 8010 | 2200 | **915** |
| Histogram, equality filter | 3159 | 8016 | 2202 | **939** |

## Parquet vs Vortex

The two OpenObserve deployments differ only in `ZO_FILE_FORMAT`, and the results
split cleanly by query shape.

**Full scans tie.** On irate and the unfiltered histogram the two formats trade
places within 5–10%. Disk usage ties too, at 95GB each.

**Filtered queries go to Vortex, by 2× or more:**

| Filtered histogram (median, ms) | 30m | 1h | 3h |
| --- | --- | --- | --- |
| Regex · Parquet | 347 | 699 | 2200 |
| Regex · Vortex | **169** | **322** | **915** |
| Equality · Parquet | 352 | 713 | 2202 |
| Equality · Vortex | **164** | **325** | **939** |

2.1× at 30m, 2.2× at 1h, 2.4× at 3h — the edge grows with the window. The
"filter by service/endpoint" queries that dominate real dashboards are exactly
where Vortex gains most.

## Cold vs hot queries

OpenObserve's 3-hour histogram queries take **~30s on a cold run** (data not in
the OS page cache) versus ~2s hot. Dropping the page cache and re-running
restores the 30s.

The bottleneck is disk throughput, and the arithmetic is unambiguous:

```
promql->search->storage: load files 76,
scan_size 137424238093, compressed_size 3627283262, took: 3 ms
```

Locating the 76 files took 3ms; reading 3.6GB of compressed data off gp3 at its
default 125 MB/s takes 3.6GB ÷ 125 MB/s ≈ 29s. Switching the volume to io2
brought the same cold query to ~3.5s.

Reproduce with `bench/drop-caches.sh`.
