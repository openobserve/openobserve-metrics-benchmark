# Where things stand — 2026-08-10 14:10 CST

Working notes, not part of the published benchmark. All testing is finished.

## Testing closed (2026-08-12)

Deployment is back to the published configuration and verified end to end:

| | |
| --- | --- |
| Dataset | `run-a`, all four, cardinality 1,085,760 |
| OpenObserve | `openobserve/openobserve:v0.92.0`, no experimental env |
| Memory | 28 GB on all four |
| Load generator | 24 replicas in the deploy file, scaled to 0 in the cluster |
| Filter | `PATH_FILTER=/api/bar` |
| Disk | 11 / 18 / 28 / 27 GB -- matches the published table exactly |

### rc3 builds migrate the metadata store, one way

An rc3 build opening a dataset runs sqlite migrations 65 and 66. v0.92.0 ships
only up to 64, sees a newer schema and refuses to start:

```
DB_SCHEMA_VERSION mismatch : expected 64, found 66
db init failed: Migration file of version 'm20260809_000001_...' is missing
```

Restoring the parquet files alone does not fix it -- the `.sqlite` in the same
directory carries the schema. **Back up a dataset before letting any rc build
touch it, or it can never be read by the release again.** `run-a` was recovered
this way from `backup/run-a-o2-*`; `run-b` and `run-c` are still on schema 66
and are rc3-only.

### Build comparisons measured (diagnostic, not in RESULTS)

- `1e921fa` vs `v0.92.0` on run-a: 1.1-1.5x faster, most consistently ~1.25x
  on filtered queries in both formats.
- `1e921fa` vs `b3f3c1d` on run-b: 1.6-2.0x faster on filtered queries.
  Confounded -- the two runs read different file layouts.
- `ZO_METRICS_INLIST_FILTER_ENABLED=true` on v0.92.0: up to 2x, by moving the
  series threshold from ~905k to ~1.36M.
- `ZO_COMPACT_MAX_FILE_SIZE=4096`: no effect on parquet, ~10% on vortex.
- `ZO_METRICS_LABEL_CACHE_MAX_SIZE`: no measurable effect. These queries touch
  few distinct label combinations, so the cache is not the bottleneck here.

### Backups on the instance store

`/mnt/k8s-disks/0/backup/` holds `run-a-*` (pre-rc3, the restore point),
`run-b-*`, `run-c-*` and `run-b-sorted-o2-vortex` (the 683-file sorted layout).
All on the same ephemeral disks as the originals -- a node replacement takes
both.

## Done (2026-08-12): RESULTS re-run on /api/bar

The published filtered-histogram numbers used `/api/service-1`, one of 50
generated endpoints carrying 25,740 series. The four fixed endpoints
(`/api/foo`, `/api/bar`, `/api/baz`, `/api/boom`) carry 51,480 each -- double --
so the choice silently halved the filtered figures. Both rounds re-run on
`/api/bar`; `bench/config.sh` now defaults to it.

- [x] back up run-a (all four, diff -rq IDENTICAL) -- backups now cover
      run-a, run-b, run-c under /mnt/k8s-disks/0/backup/
- [x] O2 back to openobserve/openobserve:v0.92.0 BEFORE mounting run-a, so rc3
      never touched it; ZO_COMPACT_MAX_FILE_SIZE removed
- [x] Round 1 at 28 GB, Round 2 at 14 GB, deploy files back to 28G
- [x] RESULTS.md / .html / .zh.html / README.md updated and cross-checked

**What changed in the conclusions.** Prometheus and Mimir roughly double when
the filter matches twice the series (1.93x, 1.80x); OpenObserve moves 2%. So
Parquet went from *slowest of four* on the light path to *third, ahead of
Prometheus* on the heavy one -- without Parquet changing at all. The old text
read that as a Parquet weakness; it is really a statement about how the other
two scale. RESULTS now says so, and carries a table showing both paths.

Round 2 reproduced the OOMKill exactly: restartCount=2, OOMKilled, exitCode=137,
157s then instant connection-refused at 3h, 193s at 6h.

**Trap when editing the HTML:** a blanket numeric substitution corrupted the
Mimir brand colour, because `7517` matched inside `#ba7517`. Scope replacements
to `<td>` and `<text>` content. The SVG bar widths also encode the values and
must be rescaled per panel, or the labels and bars disagree.

## Final state (2026-08-11)

- Deploy files describe the **published** configuration: `run-a`, 28 GB, all
  four pinned to their nodes. Verified at 1,085,760 series before shutdown.
- **Prometheus and Mimir are scaled to 0.** Their data is untouched on the node
  instance stores; `kubectl -n perf-prometheus scale sts prometheus-standalone
  --replicas=1` brings them back.
- Both OpenObserve deployments and the `bench` runner pod are still up.
- `fake-webserver` is at 0 replicas; 24 in the deploy file.
- `ZO_METRICS_INLIST_FILTER_ENABLED` was used for one experiment (below) and
  **reverted**, so the repo still matches what produced RESULTS.

### Disk on the nodes right now

| Node | run-a | run-b | run-rehearsal |
| --- | --- | --- | --- |
| ip-10-1-89-108 prometheus | 11G | 4.4G | 452M |
| ip-10-1-86-16 mimir | **26G** | 4.8G | 1.4G |
| ip-10-1-64-74 o2-parquet | 28G | 8.7G | 1.4G |
| ip-10-1-89-244 o2-vortex | 27G | 8.4G | 1.4G |

**Mimir's run-a reads 26G, but RESULTS publishes 18G, and 18G is the correct
figure.** It was measured at stop+14.8h on an instance that had not been
touched since ingestion stopped. This investigation restarted Mimir many times;
each restart re-runs compaction and re-arms `deletion_delay: 12h`, so the
superseded blocks came back. Do not "correct" the published number from a
reading taken today -- it would need another ~14h undisturbed to settle again.

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
| `run-a` | **currently mounted** — the published dataset, 24 replicas, 8h23m, frozen |
| `run-rehearsal` | 30-minute churn rehearsal, disposable |
| `run-b` | the churn experiment, kept for re-querying |

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

## Churn experiment — done; Mimir explained, OpenObserve not

Diagnostic only; it did not change RESULTS. Dataset `run-b` is still on the
instance store if anyone wants to re-query it.

Ran 2026-08-10, 10 replicas with `rollout restart` at t=1h/2h/3h, stopped at
t=6h, measured after a 2h settle. `START=1786341822`.

**The dataset came out as designed.** All four systems agreed exactly on every
count, and the A/B pair holds total samples constant while varying series 2.5x:

| Window | Series | Samples | Width |
| --- | --- | --- | --- |
| A `[0h,3h]` | 1,357,200 | 325,001,820 | 3h |
| B `[3h,6h]` | 542,880 | 325,476,892 | 3h |
| C `[1h,2h]` | 633,360 | 108,511,468 | 1h |
| D `[4h,5h]` | 452,400 | 108,576,000 | 1h |

**Latency, median of 5 warm runs (ms):**

| System | A | B | A/B | C | D | C/D |
| --- | --- | --- | --- | --- | --- | --- |
| Prometheus | 1,821 | 1,646 | 1.11x | 672 | 648 | 1.04x |
| Mimir | 5,617 | 1,531 | **3.67x** | 681 | 569 | 1.20x |
| O2 · Parquet | 2,176 | 2,657 | 0.82x | 991 | 515 | 1.92x |
| O2 · Vortex | 773 | 790 | 0.98x | 300 | 179 | 1.68x |

### Why it is inconclusive

**The C/D control failed, and not for the reason it was built to catch.** C was
supposed to hold the same series count as D and differ only in position. It does
not: C has 633,360 series against D's 452,400, 1.40x more, because `[1h,2h]`
straddles the rollout boundaries at t=1h and t=2h while `[4h,5h]` sits inside
batch 4's undivided three-hour span. So C/D never tested position at all — it is
a second, weaker series test.

**The two series tests contradict each other.** A/B (2.50x series) says Mimir
pays steeply and OpenObserve not at all. C/D (1.40x series) says the opposite:
OpenObserve pays 1.7-1.9x and Mimir only 1.20x. Both cannot be a clean read of
"cost vs series count".

The likely reason is that A/B varies two things at once. Holding samples
constant while varying series count *forces* per-series depth to move
inversely — A holds ~1h of samples per series, B holds ~3h. C/D holds depth
equal at 1h. So A/B measures series count confounded with per-series depth, and
C/D measures series count confounded with batch-boundary structure. Neither
isolates the variable.

**One observation survives:** Mimir's cost is far more sensitive to how series
are distributed across a window than the others — 3.67x against 1.11x, 0.82x
and 0.98x on the same pair. That is a large effect and worth knowing, but this
experiment cannot say whether the driver is series count, chunk count, or
per-series depth.

### Does it explain the delta against the original article?

**Partly, and only suggestively.**

- *The Mimir half is consistent.* If the original run's window held more
  distinct series — plausible, since fake-webserver was rescheduled every few
  hours there and never restarted here — Mimir would have been markedly slower
  then. That matches Mimir measuring ~2x faster now.
- *The OpenObserve half is not explained.* OpenObserve shows no A/B sensitivity
  at all, so series churn would not have made it slower. Its ~2x slowdown
  against the original article remains unaccounted for.

### Round-hour re-measurement, and what it settled

The first pass anchored windows to when the load generator came up (:03:42),
which put batch boundaries inside the windows and straddled the epoch-aligned
2h TSDB block boundaries Prometheus and Mimir cut on. Re-running on round hours
fixed both and produced a working control (two windows holding identical series
at different positions).

**Positional noise floor**, measured on byte-identical windows:

| | Prometheus | Mimir | O2 Parquet | O2 Vortex |
| --- | --- | --- | --- | --- |
| noise | 0.89-1.31x | 1.25-1.26x | 0.81-1.01x | 0.84-1.01x |

Prometheus and Mimir swing 16-31% on identical data depending on where the
window sits. OpenObserve is flat to 1-4% at 1h; its 0.81x at 3h is the one
exception and is unexplained.

**Series scaling at 3h, samples held constant (318-325M), 720 points:**

| Series | Prometheus | Mimir | O2 Parquet | O2 Vortex |
| --- | --- | --- | --- | --- |
| 904,800 | 1,650 | 1,729 | 2,652 | 808 |
| 1,357,200 | 1,719 / 1,921 | 4,655 / 5,852 | 2,106 / 2,598 | 693 / 825 |
| 1,809,600 | 1,997 | 6,104 | 2,617 | 805 |
| **2.00x ratio** | **1.21x** | **3.53x** | **0.99x** | **1.00x** |

**Mimir has a cardinality cliff, not a slope.** It jumps 2.7-3.4x between
904,800 and 1,357,200 series and then plateaus (+4% for a further 1.33x). The
cliff clears Mimir's 1.26x noise floor by 2-3x; the plateau does not. Published
run-a holds 1,085,760 series, which sits *inside* the un-probed 905k-1.36M gap,
so the knee is bracketed but not located. Empirically run-a shows no
degradation (Mimir 4,416ms vs Prometheus 4,798ms at 6h filtered).

**OpenObserve does not track series count at all** -- 2.00x the series costs
0.99x/1.00x, less than its own positional noise.

### What OpenObserve does track: samples, not output points

Decisive test, series pinned at 452,400 (all windows inside batch 4), varying
samples and points independently:

| Manipulation | O2 Parquet | O2 Vortex |
| --- | --- | --- |
| control, identical window at a later hour | 1.01x | 0.97x |
| **2x samples**, points fixed at 240 | **1.81x** | **1.66x** |
| **2x points**, samples fixed at 217M | 1.03x | 1.03x |

This is the architectural inverse of the other two: the step study showed
36->720 points moving Prometheus 1.68->3.92s and Mimir 1.14->4.11s on a fixed
window. **Prometheus and Mimir bill per output point; OpenObserve bills per
sample scanned.**

**Series does matter, up to a ceiling.** A 2h sweep at constant width, points
and samples (~217M) found it:

| Series | O2 Parquet | vs 452k | O2 Vortex | vs 452k |
| --- | --- | --- | --- | --- |
| 452,400 | 918 | 1.00x | 291 | 1.00x |
| 904,800 | 1,758 | **1.92x** | 513 | **1.76x** |
| 1,357,200 | 1,781 / 1,755 | 1.94x / 1.91x | 520 / 525 | 1.79x / 1.80x |

Cost rises nearly proportionally to ~900k series and is flat above it: 452k to
905k almost doubles the time, 905k to 1,357k adds 1%. The samples term has no
such ceiling (2x samples costs 1.81x at every width tested).

That reconciles the readings that looked contradictory:

| Test | Series range | Region | Measured |
| --- | --- | --- | --- |
| 1h | 452k -> 905k | linear | 1.89x |
| 2h | 452k -> 905k | linear | 1.92x |
| 2h | 905k -> 1,357k | saturated | 1.01x |
| 3h | 905k -> 1,810k | saturated | 0.99x |

The 3h test showed nothing because both of its points were already past the
ceiling. So: **time tracks samples, and tracks series up to ~900k, above which
extra series are free.**

Caveat: the 905k control failed (1,758 vs 1,259 ms, 1.40x). The faster window,
14:00-16:00, is the only one starting before ingestion began, so it holds 1h56m
of data and 210M samples rather than 217M -- which does not account for 40%. The
figures above use 17:00-19:00, which sits mid-dataset like the rest. The
1,357,200 control is clean (1.01x) and the saturation conclusion rests on it.

### Does it explain the delta against the original article?

**The Mimir half, yes.** At ~1.8M series Mimir is 3.5x slower than at 905k. If
the original run accumulated ~2M through pod rescheduling, it was past the
cliff; run-a at 1.09M is not. That is sufficient to explain Mimir measuring
~2x faster here.

**The OpenObserve half, no.** OpenObserve shows no series sensitivity whatever,
so churn cannot have slowed it. Its ~2x gap against the original article
remains unexplained.

### If anyone reruns it

Use round-hour windows. Fix the batch overlap by scaling to 0, waiting past the
scrape interval, then scaling back up -- `rollout restart` runs old and new pods
together for ~30-60s. And probe 0.9M-1.4M finely if the goal is to locate
Mimir's knee rather than bracket it.

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
