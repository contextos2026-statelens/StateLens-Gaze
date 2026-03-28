import Foundation

final class GazeEstimator {
    private(set) var smoothedHorizontal = 0.0
    private(set) var smoothedVertical = 0.0
    private(set) var hasSignal = false
    private(set) var calibration: AffineCalibration?

    let alpha: Double
    let stageWidth: Double
    let stageHeight: Double

    init(alpha: Double = 0.28, stageWidth: Double = 1280, stageHeight: Double = 720) {
        self.alpha = alpha
        self.stageWidth = stageWidth
        self.stageHeight = stageHeight
    }

    func ingest(_ frame: SensorFrame) -> GazePoint {
        if hasSignal {
            smoothedHorizontal = alpha * frame.horizontal + (1 - alpha) * smoothedHorizontal
            smoothedVertical = alpha * frame.vertical + (1 - alpha) * smoothedVertical
        } else {
            hasSignal = true
            smoothedHorizontal = frame.horizontal
            smoothedVertical = frame.vertical
        }
        return estimatePoint()
    }

    func estimatePoint() -> GazePoint {
        let rawPoint: GazePoint
        if let calibration {
            let row = [smoothedHorizontal, smoothedVertical, 1.0]
            let x = zip(calibration.x, row).map { $0 * $1 }.reduce(0, +)
            let y = zip(calibration.y, row).map { $0 * $1 }.reduce(0, +)
            rawPoint = GazePoint(x: x, y: y)
        } else {
            let x = (smoothedHorizontal + 1.0) * 0.5 * stageWidth
            let y = (1.0 - (smoothedVertical + 1.0) * 0.5) * stageHeight
            rawPoint = GazePoint(x: x, y: y)
        }
        return GazePoint(
            x: rawPoint.x.clamped(to: 0...stageWidth),
            y: rawPoint.y.clamped(to: 0...stageHeight)
        )
    }

    func solveCalibration(samples: [CalibrationSample]) throws {
        guard samples.count >= 3 else {
            throw EstimatorError.insufficientSamples
        }

        var xtx = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        var xtyX = Array(repeating: 0.0, count: 3)
        var xtyY = Array(repeating: 0.0, count: 3)

        for sample in samples {
            let row = [sample.horizontal, sample.vertical, 1.0]
            for i in 0..<3 {
                for j in 0..<3 {
                    xtx[i][j] += row[i] * row[j]
                }
                xtyX[i] += row[i] * sample.targetX
                xtyY[i] += row[i] * sample.targetY
            }
        }

        do {
            calibration = AffineCalibration(
                x: try gaussianSolve(xtx, xtyX),
                y: try gaussianSolve(xtx, xtyY)
            )
        } catch {
            // ノイズやサンプル偏りで行列が特異に近い場合、微小な正則化で解を安定化する。
            var regularized = xtx
            regularized[0][0] += 1e-4
            regularized[1][1] += 1e-4
            regularized[2][2] += 1e-4
            calibration = AffineCalibration(
                x: try gaussianSolve(regularized, xtyX),
                y: try gaussianSolve(regularized, xtyY)
            )
        }
    }

    func resetCalibration() {
        calibration = nil
    }

    private func gaussianSolve(_ matrix: [[Double]], _ vector: [Double]) throws -> [Double] {
        var augmented = zip(matrix, vector).map { row, value in
            row + [value]
        }

        for col in 0..<3 {
            var pivot = col
            for row in col..<3 where abs(augmented[row][col]) > abs(augmented[pivot][col]) {
                pivot = row
            }
            guard abs(augmented[pivot][col]) > 0.000_000_1 else {
                throw EstimatorError.degenerateSamples
            }
            augmented.swapAt(col, pivot)

            let divisor = augmented[col][col]
            for idx in col..<4 {
                augmented[col][idx] /= divisor
            }

            for row in 0..<3 where row != col {
                let factor = augmented[row][col]
                for idx in col..<4 {
                    augmented[row][idx] -= factor * augmented[col][idx]
                }
            }
        }

        return (0..<3).map { augmented[$0][3] }
    }
}

enum EstimatorError: LocalizedError {
    case insufficientSamples
    case degenerateSamples

    var errorDescription: String? {
        switch self {
        case .insufficientSamples:
            return "3点以上の較正サンプルが必要です。"
        case .degenerateSamples:
            return "較正点の分布が偏っているため係数を解けません。"
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
