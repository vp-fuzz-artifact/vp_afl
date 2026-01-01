#!/usr/bin/env python3
"""Campaign metrics.  usage: metrics.py <campaign_dir>

Writes three files into <campaign_dir>:

runs.csv                one line per run
    round platform example mode dumped afl_seed status run_time_s execs_done
    execs_per_sec stability_pct edges_found crashes first_crash_s first_crash_execs

cells.csv               one line per (platform, example, mode): mean and spread
                        over the rounds -> per-round and across-round stability

coverage_over_time.csv  long format, one line per sample of every run:
    platform example mode round time_s execs edges crashes
"""
import csv
import os
import re
import sys
import statistics as st

CRASH_RE = re.compile(r"time:(\d+).*?execs:(\d+)")
RUN_FIELDS = ["round", "platform", "example", "mode", "dumped", "afl_seed", "status",
              "run_time_s", "execs_done", "execs_per_sec", "stability_pct",
              "edges_found", "crashes", "first_crash_s", "first_crash_execs"]


def kv(path, sep):
    d = {}
    if os.path.exists(path):
        for line in open(path, errors="replace"):
            if sep in line:
                k, v = line.split(sep, 1)
                d[k.strip()] = v.strip()
    return d


def num(d, k):
    try:
        return float(str(d.get(k, "")).replace("%", ""))
    except ValueError:
        return None


def first_crash(d):
    """AFL encodes discovery time (ms) and exec count in the crash filename."""
    best = None
    if os.path.isdir(d):
        for n in os.listdir(d):
            m = CRASH_RE.search(n)
            if n.startswith("id:") and m:
                c = (int(m.group(1)) / 1000.0, int(m.group(2)))
                best = c if best is None or c < best else best
    return best or ("", "")


def plot_rows(path):
    """plot_data columns: 0 time, 7 crashes, 11 execs, 12 edges."""
    out = []
    if not os.path.exists(path):
        return out
    for line in open(path, errors="replace"):
        if line.startswith("#") or not line.strip():
            continue
        p = [x.strip().replace("%", "") for x in line.split(",")]
        if len(p) > 12:
            try:
                out.append((float(p[0]), float(p[11]), float(p[12]), float(p[7])))
            except ValueError:
                pass
    return sorted(out)


def main():
    camp = sys.argv[1] if len(sys.argv) > 1 else sys.exit("usage: metrics.py <campaign_dir>")
    runs, cov = [], []

    for root, dirs, _ in os.walk(camp):
        for d in sorted(dirs):
            rd = os.path.join(root, d)
            meta = kv(os.path.join(rd, "meta.txt"), "=")
            stats = kv(os.path.join(rd, "afl", "default", "fuzzer_stats"), ":")
            if not meta or not stats:
                continue
            fc_s, fc_e = first_crash(os.path.join(rd, "afl", "default", "crashes"))
            runs.append({
                "round": meta.get("round"), "platform": meta.get("platform"),
                "example": meta.get("example"), "mode": meta.get("mode"),
                "dumped": meta.get("dumped", ""),
                "afl_seed": meta.get("afl_seed", ""),
                "status": meta.get("status"),
                "run_time_s": num(stats, "run_time"),
                "execs_done": num(stats, "execs_done"),
                "execs_per_sec": num(stats, "execs_per_sec"),
                "stability_pct": num(stats, "stability"),
                "edges_found": num(stats, "edges_found"),
                "crashes": num(stats, "saved_crashes"),
                "first_crash_s": fc_s, "first_crash_execs": fc_e,
            })
            for t, ex, ed, cr in plot_rows(os.path.join(rd, "afl", "default", "plot_data")):
                cov.append([meta.get("platform"), meta.get("example"), meta.get("mode"),
                            meta.get("round"), t, ex, ed, cr])

    if not runs:
        sys.exit("no finished runs under " + camp)

    with open(os.path.join(camp, "runs.csv"), "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=RUN_FIELDS)
        w.writeheader()
        for r in sorted(runs, key=lambda r: (r["platform"], r["example"], r["mode"], r["round"])):
            w.writerow(r)

    with open(os.path.join(camp, "coverage_over_time.csv"), "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["platform", "example", "mode", "round", "time_s", "execs", "edges", "crashes"])
        w.writerows(cov)

    # ---- per cell: mean and spread over the rounds -------------------------
    cells = {}
    for r in runs:
        cells.setdefault((r["platform"], r["example"], r["mode"]), []).append(r)

    def spread(vals):
        vals = [v for v in vals if v is not None]
        if not vals:
            return "", "", "", ""
        sd = round(st.stdev(vals), 2) if len(vals) > 1 else 0.0
        return round(st.mean(vals), 2), sd, round(min(vals), 2), round(max(vals), 2)

    with open(os.path.join(camp, "cells.csv"), "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["platform", "example", "mode", "rounds", "ok",
                    "execs_per_sec_mean", "execs_per_sec_sd", "execs_per_sec_min", "execs_per_sec_max",
                    "stability_mean", "stability_sd", "stability_min", "stability_max",
                    "edges_mean", "edges_sd", "edges_min", "edges_max",
                    "rounds_with_crash", "first_crash_s_mean", "first_crash_s_sd",
                    "first_crash_execs_mean"])
        for key, rs in sorted(cells.items()):
            ok = [r for r in rs if r["status"] == "OK"]
            crashed = [r for r in ok if r["first_crash_s"] != ""]
            w.writerow(list(key) + [len(rs), len(ok)]
                       + list(spread([r["execs_per_sec"] for r in ok]))
                       + list(spread([r["stability_pct"] for r in ok]))
                       + list(spread([r["edges_found"] for r in ok]))
                       + [len(crashed)]
                       + list(spread([r["first_crash_s"] for r in crashed]))[:2]
                       + [spread([r["first_crash_execs"] for r in crashed])[0]])

    print(f"{len(runs)} runs, {len(cov)} coverage samples -> runs.csv, cells.csv, "
          f"coverage_over_time.csv in {camp}")
    bad = [f'{r["platform"]}/{r["example"]} m{r["mode"]} r{r["round"]} ({r["status"]})'
           for r in runs if r["status"] != "OK"]
    if bad:
        print("NOT OK: " + ", ".join(bad))


if __name__ == "__main__":
    main()
