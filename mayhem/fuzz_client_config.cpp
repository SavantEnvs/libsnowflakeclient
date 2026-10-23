#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <unistd.h>

#include "snowflake/client_config_parser.h"

// load_client_config() only takes a file path, so each input is written to a private 0600 scratch file.
extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  const char *tmp = getenv("TMPDIR");
  std::string path = std::string(tmp && *tmp ? tmp : "/tmp") + "/sf_client_config.XXXXXX";
  int fd = mkstemp(&path[0]);
  if (fd < 0)
  {
    return -1;
  }
  size_t off = 0;
  while (off < size)
  {
    ssize_t n = write(fd, data + off, size - off);
    if (n <= 0)
    {
      break;
    }
    off += static_cast<size_t>(n);
  }
  close(fd);

  client_config cfg;
  sf_bool ok = load_client_config(path.c_str(), &cfg);
  unlink(path.c_str());
  return ok ? 0 : -1;
}
