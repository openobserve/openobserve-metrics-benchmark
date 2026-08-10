# Where things stand — 2026-08-10 14:10 CST

Working notes, not part of the published benchmark. Delete when the churn
experiment is finished and deploy is back to the published configuration.

## Published results are final

`RESULTS.md`, `RESULTS.html` and `README.md` carry the measured numbers:
Prometheus/Mimir from the 2026-08-09 rounds, OpenObserve from the v0.92.0
re-runs, disk settled at stop+14.8h, sample count measured (2.23B) rather
than derived.

| Result | Directory | Systems |
| --- | --- | --- |
| 28 GB | `results/20260809T151558Z` | all four (O2 on rc3, superseded) |
| 14 GB | `results/20260809T162358Z` | all four (O2 on rc3, superseded) |
| 28 GB | `results/20260810T023344Z` | O2 only, v0.92.0 — **published** |
| 14 GB | `results/20260810T034550Z` | O2 only, v0.92.0 — **published** |

`results/` is gitignored; the directories are local only.

Branch `in-cluster-benchmarking`, **not merged to main**.

## Datasets on the instance store

Each node holds several datasets; only one is mounted at a time. Switch with
`deploy/set-dataset.sh <name>` then `deploy/install-all.sh`.

| Dataset | What it is |
| --- | --- |
| `run-a` | the published dataset, 24 replicas, 8h23m, frozen |
| `run-rehearsal` | 30-minute churn rehearsal, disposable |
| `run-b` | **currently mounted** — the churn experiment |

## Each system is pinned to its node

`hostPath` is node-local and nothing used to tie a StatefulSet to the node
holding its data. Scaling all four down and up put every one of them on a
different perf node, where the hostPath was created empty — all four came up
with no data, which reads exactly like total loss and was not.

Nodes are now labelled `perf-system=<name>` and each deploy file selects on it:

| Node | System |
| --- | --- |
| ip-10-1-89-108 | prometheus |
| ip-10-1-86-16 | mimir |
| ip-10-1-64-74 | o2-parquet |
| ip-10-1-89-244 | o2-vortex |

Re-label before any install on a rebuilt cluster, or the pods will not schedule.

## Churn experiment — running now

**Diagnostic only. It does not update RESULTS.** It exists to explain why Mimir
measured ~2x faster and OpenObserve ~2x slower than the original article: the
hypothesis is that the original run accumulated ~2M series in the in-memory
index while the query window held only ~1M. Whatever it finds stays in these
notes.

Testing whether a system pays for the series in the query window or the series
in its index.

```
START_UNIX  1786341822    # 2026-08-10 14:03:42 CST
t=1h,2h,3h  rollout restart -> batches 2, 3, 4
t=6h        20:03 CST, ingestion stops
+2h settle  ~22:05 CST, run the comparison
```

```bash
START=1786341822 RUNS=5 PASS_ENV="START" \
  bench/run-in-cluster.sh --script experiments/churn-compare.sh
```

`churn-compare.sh` measures four windows. A `[0h,3h]` holds ~1.35M series
against B `[3h,6h]`'s ~450k, while both hold roughly the same total samples —
so A/B ≈ 3× means cost follows series count, and A/B ≈ 1× means it follows
samples or index size (that pair cannot separate those two). C `[1h,2h]` and D
`[4h,5h]` are the control: identical in every respect but position, so C/D far
from 1× means the A/B result cannot be read.

**When it is done, put deploy back to normal:**

```bash
deploy/set-dataset.sh run-a && deploy/install-all.sh
```

`run-a` is the published dataset. Confirm cardinality is 1,085,760 at
`END_TIME=1786276800` and that `fake-webserver` is at 24 replicas in the deploy
file (churn-run.sh only scales it at runtime; the file is untouched).

**What the rehearsal taught:** at `HOUR=300` the numbers were pure noise —
the o2-vortex control read 4.00× where it must read ~1×, and single runs swung
77–586 ms. Use `RUNS=5` and wait the full settle. The control is what catches
this; do not skip it.

## Open question, unresolved

Against the original article, OpenObserve measures ~2x slower on the same
query (Parquet regex 3h: 2,200 ms there, 4,336 ms here) while Mimir measures
~2x faster. Ruled out: step (15s in both), scrape interval, cardinality, window
length, data density, disk (ours is faster), memory (ours is larger), version.
Our figure reproduces to within 1% across three independent runs on two
datasets and two OpenObserve builds, so the number itself is solid — the cause
of the difference is not known.

## Things learned the hard way

- **A pod restart can move a system to a node with no data.** See above. Check
  `kubectl -n <ns> get pod -o jsonpath='{.items[0].spec.nodeName}'` before
  concluding anything about an empty system.
- **Wait for the process, not just the pod.** A round started 120s after an
  image upgrade read 250 ms where the settled value was 123 ms, and the whole
  round had to be discarded. 300s plus a check that CPU is at zero.
- **A benchmark run and the disk measurement are on different clocks.** Query
  results are valid immediately; disk is not valid for ~14 hours.
- **`kubectl exec` on this cluster fails intermittently** with `error: EOF`,
  and `kubectl exec -i ... < file` can silently deliver a zero-byte file.
  Ship files with `tar | kubectl exec -i -- tar x` and check the size.
- **Do not run `deploy/otel-collector/install.sh` here.** The cluster's
  collector carries six unrelated pipelines and that script replaces the
  release's values wholesale.
- **The load generator must not tolerate the `perf` taint.** It used to, so
  replicas could land on a system under test and compete with it for CPU.
