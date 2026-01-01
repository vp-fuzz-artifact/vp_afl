#include "defines.hpp"
#include "logger.hpp"
#include "harness.hpp"
#include "utils.hpp"

int main(int argc, char *argv[]) {
  if (!init_logging_from_env()) { return 1; }
  Harness harness = Harness();

#if DEBUG == 1

  LOG_MESSAGE(Logger::INFO, "Run manual.");

  if (!harness.dbg_init(argc, argv)) { return 1; }

  bool ret = harness.dbg_run();

  return ret ? 0 : -1;

#else

  if (!harness.init(argc, argv)) { return 1; }

  return harness.run();

#endif
}

