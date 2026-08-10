# deploy/

```bash
./install-all.sh                                     # 1 · NVMe + the four systems
INSTALL_LOAD=1 ./install-all.sh                      # 2 · + the load
INSTALL_LOAD=1 INSTALL_COLLECTOR=1 ./install-all.sh  # 3 · + the collector
```

Each step is a no-op if already done, so re-running with the next flag is safe.

**Step 1 stops before any load.** That is the point: once `fake-webserver` is
up every system is being written to and the run has started, so it is worth
confirming all four are healthy first. `install-all.sh` prints what to check.

**`local-nvme` always runs first** — a system that starts before the mount
exists writes to the root EBS volume while appearing to use NVMe, and nothing
surfaces the mistake. See [Storage](#storage).

**Ready is not steady.** WAL replay, block loading and the first compaction all
happen after the readiness probe passes, and load applied during that window
hits each system in a different state — the comparison is only clean if all
four see identical input from the first sample. `STABILIZE_SECS` (default 120)
is the pause before the load starts.

## The collector is opt-in

`install-all.sh` deliberately does **not** install `otel-collector/`. That
script runs `helm upgrade --install -f collector-values.yaml`, which replaces
the release's values wholesale — and this repo's values file is the stripped,
benchmark-only version. On a cluster whose collector also carries other
telemetry, running it silently deletes those pipelines.

If the collector exists solely for this benchmark:

```bash
INSTALL_COLLECTOR=1 ./install-all.sh
```

If it is shared, edit the live values instead and add only what the benchmark
needs — the four `prometheusremotewrite` exporters and the single
`metrics/perf_fakeserver` pipeline from `otel-collector/collector-values.yaml`:

```bash
helm -n openobserve-collector get values o2c > /tmp/o2c.yaml
# merge in the four exporters + the pipeline
helm -n openobserve-collector upgrade o2c openobserve/openobserve-collector -f /tmp/o2c.yaml
```

Nothing reaches the four systems until some collector scrapes
`perf-fakeserver` and writes to them.

## The four systems under test

| Directory | Namespace | Service | Query API path |
| --- | --- | --- | --- |
| `prometheus/` | `perf-prometheus` | `perf-prometheus-standalone:9090` | `/api/v1/query_range` |
| `mimir/` | `perf-mimir` | `perf-mimir-standalone:9009` | `/prometheus/api/v1/query_range` |
| `openobserve-parquet/` | `perf-o2-parquet` | `o2-openobserve-standalone:5080` | `/api/default/prometheus/api/v1/query_range` |
| `openobserve-vortex/` | `perf-o2-vortex` | `o2-openobserve-standalone:5080` | `/api/default/prometheus/api/v1/query_range` |

The three path prefixes are why `bench/config.sh` stores a *base URL* per system
rather than a hostname.

## Sizing

**7 CPU / 28G, requests == limits** (Guaranteed QoS) on a dedicated
`m7gd.2xlarge` tainted `perf=true:NoSchedule`, writing to that node's
**instance-store NVMe** — identical for all four. See [Storage](#storage).

`28G` is decimal (26.08 GiB). Do not "correct" it to `28Gi`: that exceeds the
node's 29.79 GiB allocatable and the pod sits `Pending`.

28G rather than 14G because every dataset must fit in page cache. At 14G,
OpenObserve's 15.5GB did not and Prometheus's 4.5GB did, which flattered
Prometheus for reasons unrelated to its engine. Shrink these and check the
largest dataset still fits.

The Helm release name for both OpenObserve deployments must stay `o2` — it is
what produces the Service name `o2-openobserve-standalone` that the collector's
exporters address.

## Notes per component

**`prometheus/`** — runs with `--web.enable-remote-write-receiver` and an empty
`scrape_configs`. It never scrapes anything itself; all load arrives by remote
write.

**`mimir/`** — single-binary mode on filesystem blocks storage, replication
factor 1. Write-path limits are raised far above the workload so nothing is
throttled. Query-path limits: see below.

## Query limits

At their defaults, Prometheus and Mimir *refused* the million-series unfiltered
histogram rather than running it — which measures the limit, not the engine.
All four now get the same allowances:

| System | Setting | Value | Default |
| --- | --- | --- | --- |
| Prometheus | `--query.max-samples` | 1e9 | 50e6 |
| Prometheus | `--query.timeout` | 600s | 2m |
| Mimir | `limits.max_fetched_chunks_per_query` | 20e6 | 2e6 |
| Mimir | `querier.timeout` | 600s | 2m |
| Mimir | `server.http_server_write_timeout` | 600s | 2m |
| OpenObserve | `ZO_METRICS_MAX_SERIES_RESPONSE` | 40000 | lower |
| OpenObserve | `ZO_METRICS_MAX_POINTS_PER_SERIES` | 10000000 | lower |
| OpenObserve | query timeout | 600s | 600s (unchanged) |

**All three needed raising, not just the two TSDBs.** OpenObserve's stock
metrics limits would have rejected the million-series histogram before its
engine ran, exactly as Prometheus's and Mimir's did. 600s is OpenObserve's
default timeout, so it is the number the other two were matched to — that one
is the only value here that was not changed.

Two Mimir gotchas:

- **Both timeouts are required.** `http_server_write_timeout` also defaults to
  2m and fires first, closing the connection before Mimir can write its timeout
  response — the client sees a bare TCP close (`curl` reports `000`), not a
  readable error.
- `querier.timeout` belongs to the **top-level `querier` block**. Under `limits`
  it fails at startup: `field querier_timeout not found in type
  validation.plainLimits`.

**`openobserve-parquet/` and `openobserve-vortex/`** — identical apart from
`ZO_FILE_FORMAT`. Verify before every run:

```bash
diff openobserve-parquet/values.yaml openobserve-vortex/values.yaml
```

Three lines should differ, one being `ZO_FILE_FORMAT`. Then confirm it reached
the container:

```bash
kubectl -n perf-o2-parquet exec sts/o2-openobserve-standalone -- printenv ZO_FILE_FORMAT
kubectl -n perf-o2-vortex  exec sts/o2-openobserve-standalone -- printenv ZO_FILE_FORMAT
```

This matters: the chart's ConfigMap also carries a `ZO_FILE_FORMAT` default, and
it is the pod's explicit `env` (from `extraEnv`) that overrides it. Reading the
ConfigMap alone will mislead you.

**`fake-webserver/`** — 24 replicas, no flags, so image defaults apply: 54
distinct `path` values, 5 regions, 3 versions, 2 methods, and a histogram with
25 explicit buckets plus `+Inf`. That last detail is why
`codelab_api_request_duration_seconds_bucket` has exactly 26× the series of
`..._count`.

Every pod is scraped as its own target and stamped with a `pod` label, so series
count scales linearly with `replicas`: measured at ~45,220 bucket and ~1,739
`_count` series per pod. **24 replicas** therefore gives ~1,085,280 bucket series
and ~1.22M total active — the point at which the unfiltered histogram scans more
than a million series. (The same cluster at 20 replicas measured 904,410 bucket /
1,013,150 total active.) Change `replicas` for any other scale and re-run
`bench/cardinality.sh` afterwards.

**`otel-collector/`** — the load path, and the file worth reading before
anything else. One `prometheus/perf-fakeserver` receiver scrapes the 24 pods
every 15s; one pipeline fans the result out to all four exporters. The chart's
own default pipelines are removed with explicit `null`s; confirm they really
went away:

```bash
kubectl -n openobserve-collector get otelcol -o yaml | grep -A 12 'pipelines:'
```

Each collector should show exactly one pipeline, `metrics/perf_fakeserver`.

`install.sh` also installs cert-manager and the OpenTelemetry Operator if the
cluster does not already have them — the chart renders `OpenTelemetryCollector`
custom resources, so the operator has to exist first.

## Storage

Each system writes to its node's **instance-store NVMe** via a `hostPath` at
`/mnt/k8s-disks/0/<system>`, so disk speed is not a variable in the comparison.
There are no PVCs.

**The data is ephemeral.** Instance store is lost whenever the node stops, is
replaced, or is reclaimed. A dataset that took hours to ingest disappears with
the node. Use on-demand capacity and keep the perf nodes undisrupted.

### The mount

`local-nvme/mount-nvme.yaml` is a DaemonSet that formats the instance-store
device as xfs and mounts it at `/mnt/k8s-disks/0`. It is idempotent — an
existing mount or filesystem is left alone — and it re-runs when a node is
replaced.

It exists because the EKS AL2023 nodeadm setting that is supposed to do this,

```yaml
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  instance:
    localStorage:
      strategy: RAID0
```

did not take effect on these nodes: `/dev/nvme1n1` was present but had no
filesystem and was not mounted. If it works for you, the DaemonSet finds the
mount already in place and does nothing.

### Why the ordering matters

**Apply the DaemonSet before the systems under test.** A pod that starts first
binds its `hostPath` to the directory that exists at that moment and keeps that
view after the device is mounted underneath — it will happily write to the
100 GB root EBS volume for the whole run. Nothing surfaces the mistake: the
benchmark completes and reports numbers for the wrong disk. `install-all.sh`
enforces the ordering and refuses to continue if any node's
`/mnt/k8s-disks/0` is not backed by `/dev/nvme*`.

Check it any time, during ingestion especially — `Used` should be climbing:

```bash
kubectl -n kube-system exec ds/mount-nvme -- \
  nsenter -t 1 -m -- df -h /mnt/k8s-disks/0
```

### Using EBS instead

To go back to network storage, replace each `hostPath` volume with a
`volumeClaimTemplates` entry (Prometheus and Mimir) and set
`persistence.enabled: true` with a `storageClass` in the two OpenObserve values
files. Note that gp3's default profile is 3000 IOPS / 125 MB/s regardless of
volume size, and that `volumeClaimTemplates` is immutable — changing a size or
class later means deleting the StatefulSet **and** its PVC.

## Teardown

```bash
kubectl delete ns perf-prometheus perf-mimir perf-o2-parquet perf-o2-vortex perf-fakeserver
helm -n openobserve-collector uninstall o2c
kubectl delete -f local-nvme/mount-nvme.yaml
```

There are no PVs or PVCs to clean up. The data sits on the nodes' instance
store and goes away with them, but it is **not** removed by deleting the
namespaces — the directories under `/mnt/k8s-disks/0` survive. A fresh run on
the same nodes therefore starts on top of the previous run's files. Clear them
first:

```bash
kubectl -n kube-system exec ds/mount-nvme -- \
  nsenter -t 1 -m -- sh -c 'rm -rf /mnt/k8s-disks/0/{prometheus,mimir,o2-parquet,o2-vortex}'
```
