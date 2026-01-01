#ifndef DEFINES_HPP
#define DEFINES_HPP

// Settings
#define PROFILING_COUNT 15
#define OWN_NAME "test_client"
#ifndef DEBUG
  #define DEBUG 0
#endif
// End Settings

// Data to enable shared memory fuzzing for AFLplusplus
#define FS_OPT_ENABLED 0x80000001
#define FS_OPT_SHDMEM_FUZZ 0x01000000

#endif
