FROM ubuntu:22.04
ENV TERM=xterm-256color
ENV DEBIAN_FRONTEND=noninteractive

# toolchain + VP build deps (cmake fetches mwr/systemc/ocx via git at configure)
# + CRIU build deps
RUN echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/01-no-sandbox \
    && apt-get update \
    && apt-get -y install --no-install-recommends \
        build-essential \
        cmake \
        git \
        ca-certificates \
        pkg-config \
        python3 \
        python3-pip \
        libelf-dev \
        libsdl2-dev \
        libprotobuf-dev \
        libprotobuf-c-dev \
        protobuf-c-compiler \
        protobuf-compiler \
        python3-protobuf \
        libcap-dev \
        libnet1-dev \
        libnl-3-dev \
        libnl-route-3-dev \
        libbsd-dev \
        uuid-dev \
        libgnutls28-dev \
        iproute2 \
        gdb-multiarch \
    && rm -rf /var/lib/apt/lists/*

ARG CRIU_TAG=v4.2
RUN git clone --depth 1 --branch ${CRIU_TAG} \
        https://github.com/checkpoint-restore/criu /tmp/criu \
    && make -C /tmp/criu -j"$(nproc)" criu lib \
    && make -C /tmp/criu PREFIX=/usr/local install-criu install-lib \
    && ldconfig \
    && rm -rf /tmp/criu

WORKDIR /app

# Splitting the build into different steps support incremental recompilation
# On a rebuild Docker reuses the cached steps until it reaches the first one whose inputs changed, and it re-runs that step and everything after it.
# Those clones replace the CMake's own auto-fetch, in this way we can fully control the versions of the deps we are fetching
RUN git clone --depth 1 --recursive --branch avp64 https://github.com/nbosb/ocx-qemu-arm /opt/ocx-qemu-arm \
    && git clone --depth 1 --recursive --branch v2026.02.10 https://github.com/machineware-gmbh/mwr /opt/mwr \
    && git clone --depth 1 https://github.com/machineware-gmbh/systemc /opt/systemc
ENV OCX_QEMU_ARM_HOME=/opt/ocx-qemu-arm \
    MWR_HOME=/opt/mwr \
    SYSTEMC_HOME=/opt/systemc

COPY Makefile ./
COPY vp_mode/patches/ ./vp_mode/patches/
COPY vp_mode/aflplusplus/ ./vp_mode/aflplusplus/
RUN make afl

COPY vp_mode/vp-testing-interface/ ./vp_mode/vp-testing-interface/
RUN make vp-testing-interface

COPY vp_mode/vcml/ ./vp_mode/vcml/
COPY vp_mode/avp64/ ./vp_mode/avp64/
RUN make avp64

COPY vp_mode/harness/ ./vp_mode/harness/
RUN make harness
COPY scripts/startcriusocket.sh ./

ENV PRJ_ROOT_DIR=/app \
    SCRIPTS_DIR=/app/scripts \
    TC_PATH=/app/build/harness/harness \
    AFL_PATH=/app/vp_mode/aflplusplus \
    TC_VP_EXECUTABLE=/app/install/bin/avp64-runner \
    LD_LIBRARY_PATH=/app/install/lib:/app/install/lib64:/usr/local/lib/x86_64-linux-gnu
