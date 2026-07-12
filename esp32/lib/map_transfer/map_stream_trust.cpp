#include "map_stream_trust.hpp"

#include "map_stream_crypto.hpp"

#include <algorithm>
#include <utility>

namespace map_transfer {

bool MapStreamTrustStore::add(const std::string &keyId,
                              const uint8_t *publicKeyX963,
                              size_t publicKeySize) {
  if (keyId.empty() || keyId.size() > MAP_STREAM_MAX_KEY_ID_BYTES ||
      publicKeyX963 == nullptr || publicKeySize != 65 ||
      !isValidMapStreamP256PublicKey(publicKeyX963, publicKeySize) ||
      find(keyId) != nullptr) {
    return false;
  }
  if (!std::all_of(keyId.begin(), keyId.end(), [](unsigned char character) {
        return (character >= 'a' && character <= 'z') ||
               (character >= 'A' && character <= 'Z') ||
               (character >= '0' && character <= '9') || character == '.' ||
               character == '_' || character == '-';
      })) {
    return false;
  }
  TrustedMapStreamKey key;
  key.keyId = keyId;
  std::copy(publicKeyX963, publicKeyX963 + publicKeySize,
            key.publicKeyX963.begin());
  keys_.push_back(std::move(key));
  return true;
}

const TrustedMapStreamKey *
MapStreamTrustStore::find(const std::string &keyId) const {
  const auto match = std::find_if(
      keys_.begin(), keys_.end(),
      [&keyId](const TrustedMapStreamKey &key) { return key.keyId == keyId; });
  return match == keys_.end() ? nullptr : &*match;
}

bool MapStreamTrustStore::verify(
    const uint8_t *manifest, size_t manifestSize,
    const MapStreamSignatureEnvelope &envelope) const {
  const TrustedMapStreamKey *key = find(envelope.keyId);
  return key != nullptr &&
         verifyMapStreamP256Signature(manifest, manifestSize, envelope,
                                      key->publicKeyX963.data(),
                                      key->publicKeyX963.size());
}

size_t MapStreamTrustStore::size() const { return keys_.size(); }

} // namespace map_transfer
