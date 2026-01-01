#ifndef VP_CLIENT_HPP
#define VP_CLIENT_HPP

#include <sched.h>
#include <cstdint>
#include <algorithm>
#include <future>
#include <fcntl.h>
#include <thread>
#include "vp_config.hpp"
#include "vp_test/vp_comm.hpp"

enum CHKPT_MODE {
    NO_CHKPT,
    CRIU,
    FORK,
    HYBRID   
};


struct shared_mem {
  int id;
  unsigned int offset;
};


// Client that interfaces with a the virtual platform process.
class VPManager {
 public:
  testing::VpComm vp_pipe;

  VPManager();

  VPConfig config;
  bool parse_config(int argc, char *argv[]);

  [[nodiscard]] const char *get_vp_executable() const;
  [[nodiscard]] uint64_t    get_return_code_value() const;
  [[nodiscard]] pid_t       get_vp_pid() const;
 
  char* pipe_name(int fd);
  bool is_vp_running(pid_t pid);
  void set_shm(int shm_input_id, unsigned int input_offset, int shm_coverage_id, unsigned int cov_offset);
  bool send_command(testing::Command cmd, std::optional<std::chrono::milliseconds> timeout = std::nullopt);

  bool launch_vp();
  bool kill_vp_process(pid_t pid);
  void kill_granchild();
  bool restart_vp_process();
  void reserve_checkpoint_pids();
  bool restore_from_checkpoint();
  void save_checkpoint_pipe_ids();
  bool load_checkpoint_pipe_ids(std::string& req_id, std::string& res_id);
  bool flush_response();
  bool send_shm_ids();

  // Run initialization
  [[nodiscard]] bool run_init();

  // The return code was recoreded during the do_run function.
  [[nodiscard]] bool request_return_code();

 private:

  shared_mem input_shm;
  shared_mem cov_shm;

  char inh_pipe_arg[32];
  char inh_pipe_arg2[32];
  std::vector<char*> build_restore_args();


  uint64_t m_ret_value = 0;
  pid_t    vp_pid = -1;

  // Helper functions
  void spawn_vp();
  pid_t get_resurrected_pid();
  void configure_vp_logging_files() const;

  // Restarting related methods
  bool start_vp_process();
  bool start_vp_from_restore();
};

#endif
