import AppKit
import SwiftUI

@main
struct BrowserDisplayApp: App {
    @StateObject private var viewModel = HostViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 980, minHeight: 900)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    viewModel.cleanupVirtualDisplayOnExit()
                }
        }
        .windowStyle(.hiddenTitleBar)
    }
}
