from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import cv2
import numpy as np

from analysis_core import (
    VARIANTS,
    analyze_video,
    apply_variant,
    phash_similarity,
    ssim_score,
)


class AnalysisCoreTest(unittest.TestCase):
    def test_fixed_variants_keep_frame_shape(self) -> None:
        frame = np.zeros((90, 160, 3), dtype=np.uint8)
        frame[:, 20:75] = (20, 170, 240)
        for key, _ in VARIANTS:
            changed = apply_variant(frame, key, 3)
            self.assertEqual(changed.shape, frame.shape)
            self.assertEqual(changed.dtype, frame.dtype)

    def test_mirror_is_recovered_by_flip_aware_comparison(self) -> None:
        frame = np.zeros((90, 160, 3), dtype=np.uint8)
        cv2.circle(frame, (35, 44), 22, (10, 210, 240), -1)
        mirrored = apply_variant(frame, "mirror", 0)
        self.assertGreater(phash_similarity(frame, cv2.flip(mirrored, 1)), 0.99)
        self.assertLess(ssim_score(frame, mirrored), 0.9)

    def test_end_to_end_report_generation(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "sample.avi"
            writer = cv2.VideoWriter(
                str(source),
                cv2.VideoWriter_fourcc(*"MJPG"),
                10.0,
                (160, 90),
            )
            self.assertTrue(writer.isOpened())
            for index in range(20):
                frame = np.zeros((90, 160, 3), dtype=np.uint8)
                cv2.rectangle(
                    frame,
                    (index * 3, 18),
                    (index * 3 + 35, 70),
                    (30, 180, 240),
                    -1,
                )
                writer.write(frame)
            writer.release()

            results, files = analyze_video(
                str(source),
                str(root / "report"),
                max_seconds=2,
                sample_fps=2,
            )

            self.assertEqual(len(results), 4)
            self.assertTrue(Path(files["report"]).is_file())
            self.assertTrue(Path(files["csv"]).is_file())
            self.assertTrue(Path(files["preview"]).is_file())


if __name__ == "__main__":
    unittest.main()
