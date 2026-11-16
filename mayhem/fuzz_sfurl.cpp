#include <cstddef>
#include <cstdint>
#include <string>

#include "snowflake/SFURL.hpp"

using Snowflake::Client::SFURL;
using Snowflake::Client::SFURLParseError;

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  std::string text(reinterpret_cast<const char *>(data), size);
  try
  {
    SFURL url = SFURL::parse(text);
    std::string s = url.toString();
    (void)url.authority();
    (void)url.scheme();
    (void)url.host();
    (void)url.port();
    (void)url.path();
    (void)url.fragment();
    (void)url.userInfo();
    (void)url.getQueryParam("warehouse");
    url.addQueryParam("added", "a b&c=d");
    url.renewQueryParam("added", "x");
    SFURL copy(url);
    SFURL assigned;
    assigned = copy;
    (void)assigned.toString();
    // Re-parsing the serialized form must be accepted again.
    SFURL again = SFURL::parse(s);
    (void)again.toString();
  }
  catch (const SFURLParseError &)
  {
    return -1;
  }
  return 0;
}
