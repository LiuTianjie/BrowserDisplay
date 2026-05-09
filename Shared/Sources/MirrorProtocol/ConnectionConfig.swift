import Foundation

public enum VideoCodec: String, Codable, Sendable, CaseIterable {
    case vp8
    case h264
    case hevc
}

public struct StreamConfig: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var codec: VideoCodec
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int
    public var bitrate: Int
    public var captureSourceID: String?

    public init(
        id: String,
        codec: VideoCodec,
        width: Int,
        height: Int,
        framesPerSecond: Int,
        bitrate: Int,
        captureSourceID: String? = nil
    ) {
        self.id = id
        self.codec = codec
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.bitrate = bitrate
        self.captureSourceID = captureSourceID
    }

    public static let presets: [StreamConfig] = [
        StreamConfig(id: "720p30", codec: .h264, width: 1280, height: 720, framesPerSecond: 30, bitrate: 5_000_000),
        StreamConfig(id: "720p60", codec: .h264, width: 1280, height: 720, framesPerSecond: 60, bitrate: 7_000_000),
        StreamConfig(id: "768p60", codec: .h264, width: 1366, height: 768, framesPerSecond: 60, bitrate: 8_000_000),
        StreamConfig(id: "900p60", codec: .h264, width: 1600, height: 900, framesPerSecond: 60, bitrate: 10_000_000),
        StreamConfig(id: "1080p30", codec: .h264, width: 1920, height: 1080, framesPerSecond: 30, bitrate: 12_000_000),
        StreamConfig(id: "1080p60", codec: .h264, width: 1920, height: 1080, framesPerSecond: 60, bitrate: 18_000_000),
        StreamConfig(id: "1200p60", codec: .h264, width: 1920, height: 1200, framesPerSecond: 60, bitrate: 20_000_000),
        StreamConfig(id: "1440p30", codec: .h264, width: 2560, height: 1440, framesPerSecond: 30, bitrate: 22_000_000),
        StreamConfig(id: "1440p60", codec: .h264, width: 2560, height: 1440, framesPerSecond: 60, bitrate: 32_000_000),
        StreamConfig(id: "1600p60", codec: .h264, width: 2560, height: 1600, framesPerSecond: 60, bitrate: 36_000_000),
        StreamConfig(id: "2160p30", codec: .h264, width: 3840, height: 2160, framesPerSecond: 30, bitrate: 42_000_000)
    ]
}
