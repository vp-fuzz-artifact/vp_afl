#include "logger.hpp"
#include <fstream>
#include <cstdarg>
#include <iostream>

void Logger::init(const std::string &filename, log_level set_log_level) {
  file_stream.open(filename, std::ios::app);  // Open for appending
  if (!file_stream.is_open()) {
    throw std::runtime_error("Unable to open log file: " + filename);
  }
  selected_log_level = set_log_level;
}

void Logger::log(log_type msg_log_type, const std::string &format, ...) {
  va_list args;
  va_start(args, format);
  log(msg_log_type, format, args);
  va_end(args);
}

void Logger::log(log_type msg_log_type, const std::string &format,
                 va_list args) {
  if (selected_log_level == DISABLED ||
      (selected_log_level == WARNINGS_AND_ERRORS &&
       (msg_log_type != WARNING && msg_log_type != ERROR)))
    return;

  if (!file_stream.is_open()) {
    std::cerr << "Log file is not open." << std::endl;
    return;
  }
  char        time_buffer[20];  // Buffer for timestamp [YYYY-MM-DD HH:MM:SS]
  std::time_t current_time = std::time(nullptr);
  std::strftime(time_buffer, sizeof(time_buffer), "%Y-%m-%d %H:%M:%S",
                std::localtime(&current_time));

  char messageBuffer[1024];  // Buffer for formatted message

  std::string log_type_string;

  switch (msg_log_type) {
    case INFO:
      log_type_string = "INFO: ";
      break;
    case WARNING:
      log_type_string = "WARNING: ";
      break;
    case ERROR:
      log_type_string = "ERROR: ";
      break;
  }

  // Format the message
  std::vsnprintf(messageBuffer, sizeof(messageBuffer), format.c_str(), args);

  // Output the timestamp and message to the file
  std::unique_lock<std::mutex> lock(logger_mutex);
  file_stream << "[" << time_buffer << "] " << log_type_string << messageBuffer
              << std::endl;
  lock.unlock();
}

void Logger::log_error(const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  log(log_type::ERROR, fmt, args);
  va_end(args);
}

void Logger::log_info(const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  log(log_type::INFO, fmt, args);
  va_end(args);
}

void Logger::close() {
  if (file_stream.is_open()) { file_stream.close(); }
}

std::ofstream     Logger::file_stream;
Logger::log_level Logger::selected_log_level = Logger::DISABLED;
std::mutex        Logger::logger_mutex;
