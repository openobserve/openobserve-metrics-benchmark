# Local NVMe volumes

Puts each system's data on its node's instance-store NVMe instead of an EBS
volume, so disk speed stops being a variable in the comparison.

**The data is ephemeral.** Instance store is lost when the node stops, is
replaced, or is reclaimed — including a Karpenter consolidation or a spot
interruption. A run that takes hours to ingest can vanish in one node
replacement. Use on-demand capacity and keep the perf nodes from being
disrupted.

## 1 · Node group

The systems under test need `m7gd.2xlarge` (8 vCPU / 32 GiB / 474 GB NVMe) —
same CPU and memory as the `m7g.2xlarge` used before, so results stay
comparable and the only change is the disk.

Create the managed node group with this **userData** so AL2023 mounts the
instance store:

```yaml
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  instance:
    localStorage:
      strategy: RAID0
```

That mounts the disk at `/mnt/k8s-disks/0`. With one NVMe device "RAID0" is
just that device.

Keep the existing taint so nothing else lands there:

```bash
kubectl taint nodes <node> perf=true:NoSchedule
```

> `strategy: RAID0` also relocates containerd and kubelet storage onto the same
> disk, so image layers share the 474 GB. At benchmark sizes (~21 GB per system
> for 6h of ingestion) that is immaterial, but it is why `setup.sh` advertises
> 400Gi rather than the full capacity.

## 2 · StorageClass and PVs

```bash
kubectl apply -f storageclass.yaml
./setup.sh
```

`setup.sh` creates one PV per matching node, pinned to that node by
`nodeAffinity`, backed by `/mnt/k8s-disks/0/perf-bench`. It **verifies the path
is a real mountpoint first** and skips the node otherwise — without that check a
PV would quietly land on the root EBS volume and the whole point of the change
would be lost, invisibly.

```bash
./setup.sh --status     # nodes and PVs
./setup.sh --reset      # delete the PVs (needed between runs, see below)
```

## 3 · Point the systems at it

In both OpenObserve values files:

```yaml
persistence:
  storageClass: local-nvme
  size: 400Gi
```

and in the Prometheus and Mimir StatefulSets:

```yaml
volumeClaimTemplates:
  - spec:
      storageClassName: local-nvme
      resources:
        requests:
          storage: 400Gi
```

`volumeClaimTemplates` is immutable, so switching an existing deployment means
deleting the StatefulSet **and** its PVC and re-applying — `kubectl apply` alone
will not do it. That destroys the dataset and starts ingestion over.

## Re-running

Local PVs use `Retain` (`Delete` is not implemented for `no-provisioner`), so
after the PVCs go the PVs sit `Released` and will never rebind. Between runs:

```bash
kubectl delete sts,pvc -n <each namespace> --all
./setup.sh --reset
./setup.sh
```

`setup.sh` wipes the directory when it recreates the PV, so a new run never
inherits the previous run's blocks.
