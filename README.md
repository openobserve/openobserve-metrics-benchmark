# openobserve-metrics-benchmark

Everything needed to run the metrics benchmark that compares **Prometheus,
Grafana Mimir, VictoriaMetrics and OpenObserve** on the same data: the manifests, the load generator, the queries, and
the scripts that measure them.

The design in one sentence: **one synthetic workload is written, unchanged, to
four systems at once**, so every system ingests byte-identical data and the same
PromQL runs against all of them.

```
                                      ┌────────────────────────────────────┐
                                      │  Prometheus       v3.6.0           │
                                      ├────────────────────────────────────┤
  fake-webserver v5                   │  Mimir            single binary    │
  backfill Job        remote write    ├────────────────────────────────────┤
  7h of 15 s points  ─────────────►   │  VictoriaMetrics  v1.154.0 single  │  each: 12 CPU / 24 GB,
  1,338,330 series    same 10k-sample ├────────────────────────────────────┤  own m7gd.4xlarge node,
  2.22B samples       requests to all │  OpenObserve      v1.1.0, parquet  │  local NVMe
  ~80 min, then exits                 └────────────────────────────────────┘
```

All four receive the same Prometheus remote-write requests (protobuf + snappy)
from one process. Nothing is written twice, nothing is protocol-specific, and
the dataset is reproducible byte for byte: same seed and flags, same samples.

## Results

Measured numbers are in [RESULTS.md](RESULTS.md).

**The latest round (2026-10-15)** put Prometheus, Mimir, VictoriaMetrics and
OpenObserve `v1.1.0` on one backfilled dataset — 1,338,330 series, 2.22B
samples — at 12 CPU / 24 GB each. The query that scans everything,
`histogram_quantile` over all 1,179,360 bucket series with a 6-hour window:

| System | Latency |
| --- | --- |
| Prometheus | 4 m 12 s |
| Mimir | 26.7 s |
| VictoriaMetrics | 9.25 s |
| **OpenObserve** | **3.67 s** |

OpenObserve is fastest in all 16 cells: geomean 0.32× VictoriaMetrics', 11% of
Mimir's and 2.0% of Prometheus'. Vortex is left out of the published results:
with the new metrics index it queries no faster than Parquet but takes more than
twice the disk.

## What you need

- A Kubernetes cluster with **four dedicated nodes**, one per system under
  test. This repo uses EKS with `m7gd.4xlarge` (16 vCPU / 64 GiB / 950 GB local
  NVMe, Graviton/arm64). The backfill Job runs on VictoriaMetrics' node; the
  benchmark runner runs on an ordinary node in the same AZ.
- Nodes with a local NVMe instance store. See
  [deploy/README.md](deploy/README.md#storage) — the data is **ephemeral**.
- `kubectl`, `helm`, `curl`, `python3`.
- About two hours end to end: ~80 minutes of backfill (the slowest system sets
  the pace), OpenObserve's compaction and each system's settling, then ~10
  minutes of queries per size.

### Node setup

Each system must have a node to itself — that is the point of the 12 CPU /
24 GB Guaranteed-QoS sizing. Taint the node group so nothing else lands there:

```bash
kubectl taint nodes <node> perf=true:NoSchedule
```

Then label each node with the system that owns it. Each system's data lives on
its node's instance store and `hostPath` is node-local, so every deployment
selects on this label — **without it the pods stay `Pending`**, and a pod that
moved to another perf node would come up empty:

```bash
kubectl label node <node-1> perf-system=prometheus
kubectl label node <node-2> perf-system=mimir
kubectl label node <node-3> perf-system=victoriametrics
kubectl label node <node-4> perf-system=o2-parquet
```

A replaced node comes back tainted but **unlabelled**; relabel before
installing. On EKS with `eksctl`:

```yaml
managedNodeGroups:
  - name: perf
    instanceType: m7gd.4xlarge
    desiredCapacity: 4
    volumeSize: 100          # the OS disk; data lives on the instance store
    taints:
      - key: perf
        value: "true"
        effect: NoSchedule
```

For an existing managed node group, raise both the maximum and the desired
size to 4 (`aws eks update-nodegroup-config ... --scaling-config
minSize=0,maxSize=4,desiredSize=4`).

All images are multi-arch. On x86 nodes nothing needs changing.

## Running it

```bash
deploy/install-all.sh                  # NVMe + the four systems, then stops
# confirm all four are healthy, then:
INSTALL_LOAD=1 deploy/install-all.sh   # the backfill
```

Step 1 mounts each node's NVMe (and verifies it) and installs the four systems,
then **stops before any load** so you can confirm they are healthy. Step 2
pauses for them to settle and runs the backfill Job, which writes the whole
dataset to every system and exits. OpenObserve takes it with compaction off and
has it switched on afterwards — the steps, and what "settled" means for each
system, are in [deploy/README.md](deploy/README.md#after-the-backfill).

Then check that all four agree on what they hold — if they disagree, they did
not receive the same data and the latency comparison is void:

```bash
bench/run-in-cluster.sh --script cardinality.sh
```

When they agree, run the benchmark with the query range pinned to the end of
the backfilled span (2026-09-28 10:00 UTC for the default dataset):

```bash
RUNS=5 END_TIME=1790589600 bench/run-in-cluster.sh
```

This runs the measurement from a pod inside the cluster and copies the results
back. Do not time queries through `port-forward.sh`: the API-server hop puts a
1–3 s floor under every request, which destroys the ratios. See
[bench/README.md](bench/README.md#measure-from-inside-the-cluster).

Each run is 4 queries × 4 windows × 4 systems, each cell one discarded cold
request plus `RUNS` recorded ones (the unfiltered 3h and 6h cells are recorded
once). Results land in `results/<timestamp>/` as `raw.csv`, `summary.md`,
`run-metadata.txt` and `pod-state.txt` (container restarts, so an OOMKill is
not filed as a network error).

**Run it twice and pool.** A slowdown from outside the systems can hit every
one of them at once; two back-to-back runs pooled into one median per cell
absorb it: concatenate the recorded runs of both `raw.csv` files per cell and
take the median.

See [bench/README.md](bench/README.md) for the knobs and
[deploy/README.md](deploy/README.md) for what each manifest does and why.

## What is deliberately configured, and why

These choices make the comparison fair — change one and you are running a
different benchmark:

| Setting | Value | Reason |
| --- | --- | --- |
| Pod resources | 12 CPU / 24 GB, requests == limits | Guaranteed QoS on a dedicated node: fixed CPU, memory never reclaimed |
| Disk | node-local NVMe per system | Same device class everywhere; removes disk speed as a variable |
| Ingest | Prometheus remote write for all four, from one process | Identical input, one wire format |
| Timestamps | exact `start + k × 15s` | The samples compress the same way on every system; a live scrape jitters |
| Out-of-order window | 2h on Prometheus and Mimir | The backfill's concurrent senders reorder neighbouring steps; the others accept that by default |
| Mimir write limits | `ingestion_rate` 20M, `max_global_series_per_user` 150M | Writes are never throttled by defaults |
| Query limits and timeouts | Raised to match across all four — see [deploy/README.md](deploy/README.md#query-limits) | At defaults several systems *refuse* the million-series histogram, which measures the limit rather than the engine. 600 s timeout everywhere |
| Result caches | VictoriaMetrics `-search.disableCache`, OpenObserve `ZO_RESULT_CACHE_ENABLED=false`; Prometheus and Mimir have none configured | Warm runs must re-execute the query |
| OpenObserve compaction | off during the backfill, on after | Merging an hour while it is still being written leaves late files unmerged. See [deploy/README.md](deploy/README.md#after-the-backfill) |
| Mimir background timing | compaction, sync and deletion delays cut to minutes; `retention_period: 15m` | Settles ~30 minutes after the backfill with one copy of the data, read from object storage like the others read their disk |
| OpenObserve file format | Parquet, the default | Vortex queries no faster with the metrics index and takes more than twice the disk, so it was dropped |

## Known gaps

Stated plainly, because a reproduction you cannot audit is not a reproduction:

- **State your `step`.** `query_range` needs one; this repo computes it per
  window the way Grafana does, `max(15s, range / 1000)` rounded up, and
  RESULTS.md publishes it. It is the biggest single lever on absolute latency.
- **Mimir is `grafana/mimir:latest`.** Pin a concrete tag before a round you
  want to be comparable later.
- **Backfilled data lays out differently from live-scraped data.** These
  numbers are for a backfilled store; the same series scraped live are stored
  in a different layout and can read faster or slower.
- **Disk settles at different times per system.** Mimir is configured to
  drop superseded blocks and ingester copies within ~30 minutes of a backfill;
  OpenObserve deletes merged inputs after
  `ZO_COMPACT_DELETE_FILES_DELAY_MINUTES` (10 here). Prometheus keeps its last
  ~3 hours in head chunks plus WAL by design. Measure storage from each
  system's own accounting.
- **`ZO_METRICS_CACHE_ENABLED` is left at the chart default.** Set it to
  `false` in the OpenObserve values file for a strictly cache-free run.

## Repository layout

```
deploy/
  install-all.sh       NVMe + the four systems, in order, with verification
  set-dataset.sh       Point all four at a named dataset on the instance store
  local-nvme/          DaemonSet that formats and mounts each node's NVMe
  prometheus/          Prometheus v3.6.0, remote-write receiver, scrapes nothing
  mimir/               Mimir single binary, filesystem blocks storage
  victoriametrics/     VictoriaMetrics single node (Helm)
  openobserve-parquet/ OpenObserve standalone, Parquet (Helm)
  fake-webserver/      The load: a v5 backfill Job writing to all four
bench/
  config.sh            Endpoints, windows, step, runs — every knob
  queries.sh           The four PromQL expressions
  run-in-cluster.sh    Runs the driver from a pod — use this for timings
  run-benchmark.sh     The main driver -> results/<timestamp>/
  summarize.py         raw.csv -> markdown tables, warm and cold separately
  cardinality.sh       Series counts per system (run this first)
  resources.sh         CPU / memory / disk per system
  drop-caches.sh       Force a cold query
  port-forward.sh      Local ports — for browsing a UI, never for timing
  experiments/         One-off studies, not part of the benchmark
results/               Your runs land here (local only, not in git)
RESULTS.md             Measured results
```

## License

Apache-2.0. See [LICENSE](LICENSE).
