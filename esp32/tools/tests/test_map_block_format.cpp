#include "../../lib/maps/src/mapBlockFormat.hpp"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

int main() {
  const std::vector<uint8_t> emptyV1 = {'F', 'M', 'B', 1, 0, 0, 0, 0};
  assert(map_block_format::validate(emptyV1.data(), emptyV1.size()));
  const std::vector<uint8_t> valid = {
      'F', 'M', 'B', 2,
      1,   0,                         // one polygon
      0x34, 0x12, 15, 100,           // color, zoom, type
      0, 0, 0, 0, 10, 0, 10, 0,     // bbox
      2, 0, 0, 0, 0, 0, 10, 0, 10, 0, // points
      1, 0,                           // one polyline
      0x34, 0x12, 2, 15, 7,          // color, width, zoom, type
      0, 0, 0, 0, 10, 0, 10, 0,     // bbox
      1, 0, 5, 0, 5, 0};             // point
  assert(map_block_format::validate(valid.data(), valid.size()));
  for (size_t size = 0; size < valid.size(); ++size)
    assert(!map_block_format::validate(valid.data(), size));

  auto changed = valid;
  changed[3] = 3;
  assert(!map_block_format::validate(changed.data(), changed.size()));
  changed = valid;
  changed.push_back(0);
  assert(!map_block_format::validate(changed.data(), changed.size()));
  changed = valid;
  changed[18] = 0xff;
  changed[19] = 0xff;
  assert(!map_block_format::validate(changed.data(), changed.size()));

  const std::vector<uint8_t> tooManyFeatures = {'F', 'M', 'B', 1,
                                                 1,   0x40};
  map_block_format::StreamValidator featureBudget("tile.fmb");
  assert(!featureBudget.feed(tooManyFeatures.data(),
                             tooManyFeatures.size()));
  std::vector<uint8_t> oversized(map_block_format::kMaximumBlockBytes + 1,
                                 0);
  map_block_format::StreamValidator byteBudget("tile.fmb");
  assert(!byteBudget.feed(oversized.data(), oversized.size()));
  std::string pointHeavy =
      "Polygons:1\n0x1\n15\nbbox:0,0,1,1\ncoords:";
  for (uint32_t index = 0; index <= map_block_format::kMaximumPoints; ++index)
    pointHeavy += "0,0;";
  pointHeavy += "\nPolylines:0\n";
  map_block_format::StreamValidator pointBudget("tile.fmp");
  assert(!pointBudget.feed(
      reinterpret_cast<const uint8_t *>(pointHeavy.data()),
      pointHeavy.size()));

  std::vector<uint8_t> gridHeavy = {'F', 'M', 'B', 1, 1, 4};
  for (uint32_t index = 0;
       index <= map_block_format::kMaximumPolygonGridEntries / 256U;
       ++index) {
    const std::vector<uint8_t> polygon = {
        0, 0, 15,                    // color, zoom
        0, 0, 0, 0, 0xff, 0x0f, 0xff, 0x0f, // full-grid bbox
        1, 0, 0, 0, 0, 0};          // one point
    gridHeavy.insert(gridHeavy.end(), polygon.begin(), polygon.end());
  }
  gridHeavy.push_back(0);
  gridHeavy.push_back(0);
  map_block_format::StreamValidator gridBudget("tile.fmb");
  assert(!gridBudget.feed(gridHeavy.data(), gridHeavy.size()));

  map_block_format::StreamValidator binaryStream("tile.fmb");
  for (const uint8_t byte : valid)
    assert(binaryStream.feed(&byte, 1));
  assert(binaryStream.finish());

  const std::string legacyAscii =
      "Polygons:1\n0x1234\n15\nbbox:-1,-2,3,4\ncoords:-1,-2;3,4;\n"
      "Polylines:1\n0x5678\n2\n14\nbbox:0,0,5,6\ncoords:0,0;5,6;\n";
  map_block_format::StreamValidator legacy("tile.fmp");
  for (const char byte : legacyAscii)
    assert(legacy.feed(reinterpret_cast<const uint8_t *>(&byte), 1));
  assert(legacy.finish());

  std::string missingFinalNewline = legacyAscii;
  missingFinalNewline.pop_back();
  map_block_format::StreamValidator missingNewline("tile.fmp");
  assert(missingNewline.feed(
      reinterpret_cast<const uint8_t *>(missingFinalNewline.data()),
      missingFinalNewline.size()));
  assert(!missingNewline.finish());

  std::string uppercaseColor = legacyAscii;
  uppercaseColor.replace(uppercaseColor.find("0x1234"), 2, "0X");
  map_block_format::StreamValidator uppercase("tile.fmp");
  assert(!uppercase.feed(
      reinterpret_cast<const uint8_t *>(uppercaseColor.data()),
      uppercaseColor.size()));

  const std::string typedAscii =
      "Polygons:1\n0x1234\n15\n101\nbbox:-1,-2,3,4\ncoords:-1,-2;3,4;\n"
      "Polylines:1\n0x5678\n2\n14\n7\nbbox:0,0,5,6\ncoords:0,0;5,6;\n";
  map_block_format::StreamValidator typed("tile.fmp");
  assert(typed.feed(reinterpret_cast<const uint8_t *>(typedAscii.data()),
                    typedAscii.size()));
  assert(typed.finish());

  for (const std::string &invalid : {
           std::string("Polygons:0\n"),
           std::string("Polygons:1\n0x1\n15\nbbox:0,0,1,1\ncoords:\n") +
               "Polylines:0\n",
           std::string("Polygons:1\n0x1\n15\nbbox:999999999999999999,0,1,1\n") +
               "coords:0,0;\nPolylines:0\n",
           std::string("Polygons:1\n0x1\n15\nbbox:0,0,1,1\n") +
               "coords:999999999999999999,0;\nPolylines:0\n",
           typedAscii + "x",
       }) {
    map_block_format::StreamValidator rejected("tile.fmp");
    const bool fed = rejected.feed(
        reinterpret_cast<const uint8_t *>(invalid.data()), invalid.size());
    assert(!fed || !rejected.finish());
  }

  std::cout << "map block format tests passed\n";
  return 0;
}
