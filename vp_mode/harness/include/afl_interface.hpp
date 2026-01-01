#ifndef AFL_CLIENT_HPP
#define AFL_CLIENT_HPP

#include <sys/types.h>
#include "afl_config.hpp"

class AFLInterface {
 public:
  bool parse_config(int argc, char *argv[]);

  /* communication */
  [[nodiscard]] bool init();
  [[nodiscard]] bool send_vp_pid(pid_t vp_pid) const;
  [[nodiscard]] bool receive_child_timeouted_msg() const;
  [[nodiscard]] bool send_run_result(int status) const;

  /* getters */
  [[nodiscard]] int        get_shm_input_id() const;
  [[nodiscard]] int        get_shm_cov_id() const;

 private:
  AFLConfig config;

  int _profiler_count = 0;

  [[nodiscard]] int  send_init_status_to_afl() const;
  [[nodiscard]] bool receive_afl_init_status_response(
      int sent_init_status) const;
};

#endif
