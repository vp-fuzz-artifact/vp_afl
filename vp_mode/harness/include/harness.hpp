#ifndef HARNESS_HPP
#define HARNESS_HPP

#include "afl_interface.hpp"
#include "vp_manager.hpp"
#include <fstream>  // for std::ifstream
#include <chrono>
#include <signal.h>

constexpr std::chrono::milliseconds default_timeout = std::chrono::milliseconds(2000);

class Session {
public:
    void startSession(); 
    double printElapsed(std::string); 

private:
    // The correct type for storing a steady_clock timestamp
    std::chrono::steady_clock::time_point m_startTime; 
};

class Harness {
 public:
  Harness();

  static void signal_handler(int sig);
  static volatile sig_atomic_t term_signal;

  bool init(int argc, char *argv[]);

  [[nodiscard]] bool run();

  ~Harness();

  /* Debug */
  bool               dbg_init(int argc, char *argv[]);
  [[nodiscard]] bool dbg_run();

 private:

  AFLInterface afl_interface;
  VPManager    vp_manager;
  std::chrono::milliseconds timeval_ms;

  bool fuzzing_loop_body();
  void handle_criu();
  void handle_no_checkpoint();
  void handle_fork();
  void handle_hybrid();
  void init_checkpoint();
  std::function<bool(int status)> handle_restart;


  /* Debug */
  std::string seeds_path;
  int         dbg_input_shm = -1;
  int         dbg_cov_shm = -1;
};

#endif  // !HARNESS_HPP
