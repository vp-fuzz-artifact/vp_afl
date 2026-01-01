# Timing campaign

Measures the three cost components the paper metrics are built from, per
target and per checkpoint mode:

| term       | what it is                                  | measured by |
|------------|---------------------------------------------|-------------|
| `Tstart`   | setup: launch the VP + run the init code    | mode 0 `Restart` (kill + `launch_vp` + `run_init`) |
| `Tbody`    | the workload itself, one execution          | `Execution`, every mode |
| `Trestore` | bringing the system back without re-running init | mode 1 `Restart` (CRIU restore) |

and derives

```
startup weight  S = Tstart / (Tstart + Tbody)
restore gain    R = Tstart / Trestore
speedup           = (Tstart + Tbody) / (Trestore + Tbody) = 1 / ((1 - S) + S/R)
```

Only two of the three are independent — the identity above is checked on every
run, and a mismatch means the attribution is wrong. As `R` grows the speedup
tends to `1/(1 - S)`, so **the startup weight alone caps what any checkpointing
scheme can reach** on that target. `derived.csv` reports that ceiling.

Every statistic is a **median with MAD**, never a mean: boot and restore times
are right-skewed and one cold outlier moves a mean. `mad_scaled` is
`1.4826 * MAD` for readers who want a sigma-comparable spread.

## Prerequisites

The timing image only swaps in the DEBUG=1 harness, so it derives
(`Dockerfile.timing`) from the fuzzing image rather than repeating its VP, AFL
and CRIU builds. That base, `localhost/vp-afl`, is built locally by
`scripts/docker_build.sh` and is never published, so on a fresh checkout it
does not exist and cannot be pulled.

`container_build.sh` handles both cases:

```bash
./container_build.sh              # builds the base image if missing, then the
                               # timing image, then verifies the DEBUG build
./container_build.sh --skip-base  # fail with instructions instead of building it
./container_build.sh --rebuild    # rebuild the timing image
```

Building the base clones the submodules and compiles the VP, AFL and CRIU —
tens of minutes — so the script says so before it starts. If your base is
tagged differently, pass `BASE_IMAGE=localhost/vp-afl:mytag`.

### Rootless build, rootful run

podman keeps a **separate image store per user**, so an image built rootless
(`~/.local/share/containers`) is invisible to root (`/var/lib/containers`). Mode
1 needs root, so `sudo -E ./run_timing.sh` after a rootless build would
otherwise report the image as missing.

`podman_store.sh` handles it the way `scripts/docker_run.sh` does: when running
as root, it checks the invoking user's store and streams the image across with
`podman save | podman load`. Both `run_timing.sh` and `container_build.sh` use
it, so `sudo -E ./run_timing.sh` and `sudo ./container_build.sh` copy the image
instead of failing or rebuilding. `save`/`load` preserves the image Id, so a
CRIU stamp taken under one store still matches under the other.

A `--dry-run` deliberately does *not* import — it launches nothing, so it only
notes that the image is absent rather than moving gigabytes. docker needs none
of this: one daemon, one store.

The last step is a check worth having: a non-DEBUG harness takes the AFL path
and would record no intervals at all, so the script runs the binary once and
confirms it logs `Run manual.`, which only the DEBUG build does. `run_timing.sh`
catches the same thing per run as status `NOT_DEBUG_BUILD`.

## Run

```bash
./container_build.sh                                       # see Prerequisites
./run_timing.sh --dry-run                               # schedule + one command
./run_timing.sh --only-cell baremetal:zlib_baremetal --rounds 1 --only-mode 0
sudo -E ./run_timing.sh                                 # the campaign
sudo -E ./run_timing.sh --workers 4                     # see "Parallelism"
python3 timing_metrics.py <results>/timing
```

`sudo -E` is required for mode 1: without root `settings.bash` silently falls
back to mode 0, and `in_container_timing.sh` fails the run rather than
recording a mislabelled measurement.

Interrupted? Run it again — finished runs (those with `meta.txt`) are skipped.

`--dry-run` is side-effect free: it writes `schedule.tsv` and prints the podman
commands, and creates no claims, no round directories and no `timing_info.txt`.
That matters because a claim is what makes a run unreachable — a dry run that
claimed every row would leave the campaign unable to execute any of it.

Without root, mode-1 rows are passed over **unclaimed**, so a later
`sudo -E ./run_timing.sh` still picks them up; only modes 0 and 2 run.

## What a run does

One scheduled run = one container = one invocation of the DEBUG harness =
**1 `Tstart` + 10 `Tbody` + 9 `Trestore` samples** (the harness does 10
iterations, hardcoded at `harness.cpp:292`; the restart is skipped after the
last one). Repetition comes from `ROUNDS`, so 5 rounds gives 50 `Tbody` and 45
`Trestore` samples per cell and mode.

The input is **one fixed file per cell** (`TIMING_INPUT`, default
`seeds/seed_0`): we are measuring checkpointing, not input sensitivity, so
`Tbody` has to be the same workload in every mode. Its size and sha256 are
printed into `run.log` for the record.

## CRIU: dump first, then restore

Mode 1 needs an image before it can restore, so:

* the **dump** happens in round 1 (`dumped=1` in `meta.txt`), after which a
  stamp (sha256 of the `.cfg` + the container image id) is written next to the
  image;
* rounds 2..N **restore** (`dumped=0`) only if that stamp still matches;
* a mode-1 run in a later round that finds no image **defers** — it releases
  its claim and comes back — until round 1 has produced one. If round 1
  finishes without leaving an image, the deferral stops and the run dumps
  itself, so the campaign cannot spin forever;
* mode-1 runs of one cell are serialised on a lock file, because they share a
  single image directory.

`timing_metrics.py` **excludes the dump run from every median** (it pays for
creating the image, which is not what a restore costs). It stays in
`timings.csv` with `used=0` so nothing is silently dropped. The first restore
of each invocation reads a cold page cache and is flagged `cold=1` — kept in
the medians, filterable if you want warm-only numbers.

## Parallelism

`WORKERS`, the claim directory, the per-cell CRIU lock and `WORKER_CPUSETS`
work exactly as in the fuzzing campaign, and the driver is a near-copy of
`campaign/run_campaign.sh`.

One caveat worth stating plainly: the fuzzing campaign measures **throughput
over hours**, where parallelism costs a little exec/s per worker and buys a lot
of wall-clock. This campaign measures **per-operation latency**, where a
co-tenant run inflates the very intervals being reported. So:

* **never** run this while the fuzzing campaign is running;
* with `WORKERS > 1`, pin them (`../campaign/gen_cpusets.sh <workers> 2` →
  `WORKER_CPUSETS` in `timing.conf`), or `Trestore` will carry the scheduler's
  noise;
* `meta.txt` records `cpuset` and `workers`, and `timing_info.txt` records
  `nproc` and the load average at start, so the conditions are auditable
  afterwards.

The work is bounded (10 iterations, not a 12 h fuzz run), so serial is
affordable: it is minutes to a couple of hours per cell, not days.

## Output

```
<results>/timing/
  schedule.tsv  timing_info.txt
  round01/<platform>_<example>_mode<m>/
      meta.txt      tag, round, mode, dumped, status, intervals, cpuset, ...
      harness.log   the timestamped intervals (TC_LOGGING=1)
      run.log       container stdout: input sha256/size, shm ids, exit code
  timings.csv   every sample: ... interval, ms, cold, used
  metrics.csv   per cell+mode+interval: n, median, mad, mad_scaled, min, max
  derived.csv   per cell: Tstart/Tbody/Trestore + S, R, speedup (bootstrap MAD)
```

A ratio of medians has no closed-form spread, so the MAD of `S`, `R` and the
speedup comes from a seeded bootstrap (`--boot`, default 2000) over the raw
samples.

### Statuses

`OK`, `NO_TIMINGS` (ran but logged no interval), `NOT_DEBUG_BUILD` (the image
is a non-DEBUG harness, so it ran the AFL path), `SETUP_FAILED` (exit 97),
`TIMEOUT_KILLED`, `PODMAN_FAILED`, `NO_CHECKPOINT` (dump run left no
`criu.log`). Only `OK` runs enter the medians.

## Notes and open items

* **Container working directory.** `settings.bash` waits for the CRIU service
  socket at `$PRJ_ROOT_DIR/criu_service.socket`, but `startcriusocket.sh`
  creates it in `$(pwd)`. This campaign uses `-w /app` (`CONTAINER_WORKDIR`) so
  the two agree. The fuzzing campaign uses `-w /app/vp_mode/aflplusplus`, where
  the socket lands somewhere the 20 s wait loop never looks — worth checking
  against the mode-1 failures seen there.
* **Logging overhead is not a concern.** Only ~3 `INFO` messages fall inside an
  `Execution` window and ~6–8 inside a `Restart`; each is a `vsnprintf` plus one
  flushed write, so tens of microseconds against intervals of 10²–10⁴ ms.
  `printElapsed` also reads the clock *before* it logs, so the log line is
  outside its own interval. `TC_VP_LOGGING` is forced to 0 — that one *is* in
  the simulation hot path.
