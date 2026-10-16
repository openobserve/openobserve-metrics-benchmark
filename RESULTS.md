# Results

2026-10-15 · OpenObserve v1.1.0 against Prometheus, Grafana Mimir and
VictoriaMetrics.

**All latencies are milliseconds of client-observed wall time, median of the
recorded runs.** Bold is the fastest system in that row.

## Headline

On the same 1.34M-series dataset, at 12 CPU / 24 GB each, OpenObserve answers
**every one of the 16 cells fastest** — geomean **0.32×** VictoriaMetrics'
latency, **11%** of Mimir's and **2.0%** of Prometheus'. The million-series
histogram over 6 hours takes OpenObserve **3.7 s**, VictoriaMetrics 9.2 s,
Mimir 26.7 s and Prometheus 4 m 12 s.

## Conditions

| | |
| --- | --- |
| Hardware | one EC2 `m7gd.4xlarge` per system: 16 vCPU / 64 GiB, local NVMe, single node |
| Container limit | **12 CPU / 24 GB**, requests == limits, for ingest, compaction **and** queries |
| Prometheus | `quay.io/prometheus/prometheus:v3.6.0` |
| Mimir | `grafana/mimir:latest` = `sha256:04068a0a838b…` (pulled 2026-10-15) |
| VictoriaMetrics | `victoriametrics/victoria-metrics:v1.154.0`, single node |
| OpenObserve | `public.ecr.aws/zinclabs/openobserve:v1.1.0-debug` — the release `release-prod` + `mimalloc` binary on a Debian base with a shell |
| OpenObserve settings | defaults, plus `ZO_METRICS_INDEX_ENABLED=true`, result cache off and raised metrics query limits |
| Mimir settings | background timers shortened so it settles ~30 min after a backfill and answers old data from object storage only — see `deploy/mimir/deploy.yaml` |
| Load | `openobserve/fake-webserver:v5` backfill: 14 simulated nodes, 7 h at exactly 15 s, seed 1, one Job writing the same remote-write requests to every system |
| Data | 2026-09-28 03:00–10:00 UTC; queries end at 10:00 UTC (`END_TIME=1790589600`) |
| Windows / step | 30m, 1h, 3h at 15 s; 6h at 30 s |
| Filter | `path="/api/bar"` / `path=~"/api/bar"` |
| Runs | 5 recorded per cell plus one cold request; the unfiltered 3h and 6h cells once. **Two back-to-back passes pooled** (`20261015T160054Z`, `20261015T163651Z`) |
| Measured from | a pod in the cluster, same AZ, on a node not under test |

## Ingest

The backfill wrote **2,218,011,632 samples** (1,680 points × 1,338,330 series)
in **1 h 16 m 40 s**, 482.1k samples/s to each system, 222,369 requests each,
**0 retries, 0 rejected** — Prometheus and Mimir accept it with a 2 h
out-of-order window. Every system then held exactly that many samples
(OpenObserve: `SUM(records) FROM file_list`).

## Settling

Every system finished its post-ingest work before the first query. Time from
the end of the backfill:

| System | Settled after | What it waited for |
| --- | --- | --- |
| VictoriaMetrics | 5 min | no active merges |
| Prometheus | 16 min | no head compaction for 10 min |
| OpenObserve | 22 min | compaction switched on after the flush (3.5 min), merged in 7 min, merged-away inputs deleted after `ZO_COMPACT_DELETE_FILES_DELAY_MINUTES=10` |
| Mimir | 26 min | head idle-compacted and shipped, compactor merged and deleted the superseded blocks, store-gateway synced |

OpenObserve merged with its default worker count (half the CPUs, 6). Every
hour reached the compactor as ~290 one-minute files at once, and the process
peaked at **22.2 GiB RSS against a 22.35 GiB limit** — it finished without a
restart, but a larger backlog per hour would not fit in 24 GB.

## Cardinality

Verified at `END_TIME` on every system (OpenObserve: `COUNT(DISTINCT __hash__)`
per stream over the last 5 minutes, summed):

| Metric | Series | Used by |
| --- | --- | --- |
| `codelab_api_request_duration_seconds_bucket` | 1,179,360 | the histogram queries |
| `codelab_api_request_duration_seconds_count` | 45,360 | irate |
| `codelab_api_request_duration_seconds_sum` | 45,360 | |
| `codelab_api_requests_total` | 45,360 | |
| `codelab_api_request_errors_total` | 22,680 | |
| `codelab_api_http_requests_in_progress` | 210 | |
| **total** | **1,338,330** | identical everywhere |

## Results

No errors, no restarts.

| Query | Window | Prometheus | Mimir | VictoriaMetrics | OpenObserve |
| --- | --- | --- | --- | --- | --- |
| irate | 30m | 1,332 | 348 | 132 | **23** |
| | 1h | 2,360 | 428 | 164 | **36** |
| | 3h | 7,534 | 770 | 237 | **80** |
| | 6h | 9,781 | 1,045 | 339 | **112** |
| Unfiltered histogram | 30m | 33,653 | 6,738 | 4,164 | **506** |
| | 1h | 60,159 | 9,450 | 4,704 | **964** |
| | 3h | 193,082 | 20,222 | 7,222 | **2,663** |
| | 6h | 252,336 | 26,704 | 9,246 | **3,672** |
| Filtered, equality | 30m | 620 | 273 | 84 | **19** |
| | 1h | 1,102 | 329 | 110 | **34** |
| | 3h | 3,678 | 534 | 138 | **78** |
| | 6h | 4,631 | 652 | 176 | **114** |
| Filtered, regex | 30m | 640 | 274 | 82 | **22** |
| | 1h | 1,206 | 324 | 110 | **36** |
| | 3h | 3,650 | 534 | 138 | **86** |
| | 6h | 4,604 | 646 | 228 | **134** |
| **Geomean, 16 cells** | | 6,077 | 1,090 | 374 | **120** |
| vs VictoriaMetrics | | 16.2× | 2.91× | 1.00× | **0.32×** |

OpenObserve's lead is largest where the most data is scanned — the unfiltered
histogram at 30m is 8.2× faster than VictoriaMetrics — and smallest on the long
filtered histograms, 1.5–1.7× at 6h. Its cold first request barely differs
from the warm runs (unfiltered 30m: 510 ms cold); VictoriaMetrics' first touch
of that cell took 4.3 s, and of irate 30m 917 ms against 132 ms warm.

## Storage

After settling, from each system's own accounting:

| System | On disk | Of which |
| --- | --- | --- |
| OpenObserve | 2.23 GB | data 1.552 GB + `.midx` (metrics index) 0.673 GB, 537 files |
| VictoriaMetrics | 1.32 GB | 10 small parts + 1 big part, 42 minutes after the backfill |
| Prometheus | 5.43 GB | blocks 1.74 GB; head chunks 0.51 GB + WAL 3.19 GB hold the last ~3 h, by design |
| Mimir | 5.51 GB | object storage 1.94 GB (one compacted block — what queries read); ingester WAL 2.7 GB + newest local block 0.64 GB |

Mimir's ingester keeps its WAL and newest block until `close_idle_tsdb_timeout`
(13 h) closes the idle TSDB.

## Note

We removed Vortex from these results: with the new metrics index (`.midx`),
OpenObserve on Vortex queries no faster than on Parquet, yet it takes more than
twice the disk — 5.19 GB against 2.23 GB on this dataset (data 4.52 GB vs
1.55 GB; the `.midx` is the same 0.67 GB on both).
