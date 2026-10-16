# deploy/

```bash
./install-all.sh                  # 1 · NVMe + the four systems
INSTALL_LOAD=1 ./install-all.sh   # 2 · + the backfill
```

Each step is a no-op if already done, so re-running with the next flag is safe.

**Step 1 stops before any load.** The backfill writes the whole dataset to every
system in one go, so confirm all four are healthy first; `install-all.sh` prints
what to check. OpenObserve must be running with `ZO_COMPACT_ENABLED=false` for
the backfill (it is, in the values files as committed for a backfill round).

**`local-nvme` always runs first** — a system that starts before the mount
exists writes to the root EBS volume while appearing to use NVMe, and nothing
surfaces the mistake. See [Storage](#storage).

**Ready is not steady.** WAL replay, block loading and the first compaction all
happen after the readiness probe passes. `STABILIZE_SECS` (default 120) is the
pause before the load starts.

## The systems under test

| Directory | Namespace | Pod | Service | Query API base | Write endpoint |
| --- | --- | --- | --- | --- | --- |
| `prometheus/` | `perf-prometheus` | `prometheus-standalone-0` | `perf-prometheus-standalone:9090` | `/` | `/api/v1/write` |
| `mimir/` | `perf-mimir` | `mimir-standalone-0` | `perf-mimir-standalone:9009` | `/prometheus` | `/api/v1/push` |
| `victoriametrics/` | `perf-vm` | `vms-victoria-metrics-single-server-0` | `vms-victoria-metrics-single-server:8428` | `/` | `/api/v1/write` |
| `openobserve-parquet/` | `perf-o2-parquet` | `o2-openobserve-standalone-0` | `o2-openobserve-standalone:5080` | `/api/default/prometheus` | `/api/default/prometheus/api/v1/write` |

Each is pinned by `nodeSelector: perf-system=<prometheus|mimir|victoriametrics|o2-parquet>`
and tolerates `perf=true:NoSchedule`. The differing path prefixes are why
`bench/config.sh` stores a *base URL* per system rather than a hostname. The
names are load-bearing: the backfill Job and `bench/run-in-cluster.sh` address
these Services, so keep the Helm release names `vms` (VictoriaMetrics) and `o2`
(OpenObserve).

## Sizing

**12 CPU / 24G, requests == limits** (Guaranteed QoS) on a dedicated
`m7gd.4xlarge` (16 vCPU / 64 GiB, ~15.9 allocatable) tainted
`perf=true:NoSchedule`, writing to that node's **instance-store NVMe** —
identical for every system. Do not go above 12: the backfill Job shares
VictoriaMetrics' node and needs its one requested CPU.

`24G` is decimal (22.35 GiB); keep the decimal unit. It leaves each node ~35 GiB for page cache, more than any dataset here
needs, and it is the ceiling a query may use: Prometheus has peaked at 18.7 GB
on the unfiltered 6h histogram, and been OOMKilled at 14 GB.

## Notes per component

**`prometheus/`** — Prometheus v3.6.0 with `--web.enable-remote-write-receiver`
and an empty `scrape_configs`: all data arrives by remote write.
`storage.tsdb.out_of_order_time_window: 2h` lets it accept the backfill's
slightly reordered steps (four concurrent senders); without it the first
out-of-order sample is a 400 and the backfill aborts.

**`mimir/`** — single-binary mode on filesystem blocks storage, replication
factor 1, multitenancy off. Write limits are raised far above the workload.
For the backfill: `limits.out_of_order_time_window: 2h` (same reason as
Prometheus), and compaction, sync and deletion timers shortened from hours to
minutes, so Mimir settles about 30 minutes after the load and answers the
backfilled data from object storage. The image is pinned to
`grafana/mimir:3.2.2`.

**`victoriametrics/`** — `victoria-metrics-single` chart, release `vms`.
`-search.disableCache` is on, so it never answers from a result cache.
`retentionPeriod: 1` (month): **samples older than that are silently dropped**
(counted in `vm_too_small_timestamp_rows_ignored_total`, not refused), so a
backfill's start must be within the last month. The default dataset,
2026-09-28, stops fitting around 2026-10-28 — pass a newer `BACKFILL_START`, or
raise the retention, and check `vm_rows_added_to_storage_total` afterwards.

**`openobserve-parquet/`** — `openobserve-standalone` chart, release `o2`,
Parquet (the default file format). A Vortex deployment was dropped: with the metrics
index it queries no faster and takes more than twice the disk. Confirm what
reached the process before every round — the chart's ConfigMap carries its own
defaults, and it is the explicit `env` that wins:

```bash
kubectl -n perf-o2-parquet exec o2-openobserve-standalone-0 -- \
  sh -c 'tr "\0" "\n" </proc/1/environ | grep -E "ZO_COMPACT|ZO_METRICS|ZO_RESULT_CACHE|ZO_MAX_FILE" | sort'
```

The values files carry `ZO_COMPACT_ENABLED` and `ZO_MAX_FILE_RETENTION_TIME=60`
for the backfill procedure below, and `ZO_RESULT_CACHE_ENABLED=false` so warm
runs re-execute the query.

## The load: fake-webserver v5 backfill

**`fake-webserver/`** — one Job, `openobserve/fake-webserver:v5` in backfill
mode. It simulates `-num-nodes=14` on a virtual clock and writes every point
at exactly `start + k × step` to all four systems by Prometheus remote write
(protobuf + snappy, 10k samples per request, 429/5xx retried, any other 4xx
aborts), then exits. The defaults are the
published dataset:

| | |
| --- | --- |
| span | 2026-09-28 03:00:00Z + 7h (the 6h window plus 1h lookback), 15 s step, seed 1 |
| samples | 2,218,011,632, byte-identical on every run with the same flags |
| series | 1,338,330 — 1,179,360 `..._bucket`, 45,360 each `_sum`/`_count`/`requests_total` |

```bash
./fake-webserver/install.sh                                   # the default dataset
BACKFILL_START=2026-10-20T00:00:00Z ./fake-webserver/install.sh   # any other start
BACKFILL_HOURS=1 ./fake-webserver/install.sh                  # a smoke test
```

`install.sh` refuses to run while `job/backfill` exists (a second run
duplicates every sample), follows the progress lines, and fails loudly if the
Job did not complete. `-backfill-labels` adds the target labels a scrape would
(`job`, `instance`, `pod`, `node`, …) so every series carries the labels a
real scrape would give it.

The Job runs on VictoriaMetrics' node. It requests 1 CPU (all that is left
beside a Guaranteed 12) and may use up to 6 of whatever is idle; it is gone
before any query runs.

### After the backfill

Every system must hold every sample, and have finished its own post-ingest
work, before a query is timed:

| System | Holds everything when | Settled when |
| --- | --- | --- |
| OpenObserve (both) | `SELECT SUM(records) FROM file_list WHERE deleted=0` equals the generated count — ~3 min after the Job with `ZO_MAX_FILE_RETENTION_TIME=60` | compaction switched on and finished: `file_list_deleted` empty, as many `.midx` files as data files, no `compaction::merge` log line for 10 min — twice in a row |
| VictoriaMetrics | `vm_rows_added_to_storage_total` equals the generated count | `vm_active_merges` 0 |
| Prometheus | `prometheus_tsdb_head_samples_appended_total` equals the generated count | no head compaction for 10 min (`prometheus_tsdb_compactions_total` unchanged) |
| Mimir | `cortex_ingester_ingested_samples_total` equals the generated count | `cortex_ingester_memory_series` 0 (head idle-compacted and shipped), a compactor run after that, and a store-gateway sync after the run — ~30 min with this config |


OpenObserve takes one extra step, in this order:

1. **Backfill with compaction off.** Merging an hour while samples for it are
   still arriving marks the hour done; files that land in it afterwards stay
   unmerged, without `.midx`, until the hourly old-data sweep.
2. **Wait for the flush** (the first column above).
3. **Switch compaction on:** `ZO_COMPACT_ENABLED=true` in the values file,
   re-run its `install.sh`. Merging starts within a minute and each hour is
   merged once, whole.
4. **Wait for settled** (the second column).

A changed `ZO_COMPACT_MAX_FILE_SIZE` on already-merged data does nothing by
itself, and `./openobserve reset -c file-list-jobs` on a running compactor is
silently undone — the server keeps offsets in memory and writes them back. To
re-merge: `ZO_COMPACT_ENABLED=false` and re-run `install.sh`; run the reset in
each O2 pod (cwd `/`); `true` and re-run `install.sh`.

Then `bench/run-in-cluster.sh --script cardinality.sh` — all four must report
the same series counts.

## Query limits

At their defaults the systems *refuse* the million-series unfiltered histogram
rather than running it — which measures the limit, not the engine. All four get
the same allowances:

| System | Setting | Value | Default |
| --- | --- | --- | --- |
| Prometheus | `--query.max-samples` | 1e9 | 50e6 |
| Prometheus | `--query.timeout` | 600s | 2m |
| Mimir | `limits.max_fetched_chunks_per_query` | 20e6 | 2e6 |
| Mimir | `querier.timeout` | 600s | 2m |
| Mimir | `server.http_server_write_timeout` | 600s | 2m |
| VictoriaMetrics | `-search.maxSamplesPerQuery` | 2.147e9 | 1e9 |
| VictoriaMetrics | `-search.maxUniqueTimeseries` | 5e6 | derived from memory |
| VictoriaMetrics | `-search.maxQueryDuration` | 600s | 30s |
| OpenObserve | `ZO_METRICS_MAX_SERIES_RESPONSE` | 40000 | lower |
| OpenObserve | `ZO_METRICS_MAX_POINTS_PER_SERIES` | 10000000 | lower |
| OpenObserve | query timeout | 600s | 600s (unchanged) |

600s is OpenObserve's default timeout, so it is the number every other system
was matched to.

- **VictoriaMetrics:** `-search.maxSamplesPerQuery` is the one that binds — the
  6h unfiltered histogram scans ~1.18M series × 1,441 samples ≈ 1.7e9 raw
  samples. 2.147e9 is the largest value the flag accepts.
  `-search.maxSeriesPerAggrFunc` does not need raising: it bounds the series the
  aggregate *generates* (26 × 54 groups), not the ones it reads.
- **Mimir needs both timeouts.** `http_server_write_timeout` also defaults to 2m
  and fires first, closing the connection before Mimir can write its timeout
  response — the client sees a bare TCP close (`curl` reports `000`).
  `querier.timeout` belongs to the top-level `querier` block; under `limits` it
  fails at startup.
- **Prometheus memory:** raising `--query.max-samples` so the unfiltered
  histogram can run is also deciding that it may use ~19 GB for it (18.7 GB
  RSS has been measured, and an OOMKill at a 14 GB limit).

## Storage

Each system writes to its node's **instance-store NVMe** via a `hostPath` at
`/mnt/k8s-disks/0/<dataset>/<system>`, so disk speed is not a variable. There
are no PVCs.

**The data is ephemeral.** Instance store is lost whenever the node stops, is
replaced, or is scaled away. A backfill is cheap to redo, but a node that goes
away mid-round takes that system's dataset with it.

The default dataset settles at roughly 1.1 GB on VictoriaMetrics, 2.2 GB on
OpenObserve and 5.9 GB on Prometheus (RESULTS.md,
2026-10-15). The ~885 GB instance store holds many.

### The mount

`local-nvme/mount-nvme.yaml` is a DaemonSet that formats the instance-store
device as xfs and mounts it at `/mnt/k8s-disks/0`. It is idempotent — an
existing mount or filesystem is left alone — and it re-runs when a node is
replaced. It exists because the EKS AL2023 nodeadm `localStorage: RAID0`
setting did not take effect on these nodes; if it works for you, the DaemonSet
finds the mount in place and does nothing.

### Datasets

The data path carries a dataset name, `/mnt/k8s-disks/0/<dataset>/<system>`.
Change it in every file and re-apply, and the systems come up empty on a fresh
dataset while the previous one stays on disk; switching back re-attaches it.

```bash
./set-dataset.sh          # show the current name
./set-dataset.sh run-b    # switch all four, then ./install-all.sh
```

**Every file must use the same name.** A mismatch is silent — one system
quietly starts empty — and the cardinality check is the only thing that would
catch it.

What is on the nodes right now:

```bash
for p in $(kubectl -n kube-system get pods -l app=mount-nvme -o name); do
  kubectl -n kube-system exec "$p" -- nsenter -t 1 -m -- du -sh /mnt/k8s-disks/0/*/*
done
```

### Why the ordering matters

**Apply the DaemonSet before the systems under test.** A pod that starts first
binds its `hostPath` to the directory that exists at that moment and keeps that
view after the device is mounted underneath — it writes to the root EBS volume
for the whole run and nothing surfaces it. `install-all.sh` enforces the order
and refuses to continue if any node's `/mnt/k8s-disks/0` is not `/dev/nvme*`.

### Using EBS instead

Replace each `hostPath` with a `volumeClaimTemplates` entry (Prometheus, Mimir)
or `persistence.enabled: true` with a `storageClass` (VictoriaMetrics and the
OpenObserve values files). gp3's default is 3000 IOPS / 125 MB/s regardless of
size, and `volumeClaimTemplates` is immutable.

## Teardown

```bash
kubectl delete ns perf-prometheus perf-mimir perf-vm perf-o2-parquet perf-fakeserver
kubectl delete -f local-nvme/mount-nvme.yaml
```

Between rounds, scaling the StatefulSets to 0 is usually enough. Deleting the
namespaces does **not** remove the data under `/mnt/k8s-disks/0` — a fresh
round on the same nodes starts on top of it. Clear it on every node:

```bash
for p in $(kubectl -n kube-system get pods -l app=mount-nvme -o name); do
  kubectl -n kube-system exec "$p" -- nsenter -t 1 -m -- rm -rf /mnt/k8s-disks/0/<dataset>
done
```

Scaling the perf node group to zero discards every node's instance store, and
with it every dataset.
