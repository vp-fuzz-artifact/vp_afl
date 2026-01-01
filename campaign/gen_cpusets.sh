#!/usr/bin/env bash
# Print the WORKER_CPUSETS line for campaign.conf.  Run it ON the campaign
# machine.  Reads the CPU topology only, changes nothing, installs nothing.
#
#   ./gen_cpusets.sh [workers] [physical cores per worker]
#   ./gen_cpusets.sh 12 2
#
# Each worker gets whole physical cores (both SMT threads), taken from the same
# L3 cache where possible, and no physical core is given to two workers.
set -euo pipefail
W="${1:-12}"; K="${2:-2}"
lscpu -p=CPU,CORE,CACHE | python3 -c '
import sys, collections
W, K = int(sys.argv[1]), int(sys.argv[2])
core_cpus, core_l3 = collections.OrderedDict(), {}
for line in sys.stdin:
    if line.startswith("#") or not line.strip():
        continue
    cpu, core, cache = line.strip().split(",")[:3]
    core_cpus.setdefault(core, []).append(cpu)
    core_l3[core] = cache.split(":")[-1]          # last level = L3
by_l3 = collections.OrderedDict()
for core, l3 in core_l3.items():
    by_l3.setdefault(l3, []).append(core)
pool = [c for l3 in by_l3 for c in by_l3[l3]]     # grouped by L3, so a worker
                                                  # stays inside one cache
need = W * K
if need > len(pool):
    sys.exit(f"need {need} physical cores, machine has {len(pool)}")
sets = []
for w in range(W):
    cores = pool[w * K:(w + 1) * K]
    cpus = sorted((int(c) for core in cores for c in core_cpus[core]))
    sets.append(",".join(str(c) for c in cpus))
print("WORKERS=%d" % W)
print("WORKER_CPUSETS=(" + " ".join(f"\"{s}\"" for s in sets) + ")")
print("# %d of %d physical cores used, %d left for the OS"
      % (need, len(pool), len(pool) - need), file=sys.stderr)
' "$W" "$K"
