#ifndef AFL_CONFIG_HPP
#define AFL_CONFIG_HPP


struct AFLConfig {
  int        shm_input_id;
  int        shm_cov_id;
  int        ctl_fd;
  int        st_fd;

  bool parse_config(int argc, char *argv[]);
};

#endif  // !AFL_CONFIG_HPP
