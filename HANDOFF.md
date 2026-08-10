# Where things stand — 2026-08-10 12:30 CST

Working notes, not part of the published benchmark. Delete when the churn
experiment is finished and its findings are folded into RESULTS.

## Done

Everything through `1907864` is committed and the working tree is clean.
`RESULTS.md`, `RESULTS.html` and `README.md` all carry the final numbers:
Prometheus/Mimir from the 2026-08-09 rounds, OpenObserve from the v0.92.0
re-runs, disk settled at stop+14.8h.

| Result | Directory | Systems |
| --- | --- | --- |
| 28 GB | `results/20260809T151558Z` | all four (O2 on rc3, superseded) |
| 14 GB | `results/20260809T162358Z` | all four (O2 on rc3, superseded) |
| 28 GB | `results/20260810T023344Z` | O2 only, v0.92.0 — **published** |
| 14 GB | `results/20260810T034550Z` | O2 only, v0.92.0 — **published** |

`results/` is gitignored; the directories are local only.

Branch `in-cluster-benchmarking`, 14 commits, **not merged to main**.

## Cluster state

- Four `m7gd.2xlarge`, one system each, tainted `perf=true:NoSchedule`
- Data on local NVMe at `/mnt/k8s-disks/0/<system>` — **still the old flat
  layout**, the deploy files now say `/mnt/k8s-disks/0/run-a/<system>`
- OpenObserve is at **14 GB** (left from the last round); Prometheus and Mimir
  are at 28 GB
- `fake-webserver` scaled to 0; the dataset is frozen
- `bench/bench` runner pod is up; `mount-nvme` DaemonSet is up

## Next: the churn experiment

Testing whether a system pays for the series in the query window or the series
in its index. Scripts are written and syntax-checked in the scratchpad:

- `churn-run.sh` — 10 replicas, `rollout restart` at t=1h/2h/3h, stop at t=6h.
  `HOUR=300` runs a 30-minute rehearsal instead of the full six hours.
- `churn-compare.sh` — needs `START` from `churn-run.log`; measures in-window
  cardinality and latency for `[0h,3h]` against `[3h,6h]` on all four systems.

Discriminator: `[3h,6h]` holds ~450k series against `[0h,3h]`'s ~1.35M. Cost
proportional to the window means ~3x faster; cost proportional to the index
means about equal.

Steps before starting it:

1. Migrate the current data into the new layout — `mv` on the same filesystem,
   so it is instant even at 28 GB:
   ```bash
   kubectl -n kube-system exec ds/mount-nvme -- nsenter -t 1 -m -- sh -c \
     'mkdir -p /mnt/k8s-disks/0/run-a && for d in prometheus mimir o2-parquet o2-vortex; do
        [ -d /mnt/k8s-disks/0/$d ] && mv /mnt/k8s-disks/0/$d /mnt/k8s-disks/0/run-a/$d; done'
   ```
   Then apply all four deploy files and confirm cardinality is still 1,085,760
   inside the window (`END_TIME=1786276800`).
2. Put OpenObserve back to 28 GB so all four match.
3. Switch the dataset name to `run-b` in all four files, apply, confirm the
   systems come up empty.
4. Rehearse with `HOUR=300`, then run for real.

## Open question, unresolved

Against the original article, OpenObserve measures ~2x slower on the same
query (Parquet regex 3h: 2,200 ms there, 4,336 ms here) while Mimir measures
~2x faster. Ruled out: step (15s in both), scrape interval, cardinality, window
length, data density, disk (ours is faster), memory (ours is larger), version.
Our figure reproduces to within 1% across three independent runs on two
datasets and two OpenObserve builds, so the number itself is solid — the cause
of the difference is not known.

## Things learned the hard way

- **Wait for the process, not just the pod.** A round started 120s after an
  image upgrade read 250 ms where the settled value was 123 ms, and the whole
  round had to be discarded. 300s plus a check that CPU is at zero.
- **A benchmark run and the disk measurement are on different clocks.** Query
  results are valid immediately; disk is not valid for ~14 hours.
- **`kubectl exec` on this cluster fails intermittently** with `error: EOF`.
  Setup steps retry; the launch deliberately does not, because retrying a
  launch that actually succeeded would put two benchmarks on one CPU.
- **Do not run `deploy/otel-collector/install.sh` here.** The cluster's
  collector carries six unrelated pipelines and that script replaces the
  release's values wholesale.
