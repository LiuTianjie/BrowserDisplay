import Foundation

enum VirtualDisplayProviderStatus: String, Codable {
    case unavailable
    case installedNotRunning
    case ready
}

struct VirtualDisplayAvailability: Equatable {
    var status: VirtualDisplayProviderStatus
    var providerName: String
    var executableURL: URL?
    var appURL: URL?
    var message: String

    var isAvailable: Bool {
        status == .ready || status == .installedNotRunning
    }
}

struct VirtualDisplayRequest: Equatable {
    var displayName: String
    var aspectWidth: Int
    var aspectHeight: Int
    var isHiDPIEnabled: Bool
    var resolutionList: [String]

    static func mirrorDisplayDefault() -> VirtualDisplayRequest {
        let suffix = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(4)
            .uppercased()

        return VirtualDisplayRequest(
            displayName: "BrowserDisplay-\(suffix)",
            aspectWidth: 16,
            aspectHeight: 9,
            isHiDPIEnabled: true,
            resolutionList: ["1920x1080", "2560x1440"]
        )
    }
}

struct VirtualDisplayRecord: Codable, Equatable, Identifiable {
    var id: String
    var displayName: String
    var createdAt: Date
    var provider: String
    var displayID: UInt32?
    var cleanupStatus: VirtualDisplayCleanupStatus

    init(
        id: String = UUID().uuidString,
        displayName: String,
        createdAt: Date = Date(),
        provider: String,
        displayID: UInt32? = nil,
        cleanupStatus: VirtualDisplayCleanupStatus = .active
    ) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.provider = provider
        self.displayID = displayID
        self.cleanupStatus = cleanupStatus
    }

    var isBrowserDisplayOwned: Bool {
        provider == BetterDisplayProvider.providerName && displayName.hasPrefix("BrowserDisplay-")
    }
}

enum VirtualDisplayCleanupStatus: String, Codable {
    case active
    case cleanupFailed
    case removed
}

enum VirtualDisplayPanelState: Equatable {
    case unavailable
    case installedNotRunning
    case readyToCreate
    case creating
    case ready
    case removing
    case createFailed
    case cleanupFailed

    var title: String {
        switch self {
        case .unavailable:
            return "未检测到 BetterDisplay"
        case .installedNotRunning:
            return "BetterDisplay 未运行"
        case .readyToCreate:
            return "可创建虚拟屏"
        case .creating:
            return "正在创建"
        case .ready:
            return "虚拟屏已就绪"
        case .removing:
            return "正在移除"
        case .createFailed:
            return "创建失败"
        case .cleanupFailed:
            return "清理失败"
        }
    }
}

enum VirtualDisplayError: LocalizedError {
    case providerUnavailable(String)
    case commandFailed(String)
    case commandTimedOut(String)
    case createdDisplayNotFound
    case unsafeRecord

    var errorDescription: String? {
        switch self {
        case .providerUnavailable(let message):
            return message
        case .commandFailed(let message):
            return message
        case .commandTimedOut(let command):
            return "\(command) 执行超时。"
        case .createdDisplayNotFound:
            return "虚拟屏已创建，但 10 秒内没有出现在可捕获显示器列表中。请刷新捕获源后手动选择新增显示器。"
        case .unsafeRecord:
            return "这块虚拟屏不是 BrowserDisplay 本次记录创建的屏幕，已跳过清理。"
        }
    }
}
