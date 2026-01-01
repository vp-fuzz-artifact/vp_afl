#!/bin/bash

if [[ ! -f "$TC_PATH" ]]; then
    echo "Error: No harness executable at $TC_PATH"
    exit 1
fi

if [[ ! -f "$TC_VP_EXECUTABLE" ]]; then
    echo "Error: No VP executable at $TC_VP_EXECUTABLE"
    exit 1
fi


# Launch arguments of vp
export TC_VP_LAUNCH_ARGS="-f"

## Optional
# 0: No logging (default), 1: Everything, 2: Errors only
export TC_LOGGING="${TC_LOGGING:-0}"
export TC_LOGGING_PATH="${TC_LOGGING_PATH:-$PRJ_ROOT_DIR/logs/tc_out.txt}"
# 0: No logging (default), 1: Everything (log file), 2: Errors only, 3: Everything (Console)
export TC_VP_LOGGING="${TC_VP_LOGGING:-0}"
export TC_VP_LOGGING_PATH="${TC_VP_LOGGING_PATH:-$PRJ_ROOT_DIR/logs/vp_out.txt}"

# Mode
# 0: No checkpointing, 1: CRIU mode, 2: Fork mode, 3: Hybrid
export TC_CHKPT_MODE=${TC_CHKPT_MODE:-0}
# When dump = 1, we dump the process. When dump = 0, we try to recover from previous images
export TC_DUMP=${TC_DUMP:-1}

if [[ "$TC_CHKPT_MODE" == "1" ]]; then

    ### 1) Check if we're running with sudo priviledges ###
    if [[ $EUID -ne 0 ]]; then
        echo "You're not running with sudo, switching to no checkpoint..."
        export TC_CHKPT_MODE="0"

    ### 2) If we are, start the socket to dump, if requested ###
    elif [[ "$TC_DUMP" == "1" ]]; then
        if [[ -f "$SCRIPTS_DIR/startcriusocket.sh" ]]; then
            "$SCRIPTS_DIR/startcriusocket.sh"

            for i in {1..20}; do
                if [[ -S "$PRJ_ROOT_DIR/criu_service.socket" ]]; then
                    echo "CRIU socket active"
                    break
                fi
                sleep 1
            done
        else
            echo "startcriusocket.sh not found, switching to no checkpoint..."
            export TC_CHKPT_MODE="0"
        fi

    ### 3) Criu requested without dumping, check that the image exists ###
    else
        if [[ ! -f "$CRIU_IMG_DIR/criu.log" ]]; then
            echo "No image found, switching to default CRIU mode, this will dump the process before restoring"
            export TC_DUMP="1"
        fi
    fi
    
fi

# Fuzzing Settings
# export TC_START_SYMBOL="main" 
export TC_START_SYMBOL=""
export TC_END_SYMBOL=""
export TC_RETURN_REGISTER="x0"
#export TC_ERROR_SYMBOL="__stack_chk_fail" 
export TC_TIMEOUT_MS=${TC_TIMEOUT_MS:-5000}

#Additional for setup
export AFL_SKIP_CPUFREQ=1
export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1

