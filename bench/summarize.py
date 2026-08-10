#!/usr/bin/env python3
"""Turn raw.csv from run-benchmark.sh into the markdown tables the article uses.

  ./summarize.py ../results/<stamp>/raw.csv

Prints two things:
  1. one table per query, with all runs shown (the article's format), and
  2. a cross-query table of 3h medians.

A cell where every run errored renders as `error x3`, exactly as in the article
-- an error is a result here, not a missing measurement.
"""

import csv
import statistics
import sys
from collections import defaultdict

SYSTEM_ORDER = ["prometheus", "mimir", "o2-parquet", "o2-vortex"]
SYSTEM_LABEL = {
    "prometheus": "Prometheus",
    "mimir": "Mimir",
    "o2-parquet": "O2 · Parquet",
    "o2-vortex": "O2 · Vortex",
}
QUERY_LABEL = {
    "irate": "1 · irate",
    "histogram-unfiltered": "2 · Unfiltered histogram",
    "histogram-regex": "3 · Filtered histogram (regex match)",
    "histogram-equality": "4 · Filtered histogram (equality match)",
}
WINDOW_ORDER = ["30m", "1h", "3h", "6h"]


def load(path):
    """(warm, cold), each [query][window][system] -> [(latency_ms, error)].

    run 0 is the cold first-touch request. It is kept apart from runs 1..N so a
    cold outlier never lands in a median that is meant to describe warm queries.
    """
    warm = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
    cold = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
    queries, windows = [], []
    with open(path, newline="") as fh:
        for r in csv.DictReader(fh):
            q, w, s = r["query"], r["window"], r["system"]
            if q not in queries:
                queries.append(q)
            if w not in windows:
                windows.append(w)
            bucket = cold if r.get("run") == "0" else warm
            bucket[q][w][s].append((int(r["latency_ms"] or 0), r["error"]))
    return warm, cold, queries, windows


def cell(runs):
    """The article's cell format: every run on its own line, or `error xN`."""
    if not runs:
        return "—"
    if all(err for _, err in runs):
        return f"error ×{len(runs)}"
    return "<br>".join("error" if err else str(ms) for ms, err in runs)


def median_ms(runs):
    good = [ms for ms, err in runs if not err]
    return round(statistics.median(good)) if good else None


def order(seen, preferred):
    return [x for x in preferred if x in seen] + [x for x in seen if x not in preferred]


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    rows, cold, queries, windows = load(sys.argv[1])

    seen_systems = {s for q in rows for w in rows[q] for s in rows[q][w]}
    seen_systems |= {s for q in cold for w in cold[q] for s in cold[q][w]}
    systems = order(seen_systems, SYSTEM_ORDER)
    windows = order(windows, WINDOW_ORDER)
    queries = order(queries, list(QUERY_LABEL))

    out = ["# Benchmark results", "", "All values are milliseconds of client-observed "
           "wall time. Every run is shown; `error ×N` means the system refused the "
           "query on all N attempts.", ""]

    for q in queries:
        out += [f"### {QUERY_LABEL.get(q, q)}", ""]
        out.append("| Window | " + " | ".join(SYSTEM_LABEL.get(s, s) for s in systems) + " |")
        out.append("| --- |" + " --- |" * len(systems))
        for w in windows:
            if w not in rows[q]:
                continue
            out.append(f"| {w} | " + " | ".join(cell(rows[q][w].get(s, [])) for s in systems) + " |")
        out.append("")

    if any(cold[q][w] for q in cold for w in cold[q]):
        out += ["### Cold first-touch query", "",
                "One unrecorded-in-medians request per cell, issued before the "
                "warm runs above. This is what the first query after a gap "
                "costs — file opens, index loads, page cache misses — not what "
                "a warm dashboard costs.", "",
                "| Query | Window | " + " | ".join(SYSTEM_LABEL.get(s, s) for s in systems) + " |",
                "| --- | --- |" + " --- |" * len(systems)]
        for q in queries:
            for w in windows:
                if w not in cold.get(q, {}):
                    continue
                vals = [cell(cold[q][w].get(s, [])) for s in systems]
                out.append(f"| {QUERY_LABEL.get(q, q)} | {w} | " + " | ".join(vals) + " |")
        out.append("")

    widest = windows[-1] if windows else None
    if widest:
        out += [f"### {widest} medians, all queries", "",
                "| Query | " + " | ".join(SYSTEM_LABEL.get(s, s) for s in systems) + " |",
                "| --- |" + " --- |" * len(systems)]
        for q in queries:
            if widest not in rows[q]:
                continue
            vals = []
            for s in systems:
                m = median_ms(rows[q][widest].get(s, []))
                vals.append(str(m) if m is not None else "error")
            out.append(f"| {QUERY_LABEL.get(q, q)} | " + " | ".join(vals) + " |")
        out.append("")

    print("\n".join(out))


if __name__ == "__main__":
    main()
