import SwiftUI

struct GazeTab: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    gazeMapCard
                    calibrationCard
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Gaze")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Gaze Map

    private var gazeMapCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("視線マップ")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text("受信: \(viewModel.receivedPacketCount)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.systemGray5), in: Capsule())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.09, green: 0.17, blue: 0.30),
                                    Color(red: 0.06, green: 0.10, blue: 0.20),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    GridPattern()
                        .stroke(.white.opacity(0.10), lineWidth: 1)

                    ForEach(Array(viewModel.gazeTrail.enumerated()), id: \.offset) { index, point in
                        Circle()
                            .fill(
                                Color.orange.opacity(
                                    Double(index + 1) / Double(max(viewModel.gazeTrail.count, 1))
                                        * 0.24
                                )
                            )
                            .frame(width: 26, height: 26)
                            .position(
                                x: point.x / 1280.0 * size.width,
                                y: point.y / 720.0 * size.height
                            )
                    }

                    Circle()
                        .fill(.white)
                        .frame(width: 16, height: 16)
                        .overlay {
                            Circle().stroke(.orange, lineWidth: 5)
                        }
                        .shadow(color: .orange.opacity(0.35), radius: 10)
                        .position(
                            x: viewModel.latestPoint.x / 1280.0 * size.width,
                            y: viewModel.latestPoint.y / 720.0 * size.height
                        )
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }

    // MARK: - Calibration

    private var calibrationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("キャリブレーション（9点）")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(viewModel.calibrationStatusText) \(viewModel.calibrationProgressText)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundStyle(viewModel.calibrationStatusColor)
                    .background(viewModel.calibrationStatusColor.opacity(0.14), in: Capsule())
            }

            Text("赤い点を見ながら「この点を記録」を9回押してください。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(red: 0.97, green: 0.98, blue: 1.0))

                    GridPattern()
                        .stroke(Color(red: 0.80, green: 0.86, blue: 0.95), lineWidth: 1)

                    ForEach(
                        Array(viewModel.calibrationTargets.enumerated()), id: \.offset
                    ) { index, point in
                        let isCompleted = index < viewModel.calibrationCompletedCount
                        let isCurrent =
                            index == viewModel.calibrationTargetIndex
                            && viewModel.calibrationState == .running
                        Circle()
                            .fill(
                                isCompleted
                                    ? Color.green
                                    : (isCurrent
                                        ? Color.red : Color(red: 0.62, green: 0.70, blue: 0.82))
                            )
                            .frame(
                                width: isCurrent ? 16 : 11, height: isCurrent ? 16 : 11
                            )
                            .overlay {
                                if isCurrent {
                                    Circle().stroke(Color.red.opacity(0.35), lineWidth: 8)
                                }
                            }
                            .position(
                                x: point.x / 1280.0 * size.width,
                                y: point.y / 720.0 * size.height
                            )
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)

            HStack(spacing: 10) {
                Button("開始") { viewModel.startCalibration() }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                Button("この点を記録") { viewModel.captureCalibrationPoint() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(viewModel.calibrationState != .running)
                Button("リセット") { viewModel.resetCalibration() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}

private struct GridPattern: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let columns = 10
        let rows = 6

        for index in 1..<columns {
            let x = rect.width * CGFloat(index) / CGFloat(columns)
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: rect.height))
        }

        for index in 1..<rows {
            let y = rect.height * CGFloat(index) / CGFloat(rows)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: rect.width, y: y))
        }

        return path
    }
}
