import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: DashboardViewModel
    private let palette = AppPalette()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    connectionCard
                    realtimeDataCard
                    gazeMapCard
                    calibrationCard
                }
                .padding(16)
            }
            .background(backgroundGradient.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("StateLens : Gaze")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(palette.textPrimary)
                }
            }
            .alert(item: $viewModel.failureAlert) { failure in
                Alert(
                    title: Text(failure.title),
                    message: Text("理由: \(failure.reason)\n\n対処方法: \(failure.recoverySuggestion)"),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(viewModel.connectionSectionTitle)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(palette.accent)

            Picker(
                "入力モード",
                selection: Binding(
                    get: { viewModel.inputMode },
                    set: { viewModel.selectInputMode($0) }
                )
            ) {
                Text(InputMode.bluetooth.displayName).tag(InputMode.bluetooth)
                Text(InputMode.loggerBridge.displayName).tag(InputMode.loggerBridge)
            }
            .pickerStyle(.segmented)

            if viewModel.inputMode == .loggerBridge {
                HStack(spacing: 8) {
                    TextField("Host", text: $viewModel.loggerHost)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .textFieldStyle(.roundedBorder)
                    TextField("Port", text: $viewModel.loggerPort)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 96)
                }
                Text("連携先: \(viewModel.loggerEndpointDescription)")
                    .font(.caption2)
                    .foregroundStyle(palette.textSecondary)
            }

            Text("MEME接続ステータス")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(palette.textPrimary)

            statusBadge

            Button(action: viewModel.connectToMeme) {
                HStack {
                    Image(systemName: "dot.radiowaves.left.and.right")
                    Text(viewModel.buttonTitle)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(.white)
                .background(viewModel.buttonColor, in: RoundedRectangle(cornerRadius: 14))
            }

            if case .connected = viewModel.connectionState {
                Button("切断") {
                    viewModel.disconnect()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .buttonStyle(.bordered)
            }

            Text(viewModel.statusText)
                .font(.footnote)
                .foregroundStyle(palette.textSecondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("BLE診断")
                    .font(.caption2)
                    .foregroundStyle(palette.textSecondary)
                Text(viewModel.bleDiagnosticText)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(palette.textPrimary)
                    .textSelection(.enabled)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(palette.cardBorder, lineWidth: 1)
        )
        .shadow(color: palette.cardShadow, radius: 14, y: 4)
    }

    private var statusBadge: some View {
        let tuple = badgeAppearance
        return HStack(spacing: 8) {
            Circle()
                .fill(tuple.color)
                .frame(width: 10, height: 10)
            Text(tuple.label)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(tuple.color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tuple.color.opacity(0.12), in: Capsule())
    }

    private var realtimeDataCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("センサーデータ (リアルタイム)")
                    .font(.headline)
                    .foregroundStyle(palette.textPrimary)
                Spacer()
                Text("受信: \(viewModel.receivedPacketCount)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(palette.chipBackground, in: Capsule())
                    .foregroundStyle(palette.chipText)
            }

            if let frame = viewModel.latestFrame {
                dataRow(
                    label: "水平値",
                    value: frame.horizontal.formatted(.number.precision(.fractionLength(4))),
                    isBlinking: viewModel.horizontalBlinking
                )
                dataRow(
                    label: "垂直値",
                    value: frame.vertical.formatted(.number.precision(.fractionLength(4))),
                    isBlinking: viewModel.verticalBlinking
                )
                dataRow(
                    label: "まばたき強度",
                    value: frame.blinkStrength.formatted(.number.precision(.fractionLength(4))),
                    isBlinking: viewModel.blinkStrengthBlinking
                )
                dataRow(label: "データ源", value: frame.source)
            } else {
                Text("パース済みデータは未受信です。")
                    .font(.footnote)
                    .foregroundStyle(palette.textSecondary)
            }

            if let packet = viewModel.latestPacket {
                Divider()
                dataRow(label: "パケット長", value: "\(packet.byteCount) byte")
                dataRow(
                    label: "受信時刻",
                    value: timeString(from: packet.receivedAt)
                )
                dataRow(label: "表示更新時刻", value: timeString(from: viewModel.displayUpdatedAt))
                VStack(alignment: .leading, spacing: 4) {
                    Text("生データHEX（先頭20byte）")
                        .font(.caption2)
                        .foregroundStyle(palette.textSecondary)
                    Text(packet.hexPreview.isEmpty ? "-" : packet.hexPreview)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(palette.textPrimary)
                        .textSelection(.enabled)
                }
            } else {
                Divider()
                Text("生パケットは未受信です。")
                    .font(.footnote)
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(palette.cardBorder, lineWidth: 1)
        )
    }

    private func dataRow(label: String, value: String, isBlinking: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .opacity(isBlinking ? 1.0 : 0.15)
                    .scaleEffect(isBlinking ? 1.2 : 0.9)
                    .animation(.easeInOut(duration: 0.24).repeatCount(isBlinking ? 3 : 1, autoreverses: true), value: isBlinking)
                Text(value)
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .foregroundStyle(palette.textPrimary)
                    .textSelection(.enabled)
            }
        }
    }

    private func timeString(from date: Date) -> String {
        date.formatted(
            Date.FormatStyle()
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
                .second(.twoDigits)
        )
    }

    private var gazeMapCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("視線マップ")
                .font(.headline)
                .foregroundStyle(palette.textPrimary)

            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.09, green: 0.17, blue: 0.30), Color(red: 0.06, green: 0.10, blue: 0.20)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    GridPattern()
                        .stroke(.white.opacity(0.10), lineWidth: 1)

                    ForEach(Array(viewModel.gazeTrail.enumerated()), id: \.offset) { index, point in
                        Circle()
                            .fill(Color.orange.opacity(Double(index + 1) / Double(max(viewModel.gazeTrail.count, 1)) * 0.24))
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
        .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(palette.cardBorder, lineWidth: 1)
        )
    }

    private var badgeAppearance: (label: String, color: Color) {
        switch viewModel.connectionState {
        case .idle:
            return ("未接続", Color(red: 0.37, green: 0.44, blue: 0.55))
        case .scanning:
            return ("スキャン中", palette.accent)
        case .connecting:
            return ("接続中", palette.accent)
        case .connected:
            return ("接続完了", Color(red: 0.10, green: 0.42, blue: 0.85))
        case .failed:
            return ("接続失敗", Color(red: 0.78, green: 0.19, blue: 0.20))
        }
    }

    private var calibrationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("キャリブレーション（9点）")
                    .font(.headline)
                    .foregroundStyle(palette.textPrimary)
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
                .foregroundStyle(palette.textSecondary)

            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(red: 0.97, green: 0.98, blue: 1.0))

                    GridPattern()
                        .stroke(Color(red: 0.80, green: 0.86, blue: 0.95), lineWidth: 1)

                    ForEach(Array(viewModel.calibrationTargets.enumerated()), id: \.offset) { index, point in
                        let isCompleted = index < viewModel.calibrationCompletedCount
                        let isCurrent = index == viewModel.calibrationTargetIndex && viewModel.calibrationState == .running
                        Circle()
                            .fill(isCompleted ? Color.green : (isCurrent ? Color.red : Color(red: 0.62, green: 0.70, blue: 0.82)))
                            .frame(width: isCurrent ? 16 : 11, height: isCurrent ? 16 : 11)
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
                    .tint(palette.accent)
                Button("この点を記録") { viewModel.captureCalibrationPoint() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.78, green: 0.18, blue: 0.22))
                    .disabled(viewModel.calibrationState != .running)
                Button("リセット") { viewModel.resetCalibration() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(palette.cardBorder, lineWidth: 1)
        )
    }

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.94, green: 0.97, blue: 1.0), Color(red: 0.90, green: 0.95, blue: 0.99)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct AppPalette {
    let accent = Color(red: 0.05, green: 0.50, blue: 0.63)
    let cardBackground = Color.white
    let cardBorder = Color(red: 0.82, green: 0.88, blue: 0.94)
    let cardShadow = Color.black.opacity(0.05)
    let textPrimary = Color(red: 0.11, green: 0.16, blue: 0.24)
    let textSecondary = Color(red: 0.36, green: 0.44, blue: 0.54)
    let chipBackground = Color(red: 0.89, green: 0.93, blue: 0.98)
    let chipText = Color(red: 0.17, green: 0.28, blue: 0.43)
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
