import AppKit
import Foundation

final class BetterDisplayProvider: VirtualDisplayProvider {
    static let providerName = "BetterDisplay"

    let name = BetterDisplayProvider.providerName

    private let fileManager: FileManager
    private let timeout: TimeInterval

    init(fileManager: FileManager = .default, timeout: TimeInterval = 20) {
        self.fileManager = fileManager
        self.timeout = timeout
    }

    func availability() async -> VirtualDisplayAvailability {
        let appURL = findApplicationURL()
        let executableURL = findExecutableURL(appURL: appURL)

        guard appURL != nil || executableURL != nil else {
            return VirtualDisplayAvailability(
                status: .unavailable,
                providerName: name,
                executableURL: nil,
                appURL: nil,
                message: "需要 BetterDisplay 创建 macOS 虚拟显示器。MirrorDisplay 会捕获这块专用屏幕并发送到 WebViewer。"
            )
        }

        let isRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.waydabber.BetterDisplay").isEmpty == false
        return VirtualDisplayAvailability(
            status: isRunning ? .ready : .installedNotRunning,
            providerName: name,
            executableURL: executableURL,
            appURL: appURL,
            message: isRunning ? "BetterDisplay 已就绪。" : "已安装 BetterDisplay，可尝试启动后创建虚拟屏。"
        )
    }

    func createDisplay(request: VirtualDisplayRequest) async throws -> VirtualDisplayRecord {
        let availability = await availability()
        guard availability.isAvailable else {
            throw VirtualDisplayError.providerUnavailable(availability.message)
        }

        if availability.status == .installedNotRunning, let appURL = availability.appURL {
            NSWorkspace.shared.open(appURL)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        let executableURL = try executableURL(from: availability)
        let primaryArguments = [
            "create",
            "-type=VirtualScreen",
            "-virtualScreenName=\(request.displayName)",
            "-aspectWidth=\(request.aspectWidth)",
            "-aspectHeight=\(request.aspectHeight)",
            "-virtualScreenHiDPI=\(request.isHiDPIEnabled ? "on" : "off")",
            "-resolutionList=\(request.resolutionList.joined(separator: ","))"
        ]
        var result = try await run(executableURL: executableURL, arguments: primaryArguments, commandName: "BetterDisplay create")

        if result.exitCode != 0 {
            let fallbackArguments = [
                "create",
                "-devicetype=virtualscreen",
                "-virtualscreenname=\(request.displayName)",
                "-aspectWidth=\(request.aspectWidth)",
                "-aspectHeight=\(request.aspectHeight)",
                "-virtualScreenHiDPI=\(request.isHiDPIEnabled ? "on" : "off")",
                "-resolutionList=\(request.resolutionList.joined(separator: ","))"
            ]
            result = try await run(executableURL: executableURL, arguments: fallbackArguments, commandName: "BetterDisplay create")
        }

        guard result.exitCode == 0 else {
            throw VirtualDisplayError.commandFailed(result.userVisibleFailure(commandName: "BetterDisplay create"))
        }

        return VirtualDisplayRecord(displayName: request.displayName, provider: name)
    }

    func removeDisplay(record: VirtualDisplayRecord) async throws {
        guard record.isMirrorDisplayOwned else {
            throw VirtualDisplayError.unsafeRecord
        }

        let availability = await availability()
        guard availability.isAvailable else {
            throw VirtualDisplayError.providerUnavailable(availability.message)
        }

        let executableURL = try executableURL(from: availability)
        let primaryArguments = [
            "discard",
            "-name=\(record.displayName)"
        ]
        var result = try await run(executableURL: executableURL, arguments: primaryArguments, commandName: "BetterDisplay discard")

        if result.exitCode != 0 {
            let fallbackArguments = [
                "discard",
                "-namelike=\(record.displayName)"
            ]
            result = try await run(executableURL: executableURL, arguments: fallbackArguments, commandName: "BetterDisplay discard")
        }

        guard result.exitCode == 0 else {
            throw VirtualDisplayError.commandFailed(result.userVisibleFailure(commandName: "BetterDisplay discard"))
        }
    }

    func openInstallPage() {
        guard let url = URL(string: "https://betterdisplay.pro/") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func executableURL(from availability: VirtualDisplayAvailability) throws -> URL {
        if let executableURL = availability.executableURL {
            return executableURL
        }

        throw VirtualDisplayError.providerUnavailable("无法找到 BetterDisplay 命令行入口。请确认 BetterDisplay 已安装在 Applications 中。")
    }

    private func findApplicationURL() -> URL? {
        let candidates = [
            URL(fileURLWithPath: "/Applications/BetterDisplay.app"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/BetterDisplay.app")
        ]

        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    private func findExecutableURL(appURL: URL?) -> URL? {
        let appExecutableURL = appURL?.appendingPathComponent("Contents/MacOS/BetterDisplay")
        if let appExecutableURL, fileManager.isExecutableFile(atPath: appExecutableURL.path) {
            return appExecutableURL
        }

        let cliCandidates = [
            "/opt/homebrew/bin/betterdisplaycli",
            "/usr/local/bin/betterdisplaycli",
            "/usr/bin/betterdisplaycli",
            "/bin/betterdisplaycli"
        ].map(URL.init(fileURLWithPath:))

        return cliCandidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func run(executableURL: URL, arguments: [String], commandName: String) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let gate = ProcessContinuationGate(continuation: continuation)

            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.terminationHandler = { process in
                let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                gate.finish(.success(ProcessResult(exitCode: process.terminationStatus, output: output, error: error)))
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                }
                gate.finish(.failure(VirtualDisplayError.commandTimedOut(commandName)))
            }

            do {
                try process.run()
            } catch {
                gate.finish(.failure(VirtualDisplayError.commandFailed(error.localizedDescription)))
            }
        }
    }
}

private final class ProcessContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<ProcessResult, Error>

    init(continuation: CheckedContinuation<ProcessResult, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<ProcessResult, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else {
            return
        }
        didResume = true

        switch result {
        case .success(let processResult):
            continuation.resume(returning: processResult)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private struct ProcessResult {
    var exitCode: Int32
    var output: String
    var error: String

    func userVisibleFailure(commandName: String) -> String {
        let detail = [error, output]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "未知错误"
        return "\(commandName) 失败：\(detail)"
    }
}
