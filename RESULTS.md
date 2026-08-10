# Results

Measured with the manifests and scripts in this repo, from inside the cluster,
against four systems ingesting byte-identical data onto local NVMe.

**All latencies are milliseconds, median of the recorded runs.** Bold is the
fastest system in that row.

The benchmark was run twice against the same frozen dataset, changing only the
memory limit: **28 GB** (generous) and **14 GB** (modest). Both are plausible
production sizings for ~1M active series, and the pair answers two different
questions — *how fast* at 28 GB, and *what still runs at all* at 14 GB.

## Conditions

| | |
| --- | --- |
| Hardware | one EC2 `m7gd.2xlarge` per system: 8 vCPU / 32 GiB, **474 GB local NVMe**, single-node |
| Container limit | 7 CPU, memory **28 GB** (round 1) then **14 GB** (round 2); requests == limits |
| Prometheus | `quay.io/prometheus/prometheus:v3.6.0` |
| Mimir | `grafana/mimir:latest` (pulled 2026-08) |
| OpenObserve | `0.92.0-rc1-b31ff6c`, two deployments differing only in `ZO_FILE_FORMAT` |
| Load | `openobserve/fake-webserver:v2` × 24 pods, scraped every 15s |
| Ingestion | 2026-08-09 12:47–21:10 CST (8h23m), then **stopped** |
| Query range | ends 2026-08-09 20:00 CST, pinned absolutely |
| Windows | 30m / 1h / 3h / 6h — 19:30, 19:00, 17:00, 14:00 → 20:00 |
| Step | per window, Grafana's rule — see below |
| Query limits | raised to match across all four — see [deploy/README.md](deploy/README.md#query-limits) |
| Query timeout | 600s everywhere, matching OpenObserve's default |
| Caches | OpenObserve result cache off; ingestion stopped, so all four query a frozen dataset |
| Pushdown | `ZO_FEATURE_PUSHDOWN_FILTER_ENABLED=false` (parquet only; ~20% slower when on) |
| Measured from | a pod in the cluster, same AZ as all four systems |

### Step is computed, not pinned

A fixed step makes the point count grow with the window — 1440 points at 6h —
which no dashboard would request. Grafana asks for roughly the panel width in
pixels, so this benchmark uses its rule: `max(15s, range / 1000)` rounded up to
a tidy interval. The 15s floor is the scrape interval.

| Window | Step | Points |
| --- | --- | --- |
| 30m / 1h / 3h | 15s | 120 / 240 / 720 |
| 6h | 30s | 720 |

Only the 6h window widens. Publish your step whichever way you go — it is the
single biggest lever on absolute latency here.

### Cardinality

| Metric | Series | Used by |
| --- | --- | --- |
| `codelab_api_request_duration_seconds_bucket` | 1,085,760 | the histogram queries |
| `codelab_api_request_duration_seconds_count` | 41,760 | the irate query |

Verified identical on all four systems inside the query window. The bucket count
is exactly 26× the `_count` count: 25 explicit buckets plus `+Inf`.

The 6-hour window holds **361 of 361 expected sample points with no gaps**, at an
average cardinality of 41,759 — 100.00% of full.

### Method

- 3 recorded runs per cell, plus one **cold** first-touch request recorded
  separately as run 0 and excluded from the medians.
- The unfiltered histogram at 3h and 6h is recorded once: a single request costs
  minutes there, and its spread is dominated by scan volume, not run-to-run
  noise.
- 240 requests per round. Both rounds completed with no pod restarts except the
  two OOMKills described below.

## Round 1 · 28 GB of memory

Every system answers every query.

### 1 · irate

```promql
sum by (path) (irate(codelab_api_request_duration_seconds_count[1m]))
```

| Window | Step | Prometheus | Mimir | O2 · Parquet | O2 · Vortex |
| --- | --- | --- | --- | --- | --- |
| 30m | 15s | 1,332 | 1,216 | **102** | 106 |
| 1h | 15s | 2,393 | 2,254 | 180 | **158** |
| 3h | 15s | 7,517 | 8,630 | 537 | **506** |
| 6h | 30s | 10,991 | 8,814 | 1,076 | **980** |

Over 41,760 series. OpenObserve answers in under a second on every window; at 6h
it is **11.2× faster than Prometheus** and 9.0× faster than Mimir. The two
formats tie — nothing here for Vortex's layout to exploit.

### 2 · Unfiltered histogram

```promql
histogram_quantile(0.9, sum by(le, path) (
  rate(codelab_api_request_duration_seconds_bucket{}[5m])))
```

No label filter: `rate` + aggregation over all 1,085,760 series.

| Window | Step | Prometheus | Mimir | O2 · Parquet | O2 · Vortex |
| --- | --- | --- | --- | --- | --- |
| 30m | 15s | 35,517 | 34,904 | 4,598 | **4,476** |
| 1h | 15s | 62,055 | 64,813 | 8,237 | **7,500** |
| 3h | 15s | 189,565 | 245,369 | 27,559 | **27,031** |
| 6h | 30s | 268,419 | 255,386 | **46,645** | 46,833 |

**All four complete every window — but only because the limits were raised.** At
stock settings Prometheus rejects this query outright with *"query processing
would load too many samples into memory"* and Mimir with
*"err-mimir-max-chunks-per-query"*. Both refusals are protective limits, and
this repo raises them (`--query.max-samples=1e9`,
`max_fetched_chunks_per_query=20e6`) so the engines decide the outcome rather
than the defaults.

Once they do run it, OpenObserve is **5.8× faster than Prometheus** and 5.5×
faster than Mimir at 6h — 47 seconds against 4.5 and 4.3 minutes.

### 3 · Filtered histogram (regex match)

```promql
histogram_quantile(0.9, sum by(le, path) (
  rate(codelab_api_request_duration_seconds_bucket{path=~"/api/service-1"}[5m])))
```

| Window | Step | Prometheus | Mimir | O2 · Parquet | O2 · Vortex |
| --- | --- | --- | --- | --- | --- |
| 30m | 15s | 610 | 606 | 654 | **229** |
| 1h | 15s | 1,085 | 1,123 | 1,133 | **379** |
| 3h | 15s | 3,526 | 4,249 | 4,356 | **1,303** |
| 6h | 30s | 4,798 | 4,416 | 7,950 | **2,422** |

### 4 · Filtered histogram (equality match)

```promql
histogram_quantile(0.9, sum by(le, path) (
  rate(codelab_api_request_duration_seconds_bucket{path="/api/service-1"}[5m])))
```

| Window | Step | Prometheus | Mimir | O2 · Parquet | O2 · Vortex |
| --- | --- | --- | --- | --- | --- |
| 30m | 15s | 603 | 608 | 651 | **222** |
| 1h | 15s | 1,119 | 1,137 | 1,109 | **362** |
| 3h | 15s | 3,627 | 4,239 | 4,265 | **1,374** |
| 6h | 30s | 4,770 | 4,417 | 7,846 | **2,666** |

Queries 3 and 4 are a pair to show the **filter type barely matters** — regex
and equality land within 3% of each other everywhere. Scan volume is the
variable, not matcher syntax.

Filtering one path out of 54 changes the ranking completely, and it splits the
two OpenObserve formats:

- **Vortex wins outright**, by 2.0× over Prometheus and 1.8× over Mimir at 6h.
- **Parquet loses to both**, and the gap widens with the window: level at 30m,
  1.7× slower than Prometheus at 6h.

A selective filter is exactly what Vortex's layout exploits and what a
full-scan columnar format does not.

## Round 2 · 14 GB of memory

Same dataset, same queries, half the memory. **Only one thing breaks.**

| Query | Window | Prometheus | Mimir | O2 · Parquet | O2 · Vortex |
| --- | --- | --- | --- | --- | --- |
| irate | 6h | 10,799 | 8,822 | 1,165 | **1,045** |
| Unfiltered histogram | 3h | **OOMKilled** | 245,365 | 28,030 | **26,258** |
| Unfiltered histogram | 6h | **OOMKilled** | 256,976 | 45,212 | **42,586** |
| Filtered, regex | 6h | 4,976 | 4,418 | 7,481 | **2,399** |
| Filtered, equality | 6h | 4,777 | 4,412 | 7,517 | **2,353** |

Everything else lands within 5% of its 28 GB value. Halving the memory changes
almost nothing — **except that Prometheus can no longer answer the
million-series histogram at all.**

### What OOMKilled looks like

Prometheus restarted twice, both times mid-query:

| Request | Started | Ran for | Outcome |
| --- | --- | --- | --- |
| unfiltered · 3h | 16:42:36Z | 158s | OOMKilled |
| unfiltered · 3h (retry) | 16:45:14Z | 4ms | connection refused, pod restarting |
| unfiltered · 6h | 16:55:13Z | 192s | OOMKilled |
| unfiltered · 6h (retry) | 16:58:26Z | 4ms | connection refused, pod restarting |

`restartCount=2`, `lastState.terminated.reason=OOMKilled`, `exitCode=137`, and
`finishedAt=16:58:26Z` matches the last request to the second.

This is worth stating carefully, because `curl` cannot see the difference: an
OOMKill and a network failure both surface as HTTP 000. The harness records a
per-request timestamp and samples container restart state before and after the
run so the two can be told apart — otherwise this table would read "connection
failure" and mean nothing.

### Why it is Prometheus and not the others

Measured peak memory for a single 3h unfiltered histogram:

| System | Peak RSS | Peak workingSet | Time |
| --- | --- | --- | --- |
| **Prometheus** | **18.7 GB** | 20.6 GB | 196s |
| Mimir | 4.25 GB | 7.35 GB | 265s |

Prometheus loads samples into memory; at `--query.max-samples=1e9` and ~16 bytes
per sample that is ~16 GB, which matches the measured +16.9 GB rise almost
exactly. **Raising the limit so the query can run and having the query consume
20 GB are the same decision.** Under a 13.0 GiB cgroup limit there is no room
for it.

Mimir answers the same query in a quarter of the memory and takes 35% longer —
chunked streaming against bulk loading. On a 14 GB box that is the difference
between an answer and a restart.

## 6-hour medians, all queries (28 GB)

| Query | Prometheus | Mimir | O2 · Parquet | O2 · Vortex |
| --- | --- | --- | --- | --- |
| irate | 10,991 | 8,814 | 1,076 | **980** |
| Unfiltered histogram | 268,419 | 255,386 | **46,645** | 46,833 |
| Histogram, regex filter | 4,798 | 4,416 | 7,950 | **2,422** |
| Histogram, equality filter | 4,770 | 4,417 | 7,846 | **2,666** |

## Parquet vs Vortex

The two OpenObserve deployments differ only in `ZO_FILE_FORMAT`, and the results
split cleanly by query shape.

**Full scans tie.** On irate and the unfiltered histogram the two trade places
within 10%.

**Filtered queries go to Vortex, and the gap grows with the window:**

| Filtered histogram, regex (ms) | 30m | 1h | 3h | 6h |
| --- | --- | --- | --- | --- |
| Parquet | 654 | 1,133 | 4,356 | 7,950 |
| Vortex | **229** | **379** | **1,303** | **2,422** |
| Vortex advantage | 2.9× | 3.0× | 3.3× | **3.3×** |

At 6h, Parquet is slower than both Prometheus and Mimir on this query while
Vortex is roughly twice as fast as either. For dashboard-style filtered
workloads the format choice is worth more than the engine choice.

## Ingestion: resource usage

Sampled every 10 minutes across the 8h23m ingestion, at the 28 GB limit.

| System | CPU (cores, typical) | RSS (steady) | Disk |
| --- | --- | --- | --- |
| Prometheus | 1.3–1.9 | 3.2–4.1 GB | 11 GB |
| Mimir | 0.7–1.1 | 4.5–5.5 GB | 28 GB * |
| OpenObserve (Parquet) | 1.6–2.2 | **1.5–2.0 GB** | 29 GB |
| OpenObserve (Vortex) | 1.6–2.0 | **1.5–2.1 GB** | 28 GB |

> \* **Provisional.** These were taken ~2 hours after ingestion stopped, which is
> long enough for Prometheus and OpenObserve but not for Mimir — its compactor
> holds superseded source blocks for `deletion_delay: 12h`, so its volume was
> still carrying both the merged blocks and their sources. It read 21.6 GB at
> the moment of stop, rose to 29.5 GB during compaction, and will not settle
> until ~14 hours after the last write. See
> [When disk usage settles](#when-disk-usage-settles).

**Memory is where the systems differ most, and it is not close.** OpenObserve
holds 1.5–2.1 GB and stays flat for the entire eight hours. Prometheus and Mimir
run 2–3× that and move in a sawtooth as head blocks fill and compact.

**CPU is the trade**: OpenObserve runs ~1.6–2.2 cores against Prometheus's
~1.3–1.9 and Mimir's ~0.7–1.1.

Once ingestion stops, everything collapses: Prometheus to 2.4 GB, Mimir to
2.5 GB, and both OpenObserve deployments to **under 600 MB**. The ingestion-time
figures are buffers and WAL, not resident working set.

> **On measuring memory.** These are **RSS** (`k8s.pod.memory.rss`, anonymous
> pages only). Which metric you pick decides the answer: by RSS, OpenObserve
> holds 1.5 GB against Prometheus's 4.1 GB; by cgroup `workingSetBytes` it reads
> ~9.8 GB against ~4.1 GB — the ordering inverts. Working set is RSS *plus
> active page cache charged to the cgroup*, and a system continuously writing
> columnar files accumulates a lot of that: cache the kernel reclaims on demand,
> not memory the process needs. RSS undercounts Prometheus and Mimir slightly,
> since it excludes their file-backed mmap pages — they still come out well
> above OpenObserve. Whichever you use, say which.

## When disk usage settles

**Disk is the one number you cannot measure right after stopping ingestion**,
and the wait is not the same for every system:

| | Deletes merged-away files after | Disk settles at |
| --- | --- | --- |
| OpenObserve | 2h (`ZO_COMPACT_DELETE_FILES_DELAY_HOURS`) | ~2h |
| Prometheus | immediately after compaction | ~2–3h |
| Mimir | 12h (`compactor.deletion_delay`) | **~14h** |

Watched live across this run, Mimir's volume went **up** after the writes
stopped — 21.6 GB at 21:10, 29.5 GB by 22:23 — because the compactor writes the
merged block first and keeps the sources for half a day.

Neither of Mimir's timers can usefully be shortened. Its volume holds two copies
of the data: the filesystem bucket, whose superseded blocks the compactor keeps
for `deletion_delay`, and the ingester's local TSDB, kept for
`blocks_storage.tsdb.retention_period: 13h` after upload. Lowering the first only
moves an intermediate drop earlier. The second must not be lowered at all — it
is aligned with `query_store_after: 12h`, and dropping the ingester's copy early
makes queries silently return incomplete results, a far worse failure than an
inflated disk number.

**Measuring early biases the comparison towards OpenObserve**, by inflating the
systems it is compared against. Wait ~14 hours, or say your disk figures are
provisional — as the table above does.

## Reproducing

```bash
deploy/install-all.sh                      # NVMe + the four systems
INSTALL_LOAD=1 deploy/install-all.sh       # start the load once they are healthy
# ... ingest, then stop:
kubectl -n perf-fakeserver scale deploy fake-webserver --replicas=0

cd bench
./run-in-cluster.sh --script cardinality.sh    # verify all four agree first
END_TIME=<unix ts> ./run-in-cluster.sh
```

Pin `END_TIME` absolutely and stop ingestion first, or successive runs measure
different data. See [bench/README.md](bench/README.md) for every knob.
