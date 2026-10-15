#!/usr/bin/env bash
# Show or switch the dataset name in every system's data path:
#   ./set-dataset.sh            # show
#   ./set-dataset.sh run-b      # switch, then ./install-all.sh
set -euo pipefail
cd "$(dirname "$0")"

FILES=(
  prometheus/deploy.yaml
  mimir/deploy.yaml
  victoriametrics/values.yaml
  openobserve-parquet/values.yaml
)
ROOT="/mnt/k8s-disks/0"

current() {
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

They will come up empty. '${now}' is still on disk.
EOF
