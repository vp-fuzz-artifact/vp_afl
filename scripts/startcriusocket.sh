#!/bin/bash

# It creates: ./criu_service.socket
# specifies the libcriu.so path
# increases CRIU's verbosity
# criu service --address criu_service.socket --libdir /usr/local/lib/criu/ -vvvv

rm -f criu_service.socket

criu service \
    --address "$(pwd)/criu_service.socket" \
    --libdir /usr/local/lib/criu/ \
    --daemon \
    -vvvv
