#include "afl_config.hpp"
#include "logger.hpp"
#include <cstdlib>
#include "utils.hpp"

bool AFLConfig::parse_config(int /*argc*/, char *argv[]) {
  shm_input_id = parse_arg(argv[2], "test case shared memory");
  shm_cov_id = parse_arg(argv[3], "coverage shared memory");
  ctl_fd = parse_arg(argv[4], "forkserver control FD");
  st_fd = parse_arg(argv[5], "forkserver status FD");

  return true;
}

