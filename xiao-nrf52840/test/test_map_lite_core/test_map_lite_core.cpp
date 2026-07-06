#include <unity.h>

#include "map_lite_core.hpp"

namespace {

void testBlockPathFormattingMatchesExtractorLayout() {
  char path[72];

  xiao_round::map_lite_core::formatBlockPath(path, sizeof(path), "/VECTMAP",
                                             0, 0);
  TEST_ASSERT_EQUAL_STRING("/VECTMAP/+000+000/0_0.fmb", path);

  xiao_round::map_lite_core::formatBlockPath(path, sizeof(path), "/VECTMAP",
                                             65536, 0);
  TEST_ASSERT_EQUAL_STRING("/VECTMAP/+001+000/0_0.fmb", path);

  xiao_round::map_lite_core::formatBlockPath(path, sizeof(path), "/VECTMAP",
                                             -1, 0);
  TEST_ASSERT_EQUAL_STRING("/VECTMAP/-001+000/15_0.fmb", path);

  xiao_round::map_lite_core::formatBlockPath(path, sizeof(path), "/VECTMAP",
                                             -4097, -1);
  TEST_ASSERT_EQUAL_STRING("/VECTMAP/-001-001/14_15.fmb", path);

  xiao_round::map_lite_core::formatBlockPath(path, sizeof(path), "", 0, 0);
  TEST_ASSERT_EQUAL_STRING("/+000+000/0_0.fmb", path);
}

void testGpsProjectionRejectsInvalidAndMatchesMercatorScale() {
  int32_t x = 0;
  int32_t y = 0;

  TEST_ASSERT_FALSE(
      xiao_round::map_lite_core::gpsToMapMeters(0, 0, x, y));
  TEST_ASSERT_FALSE(
      xiao_round::map_lite_core::gpsToMapMeters(86000000, 0, x, y));

  TEST_ASSERT_TRUE(xiao_round::map_lite_core::gpsToMapMeters(1000000, 1000000,
                                                             x, y));
  TEST_ASSERT_INT32_WITHIN(2, 111319, x);
  TEST_ASSERT_INT32_WITHIN(2, 111325, y);
}

void testScreenMappingClampsAndInvertsY() {
  TEST_ASSERT_EQUAL_INT16(
      0, xiao_round::map_lite_core::localMapCoordToScreen(0, false));
  TEST_ASSERT_EQUAL_INT16(
      239, xiao_round::map_lite_core::localMapCoordToScreen(4095, false));
  TEST_ASSERT_EQUAL_INT16(
      239, xiao_round::map_lite_core::localMapCoordToScreen(-10, true));
  TEST_ASSERT_EQUAL_INT16(
      0, xiao_round::map_lite_core::localMapCoordToScreen(5000, true));
}

void testCandidateClassificationUsesVersionTwoTypeIds() {
  TEST_ASSERT_FALSE(xiao_round::map_lite_core::isCandidatePolyline(1, 3));
  TEST_ASSERT_TRUE(xiao_round::map_lite_core::isCandidatePolyline(2, 3));
  TEST_ASSERT_TRUE(xiao_round::map_lite_core::isCandidatePolyline(2, 51));
  TEST_ASSERT_TRUE(xiao_round::map_lite_core::isCandidatePolyline(2, 152));
  TEST_ASSERT_TRUE(xiao_round::map_lite_core::isCandidatePolyline(2, 210));
  TEST_ASSERT_FALSE(xiao_round::map_lite_core::isCandidatePolyline(2, 120));

  TEST_ASSERT_FALSE(xiao_round::map_lite_core::isCandidatePolygon(1, 152));
  TEST_ASSERT_TRUE(xiao_round::map_lite_core::isCandidatePolygon(2, 150));
  TEST_ASSERT_TRUE(xiao_round::map_lite_core::isCandidatePolygon(2, 199));
  TEST_ASSERT_FALSE(xiao_round::map_lite_core::isCandidatePolygon(2, 200));
}

void testDecisionThresholdsExposeGoNoGoReasons() {
  xiao_round::map_lite_core::ProbeStats stats;
  TEST_ASSERT_EQUAL(xiao_round::map_lite_core::Decision::Invalid,
                    xiao_round::map_lite_core::decide(stats));

  stats.headerValid = true;
  stats.scanValid = true;
  TEST_ASSERT_EQUAL(xiao_round::map_lite_core::Decision::NoData,
                    xiao_round::map_lite_core::decide(stats));

  stats.candidatePolylineCount = 1;
  TEST_ASSERT_EQUAL(xiao_round::map_lite_core::Decision::Candidate,
                    xiao_round::map_lite_core::decide(stats));

  stats.scanMs = xiao_round::map_lite_core::INTERACTION_BUDGET_MS + 1;
  TEST_ASSERT_EQUAL(xiao_round::map_lite_core::Decision::TooSlow,
                    xiao_round::map_lite_core::decide(stats));

  stats.scanMs = 0;
  stats.candidatePolylineCount =
      xiao_round::map_lite_core::CANDIDATE_FEATURE_BUDGET + 1;
  TEST_ASSERT_EQUAL(xiao_round::map_lite_core::Decision::TooComplex,
                    xiao_round::map_lite_core::decide(stats));

  stats.candidatePolylineCount = 1;
  stats.candidatePointCount =
      xiao_round::map_lite_core::CANDIDATE_POINT_BUDGET + 1;
  TEST_ASSERT_EQUAL(xiao_round::map_lite_core::Decision::TooComplex,
                    xiao_round::map_lite_core::decide(stats));
}

void testDecisionNamesMatchDiagnosticsLabels() {
  TEST_ASSERT_EQUAL_STRING(
      "unknown", xiao_round::map_lite_core::decisionName(
                     xiao_round::map_lite_core::Decision::Unknown));
  TEST_ASSERT_EQUAL_STRING(
      "no-data", xiao_round::map_lite_core::decisionName(
                     xiao_round::map_lite_core::Decision::NoData));
  TEST_ASSERT_EQUAL_STRING(
      "candidate", xiao_round::map_lite_core::decisionName(
                       xiao_round::map_lite_core::Decision::Candidate));
  TEST_ASSERT_EQUAL_STRING(
      "too-slow", xiao_round::map_lite_core::decisionName(
                      xiao_round::map_lite_core::Decision::TooSlow));
  TEST_ASSERT_EQUAL_STRING(
      "too-complex", xiao_round::map_lite_core::decisionName(
                         xiao_round::map_lite_core::Decision::TooComplex));
  TEST_ASSERT_EQUAL_STRING(
      "invalid", xiao_round::map_lite_core::decisionName(
                     xiao_round::map_lite_core::Decision::Invalid));
}

void testMapLiteExperimentDefaultsOffUntilHardwareEvidenceOptsIn() {
  TEST_ASSERT_FALSE(xiao_round::map_lite_core::DEFAULT_EXPERIMENT_ENABLED);
}

} // namespace

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(testBlockPathFormattingMatchesExtractorLayout);
  RUN_TEST(testGpsProjectionRejectsInvalidAndMatchesMercatorScale);
  RUN_TEST(testScreenMappingClampsAndInvertsY);
  RUN_TEST(testCandidateClassificationUsesVersionTwoTypeIds);
  RUN_TEST(testDecisionThresholdsExposeGoNoGoReasons);
  RUN_TEST(testDecisionNamesMatchDiagnosticsLabels);
  RUN_TEST(testMapLiteExperimentDefaultsOffUntilHardwareEvidenceOptsIn);
  return UNITY_END();
}
