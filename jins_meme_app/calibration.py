from __future__ import annotations

from dataclasses import dataclass


@dataclass(slots=True)
class CalibrationSample:
    horizontal: float
    vertical: float
    target_x: float
    target_y: float


def solve_affine(samples: list[CalibrationSample]) -> dict[str, list[float]]:
    if len(samples) < 3:
        raise ValueError("At least 3 samples are required for calibration.")

    xtx = [[0.0] * 3 for _ in range(3)]
    xty_x = [0.0] * 3
    xty_y = [0.0] * 3

    for sample in samples:
        row = [sample.horizontal, sample.vertical, 1.0]
        for i in range(3):
            for j in range(3):
                xtx[i][j] += row[i] * row[j]
            xty_x[i] += row[i] * sample.target_x
            xty_y[i] += row[i] * sample.target_y

    return {
        "x": _gaussian_solve(xtx, xty_x),
        "y": _gaussian_solve(xtx, xty_y),
    }


def project(mapping: dict[str, list[float]], horizontal: float, vertical: float) -> tuple[float, float]:
    row = [horizontal, vertical, 1.0]
    x = sum(a * b for a, b in zip(mapping["x"], row, strict=True))
    y = sum(a * b for a, b in zip(mapping["y"], row, strict=True))
    return x, y


def _gaussian_solve(matrix: list[list[float]], vector: list[float]) -> list[float]:
    augmented = [row[:] + [value] for row, value in zip(matrix, vector, strict=True)]
    size = len(augmented)

    for col in range(size):
        pivot = max(range(col, size), key=lambda idx: abs(augmented[idx][col]))
        if abs(augmented[pivot][col]) < 1e-9:
            raise ValueError("Calibration samples are degenerate. Spread points further apart.")
        augmented[col], augmented[pivot] = augmented[pivot], augmented[col]

        pivot_value = augmented[col][col]
        for j in range(col, size + 1):
            augmented[col][j] /= pivot_value

        for row in range(size):
            if row == col:
                continue
            factor = augmented[row][col]
            for j in range(col, size + 1):
                augmented[row][j] -= factor * augmented[col][j]

    return [augmented[i][size] for i in range(size)]
