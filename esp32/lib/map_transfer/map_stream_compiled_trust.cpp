#include "map_stream_compiled_trust.hpp"

#include <array>
#include <cstdint>
#include <string>

namespace map_transfer {
namespace {

struct CompiledKey {
  const char *keyId;
  const char *publicKeyX963Hex;
};

// Rotation is additive: ship new public keys here before the backend starts
// signing with them, then remove retired keys only after old artifacts age out.
constexpr std::array<CompiledKey, 0> kCompiledKeys = {};

bool decodeHex(const char *hex, std::array<uint8_t, 65> &bytes) {
  if (hex == nullptr || std::char_traits<char>::length(hex) != bytes.size() * 2)
    return false;
  const auto nibble = [](char value) -> int {
    if (value >= '0' && value <= '9')
      return value - '0';
    if (value >= 'a' && value <= 'f')
      return value - 'a' + 10;
    if (value >= 'A' && value <= 'F')
      return value - 'A' + 10;
    return -1;
  };
  for (size_t index = 0; index < bytes.size(); index++) {
    const int high = nibble(hex[index * 2]);
    const int low = nibble(hex[index * 2 + 1]);
    if (high < 0 || low < 0)
      return false;
    bytes[index] = static_cast<uint8_t>((high << 4) | low);
  }
  return true;
}

} // namespace

MapStreamTrustStore compiledMapStreamTrustStore() {
  MapStreamTrustStore trust;
  for (const CompiledKey &key : kCompiledKeys) {
    std::array<uint8_t, 65> publicKey = {};
    if (!decodeHex(key.publicKeyX963Hex, publicKey) ||
        !trust.add(key.keyId, publicKey.data(), publicKey.size())) {
      return MapStreamTrustStore();
    }
  }
  return trust;
}

} // namespace map_transfer
