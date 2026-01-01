#!/usr/bin/env python3
"""Edges over time: one figure per (platform, example), one line per mode.

usage: plot_coverage.py <campaign_dir> [--x execs]

Each line is the mean over the rounds, the band is min..max over the rounds.
plot_data is event based (AFL writes a row only when something changed, and
nothing during the first minute), so every run is resampled onto a common grid
as a step function - coverage is monotone, so holding the last value is exact.
"""
import argparse
import csv
import os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

COLORS = {"0": "#4477aa", "1": "#ee6677", "2": "#228833"}
LABELS = {"0": "mode 0 (no checkpoint)", "1": "mode 1 (CRIU)", "2": "mode 2 (fork)"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("campaign_dir")
    ap.add_argument("--x", choices=["time", "execs"], default="time",
                    help="x axis: wall clock (default) or executions")
    a = ap.parse_args()

    src = os.path.join(a.campaign_dir, "coverage_over_time.csv")
    runs = {}
    with open(src) as fh:
        for r in csv.DictReader(fh):
            key = (r["platform"], r["example"], r["mode"])
            runs.setdefault(key, {}).setdefault(r["round"], []).append(
                (float(r["time_s"]), float(r["execs"]), float(r["edges"])))

    outdir = os.path.join(a.campaign_dir, "plots")
    os.makedirs(outdir, exist_ok=True)
    targets = sorted({(p, e) for (p, e, _) in runs})

    for plat, ex in targets:
        fig, ax = plt.subplots(figsize=(6, 3.6))
        for mode in ("0", "1", "2"):
            rounds = runs.get((plat, ex, mode))
            if not rounds:
                continue
            series = []
            for rows in rounds.values():
                rows.sort()
                x = np.array([r[0] if a.x == "time" else r[1] for r in rows])
                y = np.array([r[2] for r in rows])
                if len(x) > 1:
                    series.append((x, y))
            if not series:
                continue
            xmax = min(x.max() for x, _ in series)      # compare only where all rounds ran
            grid = np.linspace(0, xmax, 400)
            # step interpolation: coverage holds its last value
            resampled = np.array([y[np.clip(np.searchsorted(x, grid, "right") - 1, 0, None)]
                                  for x, y in series])
            ax.plot(grid, resampled.mean(axis=0), color=COLORS[mode], lw=1.6,
                    label=f"{LABELS[mode]} (n={len(series)})")
            ax.fill_between(grid, resampled.min(axis=0), resampled.max(axis=0),
                            color=COLORS[mode], alpha=0.18, lw=0)
        ax.set_xlabel("time [s]" if a.x == "time" else "executions")
        ax.set_ylabel("edges found")
        ax.set_title(f"{plat} / {ex}")
        ax.grid(alpha=0.3)
        ax.legend(fontsize=8)
        fig.tight_layout()
        out = os.path.join(outdir, f"edges_{plat}_{ex}_{a.x}.pdf")
        fig.savefig(out)
        fig.savefig(out.replace(".pdf", ".png"), dpi=150)
        plt.close(fig)
        print("wrote", out)


if __name__ == "__main__":
    main()
