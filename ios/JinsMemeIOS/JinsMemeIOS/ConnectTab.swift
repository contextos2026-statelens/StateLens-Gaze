import SwiftUI

struct ConnectTab: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    connectionStatusCard
                    inputModeCard
                    diagnosCard
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("接続")
            .navigationBarTitleDisplayMode(.inline)
            .alert(item: $viewModel.failureAlert) { failure in
                Alert(
                    title: Text(failure.title),
                    message: Text("理由: \(failure.reason)\n\n対処方法: \(failure.recoverySuggestion)"),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    // MARK: - Connection Status Card

    private var connectionStatusCard: some View {
        VStack(spacing: 16) {
            // Status icon
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: statusIconName)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(statusColor)
            }

            Text(statusLabel)
                .font(.headline)
                .foregroundStyle(statusColor)

            Text(viewModel.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Connect / Disconnect buttons
            VStack(spacing: 10) {
                Button(action: viewModel.connectToMeme) {
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text(viewModel.buttonTitle)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .background(viewModel.buttonColor, in: RoundedRectangle(cornerRadius: 12))
                }

                if case .connected = viewModel.connectionState {
                    Button("切断") {
                        viewModel.disconnect()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(.red)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }

    // MARK: - Input Mode Card

    private var inputModeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("入力モード")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

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
                VStack(alignment: .leading, spacing: 12) {
                    let localIP = NetworkInterfaceInfo.bestAvailableIP() ?? "未接続"
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Wi-Fiなし(屋外)で使う場合:")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.orange)
                        Text("iPhoneの「設定 ＞ インターネット共有」をオンにすると専用IPが割り当てられます。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Loggerアプリの「WebSocketクライアント」に以下のIPを入力して送信してください。")
                            .font(.caption2)
                            .foregroundColor(.primary)
                        
                        HStack {
                            Text(localIP)
                                .font(.system(.headline, design: .monospaced))
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(8)
                            
                            Text("ポート: \(viewModel.loggerPort)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }

    // MARK: - Diagnostics Card

    private var diagnosCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BLE診断")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            // パケット受信統計
            HStack(spacing: 16) {
                statBadge(label: "受信", value: "\(viewModel.receivedPacketCount)")
                if let frame = viewModel.latestFrame {
                    statBadge(label: "H", value: String(format: "%.3f", frame.horizontal))
                    statBadge(label: "V", value: String(format: "%.3f", frame.vertical))
                } else {
                    statBadge(label: "データ", value: "未受信")
                }
            }

            if let packet = viewModel.latestPacket {
                Text("最終受信: \(packet.receivedAt, style: .time) / \(packet.byteCount)B")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // IMU概要（加速度・ジャイロ）
            if let frame = viewModel.latestFrame,
               (frame.accX != 0 || frame.accY != 0 || frame.accZ != 0) {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("6軸IMU")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        statBadge(label: "aX", value: String(format: "%.3f", frame.accX))
                        statBadge(label: "aY", value: String(format: "%.3f", frame.accY))
                        statBadge(label: "aZ", value: String(format: "%.3f", frame.accZ))
                    }
                    HStack(spacing: 12) {
                        statBadge(label: "gX", value: String(format: "%.1f", frame.gyroX))
                        statBadge(label: "gY", value: String(format: "%.1f", frame.gyroY))
                        statBadge(label: "gZ", value: String(format: "%.1f", frame.gyroZ))
                    }
                }
            }

            // 生パケットHEXダンプ（デバッグ用 — 最新20バイトの全ワード表示）
            if let packet = viewModel.latestPacket, !packet.hexPreview.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("生パケット HEX")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    Text(packet.hexPreview)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            }

            Divider()

            Text(viewModel.bleDiagnosticText)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }

    private func statBadge(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 48)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch viewModel.connectionState {
        case .idle: return .gray
        case .scanning, .connecting: return .orange
        case .connected: return .blue
        case .failed: return .red
        }
    }

    private var statusIconName: String {
        switch viewModel.connectionState {
        case .idle: return "antenna.radiowaves.left.and.right.slash"
        case .scanning: return "antenna.radiowaves.left.and.right"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .connected: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusLabel: String {
        switch viewModel.connectionState {
        case .idle: return "未接続"
        case .scanning: return "スキャン中"
        case .connecting: return "接続中"
        case .connected: return "接続完了"
        case .failed: return "接続失敗"
        }
    }
}
