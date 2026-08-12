# openobserve-metrics-benchmark

Everything needed to re-run the benchmark behind **"One Dataset, Four Systems —
Benchmarking Prometheus, Mimir, and OpenObserve on Metrics Ingestion and
Queries"**: the manifests, the collector config, the queries, and the scripts
that measure them.

The design in one sentence: **one OTel Collector scrapes one synthetic workload
and fans it out, unchanged, to four systems at once**, so every system ingests
byte-identical data and the same PromQL can be run against all of them.

```
                                 ┌──────────────────────────────┐
                                 │  Prometheus  v3.6.0          │  7 CPU / 28 GB / NVMe
                                 ├──────────────────────────────┤
  fake-webserver  ──scrape──►    │  Mimir       (single binary) │  7 CPU / 28 GB / NVMe
  24 pods, 15s     OTel      ──► ├──────────────────────────────┤
  ~1.09M series    Collector     │  OpenObserve ZO_FILE_FORMAT= │  7 CPU / 28 GB / NVMe
                   (gateway)     │              parquet         │
                                 ├──────────────────────────────┤
                                 │  OpenObserve ZO_FILE_FORMAT= │  7 CPU / 28 GB / NVMe
                                 │              vortex          │
                                 └──────────────────────────────┘
```

All four receive the same samples over `prometheusremotewrite`, with identical
queue and retry settings, from a single scrape. Nothing is written twice and
nothing is protocol-specific.

## Results this reproduces

Measured numbers are in [RESULTS.md](RESULTS.md). The headline is the query
that scans everything — `histogram_quantile` over all 1,085,760 bucket series,
6-hour window, median of the recorded runs:

| System | Latency |
| --- | --- |
| Prometheus | 4m 28s |
| Mimir | 3m 55s |
| OpenObserve · Parquet | 46.9s |
| **OpenObserve · Vortex** | **45.5s** |

At stock settings none of the three systems runs this query at all — they
refuse it on protective defaults. The benchmark raises those limits uniformly
so the engines decide the outcome instead. See
[deploy/README.md](deploy/README.md#query-limits).

**Filter to a single path and the ranking tightens.** Same window, same step,
filtering on `/api/bar`:

| System | Latency (ms) |
| --- | --- |
| Prometheus | 9,237 |
| OpenObserve · Parquet | 8,336 |
| Mimir | 7,955 |
| **OpenObserve · Vortex** | **3,022** |

Vortex wins by 3.1× over Prometheus and 2.8× over Parquet. A selective filter is
what Vortex's layout exploits and what a full-scan columnar format does not —
for dashboard-style filtered work the format choice is worth more than the
engine choice.

**Which path you filter on changes this table**, so it is worth stating.
fake-webserver produces 54 paths in two classes: 50 generated
(`/api/service-1`…`50`) at 25,740 bucket series each, and 4 fixed
(`/api/foo`, `/api/bar`, `/api/baz`, `/api/boom`) at **51,480**. Doubling the
matched series roughly doubles Prometheus (1.93×) and Mimir (1.80×) but moves
Parquet by 2% — so on a generated path Parquet is the slowest of the four, and
on a fixed one it edges past Prometheus. `PATH_FILTER` in `bench/config.sh`
selects it; RESULTS uses `/api/bar`.

And the result that is not about milliseconds. Run the same benchmark again with
the memory limit halved to **14 GB**, and almost nothing changes — every cell
lands within 8% — *except* that Prometheus is **OOMKilled** on the
million-series unfiltered histogram at 3h and 6h. That one query peaks at
18.7 GB RSS in Prometheus against 4.25 GB in Mimir; raising
`--query.max-samples` so it can run at all and having it consume 20 GB are the
same decision.

## What you need

- A Kubernetes cluster with **four dedicated nodes** for the systems under test,
  plus ordinary capacity for the load generator (24 pods × 64m/64Mi = 1.54 CPU
  and 1.5GiB of requests) and the collector (1–4 CPU, up to 6Gi).
  Uses `m7gd.2xlarge` (8 vCPU / 32GB / 474 GB NVMe, Graviton/arm64) on EKS.
- Nodes with local NVMe instance store; `m7gd.2xlarge` gives 474 GB per node.
  See [deploy/README.md](deploy/README.md#storage) — the data is **ephemeral**.
- `kubectl`, `helm`, `curl`, `python3`.
- **Time.** You need enough ingestion to cover the widest query window, at full
  cardinality. Total ingestion *duration* beyond that does not affect query
  latency — a 3h query only ever scans 3h of data — but series count does.

### Node setup

Each system must have a node to itself — that is the whole point of the
7 CPU / 28 GB Guaranteed-QoS pod sizing. Taint a four-node group so nothing else lands there:

```bash
kubectl taint nodes <node> perf=true:NoSchedule
```

Then label each node with the system that will own it. Each system's data lives
on its node's instance store, and `hostPath` is node-local, so every deployment
selects on this label — **without it the pods stay `Pending`**, and a pod that
moved to a different perf node would come up with an empty directory and look
like it had lost all its data:

```bash
kubectl label node <node-1> perf-system=prometheus
kubectl label node <node-2> perf-system=mimir
kubectl label node <node-3> perf-system=o2-parquet
kubectl label node <node-4> perf-system=o2-vortex
```

Every system's pod spec carries the matching toleration. On EKS with `eksctl`:

```yaml
managedNodeGroups:
  - name: perf
    instanceType: m7gd.2xlarge
    desiredCapacity: 4
    volumeSize: 100          # the OS disk; data lives on the instance store
    taints:
      - key: perf
        value: "true"
        effect: NoSchedule
```

If your nodes are x86, remove the `kubernetes.io/arch: arm64` nodeSelector in
`deploy/fake-webserver/deploy.yaml`. All images used here are multi-arch.

## Running it

```bash
deploy/install-all.sh                                       # the four systems
# confirm all four are healthy, then:
INSTALL_LOAD=1 deploy/install-all.sh                        # start the load
```

Step 1 mounts each node's NVMe (and verifies it) and installs the four systems
under test, then **stops before any load** so you can confirm they are healthy.
Step 2 pauses for them to settle and starts the load generator, so all four see
identical input from the first sample.

**The OTel collector is not installed by default**, because installing it
replaces the release's values and would drop any pipeline the cluster's
collector already has. Add `INSTALL_COLLECTOR=1` only if that collector exists
solely for this benchmark; otherwise wire up an existing one by hand. See
[deploy/README.md](deploy/README.md#the-collector-is-opt-in). Nothing reaches
the four systems until a collector scrapes `perf-fakeserver`.

Then wait. Come back after several hours and check that the four systems agree
on how much data they hold — if they disagree, the latency comparison is void:

```bash
bench/run-in-cluster.sh --script cardinality.sh
```

When cardinality matches across all four, run the benchmark:

```bash
bench/run-in-cluster.sh
```

This runs the measurement from a pod inside the cluster and copies the results
back. Do not time queries through `port-forward.sh`: the API-server hop puts a
1,656–2,862ms floor under every request. It is not a constant, so it does not
just inflate the numbers — it destroys the ratios, and costs the fastest system
the most. See
[bench/README.md](bench/README.md#measure-from-inside-the-cluster) for the
measured comparison.

240 requests: 4 queries × 4 windows × 4 systems × (1 cold + 3 recorded runs),
less the 3h and 6h unfiltered cells which are recorded once. Results land in
`results/<timestamp>/` as `raw.csv`, `summary.md`, `run-metadata.txt` and
`pod-state.txt` (container restarts, so an OOMKill is not filed as a network
error).

Resource usage is measured separately, during steady-state ingestion:

```bash
bench/resources.sh 12 300      # 12 snapshots, 5 minutes apart
```

See [bench/README.md](bench/README.md) for the knobs and
[deploy/README.md](deploy/README.md) for what each manifest does and why.

## What is deliberately configured, and why

These are the choices that make the comparison fair — change them and you are
running a different benchmark:

| Setting | Value | Reason |
| --- | --- | --- |
| Pod resources | 7 CPU / 28 GB memory, requests == limits | Guaranteed QoS on a dedicated node: fixed CPU shares, memory never reclaimed |
| Disk | node-local NVMe per system | Same device class everywhere; removes disk speed as a variable |
| Ingest protocol | `prometheusremotewrite` for all four | OTLP for OpenObserve and remote write for the others would compare different parsers |
| Mimir write limits | `ingestion_rate` 20M, `max_global_series_per_user` 150M | So writes are never throttled by defaults |
| Query limits and timeouts | Raised to match across all four — see [deploy/README.md](deploy/README.md#query-limits) | At defaults, Prometheus and Mimir *refuse* the million-series histogram instead of running it, which measures the limit rather than the engine. 600s timeout everywhere, matching OpenObserve's default |
| OpenObserve caches | `ZO_RESULT_CACHE_ENABLED=false` | Matches "caches disabled" on the others |
| OpenObserve pushdown | `ZO_FEATURE_PUSHDOWN_FILTER_ENABLED=false` | On by default, but ~20% *slower* in these metrics tests. Affects parquet only; set identically in both so the A/B stays clean |
| Parquet vs Vortex | `ZO_FILE_FORMAT` | The **only** difference between the two OpenObserve deployments |

`diff deploy/openobserve-parquet/values.yaml deploy/openobserve-vortex/values.yaml`
should print three lines, one of them `ZO_FILE_FORMAT`. If it prints more, the
A/B is contaminated.

## Known gaps between this repo and the published run

Stated plainly, because a reproduction you cannot audit is not a reproduction:

- **The original article did not record its `step`.** `query_range` needs a
  resolution step and the article pins none, so its absolute latencies cannot be
  compared directly with anyone else's. This repo computes one per window the
  way Grafana does — `max(15s, range / 1000)` rounded up — and
  [RESULTS.md](RESULTS.md#how-the-measurement-is-taken) publishes it. Step is the
  single biggest lever on absolute latency here: on a fixed 3h window, widening
  it from 36 to 720 points moved Prometheus 1.68s→3.92s. If you publish numbers,
  publish your step.
- **`ZO_METRICS_CACHE_ENABLED` is left at the chart default (`true`).** The
  published run did not set it either, so this repo matches it. If you want a
  strictly cache-free OpenObserve, set it to `false` — in **both** values files.
- **Mimir was `grafana/mimir:latest`**, pulled in August 2026. Pin a concrete
  tag if you need the comparison stable over time.
- **Cardinality is set by the replica count**, so quote the number you actually
  measure. Each fake-webserver pod contributes ~45,220 bucket series; the 24
  replicas here measure ~1.09M, which is what the unfiltered histogram scans.
  `bench/cardinality.sh` reports it — publish it alongside any latencies.
- **The collector here is stripped** of the pipelines that shipped the
  operator's own cluster telemetry to an internal OpenObserve. Those pipelines
  were filtered to exclude `perf-fakeserver` and never touched the systems under
  test, so removing them does not change the measured workload.
- **Halving the memory to 14 GB barely moves query latency** — every cell lands
  within 5% — but Prometheus is OOMKilled on the million-series unfiltered
  histogram, which alone peaks at 18.7 GB RSS. Sizing decides what runs, not
  how fast it runs.
- **Disk settles at different times per system.** Mimir's compactor holds
  superseded blocks for `deletion_delay: 12h`, so its volume reads high for
  ~14 hours after the last write. Measuring early inflates it.

## Repository layout

```
deploy/
  install-all.sh       NVMe + the four systems, in order, with verification
  set-dataset.sh       Point all four at a named dataset on the instance store
  local-nvme/          DaemonSet that formats and mounts each node's NVMe
  prometheus/          Prometheus v3.6.0, remote-write receiver, scrapes nothing
  mimir/               Mimir single-binary, filesystem blocks storage
  openobserve-parquet/ OpenObserve standalone, ZO_FILE_FORMAT=parquet
  openobserve-vortex/  OpenObserve standalone, ZO_FILE_FORMAT=vortex
  fake-webserver/      The load generator, 24 replicas (~1.09M bucket series)
  otel-collector/      The scrape + 4-way fan-out. The heart of the setup.
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
  experiments/         One-off studies, not part of the published benchmark
results/               Your runs land here
RESULTS.md             Measured results
RESULTS.html           The same, as a standalone page
RESULTS.zh.html        Chinese translation
```

## License

Apache-2.0. See [LICENSE](LICENSE).
