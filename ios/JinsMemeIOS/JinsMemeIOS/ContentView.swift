import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @StateObject private var settings = AppSettings()
    @State private var selectedTab = 1

    var body: some View {
        TabView(selection: $selectedTab) {
            ConnectTab(viewModel: viewModel)
                .tabItem {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text("接続")
                }
                .tag(0)

            LoggerTab(viewModel: viewModel)
                .tabItem {
                    Image(systemName: "doc.text")
                    Text("ロガー")
                }
                .badge(viewModel.isRecording ? "●" : nil)
                .tag(1)

            CSVTab(viewModel: viewModel)
                .tabItem {
                    Image(systemName: "folder")
                    Text("CSV")
                }
                .badge(viewModel.csvFiles.isEmpty ? nil : "\(viewModel.csvFiles.count)")
                .tag(2)

            SettingsTab(settings: settings, viewModel: viewModel)
                .tabItem {
                    Image(systemName: "gearshape")
                    Text("設定")
                }
                .tag(3)

            GazeTab(viewModel: viewModel)
                .tabItem {
                    Image(systemName: "eye")
                    Text("Gaze")
                }
                .tag(4)
        }
        .tint(.blue)
    }
}
