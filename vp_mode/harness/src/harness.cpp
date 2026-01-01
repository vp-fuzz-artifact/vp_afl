#include "harness.hpp"
#include <sys/shm.h>
#include <iostream>
#include <chrono>
#include <vector>
#include <numeric>
#include <cmath>
#include <csignal>
#include <cstring>
#include "afl_config.hpp"
#include "defines.hpp"
#include "logger.hpp"
#include "utils.hpp"
#if DEBUG == 1
  #include "sys/types.h"
#endif

volatile sig_atomic_t Harness::term_signal = 0;


void Session::startSession() {
  // Capture the exact moment the session started
  m_startTime = std::chrono::steady_clock::now(); 
}

double Session::printElapsed(std::string slot) {
  auto currentTime = std::chrono::steady_clock::now();
  // Compare current time against the stored variable
  auto elapsed = currentTime - m_startTime; 
  auto elapsed_ms = std::chrono::duration_cast<std::chrono::microseconds>(elapsed).count() / 1000.0;

  LOG_MESSAGE(Logger::INFO, "%s: Elapsed %.3f ms", slot.c_str(), elapsed_ms);
  return (double)elapsed_ms;
}


Harness::Harness():
timeval_ms(default_timeout),
dbg_input_shm(-1),
dbg_cov_shm(-1)
{}

Harness::~Harness(){
  pid_t pid = vp_manager.get_vp_pid(); /* TODO */ // the killing already happens in the destructor
  vp_manager.kill_vp_process(pid);
}

/* This method creates a VP instance, sends the commands
   and handles the communication with AFL                */
bool Harness::init(int argc, char *argv[]) {
  using namespace testing;

  if (argc != 6) {
    LOG_MESSAGE(Logger::ERROR, "Wrong parameters!");
    return false;
  }

  if (!afl_interface.parse_config(argc, argv)) { return false; }
  vp_manager.set_shm(afl_interface.get_shm_input_id(), 4, afl_interface.get_shm_cov_id(), 0);

  if (!vp_manager.parse_config(argc, argv)) { return false; }

  // Register termination handler
  std::signal(SIGTERM, Harness::signal_handler);

  init_checkpoint();

  int cfg_tm = std::stoi(vp_manager.config.timeout_ms);
  if(cfg_tm > 0){
    timeval_ms = std::chrono::milliseconds(cfg_tm);}

  if(!vp_manager.config.restart_from_img){
    if (!vp_manager.launch_vp()) {
      LOG_MESSAGE(Logger::ERROR, "Failed to initialize VP");
      return false;
    }

    if (!vp_manager.run_init()) { return false; }
  } else {
    LOG_MESSAGE(Logger::INFO, "Restarting the VP from image");
    handle_restart(0);
  }

  if (!afl_interface.init()) {
    LOG_MESSAGE(Logger::ERROR, "Failed to initialize AFL interface");
    return false;
  }

  return true;
}


void Harness::handle_criu(){
  uid_t uid = getuid();
  if(uid != 0){
    LOG_MESSAGE(Logger::ERROR, "Attempting CRIU without running with root priviledge, switching to no checkpoint");
    vp_manager.config.chkpt_mode = "0";
    handle_no_checkpoint();
    return;
  }
  // If we're dumping, dump the pipe names
  if(!vp_manager.config.restart_from_img) { vp_manager.save_checkpoint_pipe_ids(); }

  handle_restart = [&](int status){ bool res = vp_manager.restore_from_checkpoint(); 
                                    if(vp_manager.config.restart_from_img) vp_manager.send_shm_ids();
                                    return res; 
                                  };
  LOG_MESSAGE(Logger::INFO, "************************** STARTING CRIU MODE FUZZING **************************");
}


void Harness::handle_no_checkpoint(){
  LOG_MESSAGE(Logger::INFO, "************************** STARTING NO_CHKPT FUZZING **************************");
  vp_manager.config.restart_from_img = false; // Just in case the user was trying an unsupported feature
  handle_restart = [&](int status){ return vp_manager.restart_vp_process(); };
}


void Harness::handle_fork(){
  LOG_MESSAGE(Logger::INFO, "************************** STARTING FORK MODE FUZZING **************************");
  vp_manager.config.restart_from_img = false; // Just in case the user was trying an unsupported feature
  handle_restart = [&](int status){ if(status == -1){ 
                                      vp_manager.kill_granchild(); 
                                      vp_manager.flush_response(); // Do we need this?
                                    } return true; 
                                  };
}


void Harness::handle_hybrid(){

  // Check for sudo
  uid_t uid = getuid();
  if(uid != 0){
    LOG_MESSAGE(Logger::ERROR, "Attempting HYBRID without running with root priviledge, switching to no checkpoint");
    vp_manager.config.chkpt_mode = "0";
    handle_no_checkpoint();
    return;
  }

  // If we're dumping, dump the pipe names
  if(!vp_manager.config.restart_from_img) { vp_manager.save_checkpoint_pipe_ids(); }

  // If we're dumping, the restart will be handled by fork on the vp side. Otherwise we should restore the process!
  handle_restart = [&](int status){ if(vp_manager.config.restart_from_img){

                                      bool res = vp_manager.restore_from_checkpoint(); 
                                      vp_manager.send_shm_ids(); // send new ids to the newborn process

                                      vp_manager.config.restart_from_img = false; // from here on, fork mode takes over
                                      return res;

                                    }else if(status == -1){ 

                                      vp_manager.kill_granchild(); 
                                      vp_manager.flush_response(); // Do we need this?

                                    } return true; 
                                  };
  LOG_MESSAGE(Logger::INFO, "************************** STARTING HYBRID MODE FUZZING **************************");
}


void Harness::init_checkpoint(){

  switch(std::stoi(vp_manager.config.chkpt_mode)) 
  {
    case FORK:
      handle_fork();
      break;
    case CRIU:
      handle_criu();
      break;
    case NO_CHKPT:
      handle_no_checkpoint();
      break;
    case HYBRID:
      handle_hybrid();
      break;
    default:
      LOG_MESSAGE(Logger::ERROR, "Not a valid TC_CHKPT_MODE value, running without checkpoint");
      handle_no_checkpoint();
      break;
  }

}


bool Harness::run() {
  do {
    if (!fuzzing_loop_body()) {
      LOG_MESSAGE(Logger::ERROR, "Failed to loop");
      return false;
    }
  } while (term_signal == 0);

  return true;
}


bool Harness::fuzzing_loop_body() 
{
  int status = 0;
  pid_t current_child_pid = vp_manager.get_vp_pid();

  LOG_MESSAGE(Logger::INFO, "New fuzzing iteration");

  if (!afl_interface.receive_child_timeouted_msg()) { return false; }
  if (!afl_interface.send_vp_pid(current_child_pid)) { return false; }  

  if (vp_manager.send_command(testing::Command::DO_RUN_SHM, timeval_ms)) 
  { 
    if (!vp_manager.request_return_code()) { return false; }
    status = vp_manager.get_return_code_value();
  } 
  else {
    status = -1;
  }
  
  LOG_MESSAGE(Logger::INFO, "Finished, sending status!");

  if (!afl_interface.send_run_result(std::abs(status))) { return false; }

  return handle_restart(status);
}


void Harness::signal_handler(int sig) {
  LOG_MESSAGE(Logger::ERROR, "Terminating on signal %d", sig);

  term_signal = 1;
}


/* Debug methods */
bool Harness::dbg_init(int argc, char *argv[]) {
  if (argc != 5) {
    LOG_MESSAGE(Logger::ERROR, "Wrong amount of arguments!");
    return false;
  }

  seeds_path = argv[2];
  dbg_input_shm = parse_arg(argv[3], "test case shared memory");
  dbg_cov_shm = parse_arg(argv[4], "coverage shared memory");

  vp_manager.set_shm(dbg_input_shm, 4, dbg_cov_shm, 0);
  if (!vp_manager.parse_config(argc, argv)) { return false; }

  std::signal(SIGTERM, Harness::signal_handler);

  init_checkpoint();
  
  int cfg_tm = std::stoi(vp_manager.config.timeout_ms);
  if(cfg_tm > 0){
    timeval_ms = std::chrono::milliseconds(cfg_tm);
    LOG_MESSAGE(Logger::INFO, "Running with a timeout of %d ms", cfg_tm);
  }

  Session measure_init = Session();

  if(!vp_manager.config.restart_from_img){

    measure_init.startSession();

    if (!vp_manager.launch_vp()) {
      LOG_MESSAGE(Logger::ERROR, "Failed to initialize VP");
      return false;
    }

    measure_init.printElapsed("launch_vp");

    measure_init.startSession();

    if (!vp_manager.run_init()) { return false; }

    measure_init.printElapsed("run_init");

  } else {
    LOG_MESSAGE(Logger::INFO, "Restarting the VP from image");
    handle_restart(0);
  }

  return true;
}


bool Harness::dbg_run() {
  constexpr int offset_in_shm = 4; 
  int iterations = 10;
  int status;

  void* shm_at_res = shmat(dbg_input_shm, nullptr, 0);
  if (shm_at_res == (void*)-1) {
    LOG_MESSAGE(Logger::ERROR, "Failed to attach shared memory segment!");
    return false;
  }
  char* const mmio_data = reinterpret_cast<char*>(shm_at_res);

  // read seed file
  std::ifstream file(seeds_path, std::ios::binary | std::ios::ate);
  if (!file) {
    LOG_MESSAGE(Logger::ERROR, "Failed to open seed file");
    shmdt(mmio_data);
    return false;
  }

  // determine the size of a file and prepare to read its contents from the beginning
  std::streamsize size = file.tellg();
  file.seekg(0, std::ios::beg);

  std::vector<char> msg_to_send(size);
  if (!file.read(msg_to_send.data(), size)){
    LOG_MESSAGE(Logger::ERROR, "Failed to read seed file");
    shmdt(mmio_data);
    return false;
  }

  std::memcpy(mmio_data + offset_in_shm, msg_to_send.data(), msg_to_send.size());

  // ------------- START BENCHMARKING ---------------
  Session measure_loop = Session();
  Session tot_time = Session();

  std::vector<double> iteration_times, restarting_time;
  iteration_times.reserve(iterations);
  restarting_time.reserve(iterations);

  LOG_MESSAGE(Logger::INFO, "Benchmark starting. Iterations = %d", iterations);
  tot_time.startSession();

  // Persistent mode: Restore from checkpoint
  for(int i=0; i<iterations; i++)
  {
    measure_loop.startSession();

    LOG_MESSAGE(Logger::INFO, "Iteration n.%d", i+1);

    if (vp_manager.send_command(testing::Command::DO_RUN_SHM, timeval_ms)) 
    { 
      if (!vp_manager.request_return_code()) { return false; }
      status = vp_manager.get_return_code_value();
    } 
    else {
      status = 1;
    }

    LOG_MESSAGE(Logger::INFO, "Finished with status: %d", status);
    
    double second_ms = measure_loop.printElapsed("Execution");
    iteration_times.push_back(second_ms);

    if(i < iterations - 1){
      measure_loop.startSession();

      handle_restart(status);
    
      double second_ms = measure_loop.printElapsed("Restart");
      restarting_time.push_back(second_ms);
    }
  }

  tot_time.printElapsed("Tot Execution and Restart");
  // ----------------------------------------------
  // Compute statistics
  // ----------------------------------------------
  double sum = std::accumulate(iteration_times.begin(), iteration_times.end(), 0.0);
  double sum_restore = std::accumulate(restarting_time.begin(), restarting_time.end(), 0.0);
  double avg = sum / iteration_times.size();
  double avg_restore = sum_restore / (iteration_times.size()-1);


  LOG_MESSAGE(Logger::INFO, "Benchmark complete:");
  LOG_MESSAGE(Logger::INFO, "  Avg Iteration time:    %.3f ms", avg);
  LOG_MESSAGE(Logger::INFO, "  Tot Iteration time:    %.3f ms", sum);

  LOG_MESSAGE(Logger::INFO, "  Avg Restore time:    %.3f ms", avg_restore);
  LOG_MESSAGE(Logger::INFO, "  Tot Restore time:    %.3f ms", sum_restore);


  return true;
}