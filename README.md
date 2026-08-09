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
                                 │  Prometheus  v3.6.0          │  7C / 28G / 500Gi
                                 ├──────────────────────────────┤
  fake-webserver  ──scrape──►    │  Mimir       (single binary) │  7C / 28G / 500Gi
  24 pods, 15s     OTel      ──► ├──────────────────────────────┤
  ~1.08M series    Collector     │  OpenObserve ZO_FILE_FORMAT= │  7C / 28G / 500Gi
                   (gateway)     │              parquet         │
                                 ├──────────────────────────────┤
                                 │  OpenObserve ZO_FILE_FORMAT= │  7C / 28G / 500Gi
                                 │              vortex          │
                                 └──────────────────────────────┘
```

All four receive the same samples over `prometheusremotewrite`, with identical
queue and retry settings, from a single scrape. Nothing is written twice and
nothing is protocol-specific.

## Results this reproduces

Measured numbers are in [RESULTS.md](RESULTS.md). The headline — 3-hour
filtered `histogram_quantile`, median of the recorded runs:

| System | Latency (ms) |
| --- | --- |
| Mimir | 4,542 |
| OpenObserve · Parquet | 4,316 |
| Prometheus | 3,403 |
| **OpenObserve · Vortex** | **1,472** |

And the result that is not about milliseconds: on the **unfiltered** histogram
over ~1.08M series, Prometheus and Mimir *refuse* the query at stock limits.
Given the same allowances and the same 600s timeout, all four finish every
window — OpenObserve in 27s at 3h, against Prometheus's 3.3 and Mimir's 4.3
minutes.

## What you need

- A Kubernetes cluster with **four dedicated nodes** for the systems under test,
  plus ordinary capacity for the load generator (24 pods × 128m/64Mi = 3.07 CPU
  and 1.5GiB of requests) and the collector (1–4 CPU, up to 6Gi).
  Uses `m7g.2xlarge` (8 vCPU / 32GB, Graviton/arm64) on EKS.
- A `gp3` (or equivalent) StorageClass. Each system gets a **500Gi** PVC.
- `kubectl`, `helm`, `curl`, `python3`.
- **Time.** You need enough ingestion to cover the widest query window, at full
  cardinality. Total ingestion *duration* beyond that does not affect query
  latency — a 3h query only ever scans 3h of data — but series count does.

### Node setup

Each system must have a node to itself — that is the whole point of the 7C/28G
Guaranteed-QoS pod sizing. Taint a four-node group so nothing else lands there:

```bash
kubectl taint nodes <node> perf=true:NoSchedule
```

Every system's pod spec carries the matching toleration. On EKS with `eksctl`:

```yaml
managedNodeGroups:
  - name: perf
    instanceType: m7g.2xlarge
    desiredCapacity: 4
    volumeSize: 100          # the OS disk; data lives on the 500Gi PVCs
    taints:
      - key: perf
        value: "true"
        effect: NoSchedule
```

If your nodes are x86, remove the `kubernetes.io/arch: arm64` nodeSelector in
`deploy/fake-webserver/deploy.yaml`. All images used here are multi-arch.

## Running it

Install in this order. The collector goes **last** — its exporters point at the
other four Services, and starting it early just burns time on retries.

```bash
deploy/prometheus/install.sh
deploy/mimir/install.sh
deploy/openobserve-parquet/install.sh
deploy/openobserve-vortex/install.sh
deploy/fake-webserver/install.sh
deploy/otel-collector/install.sh          # installs cert-manager + otel-operator if missing
```

Or all six in order:

```bash
deploy/install-all.sh
```

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
~1-2 second floor under every request, which compresses the systems together and
destroys the ratios — it costs the fastest system the most. See
[bench/README.md](bench/README.md#measure-from-inside-the-cluster) for the
measured comparison.

184 requests: 4 queries × 3 windows × 4 systems × (1 cold + 3 recorded runs),
less the 3h unfiltered cell which is recorded once. Results land in
`results/<timestamp>/` as `raw.csv`, `summary.md` and `run-metadata.txt`.

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
| Pod resources | 7 CPU / 28G, requests == limits | Guaranteed QoS on a dedicated node: fixed CPU shares, memory never reclaimed |
| Disk | 500Gi gp3 per system | Same storage class and size everywhere |
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

- **`step` was not recorded.** `query_range` needs a resolution step and the
  article does not pin one. `bench/config.sh` defaults to `STEP=15s`, matching
  the scrape interval, which is consistent with the near-linear latency growth
  the article observed. Step is the single biggest lever on absolute latency
  here — if you publish numbers, publish your step.
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
- **Cold-query numbers depend on whether your data fits in RAM.** At 28G there
  is no measurable cold/hot gap. At 14G the same query measured 16.8× slower
  cold, purely because OpenObserve's dataset no longer fit in page cache while
  Prometheus's did. Check that before comparing anything.
- **Mimir needs ~3 full passes to reach steady state**, up to 3× slower on the
  first. The other three are at steady state immediately.

## Repository layout

```
deploy/
  prometheus/          Prometheus v3.6.0, remote-write receiver, scrapes nothing
  mimir/               Mimir single-binary, filesystem blocks storage
  openobserve-parquet/ OpenObserve standalone, ZO_FILE_FORMAT=parquet
  openobserve-vortex/  OpenObserve standalone, ZO_FILE_FORMAT=vortex
  fake-webserver/      The load generator, 24 replicas (~1.08M bucket series)
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
results/               Your runs land here
RESULTS.md             Measured results
```

## License

Apache-2.0. See [LICENSE](LICENSE).
