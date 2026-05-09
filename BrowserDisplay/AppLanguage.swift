import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh-Hans"

    var id: String { rawValue }

    static let preferenceKey = "BrowserDisplay.AppLanguage"

    static func saved(in defaults: UserDefaults = .standard) -> AppLanguage {
        if let rawValue = defaults.string(forKey: preferenceKey),
           let language = AppLanguage(rawValue: rawValue) {
            return language
        }

        if Locale.preferredLanguages.first?.hasPrefix("zh") == true {
            return .chinese
        }

        return .english
    }

    var next: AppLanguage {
        switch self {
        case .english:
            return .chinese
        case .chinese:
            return .english
        }
    }

    var switchTitle: String {
        switch self {
        case .english:
            return "中文"
        case .chinese:
            return "EN"
        }
    }

    var switchAccessibilityLabel: String {
        switch self {
        case .english:
            return "Switch language to Chinese"
        case .chinese:
            return "切换语言为英文"
        }
    }

    var strings: AppStrings {
        AppStrings(language: self)
    }
}

struct AppStrings {
    var language: AppLanguage

    func text(_ english: String, _ chinese: String) -> String {
        switch language {
        case .english:
            return english
        case .chinese:
            return chinese
        }
    }

    var subtitle: String { text("Turn browser devices into low-latency displays, with virtual display support", "把浏览器设备变成低延迟显示器，支持虚拟屏") }
    var captureSources: String { text("Capture Sources", "捕获源") }
    var refresh: String { text("Refresh", "刷新") }
    var authorizeAccess: String { text("Allow Access", "授权访问") }
    var session: String { text("Session", "会话") }
    var host: String { text("Host", "主机") }
    var permission: String { text("Permission", "权限") }
    var generatingAddress: String { text("Generating address", "正在生成地址") }
    var copy: String { text("Copy", "复制") }
    var open: String { text("Open", "打开") }
    var pairingCode: String { text("Pairing Code", "配对码") }
    var copyPairingCode: String { text("Copy pairing code", "复制配对码") }
    var refreshPairingCode: String { text("Refresh pairing code and disconnect the current viewer", "刷新配对码并断开当前 Viewer") }
    var quality: String { text("Quality", "画质") }
    var stopStreaming: String { text("Stop Streaming", "停止传输") }
    var startStreaming: String { text("Start Streaming", "开始传输") }
    var openSystemSettings: String { text("Open System Settings", "打开系统设置") }
    var recheck: String { text("Recheck", "重新检查") }
    var refreshSources: String { text("Refresh Sources", "刷新源") }
    var virtualDisplayMode: String { text("Extended Display Experiment", "扩展屏实验模式") }
    var virtualDisplay: String { text("Virtual Display", "虚拟屏") }
    var virtualDisplayNote: String { text("Virtual displays are provided by BetterDisplay and may depend on your BetterDisplay license or macOS version.", "虚拟屏由 BetterDisplay 提供，可能受 BetterDisplay 授权或 macOS 版本影响。") }
    var removeOnExit: String { text("Remove automatically when quitting", "退出应用时自动移除") }
    var removeVirtualDisplay: String { text("Remove Virtual Display", "移除虚拟屏") }
    var check: String { text("Check", "检测") }
    var installGuide: String { text("Install Guide", "安装说明") }
    var displaySettings: String { text("Display Settings", "显示器设置") }
    var startAndCreateVirtualDisplay: String { text("Launch and Create Virtual Display", "启动并创建虚拟屏") }
    var creating: String { text("Creating", "正在创建") }
    var createVirtualDisplayAndStart: String { text("Create Virtual Display and Start Streaming", "创建虚拟屏并开始传输") }
    var lockedWhileStreaming: String { text("Locked while streaming", "传输中锁定") }
    var scope: String { text("Scope", "范围") }
    var selected: String { text("Selected", "已选中") }
    var sourceCount: String { text("Capture source count", "捕获源数量") }
    var fullScreen: String { text("Display", "整屏") }
    var window: String { text("Window", "窗口") }
    var select: String { text("Select", "选择") }
    var resolution: String { text("Resolution", "分辨率") }
    var frameRate: String { text("Frame Rate", "帧率") }
    var bitrate: String { text("Bitrate", "码率") }
    var highLoad: String { text("High load", "高负载") }
    var recommended: String { text("Recommended", "推荐") }
    var noCaptureSources: String { text("No capture sources", "暂无可捕获源") }
    var permissionRestartHint: String { text("If this still appears after granting access, quit and reopen the Mac app. Screen Recording permission usually requires an app restart.", "授权后如果仍提示，请退出并重新打开 Mac 端应用。macOS 的屏幕录制权限通常需要重启应用才会生效。") }
    var currentDesktop: String { text("Current Desktop", "当前桌面") }
    var allDesktops: String { text("All Desktops", "全部桌面") }
    var ready: String { text("Ready", "已就绪") }
    var starting: String { text("Starting", "正在启动") }
    var checkingScreenRecording: String { text("Checking Screen Recording permission", "正在检查屏幕录制权限") }
    var needsScreenRecording: String { text("Screen Recording permission required", "需要屏幕录制权限") }
    var readingSources: String { text("Reading capturable screens and windows", "正在读取可捕获屏幕和窗口") }
    var noSourcesFound: String { text("No capturable screens or windows found", "未找到可捕获屏幕或窗口") }
    var requestingScreenRecording: String { text("Requesting Screen Recording permission", "正在请求屏幕录制权限") }
    var screenRecordingRestartRequired: String { text("Screen Recording permission is required. Allow it in System Settings, then quit and reopen the Mac app.", "需要屏幕录制权限。请在系统设置中允许后，退出并重新打开 Mac 端应用。") }
    var checkingBetterDisplay: String { text("Checking BetterDisplay", "正在检测 BetterDisplay") }
    var betterDisplayUnavailable: String { text("BetterDisplay is needed to create a macOS virtual display. BrowserDisplay captures that dedicated display and sends it to WebViewer.", "需要 BetterDisplay 创建 macOS 虚拟显示器。BrowserDisplay 会捕获这块专用屏幕并发送到 WebViewer。") }
    var betterDisplayReady: String { text("BetterDisplay is ready.", "BetterDisplay 已就绪。") }
    var betterDisplayInstalledNotRunning: String { text("BetterDisplay is installed. BrowserDisplay can try launching it before creating a virtual display.", "已安装 BetterDisplay，可尝试启动后创建虚拟屏。") }
    var localNetworkReady: String { text("Available on local network", "局域网可连接") }
    var waitingBrowserViewer: String { text("Waiting for browser viewer", "等待浏览器 Viewer") }
    var webViewerStartupFailed: String { text("WebViewer failed to start", "WebViewer 启动失败") }
    var addressCopied: String { text("Address copied", "已复制地址") }
    var pairingCodeCopied: String { text("Pairing code copied", "已复制配对码") }
    var pairingCodeRefreshed: String { text("Pairing code refreshed", "配对码已刷新") }
    var chooseCaptureSource: String { text("Select a capture source first", "请先选择捕获源") }
    var startsAfterClientConnects: String { text("Streaming starts after a client connects", "客户端连接后开始传输") }
    var restoringCapture: String { text("Video stalled, recovering capture", "画面停滞，正在恢复采集") }
    var captureRestored: String { text("Capture restored", "采集已恢复") }
    var browserDisplayVirtualDisplay: String { text("BrowserDisplay Virtual Display", "BrowserDisplay 虚拟屏") }
    var noneSelected: String { text("None selected", "未选择") }

    func readSourcesFailed(_ message: String) -> String { text("Failed to read capture sources: \(message)", "读取捕获源失败：\(message)") }
    func streamFailed(_ message: String) -> String { text("Streaming failed: \(message)", "传输失败：\(message)") }
    func stopFailed(_ message: String) -> String { text("Failed to stop: \(message)", "停止失败：\(message)") }
    func networkError(_ message: String) -> String { text("Network error: \(message)", "网络错误：\(message)") }
    func recoverCaptureFailed(_ message: String) -> String { text("Failed to recover capture: \(message)", "恢复采集失败：\(message)") }
    func connectedViewerCount(_ count: Int) -> String {
        count == 1 ? text("1 viewer connected", "1 个 Viewer 已连接") : text("\(count) viewers connected", "\(count) 个 Viewer 已连接")
    }
    func webRTCViewerCount(_ count: Int) -> String {
        count == 1 ? text("WebRTC connected", "WebRTC 已连接") : text("\(count) WebRTC viewers", "\(count) 个 WebRTC Viewer")
    }
    func virtualDisplayReadyMessage() -> String { text("Virtual display is ready. Move windows to the BrowserDisplay screen, or remove this virtual display.", "虚拟屏已就绪。把窗口拖到 BrowserDisplay 屏幕，或移除这块虚拟屏。") }
    func creatingBrowserDisplayVirtualDisplay() -> String { text("Creating a BrowserDisplay virtual display through BetterDisplay", "正在通过 BetterDisplay 创建 BrowserDisplay 虚拟屏") }
    func waitingForVirtualDisplayEnumeration() -> String { text("Virtual display created. Waiting for macOS to enumerate it.", "虚拟屏已创建，正在等待 macOS 枚举显示器") }
    func virtualDisplayReadyStartingStream() -> String { text("Virtual display is ready. Move windows to the BrowserDisplay screen. Starting streaming.", "虚拟屏已就绪。把窗口拖到 BrowserDisplay 屏幕，正在开始传输。") }
    func removingBrowserDisplayVirtualDisplay() -> String { text("Removing the virtual display created by BrowserDisplay", "正在移除 BrowserDisplay 创建的虚拟屏") }
    func manualBetterDisplayRemoval(_ displayName: String, error: String) -> String { text("\(error) You can manually remove \(displayName) in BetterDisplay.", "\(error) 可在 BetterDisplay 中手动删除 \(displayName)。") }
    func leftoverVirtualDisplay(_ displayName: String) -> String { text("Found leftover \(displayName) from last time. Click Remove Virtual Display to clean it up.", "检测到上次遗留的 \(displayName)，可点击移除虚拟屏清理。") }
    func virtualDisplayStateTitle(_ state: VirtualDisplayPanelState) -> String {
        switch state {
        case .unavailable:
            return text("BetterDisplay not found", "未检测到 BetterDisplay")
        case .installedNotRunning:
            return text("BetterDisplay not running", "BetterDisplay 未运行")
        case .readyToCreate:
            return text("Ready to create", "可创建虚拟屏")
        case .creating:
            return creating
        case .ready:
            return text("Virtual display ready", "虚拟屏已就绪")
        case .removing:
            return text("Removing", "正在移除")
        case .createFailed:
            return text("Create failed", "创建失败")
        case .cleanupFailed:
            return text("Cleanup failed", "清理失败")
        }
    }
}
