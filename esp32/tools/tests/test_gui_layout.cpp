#include "../../lib/gui/src/guiLayout.hpp"

#include <cassert>

int main() {
  // 1.75-inch viewport: 466px screen with 100px reserved UI space.
  assert(gui_layout::mapScreenAnchorX(466, 466) == 233);
  assert(gui_layout::mapScreenAnchorY(466, 366) == 233);

  // 2.06-inch viewport: 502px screen with 72px reserved UI space.
  assert(gui_layout::mapScreenAnchorX(410, 410) == 205);
  assert(gui_layout::mapScreenAnchorY(502, 430) == 251);

  // Fullscreen maps use the same physical screen center.
  assert(gui_layout::mapScreenAnchorY(466, 466) == 233);
  assert(gui_layout::mapScreenAnchorY(502, 502) == 251);
  return 0;
}
