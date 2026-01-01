# Fuzzing campaign

9 targets (3 examples x baremetal/Linux/zephyr) x 3 checkpoint modes x 5 rounds
= 135 runs, executed by several containers in parallel.

## Run

```bash
./gen_cpusets.sh 12 2                 # on the campaign machine: pin 12 workers
                                      # to 2 physical cores each -> campaign.conf
./run_campaign.sh --dry-run           # schedule + one podman command, runs nothing
./run_campaign.sh --smoke --only-cell zephyr:crypto   # one target, ~3 min
sudo -E ./run_campaign.sh --smoke     # short run of all 27 combinations
sudo -E ./run_campaign.sh             # the campaign; re-run it to resume
python3 metrics.py  <results>/campaign
python3 plot_coverage.py <results>/campaign            # edges over time
python3 plot_coverage.py <results>/campaign --x execs  # edges over executions
```

`sudo -E` is needed because CRIU (mode 1) falls back to mode 0 without root.
Nothing is installed and no machine setting is changed; AFL's usual complaints
are silenced by `AFL_SKIP_CPUFREQ` / `AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES`,
which the settings.bash exports.

Paths follow the checkout (`BENCH_ROOT` next to it, results in
`<repo>/campaign_results`); both can be overridden from the environment:

```bash
BENCH_ROOT=/data/vp_sw_benchmark/cortex-A72 RESULTS_ROOT=/data/results \
    ./run_campaign.sh
```

## Design

* **Order** — each round runs all 27 combinations once, in a random order that
  is rejection-sampled so no mode is systematically early. `ORDER_SEED` makes it
  reproducible; the result is in `schedule.tsv`. A campaign directory that
  already has a `schedule.tsv` keeps it — that is what makes a resume exact, so
  a changed seed setting only takes effect in a fresh campaign directory.
* **AFL seed** — one seed per round, shared by the 27 runs of that round:
  `AFL_SEED_BASE + round - 1`, so 42, 43, 44, 45, 46. Inside a round the three
  modes of a target mutate identically, so a difference between two modes is
  not seed luck; across rounds the streams differ, so the spread over the 5
  rounds of a cell is a trial-to-trial spread rather than the nondeterminism of
  one mutation stream, and the rounds can be compared pairwise by seed.
  `AFL_SEED_PER_ROUND=0` pins every round to `AFL_SEED_BASE` (how the campaign
  ran before). `-s` is passed either way: a fixed seed also pins `havoc_div`,
  which AFL otherwise derives from exec speed — the faster checkpoint mode
  would get a different mutation budget per input. The seed of a run is in
  `schedule.tsv`, in its `meta.txt` and in `runs.csv`.
* **Stop** — a run ends when AFL finds no new coverage for `NOFIND_<platform>`
  seconds (30 min baremetal/zephyr, 1 h Linux), or after `MAX_SECONDS` (12 h;
  `MAX_SECONDS_<platform>` overrides it for one platform).
* **CRIU** — one image directory per target, `checkpoints/<platform>_<example>`.
  The first mode-1 run of a target dumps (`TC_DUMP=1`) and stores a stamp
  (sha256 of the .cfg + container image id); later rounds restore (`TC_DUMP=0`)
  only if the stamp still matches. The rounds of one target are serialised on a
  lock file so two containers never share an image directory; a worker that
  finds the lock taken moves on and comes back later. `dumped=` in `meta.txt`
  says which round paid the dump.
* **Isolation** — AFL writes into the campaign directory, and each run has its own directory.

## Output

```
<results>/campaign/
  schedule.tsv  campaign_info.txt
  round01/<platform>_<example>_mode<m>/
      meta.txt  afl.log  harness.log  afl/default/{fuzzer_stats,plot_data,queue,crashes}
  runs.csv                 one line per run
  cells.csv                mean / sd / min / max over the 5 rounds
  coverage_over_time.csv   edges (and execs, crashes) over time, every run
  plots/edges_<platform>_<example>_time.pdf
```

`runs.csv`: round, platform, example, mode, dumped, afl_seed, status,
run_time_s, execs_done, execs_per_sec, stability_pct, edges_found, crashes,
first_crash_s, first_crash_execs.

`cells.csv` adds, per target and mode, the spread over the rounds. With a seed
per round that spread is the trial-to-trial variation of the cell, so compare
two modes by their means and sds over the 5 rounds, not by a single round. An
`sd` of 0 means five different mutation
streams reached the same number, which for `edges_mean` usually says the target
is saturated rather than that the modes agree.
