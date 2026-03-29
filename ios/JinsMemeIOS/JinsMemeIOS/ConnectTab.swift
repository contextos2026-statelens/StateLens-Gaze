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
                    .foregroundStyle(.secondary)
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
