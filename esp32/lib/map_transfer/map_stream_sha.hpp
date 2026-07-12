#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include <mbedtls/sha256.h>

namespace map_transfer {

class MapStreamSha256 {
public:
  virtual ~MapStreamSha256() = default;
  virtual bool reset() = 0;
  virtual bool update(const uint8_t *data, size_t size) = 0;
  virtual bool finish(std::array<uint8_t, 32> &digest) = 0;
};

// ESP-IDF routes this mbedTLS API through the target's configured SHA hardware
// acceleration. Host tests use the same interface with the host mbedTLS build.
class MbedTlsMapStreamSha256 final : public MapStreamSha256 {
public:
  MbedTlsMapStreamSha256();
  ~MbedTlsMapStreamSha256() override;

  bool reset() override;
  bool update(const uint8_t *data, size_t size) override;
  bool finish(std::array<uint8_t, 32> &digest) override;

private:
  mbedtls_sha256_context context_;
  bool active_ = false;
};

} // namespace map_transfer
