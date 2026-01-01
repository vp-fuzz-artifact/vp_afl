#!/usr/bin/env python3
"""Timing campaign metrics.  usage: timing_metrics.py <timing_dir> [--boot N]

Reads every round*/<platform>_<example>_mode<m>/{meta.txt,harness.log} and
writes three files into <timing_dir>:

timings.csv   one line per measured interval (every sample, nothing dropped)
                platform example mode round dumped status invocation iter
                interval ms cold used
metrics.csv   one line per (platform, example, mode, metric): median and MAD
                platform example mode metric n median mad mad_scaled min max
derived.csv   one line per (platform, example, mode) for each checkpoint
                scheme (1 CRIU, 2 fork): the three paper metrics
                startup_weight, restore_gain, speedup -- each with a bootstrap
                MAD -- plus the consistency checks.  CRIU's restore is timed
                directly; fork's is what mode 2 adds to mode 0's body, since
                the harness' Restart is a no-op when the VP forks.

Every statistic is a median with MAD (median absolute deviation), never a mean:
restore and boot times are right-skewed and a single cold outlier moves a mean.
mad_scaled is 1.4826 * MAD, the consistent estimator of sigma under normality,
for readers who want a comparable spread.

The two files report different spreads on purpose.  metrics.csv gives the
dispersion of the raw samples -- how much one restore differs from the next.
derived.csv gives the uncertainty of the reported estimate, every column from
the same bootstrap, so a row is internally consistent: restore_gain_mad follows
from Trestore_mad by propagation, and a single value can be quoted as
restore_gain +/- restore_gain_mad.

Each *_mad is accompanied by a *_rel_mad, the same spread divided by the value
it qualifies, so quantities of different magnitude can be compared directly.

Excluded from every median (but kept in timings.csv with used=0):
  * the CRIU dump run -- mode 1 with dumped=1 pays for creating the image and
    is not what a restore costs,
  * any run whose status is not OK.
"""
import argparse
import csv
import os
import random
import re
import statistics as st

ELAPSED_RE = re.compile(r"\]\s+INFO:\s+(.+?):\s+Elapsed\s+([0-9.]+)\s+ms\s*$")
TIMEOUT_RE = re.compile(r"a timeout occurred")
ITER_RE = re.compile(r"\]\s+INFO:\s+Iteration n\.(\d+)")
START_RE = re.compile(r"Benchmark starting\. Iterations = (\d+)")

BOOTSTRAP_DEFAULT = 2000
BOOTSTRAP_SEED = 20261013
MAD_TO_SIGMA = 1.4826


def kv(path, sep="="):
    d = {}
    if os.path.exists(path):
        for line in open(path, errors="replace"):
            if sep in line:
                k, v = line.split(sep, 1)
                d[k.strip()] = v.strip()
    return d


def median(xs):
    return st.median(xs) if xs else None


def mad(xs):
    """Median absolute deviation.  0.0 for a single sample, not None, so the
    column is always numeric; n in the same row says how much to trust it."""
    if not xs:
        return None
    m = st.median(xs)
    return st.median([abs(x - m) for x in xs])


def parse_log(path):
    """-> list of (invocation, iter, interval, ms).

    The harness logs, per invocation: launch_vp and run_init during init (only
    when it is not restoring from an image), then per iteration 'Iteration n.K'
    followed by 'Execution', followed by 'Restart' except on the last one.
    The log is opened in append mode, so several invocations can share a file.
    """
    rows, inv, it, timed_out = [], 0, 0, False
    if not os.path.exists(path):
        return rows
    for line in open(path, errors="replace"):
        if START_RE.search(line):
            inv += 1
            it = 0
            continue
        if TIMEOUT_RE.search(line):
            # the pipe timed out: the interval that follows measures
            # TC_TIMEOUT_MS, not the workload
            timed_out = True
            continue
        m = ITER_RE.search(line)
        if m:
            it = int(m.group(1))
            timed_out = False
            continue
        m = ELAPSED_RE.search(line)
        if m:
            label, ms = m.group(1).strip(), float(m.group(2))
            if label in ("launch_vp", "run_init"):
                rows.append((max(inv, 1), 0, label, ms, True))
            elif label in ("Execution", "Restart"):
                rows.append((max(inv, 1), it, label, ms, not timed_out))
                timed_out = False
            # 'Tot Execution and Restart' is a sum of the above: ignore it
    return rows


def collect(camp):
    runs = []
    for root, dirs, _ in os.walk(camp):
        meta_path = os.path.join(root, "meta.txt")
        if not os.path.exists(meta_path):
            continue
        meta = kv(meta_path)
        if not meta.get("platform"):
            continue
        meta["_dir"] = root
        meta["_rows"] = parse_log(os.path.join(root, "harness.log"))
        runs.append(meta)
    return runs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("camp")
    ap.add_argument("--boot", type=int, default=BOOTSTRAP_DEFAULT,
                    help="bootstrap resamples for the derived metrics' MAD")
    args = ap.parse_args()
    camp = args.camp

    runs = collect(camp)
    if not runs:
        raise SystemExit(f"no runs with meta.txt under {camp}")

    # ---- timings.csv: every sample, with the used flag --------------------
    # samples[(plat, ex, mode)][interval] = [ms, ...]   (used rows only)
    samples, warnings = {}, []
    with open(os.path.join(camp, "timings.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["platform", "example", "mode", "round", "dumped", "status",
                    "invocation", "iter", "interval", "ms", "cold", "valid",
                    "used"])
        for r in sorted(runs, key=lambda r: (r["platform"], r["example"],
                                             r["mode"], int(r["round"]))):
            plat, ex, mode = r["platform"], r["example"], r["mode"]
            dumped, status = r.get("dumped", ""), r.get("status", "")
            is_dump_run = (mode == "1" and dumped == "1")
            run_ok = (status == "OK")
            if not run_ok:
                warnings.append(f'{plat}/{ex} m{mode} r{r["round"]}: status={status}')
            seen_restart = set()
            n_invalid = 0
            for inv, it, label, ms, valid in r["_rows"]:
                # the first restore of an invocation reads a cold page cache
                cold = 1 if (label == "Restart" and inv not in seen_restart) else 0
                if label == "Restart":
                    seen_restart.add(inv)
                if not valid:
                    n_invalid += 1
                used = 1 if (run_ok and not is_dump_run and valid) else 0
                w.writerow([plat, ex, mode, r["round"], dumped, status,
                            inv, it, label, f"{ms:.3f}", cold, int(valid), used])
                if used:
                    samples.setdefault((plat, ex, mode), {}) \
                           .setdefault(label, []).append(ms)
            if n_invalid:
                warnings.append(
                    f'{plat}/{ex} m{mode} r{r["round"]}: {n_invalid} interval(s) '
                    f"followed a pipe timeout and measure TC_TIMEOUT_MS, not the "
                    f"workload -- excluded")
            n_exec = sum(1 for _, _, l, _, _ in r["_rows"] if l == "Execution")
            want = int(r.get("harness_iters", 0)) * int(r.get("repeats", 1) or 1)
            if want and n_exec != want:
                warnings.append(
                    f'{plat}/{ex} m{mode} r{r["round"]}: {n_exec} Execution '
                    f"samples, expected {want}")

    # ---- metrics.csv: median + MAD per cell, mode and interval ------------
    def put(d, plat, ex, mode, label, xs):
        d[(plat, ex, mode, label)] = xs

    rows_out = []
    for (plat, ex, mode), by_label in sorted(samples.items()):
        # Tstart as paid by re-execution: mode 0's Restart is kill + launch_vp
        # + run_init, i.e. exactly "re-run the initialization step".
        # Tstart_init is the same quantity measured at startup instead.
        init = by_label.get("launch_vp", []), by_label.get("run_init", [])
        derived_labels = dict(by_label)
        if init[0] and init[1] and len(init[0]) == len(init[1]):
            derived_labels["Tstart_init"] = [a + b for a, b in zip(*init)]
        for label, xs in sorted(derived_labels.items()):
            if not xs:
                continue
            m, d = median(xs), mad(xs)
            rows_out.append([plat, ex, mode, label, len(xs), f"{m:.3f}",
                             f"{d:.3f}", f"{d * MAD_TO_SIGMA:.3f}",
                             f"{min(xs):.3f}", f"{max(xs):.3f}"])

    with open(os.path.join(camp, "metrics.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["platform", "example", "mode", "metric", "n", "median",
                    "mad", "mad_scaled", "min", "max"])
        w.writerows(rows_out)

    # ---- derived.csv: the three paper metrics -----------------------------
    # startup_weight S = Tstart / (Tstart + Tbody)
    # restore_gain   R = Tstart / Trestore
    # speedup          = (Tstart + Tbody) / (Trestore + Tbody)
    # and the identity speedup = 1 / ((1 - S) + S/R), which must hold: only two
    # of the three are independent.  As R grows, speedup -> 1/(1 - S), so the
    # startup weight alone caps what any checkpointing scheme can reach.
    rng = random.Random(BOOTSTRAP_SEED)

    MODE_NAME = {"1": "CRIU", "2": "fork"}

    def series(plat, ex):
        """The raw sample lists a cell's metrics are built from.

        Tstart and the clean body come from mode 0, CRIU's restart from mode 1,
        and mode 2's Execution (body + fork) from mode 2."""
        ts = samples.get((plat, ex, "0"), {}).get("Restart", [])
        tb = samples.get((plat, ex, "0"), {}).get("Execution", [])
        tr1 = samples.get((plat, ex, "1"), {}).get("Restart", [])
        tb2 = samples.get((plat, ex, "2"), {}).get("Execution", [])
        return ts, tb, tr1, tb2

    def restore_cost(mode, tb, tr1, tb2):
        """What one restore costs under a checkpoint scheme.

        CRIU restarts the VP, so the harness times that interval directly.
        The fork happens VP-side and the harness' Restart is a no-op there, so
        fork's cost is what mode 2 adds to the body -- measured against mode 0,
        whose body carries no checkpointing at all, so a difference between
        CRIU's post-restore state and a cold start cannot leak into it."""
        if mode == "1":
            return median(tr1)
        Tb, Tb2 = median(tb), median(tb2)
        return None if None in (Tb, Tb2) else Tb2 - Tb

    def metrics_from(Ts, Tb, Tr):
        """The paper metrics from one scheme's three medians."""
        out = {}
        if Ts is not None:
            out["Ts"] = Ts
        if Tb is not None:
            out["Tb"] = Tb
        if Tr is not None:
            out["Tr"] = Tr
        if Ts is not None and Tb is not None and (Ts + Tb) > 0:
            out["S"] = Ts / (Ts + Tb)
        if Ts is not None and Tr not in (None, 0):
            out["R"] = Ts / Tr
        if None not in (Ts, Tb, Tr) and (Tr + Tb) > 0:
            out["speedup"] = (Ts + Tb) / (Tr + Tb)
        if "S" in out and "R" in out:
            S, R = out["S"], out["R"]
            denom = (1 - S) + S / R
            if denom > 0:
                out["speedup_pred"] = 1 / denom
            if S < 1:
                out["ceiling"] = 1 / (1 - S)
        return out

    def boot_mad(mode, ts, tb, tr1, tb2, key):
        """MAD of a metric over bootstrap resamples of the raw samples.

        A ratio of medians has no closed-form spread, and fork's restore cost
        is a difference of medians, so resample instead."""
        if not (ts and tb):
            return None
        src = tr1 if mode == "1" else tb2
        vals = []
        for _ in range(args.boot):
            rs = [rng.choice(ts) for _ in ts]
            rb = [rng.choice(tb) for _ in tb]
            rsrc = [rng.choice(src) for _ in src] if src else []
            Tr = restore_cost(mode, rb, rsrc, rsrc)
            v = metrics_from(median(rs), median(rb), Tr).get(key)
            if v is not None:
                vals.append(v)
        return mad(vals) if vals else None

    cells = sorted({(p, e) for (p, e, _m) in samples})
    with open(os.path.join(camp, "derived.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["platform", "example", "mode", "scheme",
                    "n_Tstart", "n_Tbody", "n_Trestore",
                    "Tstart_ms", "Tstart_mad", "Tstart_rel_mad",
                    "Tbody_ms", "Tbody_mad", "Tbody_rel_mad",
                    "Trestore_ms", "Trestore_mad", "Trestore_rel_mad",
                    "Tbody_mode_ms",
                    "startup_weight", "startup_weight_mad", "startup_weight_rel_mad",
                    "restore_gain", "restore_gain_mad", "restore_gain_rel_mad",
                    "speedup", "speedup_mad", "speedup_rel_mad",
                    "speedup_predicted", "speedup_ceiling"])
        for plat, ex in cells:
            ts, tb, tr1, tb2 = series(plat, ex)

            def fmt(x, nd=4):
                return "" if x is None else f"{x:.{nd}f}"

            print(f"{plat}/{ex}:")
            print(f"  Tstart   {fmt(median(ts), 1):>12} ms  MAD {fmt(mad(ts), 1)}  n={len(ts)}")
            print(f"  Tbody    {fmt(median(tb), 1):>12} ms  MAD {fmt(mad(tb), 1)}  n={len(tb)}")

            for mode in ("1", "2"):
                # the body as that mode measures it: after a CRIU restore, or
                # body plus fork
                tbm = samples.get((plat, ex, mode), {}).get("Execution", [])
                Tr = restore_cost(mode, tb, tr1, tb2)
                m = metrics_from(median(ts), median(tb), Tr)
                n_tr = len(tr1) if mode == "1" else len(tb2)
                # every spread here is the uncertainty of the estimate, from
                # the same bootstrap, so restore_gain_mad can be checked
                # against Trestore_mad by propagation.  The dispersion of the
                # raw samples is in metrics.csv.
                def unc(key):
                    return boot_mad(mode, ts, tb, tr1, tb2, key)

                def rel(key, value):
                    """The same spread as a fraction of what it qualifies, so
                    quantities of different magnitude can be compared."""
                    u = unc(key)
                    return None if (u is None or not value) else u / value

                w.writerow([plat, ex, mode, MODE_NAME[mode],
                            len(ts), len(tb), n_tr,
                            fmt(median(ts), 3), fmt(unc("Ts"), 3),
                            fmt(rel("Ts", median(ts))),
                            fmt(median(tb), 3), fmt(unc("Tb"), 3),
                            fmt(rel("Tb", median(tb))),
                            fmt(Tr, 3), fmt(unc("Tr"), 3), fmt(rel("Tr", Tr)),
                            fmt(median(tbm), 3),
                            fmt(m.get("S")), fmt(unc("S")),
                            fmt(rel("S", m.get("S"))),
                            fmt(m.get("R")), fmt(unc("R")),
                            fmt(rel("R", m.get("R"))),
                            fmt(m.get("speedup")), fmt(unc("speedup")),
                            fmt(rel("speedup", m.get("speedup"))),
                            fmt(m.get("speedup_pred")), fmt(m.get("ceiling"))])

                print(f"  [{MODE_NAME[mode]:>4}] Trestore {fmt(Tr, 1):>10} ms  "
                      f"MAD {fmt(unc('Tr'), 1)}  n={n_tr}")
                print(f"         startup weight {fmt(m.get('S'))}   "
                      f"restore gain {fmt(m.get('R'), 2)}   "
                      f"speedup {fmt(m.get('speedup'), 2)}"
                      f"  (ceiling {fmt(m.get('ceiling'), 2)})")

                sp, pred = m.get("speedup"), m.get("speedup_pred")
                if sp and pred and abs(sp - pred) / sp > 0.01:
                    warnings.append(f"{plat}/{ex} {MODE_NAME[mode]}: speedup "
                                    f"{sp:.3f} != predicted {pred:.3f} -- check "
                                    f"the attribution")

            # post-restore state should be equivalent to post-init state
            tb1 = median(samples.get((plat, ex, "1"), {}).get("Execution", []))
            if tb1 is not None and median(tb) is not None and median(tb) > 0:
                rel = abs(tb1 - median(tb)) / median(tb)
                if rel > 0.10:
                    warnings.append(
                        f"{plat}/{ex}: Tbody differs {rel:.0%} between mode 0 "
                        f"({median(tb):.1f} ms) and mode 1 ({tb1:.1f} ms) -- the "
                        f"decomposition may be leaking")

    print(f"\nwrote timings.csv, metrics.csv, derived.csv in {camp}")
    if warnings:
        print(f"\n{len(warnings)} warning(s):")
        for x in warnings:
            print("  ! " + x)


if __name__ == "__main__":
    main()
