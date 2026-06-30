# Map Rotation Feature - Changes Summary

## Overview
Attempted to implement a map rotation feature (Course-Up mode) that rotates the map based on device heading. **The feature introduced regressions that broke core functionality.**

## Files Modified

### 1. `lib/maps/src/maps.cpp`
**Changes:**
- Added `RotationMode` enum and state variables (`rotationMode`, `rotationRad`)
- Added `toggleRotationMode()` method
- Modified `readVectorMap()` to rotate map polygons/lines
- Added click handler to `canvasArrow` (GPS indicator) to toggle rotation
- Added `LV_OBJ_FLAG_CLICKABLE` and `LV_OBJ_FLAG_EVENT_BUBBLE` to arrow
- Added legacy track drawing with rotation support
- Added `redrawMap = true` in `scrollMap()` (bug fix attempt)
- Passed `rotationRad` to `routeOverlay.drawRoute()`

### 2. `lib/maps/src/maps.hpp`
**Changes:**
- Added `RotationMode` enum declaration
- Added `rotationMode`, `rotationRad` member variables
- Added `toggleRotationMode()` method declaration

### 3. `lib/route_overlay/route_overlay.cpp`
**Changes:**
- Modified `drawRoute()` to accept `rotationRad` parameter
- Added rotation transformation logic
- Added watchdog/debug logging
- Changed local `Point16` struct to `LocalPoint16` to avoid conflicts

### 4. `lib/route_overlay/route_overlay.hpp`
**Changes:**
- Updated `drawRoute()` signature to include `rotationRad` parameter

### 5. `lib/gui/src/mainScr.cpp`
**Changes:**
- Modified `triggerMapRedraw()` to center on GPS when `followGps=true` (fix attempt)
- Added direct `generateVectorMap()`/`displayMap()` call on finger release (workaround)
- Added debug logging to `updateMainScreen()` and `updateMap()`

---

## What Broke

### 1. ❌ Map Dragging
- **Symptom:** Map wouldn't respond to drag gestures
- **Root Cause:** Timer-based update path (`updateMainScreen` → `updateMap`) was blocked
- **Workaround Applied:** Called map update directly on finger release
- **Side Effect:** GPS following now broken (see #2)

### 2. ❌ GPS Following (Map Auto-Center)
- **Symptom:** Map doesn't follow GPS position after drag fix
- **Root Cause:** The workaround that fixed drag may interfere with the GPS following logic

### 3. ⚠️ Navigation Position
- **Symptom:** Map centers on route's FROM city instead of actual GPS
- **Root Cause:** iOS app sends city-level geocoded position, not actual coordinates

---

## Recommendation
Revert all changes to these files and start fresh without the rotation feature. The core map functionality (dragging, GPS following) should work without these modifications.

### Git Commands to Revert
```bash
cd IceNav-v3
git checkout -- lib/maps/src/maps.cpp
git checkout -- lib/maps/src/maps.hpp  
git checkout -- lib/route_overlay/route_overlay.cpp
git checkout -- lib/route_overlay/route_overlay.hpp
git checkout -- lib/gui/src/mainScr.cpp
```

---

## Future Implementation Notes
If attempting rotation again:
1. Don't add click handlers to small overlay objects (they interfere with touch)
2. Investigate why `updateMainScreen` timer doesn't trigger `updateMap` properly
3. Keep `followGps` state management simple - don't override in multiple places
