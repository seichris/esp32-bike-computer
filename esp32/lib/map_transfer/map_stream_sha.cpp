#include "map_stream_sha.hpp"

#include <mbedtls/version.h>

namespace map_transfer {
namespace {

int shaStarts(mbedtls_sha256_context *context) {
#if MBEDTLS_VERSION_NUMBER < 0x03000000
  return mbedtls_sha256_starts_ret(context, 0);
#else
  return mbedtls_sha256_starts(context, 0);
#endif
}

int shaUpdate(mbedtls_sha256_context *context, const uint8_t *data,
              size_t size) {
#if MBEDTLS_VERSION_NUMBER < 0x03000000
  return mbedtls_sha256_update_ret(context, data, size);
#else
  return mbedtls_sha256_update(context, data, size);
#endif
}

int shaFinish(mbedtls_sha256_context *context, uint8_t digest[32]) {
#if MBEDTLS_VERSION_NUMBER < 0x03000000
  return mbedtls_sha256_finish_ret(context, digest);
#else
  return mbedtls_sha256_finish(context, digest);
#endif
}

} // namespace

MbedTlsMapStreamSha256::MbedTlsMapStreamSha256() {
  mbedtls_sha256_init(&context_);
}

MbedTlsMapStreamSha256::~MbedTlsMapStreamSha256() {
  mbedtls_sha256_free(&context_);
}

bool MbedTlsMapStreamSha256::reset() {
  active_ = shaStarts(&context_) == 0;
  return active_;
}

bool MbedTlsMapStreamSha256::update(const uint8_t *data, size_t size) {
  if (!active_ || (data == nullptr && size != 0))
    return false;
  if (size == 0)
    return true;
  if (shaUpdate(&context_, data, size) != 0) {
    active_ = false;
    return false;
  }
  return true;
}

bool MbedTlsMapStreamSha256::finish(std::array<uint8_t, 32> &digest) {
  if (!active_)
    return false;
  active_ = false;
  return shaFinish(&context_, digest.data()) == 0;
}

} // namespace map_transfer
