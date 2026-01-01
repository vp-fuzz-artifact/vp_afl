#!/usr/bin/env python3
"""Build a reproducible run order for the timing campaign.

One "round" = every (cell, mode) exactly once; the order inside a round is a
seeded random permutation, so the schedule can be reproduced or resumed.

Unlike the fuzzing campaign there is no counterbalancing constraint: we measure
per-operation latency, not coverage over time, so a mode being early in a round
does not bias its result.  The one ordering rule that does matter -- CRIU must
dump before it can restore -- is enforced by the driver, not here, because it
depends on whether an image already exists on disk.

Prints TSV: round  idx  platform  example  mode  tag
"""
import argparse
import random


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cell", action="append", required=True,
                    help="platform:example, repeatable")
    ap.add_argument("--mode", action="append", required=True, help="repeatable")
    ap.add_argument("--rounds", type=int, required=True)
    ap.add_argument("--seed", type=int, required=True)
    args = ap.parse_args()

    pairs = [(c.split(":")[0], c.split(":")[1], m)
             for c in args.cell for m in args.mode]

    print("# round\tidx\tplatform\texample\tmode\ttag")
    for r in range(1, args.rounds + 1):
        rng = random.Random(args.seed ^ (r * 0x9E3779B1))
        order = pairs[:]
        rng.shuffle(order)
        for i, (plat, ex, mode) in enumerate(order, start=1):
            print(f"{r}\t{i}\t{plat}\t{ex}\t{mode}\tr{r:02d}_{plat}_{ex}_m{mode}")


if __name__ == "__main__":
    main()
