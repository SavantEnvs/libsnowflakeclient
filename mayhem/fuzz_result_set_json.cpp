// Fuzzes what the client does with a query response from the server in the JSON result format: the
// "data" object of the response, i.e. {"rowtype":[{column},...], "rowset":[[cell,...],...]}.
//
// The server is the untrusted party here. lib/client.c (setup_result_with_json_resp) turns "rowtype"
// into the column descriptions with set_description(), hands "rowset" to rs_create_with_json_result(),
// and then snowflake_fetch()/snowflake_column_as_*() walk the rows through rs_next()/rs_get_cell_as_*().
// setup_result_with_json_resp() is static and only reachable after a network round trip, so this harness
// makes the same calls in the same order, on a statement created through the public API.
#include <cstddef>
#include <cstdint>
#include <cstdlib>

#include "snowflake/client.h"
#include "cJSON.h"
#include "connection.h"
#include "results.h"
#include "result_set.h"

extern "C" int LLVMFuzzerInitialize(int *, char ***)
{
  // "STDOUT" keeps the logger off the filesystem; FATAL keeps it quiet.
  snowflake_global_init("STDOUT", SF_LOG_FATAL, nullptr);
  return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  cJSON *resp = snowflake_cJSON_ParseWithLength(reinterpret_cast<const char *>(data), size);
  if (resp == nullptr)
  {
    return -1;
  }
  cJSON *rowtype = snowflake_cJSON_GetObjectItem(resp, "rowtype");
  cJSON *rowset = nullptr;
  if (!snowflake_cJSON_IsArray(rowtype) ||
      json_detach_array_from_object(&rowset, resp, "rowset") != SF_JSON_ERROR_NONE)
  {
    // The client rejects such a response before building a result set.
    snowflake_cJSON_Delete(resp);
    return -1;
  }

  // A connection and statement per input, so nothing carries over between inputs.
  SF_CONNECT *sf = snowflake_init();
  snowflake_set_attribute(sf, SF_CON_TIMEZONE, "UTC");
  SF_STMT *stmt = snowflake_stmt(sf);

  // As setup_result_with_json_resp() does; snowflake_stmt_term() frees desc using total_fieldcount.
  stmt->total_fieldcount = snowflake_cJSON_GetArraySize(rowtype);
  stmt->desc = set_description(stmt, rowtype);
  stmt->qrf = SF_JSON_FORMAT;
  stmt->result_set = rs_create_with_json_result(rowset, stmt->desc, SF_JSON_FORMAT, sf->timezone);

  // What an application does: fetch every row, read every column the statement reports.
  size_t rows = rs_get_row_count_in_chunk(stmt->result_set);
  char *buf = nullptr;
  size_t buf_len = 0, buf_cap = 0;
  for (size_t r = 0; r < rows; r++)
  {
    if (rs_next(stmt->result_set) != SF_STATUS_SUCCESS)
    {
      break;
    }
    for (int idx = 1; idx <= stmt->total_fieldcount; idx++)
    {
      sf_bool b;
      int8 i8;
      int32 i32;
      int64 i64;
      uint8 u8;
      uint32 u32;
      uint64 u64;
      float32 f32;
      float64 f64;
      size_t len;
      SF_TIMESTAMP ts;
      snowflake_column_is_null(stmt, idx, &b);
      snowflake_column_as_boolean(stmt, idx, &b);
      snowflake_column_as_int8(stmt, idx, &i8);
      snowflake_column_as_int32(stmt, idx, &i32);
      snowflake_column_as_int64(stmt, idx, &i64);
      snowflake_column_as_uint8(stmt, idx, &u8);
      snowflake_column_as_uint32(stmt, idx, &u32);
      snowflake_column_as_uint64(stmt, idx, &u64);
      snowflake_column_as_float32(stmt, idx, &f32);
      snowflake_column_as_float64(stmt, idx, &f64);
      snowflake_column_as_timestamp(stmt, idx, &ts);
      snowflake_column_strlen(stmt, idx, &len);
      const char *cstr = nullptr;
      snowflake_column_as_const_str(stmt, idx, &cstr);
      snowflake_column_as_str(stmt, idx, &buf, &buf_len, &buf_cap);
    }
  }
  free(buf);

  snowflake_stmt_term(stmt);
  snowflake_term(sf);
  snowflake_cJSON_Delete(resp);
  return 0;
}
