#include "vp_manager.hpp"
#include <map>
#include <fstream>
#include "vp_test/types.hpp"
#include "vp_test/conversion.hpp"
#include <sched.h>
#include <csignal>
#include <sys/wait.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>
#include <regex>
#include <sstream>
#include <filesystem>
#include <sys/prctl.h>
#include "logger.hpp"
#include "defines.hpp"

#ifdef DEBUG
  #include <sys/ptrace.h>
#endif


VPManager::VPManager() : 
  vp_pipe() {
  // Callback for info and error logging. This enables the testing_client to
  // also write into the logging file.
  vp_pipe.log_error_message = Logger::log_error;
  vp_pipe.log_info_message = Logger::log_info;

  // Start the communication.
  vp_pipe.init();

  // Since we're about to spawn a child process, we want to make sure they don't leave behind zombie processes
  // To this end, we make this process a "subreaper", so that it can clean up its "grandchildren" (which can't be reparented)
  prctl(PR_SET_CHILD_SUBREAPER, 1);
};


void VPManager::set_shm(int shm_input_id, unsigned int input_offset, int shm_coverage_id, unsigned int cov_offset){
  input_shm = {shm_input_id, input_offset};
  cov_shm = {shm_coverage_id, cov_offset};
}


/* Parse settings.bash env variables */
bool VPManager::parse_config(int argc, char *argv[]) {
  return config.parse_config(argc, argv);
}

[[nodiscard]] const char *VPManager::get_vp_executable() const {
  return config.vp_executable;
}

[[nodiscard]] uint64_t VPManager::get_return_code_value() const {
  return m_ret_value;
}

[[nodiscard]] pid_t VPManager::get_vp_pid() const {
  return vp_pid;
}


char *VPManager::pipe_name(int fd)
{
  static char pipe_name[64];
  char path[64];

  snprintf(path, sizeof path, "/proc/self/fd/%d", fd);
  readlink(path, pipe_name, sizeof pipe_name);
  return pipe_name;
}


void VPManager::kill_granchild(){

  LOG_MESSAGE(Logger::INFO, "We're about to kill the grandchild of process %d", vp_pid);

  std::ifstream file("/proc/" + std::to_string(vp_pid) +
                   "/task/" + std::to_string(vp_pid) + "/children");

  if (!file) {
    restart_vp_process(); // we give up, let's restart from scratch
    return;
  }

  std::string line;
  std::getline(file, line);

  LOG_MESSAGE(Logger::INFO, "Found one granchildren: %s", line.c_str());

  std::istringstream iss(line);
  pid_t child_pid;

  while (iss >> child_pid) {
    LOG_MESSAGE(Logger::INFO, "Killing child %d", child_pid);
    kill_vp_process(child_pid);
  }
}


bool VPManager::start_vp_process() 
{
  if (is_vp_running(vp_pid)) {
    LOG_MESSAGE(Logger::ERROR,
                "Cannot start a VP process, because there is currently one "
                "running for this vp client: %d", vp_pid);
    return false;
  }

  LOG_MESSAGE(Logger::INFO, "Starting VP %s", config.vp_executable);

  pid_t pid = fork();
  if (pid == 0) 
  {
    /* child process (no return) */
    spawn_vp();
  }

  /* Parent process */
  if(pid > 0){
    vp_pid = pid;
    return true;
  }

  return false;
}


void VPManager::save_checkpoint_pipe_ids() {

    if (!std::filesystem::is_directory(std::string(config.criu_img_dir))) {
        LOG_MESSAGE(Logger::INFO, "criu image dir `%s` does not exist - creating dir...",
                config.criu_img_dir);
        std::filesystem::create_directories(std::string(config.criu_img_dir));
    }
    
    std::string pipes_path = std::string(config.criu_img_dir) + "/pipes.txt";
    std::ofstream file(pipes_path);

    if (file.is_open()) {
        // Get names like "pipe:[120037]"
        std::string req_name = pipe_name(vp_pipe.get_request_fd_0());
        std::string res_name = pipe_name(vp_pipe.get_response_fd_1());
        
        if (!req_name.empty() && !res_name.empty()) {
            file << req_name << "\n" << res_name << "\n";
            LOG_MESSAGE(Logger::INFO, "Saved checkpoint pipe targets: Req=%s, Res=%s", req_name.c_str(), res_name.c_str());
        } else {
            LOG_MESSAGE(Logger::ERROR, "Failed to parse pipe IDs from strings: %s, %s", req_name.c_str(), res_name.c_str());
        }
        file.close();
    } else {
        LOG_MESSAGE(Logger::ERROR, "Failed to open %s for writing", pipes_path.c_str());
    }
}


bool VPManager::load_checkpoint_pipe_ids(std::string& req_id, std::string& res_id) {
    std::string pipes_path = std::string(config.criu_img_dir) + "/pipes.txt";
    std::ifstream file(pipes_path);
    
    if (file.is_open()) {
        if (std::getline(file, req_id) && std::getline(file, res_id)) {
            file.close();
            return true;
        }
        file.close();
    }
    LOG_MESSAGE(Logger::ERROR, "Could not read pipe IDs from %s", pipes_path.c_str());
    return false;
}


std::vector<char*> VPManager::build_restore_args() {
    return {
        const_cast<char*>("criu"),
        const_cast<char*>("restore"),
        const_cast<char*>("-d"),
        const_cast<char*>("-D"),
        const_cast<char*>(config.criu_img_dir),
        const_cast<char*>("-o"),
        const_cast<char*>("restore.log"),
        const_cast<char*>("-v4"),
        const_cast<char*>("--shell-job"),
        const_cast<char*>("--inherit-fd"),
        inh_pipe_arg,
        const_cast<char*>("--inherit-fd"),
        inh_pipe_arg2,
        nullptr
    };
}


pid_t VPManager::get_resurrected_pid()
{
  std::string pid_path = std::string(config.criu_img_dir) + "/sim_pid.txt";
  std::ifstream pid_file(pid_path);
  
  if (pid_file.is_open()) {
      pid_t target_pid = 0;
      if (pid_file >> target_pid) {
          pid_file.close();
          return target_pid;
      }
      pid_file.close();
  }
  
  LOG_MESSAGE(Logger::ERROR, "Could not read tracking PID from %s", pid_path.c_str());
  return -1;
}


// Reserve the PIDs CRIU must recreate so no ordinary fork can be given them.
// Must run before the first restore, while those PIDs are still free.
void VPManager::reserve_checkpoint_pids() {
  pid_t max_pid = 0;
  for (const auto& e : std::filesystem::directory_iterator(config.criu_img_dir)) {
    const std::string n = e.path().filename().string();      // core-<pid>.img,
    if (n.rfind("core-", 0) == 0)                            // one per dumped task
      max_pid = std::max<pid_t>(max_pid, std::stoi(n.substr(5)));
  }
  if (max_pid == 0) { LOG_MESSAGE(Logger::WARNING, "no core-*.img, not reserving"); return; }

  const pid_t cursor = std::max<pid_t>(max_pid, 300);        // see RESERVED_PIDS
  std::ofstream f("/proc/sys/kernel/ns_last_pid");
  if (!f) { LOG_MESSAGE(Logger::WARNING, "cannot write ns_last_pid"); return; }
  f << cursor;
  LOG_MESSAGE(Logger::INFO, "Reserved PIDs <= %d for restore", cursor);
}


bool VPManager::start_vp_from_restore() 
{
  if (is_vp_running(vp_pid)) {
    LOG_MESSAGE(Logger::ERROR,
                "Cannot start a VP process, because there is currently one "
                "running for this vp client: %d", vp_pid);
    return false;
  }

  reserve_checkpoint_pids();

  pid_t restore_pid = fork();

  /* Parent process */ // Added to not go in infinite loop in case of error
  if (restore_pid > 0)  // This pid is short-lived, it's simply the pid of the process executing the criu restore
  {    
		int status;

    vp_pid = get_resurrected_pid();
		waitpid(restore_pid, &status, 0);

		if (WIFEXITED(status))
			status = WEXITSTATUS(status);

		if (status){
      vp_pid = -1;
			exit(status);
    }
  }
  else if (restore_pid == 0) { // Child Process

    std::string req_id, res_id;
    if(!load_checkpoint_pipe_ids(req_id, res_id))
      LOG_MESSAGE(Logger::WARNING, "Failed to construct restore arguments");

    snprintf(inh_pipe_arg, sizeof(inh_pipe_arg), "fd[%d]:%s", vp_pipe.get_request_fd_0() , req_id.c_str());
    snprintf(inh_pipe_arg2, sizeof(inh_pipe_arg2), "fd[%d]:%s", vp_pipe.get_response_fd_1() , res_id.c_str());

    auto restore_args = build_restore_args();

    std::string cmd = "Executing:";

    for (int i = 0; restore_args[i] != nullptr; ++i) {
        cmd += " ";
        cmd += restore_args[i];
    }

    LOG_MESSAGE(Logger::INFO, cmd);
    
    execvp(restore_args[0], restore_args.data());
    // We should never get here
    LOG_MESSAGE(Logger::INFO, "execvp failed");
  }

  return true;
}


/* Run the VP and send the commands */
bool VPManager::launch_vp() 
{
  if (!start_vp_process()) { return false; }

  LOG_MESSAGE(Logger::INFO, "Waiting for ready message.");
  vp_pipe.wait_for_ready();

  return true;
}


// This kills and reaps the VP process 
bool VPManager::kill_vp_process(pid_t pid) {
  if (!is_vp_running(pid)) {
    LOG_MESSAGE(Logger::INFO,
                "Cannot kill the VP process, because there is none!");
    return false;
  }

  LOG_MESSAGE(Logger::INFO, "Killing VP process %d ...", pid);

  kill(pid, SIGKILL); // This does not wait for the process termination

  // if we're trying to kill some process that is NOT vp_pid (pid != vp_pid)
  // AND the child/sim_process is still alive (is_vp_running(vp_pid)) then we cannot reap!
  // We can reap the child of vp_pid only if vp_pid is dead and pid reparented
  if(pid != vp_pid && is_vp_running(vp_pid))
    return true;

  int status;
  pid_t wpid;
  do {
      wpid = waitpid(pid, &status, 0); // blocking wait, blocks until process exits
  } while (wpid == -1 && errno == EINTR); // if interrupted (EINTR) retry the wait

  if (wpid == pid) {
      LOG_MESSAGE(Logger::INFO, "VP process %d successfully reaped", pid);
  } else if (wpid == -1 && errno == ECHILD) {
      // No such child exists, nothing to reap
      LOG_MESSAGE(Logger::INFO, "VP process %d already exited or does not exist", pid);
  } else {
      LOG_MESSAGE(Logger::WARNING, "Failed to reap VP process %d", pid);
  }

  return true;
}


bool VPManager::restart_vp_process() {

  if (!kill_vp_process(vp_pid)) { return false; }
  // Reset ready state of pipe client, because we need to receive READY signal again
  vp_pipe.reset();

  if (!launch_vp()) { return false; } 

  return run_init();
}


bool VPManager::restore_from_checkpoint() 
{
  kill_vp_process(vp_pid);

  if (!start_vp_from_restore()) { 
    LOG_MESSAGE(Logger::INFO, "Restore start failed");
    return false; 
  }
  // Set pipe communication ready after restoring
  vp_pipe.set_ready();

  flush_response();
  send_command(testing::Command::ENABLE_CODE_COVERAGE);

  return true;
}


bool VPManager::send_command(testing::Command cmd, std::optional<std::chrono::milliseconds> timeout)
{
  testing::Request  req = testing::Request();
  testing::Response res = testing::Response();

  // Sending command to the VP.
  req.request_command = cmd;
  req.data.resize(testing::command_length[req.request_command]);

  return vp_pipe.send_request(req, res, timeout);
}

bool VPManager::send_shm_ids()
{
  using namespace testing;

  Request  req;
  Response res;

  req.request_command = testing::Command::INIT_SHM;
  conversion::BufferWriter writer(req.data);

  if(!writer.write_int32((uint32_t)cov_shm.id)) return false;
  if(!writer.write_int32((uint32_t)cov_shm.offset)) return false;
  if(!writer.write_int32((uint32_t)input_shm.id)) return false;
  if(!writer.write_int32((uint32_t)input_shm.offset)) return false;

  return vp_pipe.send_request(req, res);
}


bool VPManager::run_init() 
{
  using namespace testing;

  // Enable tracking
  send_command(Command::ENABLE_MMIO_TRACKING);

  // Run init code
  Request  req;
  Response res;

  req.request_command = testing::Command::RUN_INIT;

  // Do not change to std::string: it's a "cheap copy", no mem allocation, more lightweight
  std::array<std::string_view, 5> symbols = {
      config.start_symbol, config.end_symbol, config.return_register,
      config.chkpt_mode, config.error_symbol};

  conversion::BufferWriter writer(req.data);

  if(!writer.write_int32((uint32_t)input_shm.id)) return false;
  if(!writer.write_int32((uint32_t)input_shm.offset)) return false;
  if(!writer.write_int32((uint32_t)cov_shm.id)) return false;
  if(!writer.write_int32((uint32_t)cov_shm.offset)) return false;

  for(const auto &s : symbols){
    if(!writer.write_uint8(s.size())) return false;
    if(!writer.write_string(s)) return false;
  }

  if(!vp_pipe.send_request(req, res))
    return false;

  // Enable coverage
  return send_command(Command::ENABLE_CODE_COVERAGE);
}


bool VPManager::flush_response(){
  LOG_MESSAGE(Logger::INFO, "Waiting for the restored process to be ready");

  testing::Response res = testing::Response();
  return vp_pipe.receive_response(res);
}


bool VPManager::request_return_code() {

  testing::Request  req = testing::Request();
  testing::Response res = testing::Response();

  // Sending command GET_RETURN_CODE to the VP.
  // Get exit status.
  req.request_command = testing::Command::GET_RETURN_CODE;
  req.data.resize(testing::command_length[req.request_command]);
  bool ret = vp_pipe.send_request(req, res);

  if (ret) {
    m_ret_value = testing::conversion::bytes_to_int64(res.data.data(), 0);
    LOG_MESSAGE(Logger::INFO, "Run done. Return code: %d", m_ret_value);
  }

  return ret;
}


void VPManager::spawn_vp() 
{ 
  configure_vp_logging_files();

  std::vector<char *> argv;

  argv.push_back(strdup(config.vp_executable));

  // const char *trace = "--trace-stdout";
  // argv.push_back(strdup(trace));

  // If log level is set to only errors, signal this to the VP.
  if (config.vp_loglevel == 2) {
    std::string log_errors_only = "--log-errors-only";
    argv.push_back(strdup(log_errors_only.c_str()));
  }

  // TODO: into ENV ?
  std::string full_launch_args =
      " --enable-test-receiver " /*"--test-receiver-interface 1 "*/
      "--test-receiver-pipe-request " +
      std::to_string(vp_pipe.get_request_fd_0()) +
      " --test-receiver-pipe-response " +
      std::to_string(vp_pipe.get_response_fd_1()) + " " + config.vp_launch_args;

  std::istringstream iss(full_launch_args);
  std::string        token;

  while (iss >> token) {
    argv.push_back(strdup(token.c_str()));
  }

  argv.push_back(strdup(config.target_path));
  

  std::string joined;
  for (const char* arg2 : argv) {
      if (!joined.empty()) joined += ' ';
      joined += arg2;
  }

  LOG_MESSAGE(Logger::INFO, "VP arguments: %s", joined.c_str());
  argv.push_back(nullptr);
  signal(SIGTTOU, SIG_IGN);  // Ignore SIGTTOU signal triggered by the vp trying
                             // to print sth
  signal(SIGTTIN, SIG_IGN);    // both signals: stop vp from reading and writing to the terminal

  execvp(argv[0], argv.data());
  exit(127);  // only if exec fails
}


void VPManager::configure_vp_logging_files() const {
  // Redirect stdout and stderr to files or /dev/null.
  int logging;

  // Create/open a logging file if logging is not disabled.
  if (config.vp_loglevel == 3) { // Console output
    return;
  } else if (config.vp_loglevel > 0) {
    logging = open(config.vp_logging_path, O_WRONLY | O_CREAT | O_APPEND, 0666);
  } else {
    logging = open("/dev/null", O_WRONLY);
  }

  // Redirect output and error messages to the file or /dev/null (deleting
  // them). 
  dup2(logging, STDOUT_FILENO);
  dup2(logging, STDERR_FILENO);
  close(logging);
}


bool VPManager::is_vp_running(pid_t pid)
{
  if (pid != -1 && 0 == kill(pid, 0))
    return true;

  return false;
}