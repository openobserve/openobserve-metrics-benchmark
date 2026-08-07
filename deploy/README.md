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

All four get the same envelope: **7 CPU / 14G with requests == limits**
(Guaranteed QoS, so CPU shares are fixed and memory is never reclaimed) on a
**dedicated node**, and a **500Gi** PVC.

> `memory: 14G` is decimal — 14e9 bytes = 13351Mi. Do **not** "correct" it to
> `14Gi`; that is 14336Mi, more than a `c7g.2xlarge` has left after daemonsets,
> and the pod will sit `Pending` forever.

The Helm release name for both OpenObserve deployments must stay `o2` — it is
what produces the Service name `o2-openobserve-standalone` that the collector's
exporters address.

## Notes per component

**`prometheus/`** — runs with `--web.enable-remote-write-receiver` and an empty
`scrape_configs`. It never scrapes anything itself; all load arrives by remote
write.

**`mimir/`** — single-binary mode on filesystem blocks storage, replication
factor 1. Write-path limits are raised far above the workload so nothing is
throttled. **Query-path limits are left at their defaults on purpose** — the
`err-mimir-max-chunks-per-query` failure on the 3-hour unfiltered histogram is a
finding, not a broken deployment. Raising
`-querier.max-fetched-chunks-per-query` would let it complete, at the cost of
much more memory for a single query on a 14GB machine.

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

**`fake-webserver/`** — 10 replicas, no flags, so image defaults apply: 54
distinct `path` values, 5 regions, 3 versions, 2 methods, and a histogram with
25 explicit buckets plus `+Inf`. That last detail is why
`codelab_api_request_duration_seconds_bucket` has exactly 26× the series of
`..._count`.

**`otel-collector/`** — the load path, and the file worth reading before
anything else. One `prometheus/perf-fakeserver` receiver scrapes the 10 pods
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
used gp3 at its default profile (3000 IOPS / 125 MB/s), which is what produces
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
