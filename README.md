# Binary Fuzzing with a Virtual Platform (VP Mode)

This folder contains the vp-mode, another [binary-only](https://aflplus.plus/docs/binaryonly_fuzzing/) mode of AFL++. This mode allows to fuzz target software inside a Virtual Platform (VP). 

This README explains how to get started with this project.
Check:
- [Quick Start](#quick-start) to quickly get it running, 
- [Build the project](#build-the-project) and [Start Fuzzing](#start-fuzzing) for a comprehensive guide to build and run it, 
- [Checkpointing Options](#checkpointing-options) to choose the checkpoint strategy.

The current supported VPs are:
- [AVP64](https://github.com/aut0/avp64) (SystemC based ARMv8 64bit Virtual Platform)

## Quick Start
*Prerequisites*: podman or docker ([docker_build.sh](scripts/docker_build.sh) picks the one it can find)

1. Clone the project *without* `--recursive`
1. Build the container with [docker_build.sh](scripts/docker_build.sh)
1. Run with `./scripts/docker_run.sh <path to the benchmark folder> <benchmark name>` <br />
   For example, to run an example target, run `./scripts/docker_run.sh ./vp_mode/example_target arch_pro`

## Repo Organization
| Directory | Description |
| --------- | ----------- |
| [campaign](campaign) | Scripts to run a full fuzzing campaign | 
| [scripts](scripts) | Scripts to build the project and run a single benchmark  | 
| [timing_campaign](timing_campaign) | Scripts to run timing-accurate campaigns  |
| [aflplusplus](vp_mode/aflplusplus) | AFL++ fuzzer repository | 
| [avp64](vp_mode/avp64) | ARM simulator | 
| [example_target](vp_mode/example_target) | Folder with example benchmark |
| [harness](vp_mode/harness) | Interface between AFL++ and simulator | 
| [vcml](vp_mode/vcml) | SystemC-TLM modeling library | 
| [patches](vp_mode/patches) | Fuzzer and VCML patch files | 
| [vp-testing-interface](vp_mode/vp-testing-interface) | Fuzzer-harness communication protocol | 

## Build the project

1. Clone the project *without* `--recursive` (avoid including AFL submodules!)

1. Build the project

   **With** container support:
   ```bash
   cd ~/vp_afl
   ./scripts/docker_build.sh
   ```

   **Without** container support:

   *Note* due to the long list of requirements and dependencies, it is highly encouraged to use the container support.
   Additionally, this project was only tested on Ubuntu 22.04.
   ```bash
   cd ~/vp_afl
   ./scripts/local_build.sh
   ```

   Both will:
   - Initialize the submodules
   - Fetch the dependencies (e.g., QEMU's and SystemC specific versions)
   - Apply the patches to AFL and VCML
   - Build the harness, avp64 simulator, AFL++ fuzzer and the dependencies

## Basics on how to customize your setup

To fuzz a custom application using the AVP64 simulator, you can configure the fuzzing setup (set the RNG seed, the timeout, the checkpointing strategy) 
and the simulator's properties.

> ℹ️ TL;DR 
See [example_target](vp_mode/example_target) for an example of how to setup the software repository. 
This repository contains:
- [run_fuzzer.bash](vp_mode/example_target/run_fuzzer.bash) and [settings.bash](vp_mode/example_target/settings.bash) files
- the `arch_pro` target software compiled for avp64 (under [build](vp_mode/example_target/arch_pro/build))
- the [seed directory](vp_mode/example_target/arch_pro/seeds)
- the simulator [.cfg](vp_mode/example_target/arch_pro/arch_pro.cfg) file and [mmio_config.json](vp_mode/example_target/arch_pro/mmio_config.json)

### VP configuration

The VP's configuration file allows you to modify some properties about the VP without the need to recompile the project. [This](vp_mode/example_target/arch_pro/arch_pro.cfg) is an example of a configuration file. 
In the table below, we report some useful properties that can be set in the file:

| Property | Options | Description |
| --------- | --------- | ----------- |
| `system.cpu.gdb_wait` | `true`, `false` | When set to true, the VP waits for a gdb connection on the specified port. |
| `system.cpu.gdb_port` | 1–65535 | The gdb port number. |
| `system.cpu.symbols` | - | Path to the SW sample .elf file. |
| `system.ram.images` | - | Path to the SW sample .bin file. |
| `system.ram.size` | 64 KiB - 16 GiB | Size of the RAM. |
| `system.addr_ram` | - | RAM Physical address. |
| `system.addr_uart0` | - | UART Physical address. |
| `system.term0.backends` | `tui`, `file`, `tcp:<tcp port>`, `null` | The terminal backend. When `file` is selected, the data to be sent must be available in a file named *system.term.rx*. The UART sends the data to the *system.term.tx* file. |
| `system.duration` |  Integer values with suffixes s, ms, us or ns | simulation duration. Simulation will stop automatically once this time-stamp is reached. If you want to simulate infinitely, do not use this in the file. |

*Note:*
The `simulation duration` is not the real-world (wall-clock) time. It represent the virtual, simulation time.

Additionally, the [mmio_config.json](vp_mode/example_target/arch_pro/mmio_config.json) file is required to run the simulator.
It defines what registers the VP's mmio probe should track and what action should be associated to it.
When the probe intercepts the address specified in the json, it looks for an action to perform. We currently support 3 actions:
1. *start_injection*: the probe spawns an sc thread using `sc_spawn()` which will read fuzzing data and send them to the corresponding peripheral at a predefined interval
2. *notify_sim_end*: this is used to detect when the simulation ends. It is usually associated to the simdev peripheral, which is usually accessed by the running software at the end of the main routine. The same result can also be achieved by setting a breakpoint to a symbol (you ca do it by specifying a string for `TC_START_SYMBOL`).
3. *notify_init_end*: this detects the end of the software booting or initialization routine. The detection of this access starts the checkpointing routine. The same result can also be achieved by setting a breakpoint to a symbol (you can do it by specifying a string for `TC_END_SYMBOL`).

### Fuzzing's setup

Two files are responsible for the fuzzing setup [settings.bash](vp_mode/example_target/settings.bash) and [run_fuzzer.bash](vp_mode/example_target/run_fuzzer.bash):
Both have list of configurable environmental variables that can be set when starting the fuzzing campaign.
[settings.bash](vp_mode/example_target/settings.bash) configures fuzzing-related simulator properties.

| ENV Variable               | Default       | Description |
|----------------------------|----------------|-------------|
| `TC_LOGGING`               | 0           | Harness logging level: `0 = off` (default), `1 = verbose`, `2 = errors only`. |
| `TC_LOGGING_PATH`          | `vp_afl/logs/tc_out.txt`       | Path to harness log file. |
| `TC_VP_LOGGING`            | 0       | VP logging level: `0 = off` (default), `1 = verbose`, `2 = errors only`, `3 = verbose (Console)`. |
| `TC_VP_LOGGING_PATH`       | `vp_afl/logs/vp_out.txt`       | Path to VP log file. |
| `TC_CHKPT_MODE`            | 0       | Checkpointing mode: `0 = No checkpointing`, `1 = CRIU mode`, `2 = Fork mode`, `3 = Hybrid`. |
| `TC_DUMP`                  | 1       | CRIU checkpointing: `0 = Read from stable checkpoint and restore only`, `1 = Dump`. |
| `TC_START_SYMBOL`          | Unset       | Symbol marking the start of the fuzzed region. |
| `TC_END_SYMBOL`            | Unset       | Symbol marking the end of the fuzzed region. Value in `TC_RETURN_REGISTER` is read here. |
| `TC_ERROR_SYMBOL`          | Unset       | If reached, execution aborts with return code 1. Useful for exception handlers. |
| `TC_TIMEOUT_MS`            | 5sec       | Simulator maximum execution time. |

[run_fuzzer.bash](vp_mode/example_target/run_fuzzer.bash) configures AFL++ properties, such as the RNG seed (default=42) used by the mutation engine or the AFL++ timeout. If the fuzzer does not get a reply from the harness in the specified time (default=20sec), it kills the process. This script is also responsible for starting the fuzzing.

## Run, Checkpoint and Debug the Simulator

This section explains how to run the project, enable the simulator checkpoint and debug it.

### Start Fuzzing

The default configuration runs without any checkpointing. To run with checkpointing, check the [checkpoint section](#checkpointing-options) of this README.

**With** container support:
```bash
cd ~/vp_afl
# With this command, we are running the example source code
./scripts/docker_run.sh ./vp_mode/example_target arch_pro
```
You can pass any configuration option overwriting the default value of the corresponding environmental variable:
```bash
# This will set the RNG seed used by the fuzzer's mutation engine and enables the logging of the simulator
FUZZING_SEED=100 TC_VP_LOGGING=1 ./scripts/docker_run.sh ./vp_mode/example_target arch_pro
```

**Without** container support
```bash
cd ~/vp_afl
# Set the needed envs
source ./scripts/env.sh
# For the default configuration
./vp_mode/example_target/run_fuzzer.bash arch_pro

# This will set the RNG seed used by the fuzzer's mutation engine and enables the logging of the simulator
FUZZING_SEED=100 TC_VP_LOGGING=1 ./vp_mode/example_target/run_fuzzer.bash arch_pro
```
If you run the fuzzing with `sudo`, add `-E` flag to preserve your environment:
```bash
source ./scripts/env.sh
sudo -E TC_CHKPT_MODE=1 TC_DUMP=1 ./vp_mode/example_target/run_fuzzer.bash arch_pro
```

To start a fuzzing campaign of multiple rounds where all the checkpointing configurations are exercised and useful metrics, such as speed, coverage and number o crashes are measured, please refer to the corresponding campaigns READMEs: [timing campaign](timing_campaign/README.md) and [fuzzing campaign](campaign/README.md). You can refer to the [benchmark repo](https://github.com/vp-fuzz-artifact/vp_sw_benchmarks) to run more example programs.

### Checkpointing Options

Currently you have following options for checkpointing: Checkpoint/Restore in Userspace (CRIU), Forking and Hybrid.

- CRIU is a library that saves the state of a running process to disk. This saved image can then be used to restore the checkpointed process and run it from the saved point. CRIU has the limitation of requiring root privileges.
- Fork is the Linux mechanism that allows the duplication of a process. It creates a child process that is an exact replica of the original process. It is faster than CRIU but it can only duplicate one single thread of the process (the one that calls `fork()`)
- The hybrid approach was implemented to benefit from the persistent storage of CRIU and the speed of fork. It dumps the process with CRIU, saving the process state for future runs, and it iterates with fork. This configuration has the benefits and the disadvantages of both solutions.

You can switch between the modes by selecting the correct value of  the `TC_CHKPT_MODE` environmental variable.
*Note* When CRIU is selected, the fuzzing must be started with `sudo`, otherwise the framework will disable checkpointing and switch to the non-checkpointing mode.

```bash
cd ~/vp_afl
# For the default, non-checkpointed configuration
./scripts/docker_run.sh ./vp_mode/example_target arch_pro

# to run it with CRIU: use sudo and choose restore instead of dump to restore an existing image
sudo ./scripts/docker_run.sh ./vp_mode/example_target arch_pro 1 dump

# to run it with fork
./scripts/docker_run.sh ./vp_mode/example_target arch_pro 2
```

### Debugging

This section is dedicated to run the project in debug mode.
This usually means running without the fuzzer involved.

To achieve this, rebuild in debug mode:

```bash
cd ~/vp_afl
BUILD_TYPE=Debug DEBUG=1 make all
```
To debug the simulator code itself, run it with gdb. To do it, you can use the [gdb_vp.sh](vp_mode/example_target/gdb_vp.sh):
```bash
# For arch_pro, this would look like:
./vp_mode/example_target/gdb_vp.sh arch_pro

# To enable other options, pass them as envs
sudo TC_CHKPT_MODE=1 TC_DUMP=1 ./vp_mode/example_target/gdb_vp.sh arch_pro
```
The `gdb_vp.sh` will create the shared memories, execute the `settings.bash` and launch the harness.

If you want to debug the code running on the simulator, add to the `.cfg`:
```bash
system.cpu.gdb_port   = <port number> # e.g. 5555
system.cpu.gdb_wait   = true 
```
This will stop the simulation until a debug connection is detected.

Then, open a new terminal and set up the gdb connection:
```bash
gdb-multiarch
set architecture aarch64
file <path to the .elf file that the simulator is running>
target remote :<port number> # e.g. 5555
```

## Troubleshooting

### AVP64: Building without CRIU support
If you get "Building without CRIU support" when building avp64, try the following:

- Check `vp_mode/avp64/FindLibCRIU.cmake` for the paths in hints and look if criu and x86_64-linux-gnu are installed in that paths.

### Others
- Enable harness and VP logging if fuzzing fails, by setting `TC_LOGGING` and `TC_VP_LOGGING` to a value greater than "0".
- If start/end symbols aren't found, ensure they're not optimized away or renamed by C++ — use `extern "C"`.
- For CRIU: In `vp_afl/checkpoints/<benchmark name>/` you can find the criu dump log named `criu.log` and the criu restore log named `restore.log`.
- Disable the VP's output when fuzzing by setting `system.term0.backends` to `null` In the .cfg file
- File logging not compatible with every application, e.g. buildroot will create nonsense output in a file, but perfectly readable output in the terminal.
- Remember to recompile the framework (without the debugging flag) when you want to fuzz after a debugging session
- After a long fuzzing session, the fuzzer won't start again if you don't change the output folder because it avoids overwriting the previous progress. Change output folder or delete it manually.

