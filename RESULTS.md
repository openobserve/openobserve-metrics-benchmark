# Results

Measured with the manifests and scripts in this repo, from inside the cluster.
Every number here was produced by `bench/run-in-cluster.sh` against the four
systems ingesting byte-identical data.

**All latencies are milliseconds, median of the recorded runs.** Bold is the
fastest system in that row.

## Conditions

| | |
| --- | --- |
| Hardware | one EC2 `m7g.2xlarge` per system: 8 vCPU / 32 GiB, container limit 7 CPU / 28G, gp3 500Gi, single-node |
| Prometheus | `quay.io/prometheus/prometheus:v3.6.0` |
| Mimir | `grafana/mimir:latest` (pulled 2026-08) |
| OpenObserve | `0.92.0-rc1-b31ff6c`, two deployments differing only in `ZO_FILE_FORMAT` |
| Load | `openobserve/fake-webserver:v2` × 24 pods, scraped every 15s |
| Query range | 2026-08-07 08:00–11:00 UTC, pinned absolutely |
| Step | `15s` (720 points at 3h) |
| Query limits | raised to match across all four — see [deploy/README.md](deploy/README.md#query-limits) |
| Query timeout | 600s everywhere, matching OpenObserve's default |
| Caches | OpenObserve result cache off; OS page cache dropped on all four nodes before each round |
| Pushdown | `ZO_FEATURE_PUSHDOWN_FILTER_ENABLED=false` (parquet only; ~20% slower when on) |
| Measured from | a pod in the cluster, same AZ as all four systems |

Ingestion was **stopped** before measuring, so all four query a frozen, identical
dataset. Every run pins the same absolute `END_TIME`, so repeated runs are
directly comparable.

### Cardinality

| Metric | Series | Used by |
| --- | --- | --- |
| `codelab_api_request_duration_seconds_bucket` | 1,085,760 | the histogram queries |
| `codelab_api_request_duration_seconds_count` | 41,760 | the irate query |

Verified identical on all four systems. The bucket count is exactly 26× the
`_count` count: 25 explicit buckets plus `+Inf`.

Within the 3-hour window the *union* of bucket series is ~1,357,200 — 25% above
the instantaneous count, because pods were rescheduled during ingestion and each
new pod identity creates new series. That union is what the queries actually
scan.

### Method

- 3 recorded runs per cell, plus one **cold** first-touch request recorded
  separately as run 0 and excluded from the medians.
- Whole benchmark repeated 3× with all four nodes' page caches dropped between
  rounds.
- Prometheus and both OpenObserve deployments reached steady state in round 1
  (coefficient of variation across rounds: median 1.9%, max 4.2%), so their
  numbers are the median over rounds 1–3.
- **Mimir needed ~3 full rounds to reach steady state** and its numbers are the
  median over rounds 4–6, by which point consecutive rounds agreed within 2.4%.
  See [Mimir's warmup](#mimirs-warmup).

## Ingestion: resource usage

Measured over a 3-hour steady-state ingestion window (2026-08-07 07:00–10:00
UTC), from the container metrics reported per pod.

| System | CPU (cores, typical) | CPU (peak) | Memory | Disk after compaction |
| --- | --- | --- | --- | --- |
| Prometheus | 1.25 | 2.3 | 2.8 → 4.3 GB, rising | 4.5 GB |
| Mimir | 0.9 | 2.2 | 4.0 → 5.2 GB, rising | 7.4 GB |
| OpenObserve (Parquet) | 2.4 | 3.0 | **1.2 → 1.5 GB, flat** | 15.5 GB |
| OpenObserve (Vortex) | 2.0 | 3.8 | **1.4 → 1.8 GB, flat** | 15.1 GB |

**Memory is where the systems differ most.** OpenObserve holds 1.2–1.8 GB and
stays flat for the whole window — roughly a third of Prometheus's memory and a
quarter of Mimir's. Both of the others climb steadily across the same three
hours; neither had levelled off by the end.

**CPU is the trade.** OpenObserve runs at ~2.0–2.4 cores against Prometheus's
~1.25 and Mimir's ~0.9 — about 2× and 2.5× respectively.

> **On measuring memory.** These figures are **RSS** (`k8s.pod.memory.rss`,
> anonymous pages only). Which metric you pick decides the answer here:
>
> | | OpenObserve | Prometheus |
> | --- | --- | --- |
> | RSS | 1.5 GB | 4.3 GB |
> | cgroup `workingSetBytes` | ~10 GB | ~3.5 GB |
>
> The ordering inverts. `workingSetBytes` is RSS *plus active page cache
> charged to the cgroup*, and a system writing columnar files continuously
> accumulates a lot of that — page cache the kernel will reclaim on demand and
> which is not memory the process needs. RSS is the fairer basis for comparing
> what each system actually allocates.
>
> RSS is not perfect either: it excludes file-backed mmap pages, so it
> undercounts Prometheus and Mimir, which mmap their chunk files. They still
> come out well above OpenObserve. Report which metric you used.

Disk covers ~4.8 hours of ingestion, so the absolute figures are not comparable
to longer runs. The *ratio* is the durable part: OpenObserve stores ~3.4× what
Prometheus does and ~2.1× what Mimir does — a general-purpose columnar format
keeping full detail instead of TSDB-style XOR/delta compression tuned for time
series, in exchange for data that also serves SQL and arbitrary dimensional
analysis and maps naturally onto object storage.

### When disk usage actually settles

**Disk is the one number you cannot measure right after stopping ingestion.**
Taken 12 minutes after the last write, Prometheus read 6.1 GB and Mimir
10.8 GB; 38 hours later the same volumes held **4.5 GB and 7.4 GB** — 26% and
31% smaller. OpenObserve did not move. Two stable readings 30 seconds apart
prove nothing here.

The wait is not symmetric, and it is long:

| | Deletes merged-away files after | Disk settles at |
| --- | --- | --- |
| OpenObserve | 2h (`ZO_COMPACT_DELETE_FILES_DELAY_HOURS`) | **~2h** |
| Prometheus | immediately after compaction | ~2–3h |
| Mimir | 12h (`compactor.deletion_delay`) | **~14h** |

Mimir is the outlier, and **neither of its two timers can usefully be shortened**
— its PVC holds two copies of the data:

- the **filesystem bucket**, whose superseded source blocks the compactor keeps
  for `deletion_delay: 12h`
- the **ingester's local TSDB**, kept for `blocks_storage.tsdb.retention_period:
  13h` after upload

Lowering `deletion_delay` only moves the first drop earlier; the volume still
does not reach its final size until the 13-hour timer expires, so this repo
leaves it at the default. And `retention_period` must not be lowered at all: it
is deliberately aligned with `query_store_after: 12h` and
`query_ingesters_within: 13h`, and queries do not consult the bucket for data
newer than 12h. Drop the ingester's copy early and queries silently return
incomplete results — a far worse failure than an inflated disk number.

**So: wait ~14 hours, or state that your disk figures are provisional.**

**This biases the comparison in OpenObserve's favour, so measure late.** An
early reading inflates the systems OpenObserve is being compared against:

| Measured at | vs Prometheus | vs Mimir |
| --- | --- | --- |
| t+12min | 2.5× | 1.4× |
| t+38h (settled) | **3.4×** | **2.1×** |

OpenObserve uses more disk than either, and measuring too early understates by
how much.

## 1 · irate

```promql
sum by (path) (irate(codelab_api_request_duration_seconds_count[1m]))
```

| Window | Prometheus | Mimir | O2 · Parquet | O2 · Vortex |
| --- | --- | --- | --- | --- |
| 30m | 1,213 | 1,247 | 108 | **101** |
| 1h | 2,528 | 1,924 | 185 | **168** |
| 3h | 7,167 | 9,083 | **676** | 678 |

The everyday "request rate by endpoint" panel, over 41,760 series. Both
OpenObserve formats answer in well under a second on every window; at 3h they
are **10.6× faster than Prometheus** and 13.4× faster than Mimir. The two
formats tie — this query scans everything, so there is no filter for Vortex to
exploit.

## 2 · Unfiltered histogram

```promql
histogram_quantile(0.9, sum by(le, path) (
  rate(codelab_api_request_duration_seconds_bucket{}[5m])))
```

No label filter: `rate` + aggregation over all 1,085,760 series.

| Window | Prometheus | Mimir | O2 · Parquet | O2 · Vortex |
| --- | --- | --- | --- | --- |
| 30m | 34,491 | 34,754 | 4,970 | **4,710** |
| 1h | 66,635 | 56,162 | **8,388** | 8,986 |
| 3h | 197,427 | 260,224 | **27,049** | 27,629 |

**All four systems complete every window.** That is a change from earlier runs of
this benchmark, and it is a configuration result, not an engine result: at stock
settings Prometheus rejects this query outright with *"query processing would
load too many samples into memory"* and Mimir with
*"err-mimir-max-chunks-per-query"*. Both refusals are protective limits, and
this repo raises them (`--query.max-samples=1e9`,
`max_fetched_chunks_per_query=20e6`) so the engines actually run the query
rather than the limits deciding the outcome.

Once they do run it, the gap is large: at 3h OpenObserve is **7.3× faster than
Prometheus** and **9.6× faster than Mimir**, finishing in 27 seconds against 3.3
and 4.3 minutes. Prometheus beats Mimir on the 3h window despite losing at 1h.

## 3 · Filtered histogram (regex match)

```promql
histogram_quantile(0.9, sum by(le, path) (
  rate(codelab_api_request_duration_seconds_bucket{path=~"/api/service-1"}[5m])))
```

| Window | Prometheus | Mimir | O2 · Parquet | O2 · Vortex |
| --- | --- | --- | --- | --- |
| 30m | 568 | 633 | 688 | **229** |
| 1h | 1,128 | 1,004 | 1,196 | **406** |
| 3h | 3,403 | 4,542 | 4,316 | **1,472** |

## 4 · Filtered histogram (equality match)

```promql
histogram_quantile(0.9, sum by(le, path) (
  rate(codelab_api_request_duration_seconds_bucket{path="/api/service-1"}[5m])))
```

| Window | Prometheus | Mimir | O2 · Parquet | O2 · Vortex |
| --- | --- | --- | --- | --- |
| 30m | 595 | 634 | 700 | **234** |
| 1h | 1,214 | 1,004 | 1,195 | **412** |
| 3h | 3,421 | 4,543 | 4,305 | **1,458** |

Queries 3 and 4 exist as a pair to show that the **filter type barely matters**.
Regex and equality land within 2% of each other on every system and every window
— scan volume is the variable, not matcher syntax.

Filtering one path out of 54 changes the ranking completely. Vortex wins by
2.3× over Prometheus at 3h, while **Parquet loses to Prometheus** — the
selective filter is exactly what Vortex's layout exploits and what a full-scan
columnar format does not.

## 3-hour medians, all queries

| Query | Prometheus | Mimir | O2 · Parquet | O2 · Vortex |
| --- | --- | --- | --- | --- |
| irate | 7,167 | 9,083 | **676** | 678 |
| Unfiltered histogram | 197,427 | 260,224 | **27,049** | 27,629 |
| Histogram, regex filter | 3,403 | 4,542 | 4,316 | **1,472** |
| Histogram, equality filter | 3,421 | 4,543 | 4,305 | **1,458** |

## Parquet vs Vortex

The two OpenObserve deployments differ only in `ZO_FILE_FORMAT`, and the results
split cleanly by query shape.

**Full scans tie.** On irate and the unfiltered histogram the two formats trade
places within 7%. Disk usage ties too, at 15.5 vs 15.1 GB.

**Filtered queries go to Vortex, by ~3×:**

| Filtered histogram (median, ms) | 30m | 1h | 3h |
| --- | --- | --- | --- |
| Regex · Parquet | 688 | 1,196 | 4,316 |
| Regex · Vortex | **229** | **406** | **1,472** |
| Equality · Parquet | 700 | 1,195 | 4,305 |
| Equality · Vortex | **234** | **412** | **1,458** |

3.0× at 30m, 2.9× at 1h, 2.9× at 3h. The "filter by service/endpoint" queries
that dominate real dashboards are exactly where Vortex gains most.

## Cold vs hot queries

**There is no cold/hot gap in this configuration.** With the page cache dropped
on all four nodes, the first request of each cell is within 1.0–1.2× of the warm
median, on every system and every window:

| Query · window | Prometheus | Mimir | O2 · Parquet | O2 · Vortex |
| --- | --- | --- | --- | --- |
| irate · 3h | 7,312 / 7,167 | 9,070 / 9,083 | 690 / 676 | 685 / 678 |
| Unfiltered · 3h | 197,248 / 197,427 | 260,424 / 260,224 | 27,257 / 27,049 | 27,964 / 27,629 |
| Regex · 3h | 3,497 / 3,403 | 4,544 / 4,542 | 4,408 / 4,316 | 1,471 / 1,472 |

*(cold / warm)*

This is a memory-capacity result, not a storage one. Under the earlier 14G
envelope the same 3h filtered histogram measured **78.9s cold against 4.8s warm
— a 16.8× gap** — because OpenObserve's ~15.5 GB dataset could not fit in the
~11 GB of page cache available, while Prometheus's 4.5 GB could. That asymmetry
silently flattered whichever system fit in RAM.

At 28G every dataset fits, the gap disappears, and the comparison is about query
execution again. **If you shrink the memory envelope, re-check that the largest
dataset still fits before trusting any warm number.**

The disk still matters when data genuinely exceeds RAM: on gp3's default
125 MB/s profile, a query pulling 3.6 GB of compressed data cannot finish faster
than ~29s no matter what the engine does.

## Mimir's warmup

Mimir is the only system here that does not reach steady state immediately. Its
first pass is up to 3× slower than its converged value, and it takes about three
full passes to settle:

| Cell | Round 1 | Round 2 | Round 3 | Round 6 |
| --- | --- | --- | --- | --- |
| irate · 30m | 2,852 | 2,266 | 1,213 | 1,247 |
| irate · 1h | 3,743 | 3,021 | 1,911 | 1,924 |
| Unfiltered · 30m | 79,316 | 63,094 | 34,698 | 34,794 |
| Unfiltered · 1h | 104,906 | 56,204 | 56,262 | 56,144 |

The page cache was dropped between every round, so this is not OS-level caching
— it is Mimir's own in-process index and chunk caches filling up. Prometheus and
both OpenObserve deployments were already at steady state in round 1.

This is worth knowing operationally: a freshly restarted Mimir will serve its
first queries considerably slower than its steady-state numbers suggest.

## Reproducing

```bash
cd bench
./run-in-cluster.sh --script cardinality.sh    # verify all four agree first
END_TIME=<unix ts> ./run-in-cluster.sh
```

Pin `END_TIME` absolutely and stop ingestion first, or successive runs measure
different data. See [bench/README.md](bench/README.md) for every knob.
