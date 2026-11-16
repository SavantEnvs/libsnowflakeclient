#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "util/Base64.hpp"

using Snowflake::Client::Util::Base64;

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  if (size < 1)
  {
    return -1;
  }
  const uint8_t mode = data[0];
  const char *src = reinterpret_cast<const char *>(data + 1);
  const size_t srcLen = size - 1;

  // Decode arbitrary text with the raw API; dstLength is the caller-visible capacity.
  std::vector<char> dst(Base64::decodedLength(srcLen) + 4);
  size_t cap = (mode & 1) ? dst.size() : dst.size() / 2;
  if (mode & 2)
  {
    Base64::decodeUrl(src, srcLen, dst.data(), cap);
  }
  else
  {
    Base64::decode(src, srcLen, dst.data(), cap);
  }

  // High level wrappers: any std::exception is how they reject bad input.
  try
  {
    std::string code(src, srcLen);
    if (mode & 4)
    {
      Base64::decodePadding(code);
    }
    else
    {
      Base64::decodeURLNoPadding(code);
    }
  }
  catch (const std::exception &)
  {
  }

  // Encoding must round-trip on the raw bytes.
  std::vector<char> bytes(src, src + srcLen);
  std::string padded = Base64::encodePadding(bytes);
  if (Base64::decodePadding(padded) != bytes)
  {
    __builtin_trap();
  }
  if (bytes.empty())
  {
    // encodeURLNoPadding({}) reads buffer[-1]: a real out-of-bounds read, written up in
    // mayhem/fuzz_base64/known-findings/. It is not called here because no caller in the tree encodes
    // an empty buffer (they pass JWT parts, digests and signatures), and the 1-byte input that would
    // reach it is the first one any fuzzer tries, so the decoders above would never get fuzzed.
    return 0;
  }
  std::string unpadded = Base64::encodeURLNoPadding(bytes);
  if (Base64::decodeURLNoPadding(unpadded) != bytes)
  {
    __builtin_trap();
  }
  return 0;
}
