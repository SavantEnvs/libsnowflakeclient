#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "cJSON.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  cJSON *root = snowflake_cJSON_ParseWithLength((const char *)data, size);
  if (root == NULL)
  {
    return -1;
  }
  char *pretty = snowflake_cJSON_Print(root);
  char *compact = snowflake_cJSON_PrintUnformatted(root);
  if (pretty == NULL || compact == NULL)
  {
    abort();
  }
  // Re-parsing the printed text must not crash (printing is lossy for NULs and doubles, so no equality check).
  cJSON *again = snowflake_cJSON_Parse(compact);
  cJSON *dup = snowflake_cJSON_Duplicate(root, 1);
  if (dup == NULL)
  {
    abort();
  }
  cJSON *item = snowflake_cJSON_GetObjectItem(root, "data");
  if (item != NULL)
  {
    (void)snowflake_cJSON_GetArraySize(item);
  }
  snowflake_cJSON_Delete(dup);
  snowflake_cJSON_Delete(again);
  snowflake_cJSON_free(compact);
  snowflake_cJSON_free(pretty);
  snowflake_cJSON_Delete(root);
  return 0;
}
