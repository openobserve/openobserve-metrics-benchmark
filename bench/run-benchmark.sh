#!/usr/bin/env bash
# Runs the four PromQL queries against all four systems, over every window in
# WINDOWS, RUNS times each plus one cold run 0 -- with the unfiltered histogram
# recorded once on the widest windows (see SINGLE_RUN_CELLS).
#
# The step is computed per window the way Grafana does, not pinned at 15s; see
# config.sh.
#
# Writes a CSV of every individual request to results/<timestamp>/raw.csv and
# prints a median summary at the end.
#
# Usage:
#   ./run-benchmark.sh
#   END_TIME=2026-08-06T03:00:00+08:00 ./run-benchmark.sh
#   SYSTEMS_FILTER=o2-vortex QUERY_FILTER=histogram-regex ./run-benchmark.sh
set -uo pipefail

cd "$(dirname "$0")"
# shellcheck source=config.sh
source ./config.sh
# shellcheck source=queries.sh
source ./queries.sh

command -v curl    >/dev/null || die "curl not found"
command -v python3 >/dev/null || die "python3 not found"

: "${SYSTEMS_FILTER:=}"   # substring match on the system label
: "${QUERY_FILTER:=}"     # substring match on the query id

END_TS="$(resolve_end_time)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTDIR="../results/${STAMP}"
mkdir -p "${OUTDIR}"
RAW="${OUTDIR}/raw.csv"
BODY="$(mktemp)"
trap 'rm -f "${BODY}"' EXIT

echo "query,window,step,system,run,started_unix,http_code,latency_ms,series,error" > "${RAW}"

# Record exactly what was run, so a CSV is never orphaned from its parameters.
cat > "${OUTDIR}/run-metadata.txt" <<EOF
started_utc     $(date -u +%Y-%m-%dT%H:%M:%SZ)
end_time_unix   ${END_TS}
end_time_utc    $(python3 -c "import datetime,sys;print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).isoformat())" "${END_TS}")
windows_sec     ${WINDOWS}
step            ${STEP:-per-window (Grafana rule: max(${MIN_INTERVAL}s, range/${MAX_DATA_POINTS}), rounded up)}
runs            ${RUNS}
warmup          ${WARMUP} (unrecorded requests per cell before the recorded runs)
path_filter     ${PATH_FILTER}
prometheus      ${PROM_BASE}
mimir           ${MIMIR_BASE}
o2_parquet      ${O2_PARQUET_BASE}
o2_vortex       ${O2_VORTEX_BASE}
EOF

echo "==> end of range: ${END_TS} ($(python3 -c "import datetime,sys;print(datetime.datetime.fromtimestamp(int(sys.argv[1])).isoformat())" "${END_TS}") local)"
echo "==> step=${STEP:-per-window} runs=${RUNS} path=${PATH_FILTER}"
echo "==> writing ${RAW}"
echo

# Parses a Prometheus-API JSON body: prints "<series_count>\t<error_message>".
parse_body() {
  python3 - "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        doc = json.load(fh)
except Exception as exc:
    print(f"-\tunparseable response: {exc}")
    sys.exit()
if doc.get("status") != "success":
    msg = doc.get("error") or doc.get("message") or "unknown error"
    print(f"-\t{' '.join(str(msg).split())}")
    sys.exit()
data = doc.get("data") or {}
result = data.get("result")
print(f"{len(result) if isinstance(result, list) else '-'}\t")
PY
}

csv_escape() { printf '"%s"' "${1//\"/\"\"}"; }

# Issues one request and appends one CSV row. Reads the loop's variables
# (qid, label, sys, base, auth_args, promql, start_ts, run) from the enclosing
# scope; `run` is 0 for the cold first-touch request.
do_request() {
  local timing http_code secs ms series errmsg parsed started
  started="$(date +%s)"

  # %{time_total} is the full request wall time as seen by the client.
  # ${arr[@]+"${arr[@]}"} is the portable way to expand a possibly-empty array
  # under `set -u`; plain "${arr[@]}" is an unbound-variable error on bash 3.2
  # (what macOS ships).
  : > "${BODY}"
  # curl still emits -w output on timeout (with http_code 000), so keep
  # whatever it gave us rather than discarding it on a non-zero exit.
  timing="$(curl -sS -o "${BODY}" -w '%{http_code} %{time_total}' \
    --max-time "${CURL_TIMEOUT}" \
    ${auth_args[@]+"${auth_args[@]}"} \
    --data-urlencode "query=${promql}" \
    --data-urlencode "start=${start_ts}" \
    --data-urlencode "end=${END_TS}" \
    --data-urlencode "step=${step}" \
    "${base}/api/v1/query_range" 2>/dev/null)" || true
  [[ "${timing}" == *" "* ]] || timing="000 0"

  http_code="${timing%% *}"
  secs="${timing##* }"
  ms="$(python3 -c "import sys;print(round(float(sys.argv[1])*1000))" "${secs}" 2>/dev/null || echo 0)"

  if [[ "${http_code}" == "000" ]]; then
    # No HTTP response at all: timed out, refused, or DNS failed. The elapsed
    # time is still meaningful -- it is the timeout.
    series="-"
    errmsg="no response after ${ms}ms (timeout or connection failure)"
  else
    parsed="$(parse_body "${BODY}")"
    series="${parsed%%$'\t'*}"
    errmsg="${parsed#*$'\t'}"
    [[ "${http_code}" != "200" && -z "${errmsg}" ]] && errmsg="HTTP ${http_code}"
  fi

  if [[ -n "${errmsg}" ]]; then
    printf '%sERR ' "$([[ "${run}" == "0" ]] && echo '~' || true)"
  else
    printf '%s%s ' "$([[ "${run}" == "0" ]] && echo '~' || true)" "${ms}"
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${qid}" "${label}" "${step}" "${sys}" "${run}" "${started}" "${http_code}" "${ms}" \
    "${series}" "$(csv_escape "${errmsg}")" >> "${RAW}"
}

for qid in "${QUERY_IDS[@]}"; do
  [[ -n "${QUERY_FILTER}" && "${qid}" != *"${QUERY_FILTER}"* ]] && continue
  promql="$(build_query "${qid}")"
  echo "### ${qid}"
  echo "    ${promql}"

  for win in ${WINDOWS}; do
    start_ts=$(( END_TS - win ))
    label="$(human_window "${win}")"
    step="$(step_for_window "${win}")"

    for entry in "${SYSTEMS[@]}"; do
      IFS='|' read -r sys base auth <<< "${entry}"
      [[ -n "${SYSTEMS_FILTER}" && "${sys}" != *"${SYSTEMS_FILTER}"* ]] && continue

      printf '    %-6s %-5s %-12s ' "${label}" "${step}" "${sys}"

      auth_args=()
      [[ -n "${auth}" ]] && auth_args=(--user "${auth}")

      # Cells listed in SINGLE_RUN_CELLS get one recorded run instead of RUNS.
      # For a cell where a single request costs minutes, repeating it buys
      # little: its spread is dominated by scan volume, not by run-to-run noise.
      cell_runs="${RUNS}"
      for c in ${SINGLE_RUN_CELLS}; do
        [[ "${qid}:${label}" == "${c}" ]] && cell_runs=1
      done

      # run 0 is the cold, first-touch request: file opens, metadata and index
      # loads, page cache misses. It is RECORDED but kept out of the medians,
      # because it answers a different question ("what does the first query
      # after a gap cost?") than runs 1..N ("what does a warm dashboard cost?").
      # summarize.py reports it in its own table. Printed as `~N` in the log.
      for (( w = 0; w < WARMUP; w++ )); do
        run=0
        do_request
      done

      for run in $(seq 1 "${cell_runs}"); do
        do_request
      done
      echo
    done
  done
  echo
done

echo "==> raw results: ${RAW}"
./summarize.py "${RAW}" | tee "${OUTDIR}/summary.md"
echo
echo "==> summary:     ${OUTDIR}/summary.md"
