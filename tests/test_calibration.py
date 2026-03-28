import unittest

from jins_meme_app.calibration import CalibrationSample, project, solve_affine


class CalibrationTests(unittest.TestCase):
    def test_affine_solution_projects_training_points(self):
        samples = [
            CalibrationSample(horizontal=-1.0, vertical=-1.0, target_x=0.0, target_y=720.0),
            CalibrationSample(horizontal=1.0, vertical=-1.0, target_x=1280.0, target_y=720.0),
            CalibrationSample(horizontal=-1.0, vertical=1.0, target_x=0.0, target_y=0.0),
            CalibrationSample(horizontal=1.0, vertical=1.0, target_x=1280.0, target_y=0.0),
        ]

        mapping = solve_affine(samples)
        x, y = project(mapping, 0.0, 0.0)

        self.assertAlmostEqual(x, 640.0, places=5)
        self.assertAlmostEqual(y, 360.0, places=5)

    def test_affine_solution_requires_non_degenerate_points(self):
        samples = [
            CalibrationSample(horizontal=0.0, vertical=0.0, target_x=10.0, target_y=10.0),
            CalibrationSample(horizontal=0.0, vertical=0.0, target_x=20.0, target_y=20.0),
            CalibrationSample(horizontal=0.0, vertical=0.0, target_x=30.0, target_y=30.0),
        ]

        with self.assertRaises(ValueError):
            solve_affine(samples)


if __name__ == "__main__":
    unittest.main()
