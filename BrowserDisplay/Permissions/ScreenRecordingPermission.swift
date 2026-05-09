import AppKit
import Foundation

struct ScreenRecordingPermission {
    static func statusText() -> String {
        hasAccess() ? "已就绪" : "需要屏幕录制权限"
    }

    static func hasAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static var diagnostics: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "未知包名"
        let bundlePath = Bundle.main.bundlePath
        return "\(bundleID) · \(bundlePath)"
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
