#!/usr/bin/env bash
# Points all four systems at a named dataset directory on the instance store.
#
#   ./set-dataset.sh              # show the current name
#   ./set-dataset.sh run-b        # switch all four to /mnt/k8s-disks/0/run-b/
#
# Each system stores under /mnt/k8s-disks/0/<dataset>/<system>. Switching the
# name gives you a fresh, empty set of four while the previous dataset stays on
# disk untouched -- switch back to re-measure it without re-ingesting.
#
# This only edits the deploy files. Apply them, and remember that a system with
# an existing dataset needs its pod restarted to pick up the new path:
#
#   ./set-dataset.sh run-b && ./install-all.sh
#
# The systems come up empty; nothing is deleted. Old datasets are removed by
# hand when the disk is needed:
#
#   kubectl -n kube-system exec ds/mount-nvme -- \
#     nsenter -t 1 -m -- rm -rf /mnt/k8s-disks/0/<dataset>
set -euo pipefail
cd "$(dirname "$0")"

FILES=(
  prometheus/deploy.yaml
  mimir/deploy.yaml
  openobserve-parquet/values.yaml
  openobserve-vortex/values.yaml
)
ROOT="/mnt/k8s-disks/0"

current() {
  # Every file carries exactly one such path; take the dataset component.
  sed -n "s#.*${ROOT}/\([^/]*\)/.*#\1#p" "${FILES[0]}" | head -1
}

now="$(current)"

if [[ $# -eq 0 ]]; then
  echo "current dataset: ${now}"
  for f in "${FILES[@]}"; do
    printf '  %-34s %s\n' "${f}" "$(grep -o "${ROOT}/[^ \"]*" "${f}" | head -1)"
  done
  exit 0
fi

new="$1"
case "${new}" in
  */*|"") echo "error: dataset name must be a single path component" >&2; exit 1 ;;
esac

if [[ "${new}" == "${now}" ]]; then
  echo "already on '${new}'; nothing to change"
  exit 0
fi

for f in "${FILES[@]}"; do
  # Anchored on the full root so nothing else in the file can match.
  sed -i.bak "s#${ROOT}/${now}/#${ROOT}/${new}/#g" "${f}"
  rm -f "${f}.bak"
done

echo "dataset: ${now} -> ${new}"
for f in "${FILES[@]}"; do
  printf '  %-34s %s\n' "${f}" "$(grep -o "${ROOT}/[^ \"]*" "${f}" | head -1)"
done

cat <<EOF

Apply it:
  ./install-all.sh

The four will come up empty. '${now}' is still on disk.
EOF
