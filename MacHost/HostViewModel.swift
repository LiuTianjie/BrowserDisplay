import AppKit
import Foundation
import Combine
import MirrorProtocol

@MainActor
final class HostViewModel: ObservableObject {
    @Published var hostName = MirrorDiscovery.displayName()
    @Published var connectionStatus = "正在启动"
    @Published var screenRecordingStatus = "正在检查屏幕录制权限"
    @Published var permissionDiagnostics = ScreenRecordingPermission.diagnostics
    @Published var captureSources: [CaptureSource] = []
    @Published var selectedSourceID: String?
    @Published var selectedSourceScope: CaptureSourceScope = .currentDesktop
    @Published var selectedConfigID = "1080p60"
    @Published var isStreaming = false
    @Published var hasCheckedScreenRecordingAccess = false
    @Published var hasScreenRecordingAccess = false
    @Published var webViewerURL = ""
    @Published var webViewerPairingCode = ""
    @Published var webViewerStatus = "正在启动"
    @Published var connectedWebViewers = 0
    @Published var virtualDisplayState: VirtualDisplayPanelState = .unavailable
    @Published var virtualDisplayStatus = "正在检测 BetterDisplay"
    @Published var currentVirtualDisplayRecord: VirtualDisplayRecord?
    @Published var virtualDisplayErrorMessage: String?
    @Published var shouldCleanupVirtualDisplayOnExit = false

    private let webViewerService = WebViewerService()
    private let webRTCSender = WebRTCScreenSender()
    private let captureManager = ScreenCaptureManager()
    private let virtualDisplayProvider = BetterDisplayProvider()
    private let virtualDisplayStore = VirtualDisplayStore()
    private let preferences = UserDefaults.standard
    private var streamWatchdogTask: Task<Void, Never>?
    private var lastCapturedFrameAt: Date?

    var canStream: Bool {
        !captureSources.isEmpty
    }

    var canChangeCaptureSource: Bool {
        !isStreaming
    }

    func prepare() async {
        selectedSourceScope = .currentDesktop
        permissionDiagnostics = ScreenRecordingPermission.diagnostics
        startNetworking()
        shouldCleanupVirtualDisplayOnExit = preferences.bool(forKey: "MirrorDisplay.VirtualDisplay.cleanupOnExit")
        await refreshVirtualDisplayAvailability()
        restoreLastVirtualDisplayRecord()
        await refreshCaptureSources()
    }

    func checkScreenRecordingAccess() {
        hasCheckedScreenRecordingAccess = true
        hasScreenRecordingAccess = ScreenRecordingPermission.hasAccess()
        screenRecordingStatus = hasScreenRecordingAccess ? "已就绪" : "需要屏幕录制权限"
        permissionDiagnostics = ScreenRecordingPermission.diagnostics
    }

    func refreshCaptureSources() async {
        guard canChangeCaptureSource else {
            return
        }

        hasCheckedScreenRecordingAccess = true
        permissionDiagnostics = ScreenRecordingPermission.diagnostics
        screenRecordingStatus = "正在读取可捕获屏幕和窗口"

        do {
            captureSources = try await captureManager.availableSources(scope: selectedSourceScope)
            hasScreenRecordingAccess = true
            if !captureSources.contains(where: { $0.id == selectedSourceID }) {
                selectedSourceID = captureSources.first?.id
            }
            screenRecordingStatus = captureSources.isEmpty ? "未找到可捕获屏幕或窗口" : "已就绪"
        } catch {
            hasScreenRecordingAccess = ScreenRecordingPermission.hasAccess()
            screenRecordingStatus = hasScreenRecordingAccess
                ? "读取捕获源失败：\(error.localizedDescription)"
                : "需要屏幕录制权限。请在系统设置中允许后，退出并重新打开 Mac 端应用。"
            captureSources = []
            selectedSourceID = nil
        }
    }

    func requestScreenRecordingAccess() async {
        hasCheckedScreenRecordingAccess = true
        screenRecordingStatus = "正在请求屏幕录制权限"
        let granted = ScreenRecordingPermission.requestAccess()
        await refreshCaptureSources()

        if !hasScreenRecordingAccess {
            if !granted {
                ScreenRecordingPermission.openSettings()
            }
            screenRecordingStatus = "需要屏幕录制权限。请在系统设置中允许后，退出并重新打开 Mac 端应用。"
        }
    }

    func openScreenRecordingSettings() {
        ScreenRecordingPermission.openSettings()
    }

    func selectCaptureSource(_ sourceID: String) {
        guard canChangeCaptureSource else {
            return
        }

        selectedSourceID = sourceID
        updateStreamStateForCurrentSelection()
    }

    func refreshVirtualDisplayAvailability() async {
        guard virtualDisplayState != .creating, virtualDisplayState != .removing else {
            return
        }

        let availability = await virtualDisplayProvider.availability()
        virtualDisplayStatus = availability.message
        virtualDisplayErrorMessage = nil

        if let record = currentVirtualDisplayRecord, record.cleanupStatus != .removed {
            virtualDisplayState = record.cleanupStatus == .cleanupFailed ? .cleanupFailed : .ready
            virtualDisplayStatus = "虚拟屏已就绪。把窗口拖到 MirrorDisplay 屏幕，或移除这块虚拟屏。"
            return
        }

        switch availability.status {
        case .unavailable:
            virtualDisplayState = .unavailable
        case .installedNotRunning:
            virtualDisplayState = .installedNotRunning
        case .ready:
            virtualDisplayState = .readyToCreate
        }
    }

    func createVirtualDisplayAndStart() async {
        guard !isStreaming, virtualDisplayState != .creating, virtualDisplayState != .removing else {
            return
        }

        virtualDisplayState = .creating
        virtualDisplayStatus = "正在通过 BetterDisplay 创建 MirrorDisplay 虚拟屏"
        virtualDisplayErrorMessage = nil

        do {
            selectedSourceScope = .allDesktops
            let existingDisplayIDs = try await currentDisplayIDs()
            let request = VirtualDisplayRequest.mirrorDisplayDefault()
            var record = try await virtualDisplayProvider.createDisplay(request: request)
            virtualDisplayStore.save(record)
            currentVirtualDisplayRecord = record
            virtualDisplayStatus = "虚拟屏已创建，正在等待 macOS 枚举显示器"

            let source = try await waitForCreatedVirtualDisplay(record: record, previousDisplayIDs: existingDisplayIDs)
            record.displayID = source.displayID
            virtualDisplayStore.save(record)
            currentVirtualDisplayRecord = record

            await refreshCaptureSources()
            if let displayID = record.displayID,
               let refreshedSource = captureSources.first(where: { $0.displayID == displayID }) {
                selectedSourceID = refreshedSource.id
            } else {
                selectedSourceID = source.id
            }

            virtualDisplayState = .ready
            virtualDisplayStatus = "虚拟屏已就绪。把窗口拖到 MirrorDisplay 屏幕，正在开始传输。"
            await startStreaming()
        } catch {
            virtualDisplayState = .createFailed
            virtualDisplayErrorMessage = error.localizedDescription
            virtualDisplayStatus = error.localizedDescription
            await refreshCaptureSources()
        }
    }

    func removeVirtualDisplay() async {
        guard var record = currentVirtualDisplayRecord else {
            return
        }

        guard record.isMirrorDisplayOwned else {
            virtualDisplayState = .cleanupFailed
            virtualDisplayErrorMessage = VirtualDisplayError.unsafeRecord.localizedDescription
            virtualDisplayStatus = VirtualDisplayError.unsafeRecord.localizedDescription
            return
        }

        virtualDisplayState = .removing
        virtualDisplayStatus = "正在移除 MirrorDisplay 创建的虚拟屏"
        virtualDisplayErrorMessage = nil

        if isStreaming {
            await stopStreaming()
        }

        do {
            try await virtualDisplayProvider.removeDisplay(record: record)
            record.cleanupStatus = .removed
            virtualDisplayStore.markRemoved(record)
            currentVirtualDisplayRecord = nil
            selectedSourceID = nil
            await refreshCaptureSources()
            await refreshVirtualDisplayAvailability()
        } catch {
            record.cleanupStatus = .cleanupFailed
            currentVirtualDisplayRecord = record
            virtualDisplayStore.markCleanupFailed(record)
            virtualDisplayState = .cleanupFailed
            virtualDisplayErrorMessage = error.localizedDescription
            virtualDisplayStatus = "\(error.localizedDescription) 可在 BetterDisplay 中手动删除 \(record.displayName)。"
        }
    }

    func cleanupVirtualDisplayOnExit() {
        guard shouldCleanupVirtualDisplayOnExit else {
            return
        }

        guard let record = currentVirtualDisplayRecord, record.isMirrorDisplayOwned, record.cleanupStatus != .removed else {
            return
        }

        Task.detached { [virtualDisplayProvider, virtualDisplayStore] in
            do {
                try await virtualDisplayProvider.removeDisplay(record: record)
                virtualDisplayStore.markRemoved(record)
            } catch {
                virtualDisplayStore.markCleanupFailed(record)
            }
        }
    }

    func openBetterDisplayInstallPage() {
        virtualDisplayProvider.openInstallPage()
    }

    func openDisplaySettings() {
        virtualDisplayProvider.openDisplaySettings()
    }

    func setCleanupVirtualDisplayOnExit(_ enabled: Bool) {
        shouldCleanupVirtualDisplayOnExit = enabled
        preferences.set(enabled, forKey: "MirrorDisplay.VirtualDisplay.cleanupOnExit")
    }

    func toggleStreaming() async {
        if isStreaming {
            await stopStreaming()
        } else {
            await startStreaming()
        }
    }

    private func startStreaming() async {
        guard let selectedSourceID else {
            connectionStatus = "请先选择捕获源"
            return
        }

        let config = StreamConfig.presets.first(where: { $0.id == selectedConfigID }) ?? StreamConfig.presets[0]
        let webRTCSender = webRTCSender

        do {
            webRTCSender.start(config: config)

            try await captureManager.startCapture(sourceID: selectedSourceID, scope: selectedSourceScope, config: config) { sampleBuffer in
                Task { @MainActor in
                    self.lastCapturedFrameAt = Date()
                }
                webRTCSender.push(sampleBuffer)
            }

            isStreaming = true
            lastCapturedFrameAt = Date()
            startStreamWatchdog(sourceID: selectedSourceID, scope: selectedSourceScope, config: config)
            connectionStatus = "客户端连接后开始传输"
            webViewerService.updateStreamState(
                isStreaming: true,
                quality: qualityLabel(for: config),
                codec: codecLabel(for: config),
                sourceName: currentStreamSourceName(),
                sourceKind: currentStreamSourceKind()
            )
        } catch {
            isStreaming = false
            connectionStatus = "传输失败：\(error.localizedDescription)"
            webViewerService.updateStreamState(
                isStreaming: false,
                quality: qualityLabel(for: config),
                codec: codecLabel(for: config),
                sourceName: currentStreamSourceName(),
                sourceKind: currentStreamSourceKind()
            )
        }
    }

    private func stopStreaming() async {
        do {
            try await captureManager.stopCapture()
        } catch {
            connectionStatus = "停止失败：\(error.localizedDescription)"
        }

        streamWatchdogTask?.cancel()
        streamWatchdogTask = nil
        lastCapturedFrameAt = nil
        webRTCSender.stop()
        isStreaming = false
        let config = StreamConfig.presets.first(where: { $0.id == selectedConfigID }) ?? StreamConfig.presets[0]
        webViewerService.updateStreamState(
            isStreaming: false,
            quality: qualityLabel(for: config),
            codec: codecLabel(for: config),
            sourceName: currentStreamSourceName(),
            sourceKind: currentStreamSourceKind()
        )
        if !connectionStatus.hasPrefix("停止失败") {
            connectionStatus = "已就绪"
        }
    }

    private func startNetworking() {
        do {
            webViewerService.onViewerConnected = { [weak self] in
                Task { @MainActor in
                    guard let self else {
                        return
                    }
                    self.connectedWebViewers = self.webViewerService.connectedViewerCount
                    self.webViewerStatus = self.connectedWebViewers == 1 ? "1 个 Viewer 已连接" : "\(self.connectedWebViewers) 个 Viewer 已连接"
                }
            }
            webViewerService.onViewerDisconnected = { [weak self] in
                Task { @MainActor in
                    guard let self else {
                        return
                    }
                    self.connectedWebViewers = self.webViewerService.connectedViewerCount
                    self.webViewerStatus = self.connectedWebViewers > 0 ? "\(self.connectedWebViewers) 个 Viewer 已连接" : "等待浏览器 Viewer"
                }
            }
            webViewerService.onSignalMessage = { [weak self] envelope in
                self?.webRTCSender.handleSignal(envelope)
            }
            webRTCSender.onLocalSignal = { [weak self] payload, clientID in
                self?.webViewerService.sendSignal(payload, to: clientID)
            }
            webRTCSender.onViewerCountChanged = { [weak self] count in
                Task { @MainActor in
                    guard let self else {
                        return
                    }

                    if count > 0 {
                        self.webViewerStatus = count == 1 ? "WebRTC 已连接" : "\(count) 个 WebRTC Viewer"
                    } else if self.connectedWebViewers > 0 {
                        self.webViewerStatus = "\(self.connectedWebViewers) 个 Viewer 已连接"
                    } else {
                        self.webViewerStatus = "等待浏览器 Viewer"
                    }
                }
            }
            webRTCSender.onStatusChanged = { [weak self] status in
                Task { @MainActor in
                    self?.webViewerStatus = status
                }
            }
            try webViewerService.start(port: MirrorDiscovery.defaultWebViewerPort)
            let config = StreamConfig.presets.first(where: { $0.id == selectedConfigID }) ?? StreamConfig.presets[0]
            webViewerService.updateStreamState(
                isStreaming: isStreaming,
                quality: qualityLabel(for: config),
                codec: codecLabel(for: config),
                sourceName: currentStreamSourceName(),
                sourceKind: currentStreamSourceKind()
            )
            webViewerURL = webViewerService.viewerURLString
            webViewerPairingCode = webViewerService.pairingCode
            webViewerStatus = "等待浏览器 Viewer"
            connectionStatus = "局域网可连接"
        } catch {
            connectionStatus = "网络错误：\(error.localizedDescription)"
            webViewerStatus = "WebViewer 启动失败"
        }
    }

    func copyWebViewerURL() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(webViewerURL, forType: .string)
        webViewerStatus = "已复制地址"
    }

    func copyWebViewerPairingCode() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(webViewerPairingCode, forType: .string)
        webViewerStatus = "已复制配对码"
    }

    func regenerateWebViewerPairingCode() {
        webViewerService.regeneratePairingCode()
        webViewerPairingCode = webViewerService.pairingCode
        connectedWebViewers = webViewerService.connectedViewerCount
        webViewerStatus = "配对码已刷新"
    }

    func openWebViewerURL() {
        guard let url = URL(string: webViewerURL) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func qualityLabel(for config: StreamConfig) -> String {
        "\(config.height)p\(config.framesPerSecond)"
    }

    private func codecLabel(for config: StreamConfig) -> String {
        switch config.codec {
        case .h264:
            return "H264"
        case .vp8:
            return "VP8"
        case .hevc:
            return "H265"
        }
    }

    private func startStreamWatchdog(sourceID: String, scope: CaptureSourceScope, config: StreamConfig) {
        streamWatchdogTask?.cancel()
        streamWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else {
                    return
                }

                await MainActor.run {
                    guard self.isStreaming else {
                        return
                    }

                    let elapsed = abs(self.lastCapturedFrameAt?.timeIntervalSinceNow ?? -Double.infinity)
                    guard elapsed > 20 else {
                        return
                    }

                    self.connectionStatus = "画面停滞，正在恢复采集"
                    Task {
                        await self.restartCapture(sourceID: sourceID, scope: scope, config: config)
                    }
                }
            }
        }
    }

    private func restartCapture(sourceID: String, scope: CaptureSourceScope, config: StreamConfig) async {
        guard isStreaming else {
            return
        }

        do {
            try await captureManager.stopCapture()
            try await captureManager.startCapture(sourceID: sourceID, scope: scope, config: config) { [weak self] sampleBuffer in
                Task { @MainActor in
                    self?.lastCapturedFrameAt = Date()
                }
                guard let self else {
                    return
                }
                self.webRTCSender.push(sampleBuffer)
            }
            lastCapturedFrameAt = Date()
            connectionStatus = "采集已恢复"
        } catch {
            connectionStatus = "恢复采集失败：\(error.localizedDescription)"
        }
    }

    private func restoreLastVirtualDisplayRecord() {
        guard currentVirtualDisplayRecord == nil else {
            return
        }

        if let record = virtualDisplayStore.activeMirrorDisplayRecords().sorted(by: { $0.createdAt > $1.createdAt }).first {
            currentVirtualDisplayRecord = record
            virtualDisplayState = record.cleanupStatus == .cleanupFailed ? .cleanupFailed : .ready
            virtualDisplayStatus = "检测到上次遗留的 \(record.displayName)，可点击移除虚拟屏清理。"
        }
    }

    private func currentDisplayIDs() async throws -> Set<CGDirectDisplayID> {
        let displays = try await captureManager.availableDisplaySources(scope: .allDesktops, includeThumbnails: false)
        return Set(displays.compactMap(\.displayID))
    }

    private func waitForCreatedVirtualDisplay(record: VirtualDisplayRecord, previousDisplayIDs: Set<CGDirectDisplayID>) async throws -> CaptureSource {
        let deadline = Date().addingTimeInterval(10)

        while Date() < deadline {
            let sources = try await captureManager.availableDisplaySources(scope: .allDesktops, includeThumbnails: false)

            if let nameMatch = sources.first(where: { source in
                source.name == record.displayName || source.displayNameHint == record.displayName || source.name.hasPrefix(record.displayName)
            }) {
                return nameMatch
            }

            if let newDisplay = sources.first(where: { source in
                guard let displayID = source.displayID else {
                    return false
                }
                return !previousDisplayIDs.contains(displayID)
            }) {
                return newDisplay
            }

            try await Task.sleep(nanoseconds: 500_000_000)
        }

        throw VirtualDisplayError.createdDisplayNotFound
    }

    private func currentStreamSourceName() -> String {
        if let record = currentVirtualDisplayRecord,
           let selectedSourceID,
           let selectedSource = captureSources.first(where: { $0.id == selectedSourceID }),
           selectedSource.displayID == record.displayID || selectedSource.name == record.displayName {
            return "MirrorDisplay 虚拟屏"
        }

        if let selectedSourceID,
           let selectedSource = captureSources.first(where: { $0.id == selectedSourceID }) {
            return selectedSource.name
        }

        return "未选择"
    }

    private func currentStreamSourceKind() -> String {
        if currentStreamSourceName() == "MirrorDisplay 虚拟屏" {
            return "virtual-display"
        }

        if let selectedSourceID, selectedSourceID.hasPrefix("display-") {
            return "display"
        }

        if let selectedSourceID, selectedSourceID.hasPrefix("window-") {
            return "window"
        }

        return "capture"
    }

    private func updateStreamStateForCurrentSelection() {
        let config = StreamConfig.presets.first(where: { $0.id == selectedConfigID }) ?? StreamConfig.presets[0]
        webViewerService.updateStreamState(
            isStreaming: isStreaming,
            quality: qualityLabel(for: config),
            codec: codecLabel(for: config),
            sourceName: currentStreamSourceName(),
            sourceKind: currentStreamSourceKind()
        )
    }
}
