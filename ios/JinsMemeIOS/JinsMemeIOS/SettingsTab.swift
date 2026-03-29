import SwiftUI

struct SettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        NavigationStack {
            List {
                // Recording settings
                Section {
                    Toggle("自動保存", isOn: $settings.autoSave)

                    HStack {
                        Text("保存周期")
                        Spacer()
                        Text("\(settings.saveIntervalMinutes) 分")
                            .foregroundStyle(.blue)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        cycleInterval()
                    }

                    Toggle("ジャイロ取得", isOn: $settings.enableGyro)
                }

                // Integration
                Section {
                    Toggle("Google Drive連携", isOn: $settings.googleDriveEnabled)

                    HStack {
                        Text("未連携データをアップロード")
                        Spacer()
                        Text("\(viewModel.pendingUploadCount) 件")
                            .foregroundStyle(.blue)
                    }
                }

                // Developer tools
                Section {
                    HStack {
                        Text("機能サンプル")
                        Spacer()
                        Text("HTMLビューを開く")
                            .foregroundStyle(.blue)
                    }

                    HStack {
                        Text("WebSocketクライアント")
                        Spacer()
                        Text("追加する")
                            .foregroundStyle(.blue)
                    }
                }

                // About
                Section {
                    HStack {
                        Text("バージョン")
                        Spacer()
                        Text(appVersionString)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Helpers

    private func cycleInterval() {
        let intervals = [15, 30, 60, 120]
        if let index = intervals.firstIndex(of: settings.saveIntervalMinutes) {
            let nextIndex = (index + 1) % intervals.count
            settings.saveIntervalMinutes = intervals[nextIndex]
        } else {
            settings.saveIntervalMinutes = 60
        }
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "version \(version).\(build)"
    }
}
