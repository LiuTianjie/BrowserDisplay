import AppKit
import Foundation
import Combine
import MirrorProtocol

@MainActor
final class HostViewModel: ObservableObject {
    @Published var hostName = MirrorDiscovery.displayName()
    @Published var language = AppLanguage.saved()
    @Published var connectionStatus = AppLanguage.saved().strings.starting
    @Published var screenRecordingStatus = AppLanguage.saved().strings.checkingScreenRecording
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
    @Published var webViewerStatus = AppLanguage.saved().strings.starting
    @Published var connectedWebViewers = 0
    @Published var virtualDisplayState: VirtualDisplayPanelState = .unavailable
    @Published var virtualDisplayStatus = AppLanguage.saved().strings.checkingBetterDisplay
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

    var strings: AppStrings {
        language.strings
    }

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
        shouldCleanupVirtualDisplayOnExit = preferences.bool(forKey: "BrowserDisplay.VirtualDisplay.cleanupOnExit")
        await refreshVirtualDisplayAvailability()
        restoreLastVirtualDisplayRecord()
        await refreshCaptureSources()
    }

    func toggleLanguage() {
        language = language.next
        preferences.set(language.rawValue, forKey: AppLanguage.preferenceKey)
        relocalizeStableStatuses()
        updateStreamStateForCurrentSelection()
    }

    func checkScreenRecordingAccess() {
        hasCheckedScreenRecordingAccess = true
        hasScreenRecordingAccess = ScreenRecordingPermission.hasAccess()
        screenRecordingStatus = hasScreenRecordingAccess ? strings.ready : strings.needsScreenRecording
        permissionDiagnostics = ScreenRecordingPermission.diagnostics
    }

    func refreshCaptureSources() async {
        guard canChangeCaptureSource else {
            return
        }

        hasCheckedScreenRecordingAccess = true
        permissionDiagnostics = ScreenRecordingPermission.diagnostics
        screenRecordingStatus = strings.readingSources

        do {
            captureSources = try await captureManager.availableSources(scope: selectedSourceScope)
            hasScreenRecordingAccess = true
            if !captureSources.contains(where: { $0.id == selectedSourceID }) {
                selectedSourceID = captureSources.first?.id
            }
            screenRecordingStatus = captureSources.isEmpty ? strings.noSourcesFound : strings.ready
        } catch {
            hasScreenRecordingAccess = ScreenRecordingPermission.hasAccess()
            screenRecordingStatus = hasScreenRecordingAccess
                ? strings.readSourcesFailed(error.localizedDescription)
                : strings.screenRecordingRestartRequired
            captureSources = []
            selectedSourceID = nil
        }
    }

    func requestScreenRecordingAccess() async {
        hasCheckedScreenRecordingAccess = true
        screenRecordingStatus = strings.requestingScreenRecording
        let granted = ScreenRecordingPermission.requestAccess()
        await refreshCaptureSources()

        if !hasScreenRecordingAccess {
            if !granted {
                ScreenRecordingPermission.openSettings()
            }
            screenRecordingStatus = strings.screenRecordingRestartRequired
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
        virtualDisplayStatus = localizedAvailabilityMessage(availability)
        virtualDisplayErrorMessage = nil

        if let record = currentVirtualDisplayRecord, record.cleanupStatus != .removed {
            virtualDisplayState = record.cleanupStatus == .cleanupFailed ? .cleanupFailed : .ready
            virtualDisplayStatus = strings.virtualDisplayReadyMessage()
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
        virtualDisplayStatus = strings.creatingBrowserDisplayVirtualDisplay()
        virtualDisplayErrorMessage = nil

        do {
            selectedSourceScope = .allDesktops
            let existingDisplayIDs = try await currentDisplayIDs()
            let request = VirtualDisplayRequest.mirrorDisplayDefault()
            var record = try await virtualDisplayProvider.createDisplay(request: request)
            virtualDisplayStore.save(record)
            currentVirtualDisplayRecord = record
            virtualDisplayStatus = strings.waitingForVirtualDisplayEnumeration()

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
            virtualDisplayStatus = strings.virtualDisplayReadyStartingStream()
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

        guard record.isBrowserDisplayOwned else {
            virtualDisplayState = .cleanupFailed
            virtualDisplayErrorMessage = VirtualDisplayError.unsafeRecord.localizedDescription
            virtualDisplayStatus = VirtualDisplayError.unsafeRecord.localizedDescription
            return
        }

        virtualDisplayState = .removing
        virtualDisplayStatus = strings.removingBrowserDisplayVirtualDisplay()
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
            virtualDisplayStatus = strings.manualBetterDisplayRemoval(record.displayName, error: error.localizedDescription)
        }
    }

    func cleanupVirtualDisplayOnExit() {
        guard shouldCleanupVirtualDisplayOnExit else {
            return
        }

        guard let record = currentVirtualDisplayRecord, record.isBrowserDisplayOwned, record.cleanupStatus != .removed else {
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
        preferences.set(enabled, forKey: "BrowserDisplay.VirtualDisplay.cleanupOnExit")
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
            connectionStatus = strings.chooseCaptureSource
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
            connectionStatus = strings.startsAfterClientConnects
            webViewerService.updateStreamState(
                isStreaming: true,
                quality: qualityLabel(for: config),
                codec: codecLabel(for: config),
                sourceName: currentStreamSourceName(),
                sourceKind: currentStreamSourceKind()
            )
        } catch {
            isStreaming = false
            connectionStatus = strings.streamFailed(error.localizedDescription)
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
            connectionStatus = strings.stopFailed(error.localizedDescription)
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
        if !connectionStatus.hasPrefix(strings.stopFailed("")) {
            connectionStatus = strings.ready
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
                    self.webViewerStatus = self.strings.connectedViewerCount(self.connectedWebViewers)
                }
            }
            webViewerService.onViewerDisconnected = { [weak self] in
                Task { @MainActor in
                    guard let self else {
                        return
                    }
                    self.connectedWebViewers = self.webViewerService.connectedViewerCount
                    self.webViewerStatus = self.connectedWebViewers > 0 ? self.strings.connectedViewerCount(self.connectedWebViewers) : self.strings.waitingBrowserViewer
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
                        self.webViewerStatus = self.strings.webRTCViewerCount(count)
                    } else if self.connectedWebViewers > 0 {
                        self.webViewerStatus = self.strings.connectedViewerCount(self.connectedWebViewers)
                    } else {
                        self.webViewerStatus = self.strings.waitingBrowserViewer
                    }
                }
            }
            webRTCSender.onStatusChanged = { [weak self] status in
                Task { @MainActor in
                    self?.webViewerStatus = self?.localizedWebRTCStatus(status) ?? status
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
            webViewerStatus = strings.waitingBrowserViewer
            connectionStatus = strings.localNetworkReady
        } catch {
            connectionStatus = strings.networkError(error.localizedDescription)
            webViewerStatus = strings.webViewerStartupFailed
        }
    }

    func copyWebViewerURL() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(webViewerURL, forType: .string)
        webViewerStatus = strings.addressCopied
    }

    func copyWebViewerPairingCode() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(webViewerPairingCode, forType: .string)
        webViewerStatus = strings.pairingCodeCopied
    }

    func regenerateWebViewerPairingCode() {
        webViewerService.regeneratePairingCode()
        webViewerPairingCode = webViewerService.pairingCode
        connectedWebViewers = webViewerService.connectedViewerCount
        webViewerStatus = strings.pairingCodeRefreshed
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

                    self.connectionStatus = self.strings.restoringCapture
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
            connectionStatus = strings.captureRestored
        } catch {
            connectionStatus = strings.recoverCaptureFailed(error.localizedDescription)
        }
    }

    private func restoreLastVirtualDisplayRecord() {
        guard currentVirtualDisplayRecord == nil else {
            return
        }

        if let record = virtualDisplayStore.activeBrowserDisplayRecords().sorted(by: { $0.createdAt > $1.createdAt }).first {
            currentVirtualDisplayRecord = record
            virtualDisplayState = record.cleanupStatus == .cleanupFailed ? .cleanupFailed : .ready
            virtualDisplayStatus = strings.leftoverVirtualDisplay(record.displayName)
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
            return strings.browserDisplayVirtualDisplay
        }

        if let selectedSourceID,
           let selectedSource = captureSources.first(where: { $0.id == selectedSourceID }) {
            return selectedSource.name
        }

        return strings.noneSelected
    }

    private func currentStreamSourceKind() -> String {
        if currentStreamSourceName() == strings.browserDisplayVirtualDisplay {
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

    private func relocalizeStableStatuses() {
        if hasCheckedScreenRecordingAccess {
            if hasScreenRecordingAccess {
                screenRecordingStatus = captureSources.isEmpty ? strings.noSourcesFound : strings.ready
            } else {
                screenRecordingStatus = strings.screenRecordingRestartRequired
            }
        } else {
            screenRecordingStatus = strings.checkingScreenRecording
        }

        if isStreaming {
            connectionStatus = strings.startsAfterClientConnects
        } else if !webViewerURL.isEmpty {
            connectionStatus = strings.localNetworkReady
        } else {
            connectionStatus = strings.starting
        }

        if connectedWebViewers > 0 {
            webViewerStatus = strings.connectedViewerCount(connectedWebViewers)
        } else {
            webViewerStatus = webViewerURL.isEmpty ? strings.starting : strings.waitingBrowserViewer
        }

        if let record = currentVirtualDisplayRecord, record.cleanupStatus != .removed {
            virtualDisplayStatus = strings.virtualDisplayReadyMessage()
        } else {
            switch virtualDisplayState {
            case .unavailable:
                virtualDisplayStatus = strings.betterDisplayUnavailable
            case .installedNotRunning:
                virtualDisplayStatus = strings.betterDisplayInstalledNotRunning
            case .readyToCreate, .ready:
                virtualDisplayStatus = strings.betterDisplayReady
            case .creating:
                virtualDisplayStatus = strings.creatingBrowserDisplayVirtualDisplay()
            case .removing:
                virtualDisplayStatus = strings.removingBrowserDisplayVirtualDisplay()
            case .createFailed, .cleanupFailed:
                break
            }
        }
    }

    private func localizedAvailabilityMessage(_ availability: VirtualDisplayAvailability) -> String {
        switch availability.status {
        case .unavailable:
            return strings.betterDisplayUnavailable
        case .installedNotRunning:
            return strings.betterDisplayInstalledNotRunning
        case .ready:
            return strings.betterDisplayReady
        }
    }

    private func localizedWebRTCStatus(_ status: String) -> String {
        switch status {
        case "收到 WebRTC offer":
            return strings.text("Received WebRTC offer", "收到 WebRTC offer")
        case "设置 remote SDP 失败":
            return strings.text("Failed to set remote SDP", "设置 remote SDP 失败")
        case "生成 WebRTC answer 失败":
            return strings.text("Failed to create WebRTC answer", "生成 WebRTC answer 失败")
        case "设置 local SDP 失败":
            return strings.text("Failed to set local SDP", "设置 local SDP 失败")
        case "已发送 WebRTC answer":
            return strings.text("Sent WebRTC answer", "已发送 WebRTC answer")
        case "添加 ICE candidate 失败":
            return strings.text("Failed to add ICE candidate", "添加 ICE candidate 失败")
        default:
            if status.hasPrefix("WebRTC 已推送首帧 ") {
                let suffix = status.replacingOccurrences(of: "WebRTC 已推送首帧 ", with: "")
                return strings.text("WebRTC pushed first frame \(suffix)", status)
            }
            return status
        }
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
