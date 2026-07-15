#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace destination_picker_protocol {

static constexpr uint8_t CAPABILITY_MASK = 1 << 6;
static constexpr uint8_t CLIENT_VERSION = 5;
static constexpr uint8_t CATALOG_VERSION = 1;
static constexpr size_t CHUNK_HEADER_SIZE = 7;
static constexpr uint8_t MAX_CHUNK_COUNT = 160;
static constexpr size_t MAX_CATALOG_BYTES = 4096;
static constexpr uint8_t MAX_FAVORITES = 8;
static constexpr uint8_t MAX_RECENTS = 5;
static constexpr uint8_t MAX_ITEMS = MAX_FAVORITES + MAX_RECENTS;
static constexpr size_t MAX_LABEL_BYTES = 64;
static constexpr uint32_t CHUNK_TIMEOUT_MS = 5000;

enum class ChunkResult : uint8_t {
  Rejected,
  Accepted,
  Complete,
};

class CatalogReassembler {
public:
  ChunkResult consume(const uint8_t *data, size_t size, uint32_t nowMs) {
    if (data == nullptr || size <= CHUNK_HEADER_SIZE || data[0] != 'D' ||
        data[1] != 'L' || data[2] != 'S' || data[3] != 'T') {
      return ChunkResult::Rejected;
    }

    const uint8_t transferId = data[4];
    const uint8_t chunkIndex = data[5];
    const uint8_t chunkCount = data[6];
    if (chunkCount == 0 || chunkCount > MAX_CHUNK_COUNT ||
        chunkIndex >= chunkCount) {
      reset();
      return ChunkResult::Rejected;
    }

    if (!active_ || expired(nowMs)) {
      reset();
      if (chunkIndex != 0) {
        return ChunkResult::Rejected;
      }
      active_ = true;
      transferId_ = transferId;
      chunkCount_ = chunkCount;
    } else if (transferId != transferId_ || chunkCount != chunkCount_ ||
               chunkIndex != nextChunkIndex_) {
      // A new chunk zero may supersede an interrupted transfer. Any other
      // discontinuity is rejected without exposing partial payload data.
      reset();
      if (chunkIndex != 0) {
        return ChunkResult::Rejected;
      }
      active_ = true;
      transferId_ = transferId;
      chunkCount_ = chunkCount;
    }

    const size_t payloadSize = size - CHUNK_HEADER_SIZE;
    if (payload_.size() + payloadSize > MAX_CATALOG_BYTES) {
      reset();
      return ChunkResult::Rejected;
    }

    payload_.append(reinterpret_cast<const char *>(data + CHUNK_HEADER_SIZE),
                    payloadSize);
    nextChunkIndex_++;
    lastChunkMs_ = nowMs;
    return nextChunkIndex_ == chunkCount_ ? ChunkResult::Complete
                                          : ChunkResult::Accepted;
  }

  bool expire(uint32_t nowMs) {
    if (!active_ || !expired(nowMs)) {
      return false;
    }
    reset();
    return true;
  }

  const std::string &payload() const { return payload_; }
  bool active() const { return active_; }

  void reset() {
    active_ = false;
    transferId_ = 0;
    chunkCount_ = 0;
    nextChunkIndex_ = 0;
    lastChunkMs_ = 0;
    payload_.clear();
  }

private:
  bool expired(uint32_t nowMs) const {
    return active_ && static_cast<uint32_t>(nowMs - lastChunkMs_) >
                          CHUNK_TIMEOUT_MS;
  }

  bool active_ = false;
  uint8_t transferId_ = 0;
  uint8_t chunkCount_ = 0;
  uint8_t nextChunkIndex_ = 0;
  uint32_t lastChunkMs_ = 0;
  std::string payload_;
};

inline uint32_t readUInt32LE(const uint8_t *data) {
  return static_cast<uint32_t>(data[0]) |
         (static_cast<uint32_t>(data[1]) << 8) |
         (static_cast<uint32_t>(data[2]) << 16) |
         (static_cast<uint32_t>(data[3]) << 24);
}

inline uint16_t readUInt16LE(const uint8_t *data) {
  return static_cast<uint16_t>(data[0]) |
         (static_cast<uint16_t>(data[1]) << 8);
}

inline void writeUInt32LE(uint32_t value, uint8_t *data) {
  data[0] = static_cast<uint8_t>(value);
  data[1] = static_cast<uint8_t>(value >> 8);
  data[2] = static_cast<uint8_t>(value >> 16);
  data[3] = static_cast<uint8_t>(value >> 24);
}

inline void writeUInt16LE(uint16_t value, uint8_t *data) {
  data[0] = static_cast<uint8_t>(value);
  data[1] = static_cast<uint8_t>(value >> 8);
}

inline bool isValidUtf8(const char *data, size_t size) {
  if (data == nullptr) {
    return size == 0;
  }
  size_t index = 0;
  while (index < size) {
    const uint8_t first = static_cast<uint8_t>(data[index++]);
    if (first <= 0x7F) {
      continue;
    }

    uint32_t codePoint = 0;
    size_t continuationCount = 0;
    uint32_t minimum = 0;
    if ((first & 0xE0) == 0xC0) {
      codePoint = first & 0x1F;
      continuationCount = 1;
      minimum = 0x80;
    } else if ((first & 0xF0) == 0xE0) {
      codePoint = first & 0x0F;
      continuationCount = 2;
      minimum = 0x800;
    } else if ((first & 0xF8) == 0xF0) {
      codePoint = first & 0x07;
      continuationCount = 3;
      minimum = 0x10000;
    } else {
      return false;
    }
    if (index + continuationCount > size) {
      return false;
    }
    for (size_t i = 0; i < continuationCount; i++) {
      const uint8_t next = static_cast<uint8_t>(data[index++]);
      if ((next & 0xC0) != 0x80) {
        return false;
      }
      codePoint = (codePoint << 6) | (next & 0x3F);
    }
    if (codePoint < minimum || codePoint > 0x10FFFF ||
        (codePoint >= 0xD800 && codePoint <= 0xDFFF)) {
      return false;
    }
  }
  return true;
}

} // namespace destination_picker_protocol
