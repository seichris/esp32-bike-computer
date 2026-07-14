#pragma once

#include "map_stream_format.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace map_transfer {

struct TrustedMapStreamKey {
  std::string keyId;
  std::array<uint8_t, 65> publicKeyX963 = {};
};

class MapStreamTrustStore {
public:
  bool add(const std::string &keyId, const uint8_t *publicKeyX963,
           size_t publicKeySize);
  const TrustedMapStreamKey *find(const std::string &keyId) const;
  bool verify(const uint8_t *manifest, size_t manifestSize,
              const MapStreamSignatureEnvelope &envelope) const;
  size_t size() const;

private:
  std::vector<TrustedMapStreamKey> keys_;
};

} // namespace map_transfer
