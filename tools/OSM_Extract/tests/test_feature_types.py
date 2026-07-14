import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from feature_types import get_type_id


class FeatureTypeTests(unittest.TestCase):
    def test_building_subtypes_remain_buildings(self):
        self.assertEqual(get_type_id("building.residential"), 100)
        self.assertEqual(get_type_id("building.service"), 100)
        self.assertEqual(get_type_id("building.apartments"), 100)

    def test_road_subtypes_keep_their_road_ids(self):
        self.assertEqual(get_type_id("highway.residential"), 7)
        self.assertEqual(get_type_id("highway.service"), 10)


if __name__ == "__main__":
    unittest.main()
