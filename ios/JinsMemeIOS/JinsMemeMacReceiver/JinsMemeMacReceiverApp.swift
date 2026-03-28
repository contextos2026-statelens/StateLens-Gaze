import SwiftUI

@main
struct JinsMemeMacReceiverApp: App {
    @StateObject private var viewModel = MacReceiverViewModel()

    var body: some Scene {
        WindowGroup {
            MacReceiverContentView(viewModel: viewModel)
                .frame(minWidth: 980, minHeight: 720)
        }
    }
}
