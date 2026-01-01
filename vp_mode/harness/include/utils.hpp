#ifndef UTILS_HPP
#define UTILS_HPP

#include <optional>

bool               init_logging_from_env();
std::optional<int> parse_number(const char *str);
int                parse_arg(const char *str, const char *msg);

#endif  // !UTILS_HPP
