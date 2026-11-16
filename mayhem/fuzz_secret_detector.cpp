#include <cstddef>
#include <cstdint>
#include <string>

#include "logger/SecretDetector.hpp"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  std::string text(reinterpret_cast<const char *>(data), size);
  std::string masked = Snowflake::Client::SecretDetector::maskSecrets(text);
  return masked.empty() && !text.empty() ? -1 : 0;
}
