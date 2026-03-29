import SwiftUI

struct MiniLineChartView: View {
    let data: [Double]
    let color: Color
    let lineWidth: CGFloat

    init(data: [Double], color: Color = .blue, lineWidth: CGFloat = 1.5) {
        self.data = data
        self.color = color
        self.lineWidth = lineWidth
    }

    var body: some View {
        GeometryReader { geometry in
            if data.count >= 2 {
                let minVal = data.min() ?? 0
                let maxVal = data.max() ?? 1
                let range = maxVal - minVal
                let effectiveRange = range < 0.0001 ? 1.0 : range

                Path { path in
                    let stepX = geometry.size.width / CGFloat(max(data.count - 1, 1))
                    let height = geometry.size.height

                    for (index, value) in data.enumerated() {
                        let x = CGFloat(index) * stepX
                        let normalizedY = (value - minVal) / effectiveRange
                        let y = height - (CGFloat(normalizedY) * height * 0.8 + height * 0.1)

                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(color, lineWidth: lineWidth)

                // Fill gradient under the line
                Path { path in
                    let stepX = geometry.size.width / CGFloat(max(data.count - 1, 1))
                    let height = geometry.size.height

                    path.move(to: CGPoint(x: 0, y: height))

                    for (index, value) in data.enumerated() {
                        let x = CGFloat(index) * stepX
                        let normalizedY = (value - minVal) / effectiveRange
                        let y = height - (CGFloat(normalizedY) * height * 0.8 + height * 0.1)
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: geometry.size.width, y: height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.15), color.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            } else {
                // No data state
                Path { path in
                    let y = geometry.size.height / 2
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
                .stroke(Color.gray.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
    }
}

/// Multi-line chart for displaying multiple data series (e.g., accX/Y/Z)
struct MultiLineChartView: View {
    let series: [(data: [Double], color: Color)]
    let lineWidth: CGFloat

    init(series: [(data: [Double], color: Color)], lineWidth: CGFloat = 1.5) {
        self.series = series
        self.lineWidth = lineWidth
    }

    var body: some View {
        GeometryReader { geometry in
            let allValues = series.flatMap(\.data)
            if allValues.count >= 2 {
                let minVal = allValues.min() ?? 0
                let maxVal = allValues.max() ?? 1
                let range = maxVal - minVal
                let effectiveRange = range < 0.0001 ? 1.0 : range

                ForEach(Array(series.enumerated()), id: \.offset) { _, entry in
                    Path { path in
                        let stepX = geometry.size.width / CGFloat(max(entry.data.count - 1, 1))
                        let height = geometry.size.height

                        for (index, value) in entry.data.enumerated() {
                            let x = CGFloat(index) * stepX
                            let normalizedY = (value - minVal) / effectiveRange
                            let y = height - (CGFloat(normalizedY) * height * 0.8 + height * 0.1)

                            if index == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(entry.color, lineWidth: lineWidth)
                }
            } else {
                Path { path in
                    let y = geometry.size.height / 2
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
                .stroke(Color.gray.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
    }
}
