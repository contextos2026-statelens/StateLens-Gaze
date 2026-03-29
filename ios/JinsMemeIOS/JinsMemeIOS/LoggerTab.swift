import SwiftUI

struct LoggerTab: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Data mode segment control
                dataModeSelector
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                // Scrollable data sections
                ScrollView {
                    VStack(spacing: 2) {
                        blinkSection
                        gazeMovementSection
                        accelerationSection
                        gyroSection
                        accAngleSection
                        utilitySection
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 80)
                }

                // Record button at bottom
                recordButton
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("ロガー")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Data Mode Selector

    private var dataModeSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(LoggerDataMode.allCases) { mode in
                    Button {
                        viewModel.loggerDataMode = mode
                    } label: {
                        Text(mode.rawValue)
                            .font(.system(size: 11, weight: viewModel.loggerDataMode == mode ? .bold : .medium))
                            .foregroundStyle(viewModel.loggerDataMode == mode ? .white : .primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                viewModel.loggerDataMode == mode
                                    ? Color.blue
                                    : Color(.systemGray5),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Data Sections

    private var blinkSection: some View {
        DataSectionView(
            title: "まばたき",
            color: .orange,
            rows: [
                DataRowInfo(
                    label: "strength",
                    value: formatValue(viewModel.latestFrame?.blinkStrength),
                    chartData: viewModel.blinkStrengthHistory,
                    chartColor: .orange
                ),
                DataRowInfo(
                    label: "speed",
                    value: formatValue(viewModel.extendedData.blinkSpeed),
                    chartData: viewModel.blinkSpeedHistory,
                    chartColor: .red
                ),
            ]
        )
    }

    private var gazeMovementSection: some View {
        DataSectionView(
            title: "視線移動",
            color: .green,
            rows: [
                DataRowInfo(
                    label: "up/down",
                    value: formatValue(viewModel.latestFrame?.vertical),
                    chartData: viewModel.verticalHistory,
                    chartColor: .green
                ),
                DataRowInfo(
                    label: "right/left",
                    value: formatValue(viewModel.latestFrame?.horizontal),
                    chartData: viewModel.horizontalHistory,
                    chartColor: .teal
                ),
            ]
        )
    }

    private var accelerationSection: some View {
        DataSectionView(
            title: "加速度",
            color: .cyan,
            rows: [
                DataRowInfo(
                    label: "accX",
                    value: formatValue(viewModel.extendedData.accX),
                    chartData: viewModel.accXHistory,
                    chartColor: .red
                ),
                DataRowInfo(
                    label: "accY",
                    value: formatValue(viewModel.extendedData.accY),
                    chartData: viewModel.accYHistory,
                    chartColor: .green
                ),
                DataRowInfo(
                    label: "accZ",
                    value: formatValue(viewModel.extendedData.accZ),
                    chartData: viewModel.accZHistory,
                    chartColor: .blue
                ),
            ]
        )
    }

    private var gyroSection: some View {
        DataSectionView(
            title: "角度（gyro）",
            color: .purple,
            rows: [
                DataRowInfo(
                    label: "roll",
                    value: formatValue(viewModel.extendedData.gyroRoll),
                    chartData: viewModel.gyroRollHistory,
                    chartColor: .red
                ),
                DataRowInfo(
                    label: "pitch",
                    value: formatValue(viewModel.extendedData.gyroPitch),
                    chartData: viewModel.gyroPitchHistory,
                    chartColor: .green
                ),
                DataRowInfo(
                    label: "yaw",
                    value: formatValue(viewModel.extendedData.gyroYaw),
                    chartData: viewModel.gyroYawHistory,
                    chartColor: .blue
                ),
            ]
        )
    }

    private var accAngleSection: some View {
        DataSectionView(
            title: "角度（acc）",
            color: .indigo,
            rows: [
                DataRowInfo(
                    label: "tiltX",
                    value: formatValue(viewModel.extendedData.tiltX),
                    chartData: viewModel.tiltXHistory,
                    chartColor: .red
                ),
                DataRowInfo(
                    label: "tiltY",
                    value: formatValue(viewModel.extendedData.tiltY),
                    chartData: viewModel.tiltYHistory,
                    chartColor: .green
                ),
            ]
        )
    }

    private var utilitySection: some View {
        DataSectionView(
            title: "ユーティリティ",
            color: .gray,
            rows: [
                DataRowInfo(
                    label: "isStill",
                    value: formatValue(viewModel.extendedData.isStill, decimals: 0),
                    chartData: viewModel.isStillHistory,
                    chartColor: .orange
                ),
                DataRowInfo(
                    label: "noise",
                    value: formatValue(viewModel.extendedData.noise),
                    chartData: viewModel.noiseHistory,
                    chartColor: .gray
                ),
            ]
        )
    }

    // MARK: - Record Button

    private var recordButton: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                viewModel.toggleRecording()
            } label: {
                HStack {
                    Circle()
                        .fill(viewModel.isRecording ? .white : .red)
                        .frame(width: 12, height: 12)
                    Text(viewModel.isRecording ? "停止" : "記録")
                        .font(.headline)
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(viewModel.isRecording ? .white : .primary)
                .background(
                    viewModel.isRecording
                        ? Color.red
                        : Color(.systemGray5),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Helpers

    private func formatValue(_ value: Double?, decimals: Int = 2) -> String {
        guard let value else { return "-" }
        return String(format: "%.\(decimals)f", value)
    }
}

// MARK: - Data Section View

struct DataRowInfo: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let chartData: [Double]
    let chartColor: Color
}

struct DataSectionView: View {
    let title: String
    let color: Color
    let rows: [DataRowInfo]

    var body: some View {
        VStack(spacing: 0) {
            // Section header
            HStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: 4, height: 18)
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(color)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(color.opacity(0.08))

            // Data rows
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    // Label and value
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(row.value)
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                    }
                    .frame(width: 90, alignment: .leading)

                    // Mini chart
                    MiniLineChartView(
                        data: row.chartData,
                        color: row.chartColor
                    )
                    .frame(height: 36)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                if row.id != rows.last?.id {
                    Divider()
                        .padding(.leading, 12)
                }
            }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.03), radius: 4, y: 1)
        .padding(.vertical, 4)
    }
}
