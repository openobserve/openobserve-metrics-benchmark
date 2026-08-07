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
                                 │  Prometheus  v3.6.0          │  7C / 14G / 500Gi
                                 ├──────────────────────────────┤
  fake-webserver  ──scrape──►    │  Mimir       (single binary) │  7C / 14G / 500Gi
  24 pods, 15s     OTel      ──► ├──────────────────────────────┤
  ~1.08M series    Collector     │  OpenObserve ZO_FILE_FORMAT= │  7C / 14G / 500Gi
                   (gateway)     │              parquet         │
                                 ├──────────────────────────────┤
                                 │  OpenObserve ZO_FILE_FORMAT= │  7C / 14G / 500Gi
                                 │              vortex          │
                                 └──────────────────────────────┘
```

All four receive the same samples over `prometheusremotewrite`, with identical
queue and retry settings, from a single scrape. Nothing is written twice and
nothing is protocol-specific.

## Results this reproduces

The published numbers are in [RESULTS.md](RESULTS.md). The headline — 3-hour
filtered `histogram_quantile`, median of 3 runs:

| System | Latency (ms) |
| --- | --- |
| Mimir | 8,010 |
| Prometheus | 3,184 |
| OpenObserve · Parquet | 2,200 |
| **OpenObserve · Vortex** | **915** |

And the result that is not about milliseconds: on the **unfiltered** histogram
over ~1.08M series, Prometheus errors on every window and Mimir errors at 3h.
Only the two OpenObserve deployments return an answer on all three windows.

## What you need

- A Kubernetes cluster with **four dedicated nodes** for the systems under test,
  plus ordinary capacity for the load generator (24 pods × 128m/64Mi = 3.07 CPU
  and 1.5GiB of requests) and the collector (1–4 CPU, up to 6Gi).
  The published run used `c7g.2xlarge` (8 vCPU / 16GB, Graviton/arm64) on EKS.
- A `gp3` (or equivalent) StorageClass. Each system gets a **500Gi** PVC.
- `kubectl`, `helm`, `curl`, `python3`.
- **Time.** The interesting numbers need hours of ingestion before there is
  enough data to query over a 3-hour window. The published run had been
  ingesting for roughly 30 hours (7.1 billion samples) when it was measured.

### Node setup

Each system must have a node to itself — that is the whole point of the 7C/14G
Guaranteed-QoS pod sizing. Taint a four-node group so nothing else lands there:

```bash
kubectl taint nodes <node> perf=true:NoSchedule
```

Every system's pod spec carries the matching toleration. On EKS with `eksctl`:

```yaml
managedNodeGroups:
  - name: perf
    instanceType: c7g.2xlarge
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
bench/port-forward.sh          # terminal 1, leave running
bench/cardinality.sh           # terminal 2
```

When cardinality matches across all four, run the benchmark:

```bash
bench/run-benchmark.sh
```

144 requests (4 queries × 3 windows × 4 systems × 3 runs). Results land in
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
| Pod resources | 7 CPU / 14G, requests == limits | Guaranteed QoS on a dedicated node: fixed CPU shares, memory never reclaimed |
| Disk | 500Gi gp3 per system | Same storage class and size everywhere |
| Ingest protocol | `prometheusremotewrite` for all four | OTLP for OpenObserve and remote write for the others would compare different parsers |
| Mimir write limits | `ingestion_rate` 20M, `max_global_series_per_user` 150M | So writes are never throttled by defaults |
| Mimir query limits | **left at defaults** | `err-mimir-max-chunks-per-query` at 3h is a result, not a misconfiguration |
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
- **Cold-query numbers depend on your disk.** The ~30s cold / ~2s hot gap in the
  article is gp3 at its default 125 MB/s reading ~3.6GB. On io2 the same query
  took ~3.5s. Use `bench/drop-caches.sh` to measure your own.

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
  run-benchmark.sh     The main driver -> results/<timestamp>/
  summarize.py         raw.csv -> the article's markdown tables
  cardinality.sh       Series counts per system (run this first)
  resources.sh         CPU / memory / disk per system
  drop-caches.sh       Force a cold query
  port-forward.sh      Local ports for all four systems
results/               Your runs land here
RESULTS.md             The published numbers, for comparison
```

## License

Apache-2.0. See [LICENSE](LICENSE).
