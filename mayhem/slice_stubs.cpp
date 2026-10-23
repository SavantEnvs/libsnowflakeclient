// The library slice built by mayhem/build.sh leaves out the connection/HTTP client (it needs curl with
// Snowflake's patched options, Arrow, and the AWS/Azure SDKs). cpp/util/SnowflakeCommon.cpp, which also holds
// helpers the slice does need, references these client symbols; nothing in the slice calls them.
#include <cstdlib>
#include <string>
#include <vector>
#include "snowflake/PlatformDetection.hpp"
#include "snowflake/client.h"
extern "C" {
#include "connection.h"
}

namespace Snowflake { namespace Client { namespace PlatformDetection {
void getDetectedPlatforms(std::vector<std::string>&, long) { std::abort(); }
}}}

extern "C" {
sf_bool is_string_empty(const char *) { std::abort(); }
void handle_single_param(SF_CONNECT *, const char *, const char *) { std::abort(); }
SF_CONNECT *STDCALL snowflake_init() { std::abort(); }
SF_STATUS STDCALL snowflake_term(SF_CONNECT *) { std::abort(); }
}
