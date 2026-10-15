# Results

2026-10-15 · OpenObserve v1.1.0 against Prometheus, Grafana Mimir and
VictoriaMetrics.

**All latencies are milliseconds of client-observed wall time, median of the
recorded runs.** Bold is the fastest system in that row.

## Headline

On the same 1.34M-series dataset, at 12 CPU / 24 GB each, OpenObserve answers
**every one of the 16 cells fastest** — geomean **0.31×** VictoriaMetrics'
latency, **6.1%** of Mimir's and **2.0%** of Prometheus'. The million-series
histogram over 6 hours takes OpenObserve **3.7 s**, VictoriaMetrics 8.8 s,
Mimir 71 s and Prometheus 4 m 17 s.

## Conditions

| | |
| --- | --- |
| Hardware | one EC2 `m7gd.4xlarge` per system: 16 vCPU / 64 GiB, local NVMe, single node |
| Container limit | **12 CPU / 24 GB**, requests == limits, for ingest, compaction **and** queries |
| Prometheus | `quay.io/prometheus/prometheus:v3.6.0` |
| Mimir | `grafana/mimir:latest` = `sha256:04068a0a838b…` (pulled 2026-10-15) |
| VictoriaMetrics | `victoriametrics/victoria-metrics:v1.154.0`, single node |
| OpenObserve | `public.ecr.aws/zinclabs/openobserve:v1.1.0-debug` — the release `release-prod` + `mimalloc` binary on a Debian base with a shell; `ZO_FILE_FORMAT=parquet` |
| OpenObserve settings | `ZO_METRICS_INDEX_ENABLED=true`, `ZO_FILE_MERGE_THREAD_NUM=1` (see below), `ZO_COMPACT_MAX_FILE_SIZE` at its 2 GB default, result cache off, pushdown filter off |
| Load | `openobserve/fake-webserver:v5` backfill: 14 simulated nodes, 7 h at exactly 15 s, seed 1, one Job writing the same remote-write requests to every system |
| Data | 2026-09-28 03:00–10:00 UTC; queries end at 10:00 UTC (`END_TIME=1790589600`) |
| Windows / step | 30m, 1h, 3h at 15 s; 6h at 30 s |
| Filter | `path="/api/bar"` / `path=~"/api/bar"` — one of the four heavy paths |
| Runs | 5 recorded per cell plus one cold request; the unfiltered 3h and 6h cells once. **Two back-to-back passes pooled** (`20261015T070559Z`, `20261015T074822Z`) |
| Measured from | a pod in the cluster, same AZ, on a node not under test |

## Ingest

The backfill wrote **2,218,011,632 samples** (1,680 points × 1,338,330 series)
in **1 h 19 m 42 s**, 463.8k samples/s to each target, 222,369 requests each,
**0 retries, 0 rejected** — Prometheus and Mimir accepted it with a 2 h
out-of-order window. Every system then held exactly that many samples
(OpenObserve: `SUM(records) FROM file_list`).

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

No errors, no restarts. The two passes agreed within 25% on every cell but one
(an 11 ms difference on a ~30 ms cell).

| Query | Window | Prometheus | Mimir | VictoriaMetrics | OpenObserve |
| --- | --- | --- | --- | --- | --- |
| irate | 30m | 1,335 | 572 | 164 | **26** |
| | 1h | 2,198 | 778 | 210 | **40** |
| | 3h | 8,112 | 1,557 | 281 | **84** |
| | 6h | 10,402 | 2,552 | 314 | **112** |
| Unfiltered histogram | 30m | 33,514 | 14,850 | 4,152 | **498** |
| | 1h | 61,054 | 19,790 | 6,127 | **986** |
| | 3h | 196,290 | 43,092 | 7,898 | **2,698** |
| | 6h | 256,860 | 71,273 | 8,804 | **3,701** |
| Filtered, equality | 30m | 626 | 390 | 92 | **18** |
| | 1h | 1,137 | 491 | 120 | **33** |
| | 3h | 3,717 | 907 | 154 | **78** |
| | 6h | 4,694 | 1,350 | 168 | **116** |
| Filtered, regex | 30m | 614 | 380 | 92 | **24** |
| | 1h | 1,115 | 476 | 121 | **38** |
| | 3h | 3,725 | 894 | 150 | **86** |
| | 6h | 4,701 | 1,356 | 169 | **132** |
| **Geomean, 16 cells** | | 6,113 | 2,028 | 400 | **123** |
| vs VictoriaMetrics | | 15.3× | 5.06× | 1.00× | **0.31×** |

OpenObserve's lead is largest where the most data is scanned — the unfiltered
histogram at 30m is 8.3× faster than VictoriaMetrics — and smallest on the long
filtered histograms, 1.3–1.5× at 6h. Its cold first request barely differs from
the warm runs (unfiltered 30m: 509 ms cold); VictoriaMetrics' first touch of
that cell took 13.7 s against 4.2 s warm.

## Storage

After settling, from each system's own accounting:

| System | On disk | Of which |
| --- | --- | --- |
| VictoriaMetrics | **1.06 GB** | |
| OpenObserve | 2.23 GB | data 1.553 GB + `.midx` (metrics index) 0.673 GB, 537 files |
| Prometheus | 5.93 GB | blocks 1.74 GB; head chunks 1.01 GB + WAL 3.19 GB hold the last ~3 h, by design |
| Mimir | 11.0 GB | object store 5.8 GB, ingester copies 5.2 GB — not settled, see below |

Mimir's figure double-counts: ingester-local copies are kept 13 h after upload
and pre-compaction blocks 12 h after compaction. `deploy/mimir/deploy.yaml` now
shortens both (see *Changes for the next round*).

## What had to be configured, and why

**`ZO_FILE_MERGE_THREAD_NUM=1`.** Switching compaction on after the backfill
queues an hour of ~290 one-minute files per stream at once. At the default of
6 merge workers (CPU/2) at 24 GB, OpenObserve reached 22.6 GB within four
minutes, and a second deployment running the same merge was OOMKilled. One
290-file merge peaks at ~5 GiB RSS (`VmHWM`) while DataFusion accounts for
~950 MB of it; six at once do not fit. With one worker the merge finished
without a restart. The setting does not touch the query path: in standalone
mode the DataFusion memory pool is sized from memory, not from this count. A
live system merges a few files at a time and would not hit this; a backlog
(backfill, or compaction paused) does.

**Mimir read through ingesters and store-gateway in this round.** With
`query_ingesters_within: 0` the querier asked both for the 17-day-old data and
de-duplicated. The next round's config reads it from the store-gateway only.

## Changes for the next round

`deploy/mimir/deploy.yaml` now settles Mimir about 30 minutes after a backfill,
with one copy of the data, read from object storage like the other systems read
their disk: `head_compaction_idle_timeout: 5m`, `retention_period: 15m`,
`sync_interval: 1m`, `ignore_deletion_mark_delay: 5m`,
`ignore_deletion_mark_while_querying_delay: 4m`,
`first_level_compaction_wait_period: 1m`, `compaction_interval: 5m`,
`cleanup_interval: 5m`, `deletion_delay: 10m`, and `query_ingesters_within`
back to its 13 h default. Mimir validates two of these at startup: the
while-querying delay must exceed 3× `sync_interval` and stay below
`ignore_deletion_mark_delay`.

## Open issues found

- OpenObserve's stream stats (`/api/default/streams`) report 158M documents
  against 2,218M actual, although their offset kept up with `file_list`.
  Something in the backfill → compaction-on → OOM → restart sequence broke the
  incremental totals; `file_list` is correct. Not yet root-caused.
- `bench/cardinality.sh` asks OpenObserve for the all-metrics total with a
  selector that has no metric name, which it rejects; the per-stream SQL above
  is the equivalent.

## Note

We removed Vortex from these results: with the new metrics index (`.midx`),
OpenObserve on Vortex queries no faster than on Parquet, yet it takes more than
twice the disk — 5.19 GB against 2.23 GB on this dataset (data 4.52 GB vs
1.55 GB; the `.midx` is the same 0.67 GB on both).
