#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <unistd.h>
#include <sys/stat.h>

#include "snowflake/TomlConfigParser.hpp"

// load_toml_config() reads $SNOWFLAKE_HOME/connections.toml (which must be owner-only), so each input is
// written there inside a private scratch directory created once per process.
extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  static std::string dir;
  if (dir.empty())
  {
    const char *tmp = getenv("TMPDIR");
    std::string templ = std::string(tmp && *tmp ? tmp : "/tmp") + "/sf_toml_home.XXXXXX";
    if (mkdtemp(&templ[0]) == nullptr)
    {
      return -1;
    }
    dir = templ;
    setenv("SNOWFLAKE_HOME", dir.c_str(), 1);
    unsetenv("SNOWFLAKE_DEFAULT_CONNECTION_NAME");
  }
  std::string path = dir + "/connections.toml";
  FILE *f = fopen(path.c_str(), "wb");
  if (f == nullptr)
  {
    return -1;
  }
  fchmod(fileno(f), 0600);
  fwrite(data, 1, size, f);
  fclose(f);

  std::string dsn = load_toml_config_as_dsn();
  return dsn.empty() ? -1 : 0;
}
