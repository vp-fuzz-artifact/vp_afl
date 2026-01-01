#!/usr/bin/env python3
"""Build a reproducible, order-counterbalanced run schedule.

Randomised complete block design:
  * one "round" = every (cell, mode) exactly once  -> 9 cells x 3 modes = 27 runs
  * the order inside a round is a random permutation (seeded -> reproducible)
  * rejection sampling enforces that no mode is systematically early:
      - the first run of a round uses a different mode than the first run of
        every earlier round (as long as rounds <= number of modes * k)
      - each mode's mean position inside the round stays within +-POS_TOL of
        the round's mean position
  * the AFL seed is per round, not per run: all runs of round r use
    afl_seed_base + (r - 1), so the modes of a target are compared on one
    mutation stream while the rounds remain independent trials
Prints TSV: round  idx  platform  example  mode  afl_seed  tag
"""
import argparse
import random
import statistics
import sys

POS_TOL = 3.0
MAX_TRIES = 20000


def round_ok(order, first_modes, n):
    if order[0][2] in first_modes:
        return False
    mid = (n - 1) / 2.0
    by_mode = {}
    for pos, (_, _, mode) in enumerate(order):
        by_mode.setdefault(mode, []).append(pos)
    return all(abs(statistics.mean(v) - mid) <= POS_TOL for v in by_mode.values())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cell", action="append", required=True,
                    help="platform:example, repeatable")
    ap.add_argument("--mode", action="append", required=True, help="repeatable")
    ap.add_argument("--rounds", type=int, required=True)
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--afl-seed-base", type=int, required=True,
                    help="AFL -s seed of round 1")
    ap.add_argument("--afl-seed-per-round", type=int, choices=(0, 1), default=1,
                    help="1 (default): round r uses base + r - 1; "
                         "0: every round uses base")
    args = ap.parse_args()

    pairs = [(c.split(":")[0], c.split(":")[1], m)
             for c in args.cell for m in args.mode]
    n = len(pairs)

    print("# round\tidx\tplatform\texample\tmode\tafl_seed\ttag")
    first_modes = set()
    for r in range(1, args.rounds + 1):
        rng = random.Random((args.seed, r).__hash__() ^ args.seed ^ r)
        order = None
        for _ in range(MAX_TRIES):
            cand = pairs[:]
            rng.shuffle(cand)
            if round_ok(cand, first_modes, n):
                order = cand
                break
        if order is None:                       # constraint unsatisfiable
            order = pairs[:]
            rng.shuffle(order)
        first_modes.add(order[0][2])
        if len(first_modes) == len(args.mode):
            first_modes = set()                 # start a new rotation cycle
        seed = args.afl_seed_base + (r - 1 if args.afl_seed_per_round else 0)
        for i, (plat, ex, mode) in enumerate(order, start=1):
            tag = f"r{r:02d}_{plat}_{ex}_m{mode}"
            print(f"{r}\t{i}\t{plat}\t{ex}\t{mode}\t{seed}\t{tag}")


if __name__ == "__main__":
    main()
