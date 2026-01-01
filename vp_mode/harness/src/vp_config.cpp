#include "vp_config.hpp"
#include "logger.hpp"
#include "utils.hpp"

#include <cstdlib>
#include <string>

/* Parse settings.bash env variables */
bool VPConfig::parse_config(int /*argc*/, char *argv[]) {
  target_path = argv[1];

  // VP executable and launch arguments
  vp_executable = std::getenv("TC_VP_EXECUTABLE");
  if (!vp_executable) {
    LOG_MESSAGE(Logger::ERROR,
                "TC_VP_EXECUTABLE environment variable not set!");
    return false;
  }

  vp_launch_args = std::getenv("TC_VP_LAUNCH_ARGS");
  if (!vp_launch_args) { vp_launch_args = ""; }

  // VP logging configuration
  const char *vp_logging = std::getenv("TC_VP_LOGGING");
  vp_loglevel = 0;
  if (vp_logging) {
    try {
      vp_loglevel = std::stoi(vp_logging);
    } catch (std::exception &e) {
      LOG_MESSAGE(Logger::ERROR,
                  "Could not parse value of TC_VP_LOGGING! Logging disabled.");
    }
    vp_logging_path = std::getenv("TC_VP_LOGGING_PATH");
    if (vp_loglevel > 0 && !vp_logging_path) {
      LOG_MESSAGE(Logger::ERROR,
                  "TC_VP_LOGGING_PATH environment variable not "
                  "set, disabling VP logging.");
      vp_loglevel = 0;
      vp_logging_path = "";
    }
  } else {
    vp_logging_path = "";
  }

  // Chkpt mode
  chkpt_mode = std::getenv("TC_CHKPT_MODE");
  if (!chkpt_mode) {
    LOG_MESSAGE(Logger::INFO, "TC_CHKPT_MODE not set, running without checkpoint");
    chkpt_mode = "0";
  }

  timeout_ms = std::getenv("TC_TIMEOUT_MS");
  if (!timeout_ms) {
    LOG_MESSAGE(Logger::INFO, "TC_TIMEOUT_MS not set, running with the default timeout (2s)");
    timeout_ms = "2000";
  }

  // Other required environment variables
  start_symbol = std::getenv("TC_START_SYMBOL");
  if (!start_symbol) {
    LOG_MESSAGE(Logger::INFO, "TC_START_SYMBOL not set");
    start_symbol = "";
  }

  end_symbol = std::getenv("TC_END_SYMBOL");
  if (!end_symbol) {
    LOG_MESSAGE(Logger::INFO, "TC_END_SYMBOL environment variable not set!");
    end_symbol = "";
  }

  criu_img_dir = std::getenv("CRIU_IMG_DIR");
  if (!criu_img_dir) {
    LOG_MESSAGE(Logger::INFO, "CRIU_IMG_DIR environment variable not set! Running with the default folder ./checkpoints/default");
    criu_img_dir = "./checkpoints/default";
  }

  const char* val = std::getenv("TC_DUMP");
  restart_from_img = (val && std::string_view(val) == "0");

  // No error message for those because depending on the application they could also not be set
  return_register = std::getenv("TC_RETURN_REGISTER");
  if (!return_register) { return_register = ""; }

  error_symbol = std::getenv("TC_ERROR_SYMBOL");
  if (!error_symbol) { error_symbol = ""; }

  return true;
}
