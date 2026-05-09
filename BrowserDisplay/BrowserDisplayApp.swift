import AppKit
import SwiftUI

@main
struct BrowserDisplayApp: App {
    @StateObject private var viewModel = HostViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(
                    minWidth: BrowserDisplayLayout.minimumWindowWidth,
                    minHeight: BrowserDisplayLayout.minimumWindowHeight
                )
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    viewModel.cleanupVirtualDisplayOnExit()
                }
        }
        .windowStyle(.hiddenTitleBar)
    }
}
