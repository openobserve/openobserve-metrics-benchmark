# deploy/

Six components. Install in the order below — the collector must be last,
because its exporters point at the other four Services.

```bash
./prometheus/install.sh
./mimir/install.sh
./openobserve-parquet/install.sh
./openobserve-vortex/install.sh
./fake-webserver/install.sh
./otel-collector/install.sh
```

`./install-all.sh` runs exactly that sequence.

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
`m7g.2xlarge` tainted `perf=true:NoSchedule`, plus a **500Gi** PVC — identical
for all four.

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
| OpenObserve | (default) | 600s | 600s |

600s is OpenObserve's default; the others are matched to it.

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

Every PVC requests 500Gi from the **default StorageClass**. The published run
uses gp3 at its default profile (3000 IOPS / 125 MB/s), which is what produces
the cold-query behaviour discussed in the article. To pin it explicitly, create
a StorageClass and set `persistence.storageClass` in the two OpenObserve values
files and `storageClassName` in the two StatefulSets:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  type: gp3
```

`volumeClaimTemplates` is immutable. Changing a size or class later means
deleting the StatefulSet **and** its PVC and re-applying — `kubectl apply` alone
will not do it.

## Teardown

```bash
kubectl delete ns perf-prometheus perf-mimir perf-o2-parquet perf-o2-vortex perf-fakeserver
helm -n openobserve-collector uninstall o2c
```

Deleting the namespaces releases the four 500Gi volumes. Check that they
actually went — `kubectl get pv` — since a `Retain` reclaim policy will keep
billing you.
