#include "utils.hpp"
#include "logger.hpp"

#include <string>
#include <charconv>

bool init_logging_from_env() {
  const char *logging = std::getenv("TC_LOGGING");
  if (logging == nullptr) { return true; }

  int log_level = 0;
  try {
    log_level = std::stoi(logging);
  } catch (const std::exception &e) {
    LOG_MESSAGE(Logger::ERROR, "Invalid logging level in TC_LOGGING");
    return false;
  }
  const char *logging_path = std::getenv("TC_LOGGING_PATH");
  if (log_level > 0 && logging_path) {
    Logger::init(logging_path, (Logger::log_level)log_level);
    LOG_MESSAGE(Logger::WARNING, "LOGGING ENABLED!");
  }
  return true;
}

std::optional<int> parse_number(const char *str) {
  std::string_view sv(str);
  int              base = 10;

  // Detect base from prefix
  if (sv.size() > 2 && sv[0] == '0') {
    if (sv[1] == 'x' || sv[1] == 'X') {
      base = 16;
      sv.remove_prefix(2);
    }
  }

  int value;
  auto [ptr, ec] =
      std::from_chars(sv.data(), sv.data() + sv.size(), value, base);
  if (ec == std::errc()) {
    return value;
  } else {
    return std::nullopt;
  }
}

int parse_arg(const char *str, const char *msg) {
  // Try to parse the string `str` into an integer.
  std::optional<int> parsed_arg_opt = parse_number(str);

  // If the string could not be parsed into a number, print an error message and exit.
  if (!parsed_arg_opt) {
    LOG_MESSAGE(Logger::ERROR, "Invalid value for param: %s", msg);
    exit(1);
  }

  // If parsing succeeded, extract the value and return it.
  int parsed_arg = parsed_arg_opt.value();

  return parsed_arg;
}
