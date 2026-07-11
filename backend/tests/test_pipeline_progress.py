import sys
import unittest

from map_platform.pipeline import CommandRunner, parse_map_progress


class PipelineProgressTests(unittest.TestCase):
    def test_parse_map_progress(self):
        self.assertEqual(parse_map_progress("MAP_PROGRESS:24:100\n"), (24, 100))
        self.assertEqual(parse_map_progress("building\rMAP_PROGRESS:100:100\n"), (100, 100))
        self.assertIsNone(parse_map_progress("MAP_PROGRESS:101:100\n"))
        self.assertIsNone(parse_map_progress("unrelated output\n"))

    def test_streaming_runner_reports_output_before_completion(self):
        lines = []
        output = CommandRunner().run_streaming(
            [sys.executable, "-c", "print('MAP_PROGRESS:1:2', flush=True); print('MAP_PROGRESS:2:2', flush=True)"],
            on_output=lines.append,
        )

        self.assertEqual(
            [parse_map_progress(line) for line in lines],
            [(1, 2), (2, 2)],
        )
        self.assertIn("MAP_PROGRESS:2:2", output)


if __name__ == "__main__":
    unittest.main()
