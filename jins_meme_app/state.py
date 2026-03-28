from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field
from time import time

from .calibration import CalibrationSample, project, solve_affine


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


@dataclass(slots=True)
class AppState:
    history_limit: int = 180
    ema_alpha: float = 0.28
    width: int = 1280
    height: int = 720
    latest_payload: dict = field(default_factory=dict)
    smoothed_horizontal: float = 0.0
    smoothed_vertical: float = 0.0
    has_signal: bool = False
    mapping: dict[str, list[float]] | None = None
    calibration_samples: list[CalibrationSample] = field(default_factory=list)
    gaze_history: deque = field(init=False)

    def __post_init__(self) -> None:
        self.gaze_history = deque(maxlen=self.history_limit)

    def ingest(self, payload: dict) -> dict:
        measurement = self._normalize_measurement(payload)
        horizontal = measurement["horizontal"]
        vertical = measurement["vertical"]

        if not self.has_signal:
            self.smoothed_horizontal = horizontal
            self.smoothed_vertical = vertical
            self.has_signal = True
        else:
            alpha = self.ema_alpha
            self.smoothed_horizontal = alpha * horizontal + (1 - alpha) * self.smoothed_horizontal
            self.smoothed_vertical = alpha * vertical + (1 - alpha) * self.smoothed_vertical

        point_x, point_y = self.estimate_point()
        state = {
            "timestamp": time(),
            "raw": measurement,
            "smooth": {
                "horizontal": self.smoothed_horizontal,
                "vertical": self.smoothed_vertical,
            },
            "gaze": {
                "x": point_x,
                "y": point_y,
                "normalizedX": point_x / self.width,
                "normalizedY": point_y / self.height,
            },
            "calibrated": self.mapping is not None,
            "samples": len(self.calibration_samples),
            "screen": {"width": self.width, "height": self.height},
        }
        self.latest_payload = state
        self.gaze_history.append(
            {
                "timestamp": state["timestamp"],
                "x": point_x,
                "y": point_y,
                "blinkStrength": measurement["blinkStrength"],
            }
        )
        return state

    def estimate_point(self) -> tuple[float, float]:
        if self.mapping is not None:
            x, y = project(self.mapping, self.smoothed_horizontal, self.smoothed_vertical)
        else:
            x = (self.smoothed_horizontal + 1.0) * 0.5 * self.width
            y = (1.0 - (self.smoothed_vertical + 1.0) * 0.5) * self.height
        return _clamp(x, 0.0, self.width), _clamp(y, 0.0, self.height)

    def add_calibration_sample(self, target_x: float, target_y: float) -> dict:
        self.calibration_samples.append(
            CalibrationSample(
                horizontal=self.smoothed_horizontal,
                vertical=self.smoothed_vertical,
                target_x=target_x,
                target_y=target_y,
            )
        )
        return {
            "samples": len(self.calibration_samples),
            "latest": {
                "horizontal": self.smoothed_horizontal,
                "vertical": self.smoothed_vertical,
                "targetX": target_x,
                "targetY": target_y,
            },
        }

    def solve_calibration(self) -> dict:
        self.mapping = solve_affine(self.calibration_samples)
        return {
            "mapping": self.mapping,
            "samples": len(self.calibration_samples),
        }

    def clear_calibration(self) -> dict:
        self.calibration_samples.clear()
        self.mapping = None
        return {"ok": True}

    def snapshot(self) -> dict:
        return {
            "latest": self.latest_payload,
            "history": list(self.gaze_history),
            "samples": len(self.calibration_samples),
            "calibrated": self.mapping is not None,
            "screen": {"width": self.width, "height": self.height},
        }

    def _normalize_measurement(self, payload: dict) -> dict:
        horizontal = payload.get("horizontal")
        vertical = payload.get("vertical")

        if horizontal is None:
            right = float(payload.get("eogRight", payload.get("right", 0.0)))
            left = float(payload.get("eogLeft", payload.get("left", 0.0)))
            horizontal = right - left

        if vertical is None:
            upper = float(payload.get("eogUpper", payload.get("upper", 0.0)))
            lower = float(payload.get("eogLower", payload.get("lower", 0.0)))
            vertical = upper - lower

        horizontal = float(horizontal)
        vertical = float(vertical)

        gain_h = float(payload.get("gainHorizontal", 1.0))
        gain_v = float(payload.get("gainVertical", 1.0))

        normalized_h = _clamp(horizontal * gain_h, -1.0, 1.0)
        normalized_v = _clamp(vertical * gain_v, -1.0, 1.0)

        return {
            "horizontal": normalized_h,
            "vertical": normalized_v,
            "blinkStrength": float(payload.get("blinkStrength", 0.0)),
            "sourceTimestamp": payload.get("timestamp"),
        }
