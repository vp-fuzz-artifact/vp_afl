#include "afl_interface.hpp"
#include <unistd.h>
#include "afl_config.hpp"
#include "logger.hpp"
#include "defines.hpp"

/* Parse shm and pipes fds and ids*/
bool AFLInterface::parse_config(int argc, char *argv[]) {
  bool ret = config.parse_config(argc, argv);

  return ret;
}

[[nodiscard]] int AFLInterface::send_init_status_to_afl() const {
  // status = 0x81000001
  int status = FS_OPT_ENABLED | FS_OPT_SHDMEM_FUZZ;
  if (write(config.st_fd, &status, sizeof(status)) != sizeof(status)) {
    LOG_MESSAGE(Logger::ERROR,
                "Not running in forkserver mode, just executing the program.");
  }

  return status;
}

bool AFLInterface::init() {
  int status = send_init_status_to_afl();
  return receive_afl_init_status_response(status);
}

bool AFLInterface::send_vp_pid(pid_t vp_pid) const {
  if (write(config.st_fd, &vp_pid, sizeof(vp_pid)) != sizeof(vp_pid)) {
    LOG_MESSAGE(Logger::ERROR, "Failed to communicate with AFL.");
    return false;
  }
  return true;
}

bool AFLInterface::receive_afl_init_status_response(
    int sent_init_status) const {
  int read_status;

  if (read(config.ctl_fd, &read_status, sizeof(read_status)) !=
      sizeof(read_status)) {
    LOG_MESSAGE(Logger::ERROR, "AFL parent exited before forkserver was up.");
    return false;
  }

  if (read_status != sent_init_status) {
    LOG_MESSAGE(Logger::INFO, "Read response from AFL: %d need %d", read_status,
                sent_init_status);
    LOG_MESSAGE(Logger::ERROR,
                "Unexpected response from AFL++ on forkserver setup.");
    return false;
  }

  return true;
}

bool AFLInterface::receive_child_timeouted_msg() const {
  int child_timed_out;
  if (read(config.ctl_fd, &child_timed_out, sizeof(child_timed_out)) !=
      sizeof(child_timed_out)) {
    LOG_MESSAGE(Logger::ERROR, "Failed to receive child_timed_out from AFL.");
    return false;
  }

  LOG_MESSAGE(Logger::INFO, "Child Timeouted response: %d", child_timed_out);
  return true;
}

[[nodiscard]] bool AFLInterface::send_run_result(int status) const {
  if (write(config.st_fd, &status, sizeof(status)) != sizeof(status)) {
    LOG_MESSAGE(Logger::ERROR, "Failed to send status to AFL.");
    return false;
  }

  return true;
}

[[nodiscard]] int AFLInterface::get_shm_input_id() const {
  return config.shm_input_id;
}

[[nodiscard]] int AFLInterface::get_shm_cov_id() const {
  return config.shm_cov_id;
}
