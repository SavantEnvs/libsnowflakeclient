# Base64::encodeURLNoPadding reads one byte before its buffer on empty input

**Where:** `cpp/util/Base64.cpp`, `Base64::encodeURLNoPadding`:

```cpp
size_t len = encodeUrl(bytes.data(), bytes.size(), (void *) buffer.data());
// remove the end of padding
while (buffer[len - 1] == '=') len--;
```

**Cause:** for an empty `bytes`, `len` is 0, so `buffer[len - 1]` is `buffer[SIZE_MAX]` on an empty
`std::string`: an out-of-bounds read one byte before the string's storage (undefined behaviour; UBSan
and ASan both report it).

**Impact:** low. Every caller in the tree passes non-empty data (a serialized JWT header or claim set,
a SHA-256 digest, random bytes, or a signature: `cpp/jwt/Signer.cpp`, `cpp/jwt/ClaimSet.hpp`,
`cpp/jwt/Header.hpp`, `cpp/lib/AuthenticationChallengeProvider.cpp`, `cpp/lib/Authenticator.cpp`), and
the argument is produced by the client, not taken from the network. It is reachable only by a caller
of the public `IBase64::encodeURLNoPadding` that passes an empty vector.

**Fix (one line):** `while (len > 0 && buffer[len - 1] == '=') len--;`

**Reproduce:** there is no input file, because `mayhem/fuzz_base64.cpp` does not call
`encodeURLNoPadding` with an empty vector: the 1-byte input that would do so is also the first input
any fuzzer tries, and a target that aborts on it never gets to fuzz the decoders. To see the report,
call `Snowflake::Client::Util::Base64::encodeURLNoPadding({})` from a sanitized build.
