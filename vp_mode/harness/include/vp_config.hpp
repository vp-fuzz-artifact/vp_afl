#ifndef VP_CONFIG_HPP
#define VP_CONFIG_HPP

struct VPConfig {
  const char  *target_path;
  const char  *start_symbol;
  const char  *end_symbol;
  const char  *chkpt_mode;
  const char  *criu_img_dir;
  const char  *timeout_ms;
  const char  *return_register;
  const char  *vp_executable;
  const char  *vp_launch_args;
  int          vp_loglevel;
  bool         restart_from_img;
  const char  *vp_logging_path;
  const char  *error_symbol;

  bool parse_config(int argc, char *argv[]);
};

#endif  // !VP_CONFIG_HPP
