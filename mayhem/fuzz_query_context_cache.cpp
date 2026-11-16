#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "cJSON.h"
#include "lib/ClientQueryContextCache.hpp"

using Snowflake::Client::ClientQueryContextCache;

// First byte picks the cache capacity (1..16); the rest is the server's `queryContext` JSON.
extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  if (size < 2)
  {
    return -1;
  }
  size_t capacity = (data[0] & 0x0f) + 1;
  cJSON *json = snowflake_cJSON_ParseWithLength(reinterpret_cast<const char *>(data + 1), size - 1);
  if (json == nullptr)
  {
    return -1;
  }

  ClientQueryContextCache cache(capacity);
  cache.deserializeQueryContext(json);
  cache.deserializeQueryContext(json);
  cache.deserializeQueryContextReq(json);

  cJSON *serialized = cache.serializeQueryContext();
  if (serialized != nullptr)
  {
    ClientQueryContextCache other(capacity);
    other.deserializeQueryContextReq(serialized);
    snowflake_cJSON_Delete(serialized);
  }

  std::vector<uint64> ids, stamps, prios;
  std::vector<std::string> ctxs;
  if (cache.getElements(ids, stamps, prios, ctxs) > capacity)
  {
    __builtin_trap();
  }
  snowflake_cJSON_Delete(json);
  return 0;
}
