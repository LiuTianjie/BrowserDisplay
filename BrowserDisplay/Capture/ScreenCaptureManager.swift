import AppKit
import CoreMedia
import Foundation
import MirrorProtocol
import ScreenCaptureKit

struct CaptureSource: Identifiable, Equatable {
    var id: String
    var name: String
    var kind: String
    var thumbnail: NSImage?
    var displayID: CGDirectDisplayID?
    var displayNameHint: String?
    var isVirtualBrowserDisplay: Bool = false

    static func == (lhs: CaptureSource, rhs: CaptureSource) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.kind == rhs.kind
    }
}

enum CaptureSourceScope: String, CaseIterable, Identifiable {
    case currentDesktop
    case allDesktops

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentDesktop:
            return "当前桌面"
        case .allDesktops:
            return "全部桌面"
        }
    }
}

final class ScreenCaptureManager: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "mirror-display.capture.samples", qos: .userInteractive)
    private var frameHandler: ((CMSampleBuffer) -> Void)?

    func availableSources(scope: CaptureSourceScope, includeThumbnails: Bool = true) async throws -> [CaptureSource] {
        let content = try await shareableContent(scope: scope)
        let displays = content.displays.map { display in
            let displayName = displayName(for: display.displayID)
            return CaptureSource(
                id: "display-\(display.displayID)",
                name: displayName,
                kind: "整屏",
                thumbnail: includeThumbnails ? makeDisplayThumbnail(display.displayID) : nil,
                displayID: display.displayID,
                displayNameHint: displayName,
                isVirtualBrowserDisplay: displayName.hasPrefix("BrowserDisplay-")
            )
        }
        let windows = uniqueWindows(from: content.windows
            .filter { isCapturableApplicationWindow($0, scope: scope) }
            .sorted(by: sortWindows))
            .map { window in
            let title = window.title ?? ""
            let appName = window.owningApplication?.applicationName ?? "应用窗口"
            return CaptureSource(
                id: "window-\(window.windowID)",
                name: title.isEmpty ? appName : title,
                kind: appName,
                thumbnail: includeThumbnails ? makeWindowThumbnail(window.windowID) : nil,
                displayID: nil,
                displayNameHint: nil,
                isVirtualBrowserDisplay: false
            )
        }

        return displays + Array(windows)
    }

    func availableDisplaySources(scope: CaptureSourceScope, includeThumbnails: Bool = false) async throws -> [CaptureSource] {
        try await availableSources(scope: scope, includeThumbnails: includeThumbnails)
            .filter { $0.displayID != nil }
    }

    func startCapture(
        sourceID: String,
        scope: CaptureSourceScope,
        config: StreamConfig,
        frameHandler: @escaping (CMSampleBuffer) -> Void
    ) async throws {
        try await stopCapture()

        let content = try await shareableContent(scope: scope)
        let filter = try makeContentFilter(sourceID: sourceID, content: content)
        let streamConfig = makeStreamConfiguration(config)
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)

        self.frameHandler = frameHandler
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stopCapture() async throws {
        guard let stream else {
            frameHandler = nil
            return
        }

        try await stream.stopCapture()
        self.stream = nil
        frameHandler = nil
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, isCompleteFrame(sampleBuffer) else {
            return
        }

        frameHandler?(sampleBuffer)
    }

    private func makeContentFilter(sourceID: String, content: SCShareableContent) throws -> SCContentFilter {
        if sourceID.hasPrefix("display-") {
            let rawID = sourceID.replacingOccurrences(of: "display-", with: "")
            guard
                let displayID = CGDirectDisplayID(rawID),
                let display = content.displays.first(where: { $0.displayID == displayID })
            else {
                throw ScreenCaptureError.sourceNotFound
            }

            return SCContentFilter(display: display, excludingWindows: [])
        }

        if sourceID.hasPrefix("window-") {
            let rawID = sourceID.replacingOccurrences(of: "window-", with: "")
            guard
                let windowID = CGWindowID(rawID),
                let window = content.windows.first(where: { $0.windowID == windowID })
            else {
                throw ScreenCaptureError.sourceNotFound
            }

            return SCContentFilter(desktopIndependentWindow: window)
        }

        throw ScreenCaptureError.sourceNotFound
    }

    private func shareableContent(scope: CaptureSourceScope) async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: scope == .currentDesktop)
    }

    private func makeStreamConfiguration(_ config: StreamConfig) -> SCStreamConfiguration {
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = config.width
        streamConfig.height = config.height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.framesPerSecond))
        streamConfig.queueDepth = config.framesPerSecond > 30 ? 8 : 6
        streamConfig.showsCursor = true
        streamConfig.capturesAudio = false
        streamConfig.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        return streamConfig
    }

    private func makeDisplayThumbnail(_ displayID: CGDirectDisplayID) -> NSImage? {
        guard let image = CGDisplayCreateImage(displayID) else {
            return nil
        }

        return makeThumbnail(from: image)
    }

    private func displayName(for displayID: CGDirectDisplayID) -> String {
        if let name = localizedDisplayName(for: displayID), !name.isEmpty {
            return name
        }

        return "显示器 \(displayID)"
    }

    private func localizedDisplayName(for displayID: CGDirectDisplayID) -> String? {
        for screen in NSScreen.screens {
            guard
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                number.uint32Value == displayID
            else {
                continue
            }

            return screen.localizedName
        }

        return nil
    }

    private func makeWindowThumbnail(_ windowID: CGWindowID) -> NSImage? {
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            return nil
        }

        return makeThumbnail(from: image)
    }

    private func isCapturableApplicationWindow(_ window: SCWindow, scope: CaptureSourceScope) -> Bool {
        let app = window.owningApplication
        let bundleIdentifier = app?.bundleIdentifier ?? ""
        let appName = app?.applicationName ?? ""
        let title = window.title ?? ""
        let frame = window.frame

        guard window.windowLayer == 0 else {
            return false
        }

        guard frame.width >= 120, frame.height >= 80 else {
            return false
        }

        if bundleIdentifier == Bundle.main.bundleIdentifier {
            return false
        }

        guard isRegularUserApplication(app) else {
            return false
        }

        let blockedBundleIdentifiers: Set<String> = [
            "com.apple.controlcenter",
            "com.apple.dock",
            "com.apple.loginwindow",
            "com.apple.notificationcenterui",
            "com.apple.systemuiserver",
            "com.apple.UserNotificationCenter",
            "com.apple.WindowManager",
            "com.apple.Spotlight",
            "com.apple.TextInputMenuAgent",
            "com.apple.assistant_service",
            "com.apple.ScreenContinuity"
        ]

        if blockedBundleIdentifiers.contains(bundleIdentifier) || bundleIdentifier.contains("OpenAndSavePanelService") {
            return false
        }

        let blockedNames: Set<String> = [
            "控制中心",
            "Dock",
            "loginwindow",
            "Notification Center",
            "SystemUIServer",
            "UserNotificationCenter",
            "WindowManager",
            "Spotlight",
            "Wi-Fi",
            "Battery",
            "NowPlaying",
            "CC Switch",
            "Radial Menu",
            "App Shortcuts Preview"
        ]

        if blockedNames.contains(appName) || blockedNames.contains(title) {
            return false
        }

        let serviceTerms = [
            "自动填充",
            "AutoFill",
            "Open and Save Panel Service",
            "Save Panel Service",
            "App Shortcuts Preview",
            "Control Center",
            "Menu Bar"
        ]
        let searchableText = "\(title) \(appName) \(bundleIdentifier)"
        if serviceTerms.contains(where: { searchableText.localizedCaseInsensitiveContains($0) }) {
            return false
        }

        if scope == .allDesktops, isLikelyAuxiliaryWindow(title: title, appName: appName) {
            return false
        }

        return true
    }

    private func isRegularUserApplication(_ app: SCRunningApplication?) -> Bool {
        guard let app else {
            return false
        }

        let runningApp = NSRunningApplication(processIdentifier: pid_t(app.processID))
        return runningApp?.activationPolicy == .regular
    }

    private func isLikelyAuxiliaryWindow(title: String, appName: String) -> Bool {
        let normalizedTitle = normalized(title)
        let normalizedAppName = normalized(appName)

        if normalizedTitle.isEmpty {
            return true
        }

        let auxiliaryTerms = [
            "preview",
            "popover",
            "panel",
            "menu",
            "shortcut",
            "switch",
            "radial",
            "notification",
            "hud",
            "overlay",
            "floating",
            "自动填充",
            "菜单",
            "预览",
            "通知"
        ]

        if auxiliaryTerms.contains(where: { normalizedTitle.contains($0) || normalizedAppName.contains($0) }) {
            return true
        }

        return false
    }

    private func uniqueWindows(from windows: [SCWindow]) -> [SCWindow] {
        var seen = Set<String>()

        return windows.filter { window in
            let title = normalized(window.title ?? "")
            let appName = normalized(window.owningApplication?.applicationName ?? "")
            let bundleIdentifier = window.owningApplication?.bundleIdentifier ?? ""

            let normalizedTitle = title.isEmpty ? appName : title
            let key = "\(bundleIdentifier)|\(appName)|\(normalizedTitle)"

            if seen.contains(key) {
                return false
            }

            seen.insert(key)
            return true
        }
    }

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func sortWindows(_ lhs: SCWindow, _ rhs: SCWindow) -> Bool {
        let lhsApp = lhs.owningApplication?.applicationName ?? ""
        let rhsApp = rhs.owningApplication?.applicationName ?? ""

        if lhsApp.localizedStandardCompare(rhsApp) != .orderedSame {
            return lhsApp.localizedStandardCompare(rhsApp) == .orderedAscending
        }

        let lhsTitle = lhs.title ?? ""
        let rhsTitle = rhs.title ?? ""
        if lhsTitle.localizedStandardCompare(rhsTitle) != .orderedSame {
            return lhsTitle.localizedStandardCompare(rhsTitle) == .orderedAscending
        }

        return lhs.windowID < rhs.windowID
    }

    private func makeThumbnail(from image: CGImage, maxPixelDimension: CGFloat = 640) -> NSImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(1, maxPixelDimension / max(width, height))
        let size = NSSize(width: width * scale, height: height * scale)

        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: size).draw(in: NSRect(origin: .zero, size: size))
        thumbnail.unlockFocus()
        return thumbnail
    }

    private nonisolated func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let statusRawValue = attachments.first?[SCStreamFrameInfo.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRawValue)
        else {
            return true
        }

        return status == .complete
    }
}

enum ScreenCaptureError: LocalizedError {
    case sourceNotFound

    var errorDescription: String? {
        switch self {
        case .sourceNotFound:
            return "所选捕获源已不可用。"
        }
    }
}
