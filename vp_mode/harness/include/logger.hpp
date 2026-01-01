#ifndef LOGGER_HPP
#define LOGGER_HPP

#include <mutex>
#include <string>

// Logging macro
#define LOG_MESSAGE(type, format, ...) Logger::log(type, format, ##__VA_ARGS__)

class Logger {
 public:
  enum log_level { DISABLED, ALL, WARNINGS_AND_ERRORS };

  enum log_type { INFO, WARNING, ERROR };

  static void init(const std::string &filename, log_level set_log_level);

  static void log(log_type msg_log_type, const std::string &format, ...);

  static void log_error(const char *fmt, ...);

  static void log_info(const char *fmt, ...);

  static void close();

 private:
  static void log(log_type msg_log_type, const std::string &format,
                  va_list args);

  // Mutex to synchonize logging when multiple threads are logging to the same
  // file.
  static std::mutex logger_mutex;

  static std::ofstream file_stream;
  static log_level     selected_log_level;
};

#endif

