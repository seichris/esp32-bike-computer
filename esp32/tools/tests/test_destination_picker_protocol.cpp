#include "../../lib/ble_navigation/destination_picker_protocol.hpp"

#include <cassert>
#include <cstdint>
#include <string>
#include <vector>

using destination_picker_protocol::CatalogReassembler;
using destination_picker_protocol::ChunkResult;

static std::vector<uint8_t> chunk(uint8_t transferId, uint8_t index,
                                  uint8_t count, const std::string &payload) {
  std::vector<uint8_t> result{'D', 'L', 'S', 'T', transferId, index, count};
  result.insert(result.end(), payload.begin(), payload.end());
  return result;
}

int main() {
  static_assert(destination_picker_protocol::MAX_FAVORITES == 3);
  static_assert(destination_picker_protocol::MAX_RECENTS == 5);
  static_assert(destination_picker_protocol::MAX_ITEMS == 8);
  static_assert(destination_picker_protocol::REQUEST_TIMEOUT_MS == 15000);
  static_assert(destination_picker_protocol::TERMINAL_STATUS_DISPLAY_MS ==
                5000);

  CatalogReassembler reassembler;
  auto first = chunk(7, 0, 2, "{\"version\":1,");
  auto second = chunk(7, 1, 2, "\"items\":[]}");
  assert(reassembler.consume(first.data(), first.size(), 100) ==
         ChunkResult::Accepted);
  assert(reassembler.consume(second.data(), second.size(), 110) ==
         ChunkResult::Complete);
  assert(reassembler.payload() == "{\"version\":1,\"items\":[]}");

  reassembler.reset();
  assert(reassembler.consume(second.data(), second.size(), 200) ==
         ChunkResult::Rejected);
  assert(!reassembler.active());

  assert(reassembler.consume(first.data(), first.size(), 300) ==
         ChunkResult::Accepted);
  auto wrongOrder = chunk(7, 0, 2, "replacement");
  assert(reassembler.consume(wrongOrder.data(), wrongOrder.size(), 310) ==
         ChunkResult::Accepted);
  assert(reassembler.payload() == "replacement");

  assert(reassembler.expire(
      310 + destination_picker_protocol::CHUNK_TIMEOUT_MS + 1));
  assert(!reassembler.active());

  auto oversizedCount = chunk(
      1, 0, destination_picker_protocol::MAX_CHUNK_COUNT + 1, "x");
  assert(reassembler.consume(oversizedCount.data(), oversizedCount.size(),
                             400) == ChunkResult::Rejected);

  uint8_t encoded[6]{};
  destination_picker_protocol::writeUInt32LE(0xA1B2C3D4, encoded);
  destination_picker_protocol::writeUInt16LE(0xE5F6, encoded + 4);
  assert(destination_picker_protocol::readUInt32LE(encoded) == 0xA1B2C3D4);
  assert(destination_picker_protocol::readUInt16LE(encoded + 4) == 0xE5F6);

  const std::string validUtf8 = "Cafe \xE9\xAA\x91\xF0\x9F\x9A\xB2";
  assert(destination_picker_protocol::isValidUtf8(validUtf8.data(),
                                                   validUtf8.size()));
  const char truncatedUtf8[] = {static_cast<char>(0xE9),
                                static_cast<char>(0xAA)};
  assert(!destination_picker_protocol::isValidUtf8(truncatedUtf8,
                                                    sizeof(truncatedUtf8)));
  const char overlongUtf8[] = {static_cast<char>(0xC0),
                               static_cast<char>(0xAF)};
  assert(!destination_picker_protocol::isValidUtf8(overlongUtf8,
                                                    sizeof(overlongUtf8)));

  return 0;
}
