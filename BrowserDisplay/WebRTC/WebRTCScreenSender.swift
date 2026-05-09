import CoreMedia
import Foundation
import LiveKitWebRTC
import MirrorProtocol

private typealias RTCPeerConnectionFactory = LKRTCPeerConnectionFactory
private typealias RTCDefaultVideoEncoderFactory = LKRTCDefaultVideoEncoderFactory
private typealias RTCDefaultVideoDecoderFactory = LKRTCDefaultVideoDecoderFactory
private typealias RTCVideoSource = LKRTCVideoSource
private typealias RTCVideoTrack = LKRTCVideoTrack
private typealias RTCVideoCapturer = LKRTCVideoCapturer
private typealias RTCCVPixelBuffer = LKRTCCVPixelBuffer
private typealias RTCVideoFrame = LKRTCVideoFrame
private typealias RTCPeerConnection = LKRTCPeerConnection
private typealias RTCPeerConnectionDelegate = LKRTCPeerConnectionDelegate
private typealias RTCSignalingState = LKRTCSignalingState
private typealias RTCMediaStream = LKRTCMediaStream
private typealias RTCIceConnectionState = LKRTCIceConnectionState
private typealias RTCIceGatheringState = LKRTCIceGatheringState
private typealias RTCIceCandidate = LKRTCIceCandidate
private typealias RTCConfiguration = LKRTCConfiguration
private typealias RTCMediaConstraints = LKRTCMediaConstraints
private typealias RTCSessionDescription = LKRTCSessionDescription
private typealias RTCDataChannel = LKRTCDataChannel
private typealias RTCRtpSender = LKRTCRtpSender
private typealias RTCRtpEncodingParameters = LKRTCRtpEncodingParameters

final class WebRTCScreenSender {
    var onLocalSignal: ((String, String) -> Void)?
    var onViewerCountChanged: ((Int) -> Void)?
    var onStatusChanged: ((String) -> Void)?

    private let queue = DispatchQueue(label: "mirror-display.webrtc.sender", qos: .userInteractive)
    private let factory: RTCPeerConnectionFactory
    private let videoSource: RTCVideoSource
    private let videoTrack: RTCVideoTrack
    private let capturer: RTCVideoCapturer
    private var sessions: [String: ViewerSession] = [:]
    private var config = StreamConfig.presets[0]
    private var isStreaming = false
    private var pushedFrameCount = 0
    private var lastPushedFrameAtNs: UInt64 = 0
    private var lastPixelBuffer: CVPixelBuffer?
    private var framePumpTimer: DispatchSourceTimer?

    init() {
        LKRTCInitializeSSL()

        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        videoSource = factory.videoSource(forScreenCast: true)
        videoTrack = factory.videoTrack(with: videoSource, trackId: "mirror-screen-video")
        capturer = RTCVideoCapturer(delegate: videoSource)
    }

    func start(config: StreamConfig) {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            self.config = config
            self.isStreaming = true
            self.pushedFrameCount = 0
            self.lastPushedFrameAtNs = 0
            self.videoSource.adaptOutputFormat(toWidth: Int32(config.width), height: Int32(config.height), fps: Int32(config.framesPerSecond))
            self.videoTrack.isEnabled = true
            self.sessions.values.forEach { self.applyEncodingParameters(to: $0.sender) }
            self.startFramePump()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            self.isStreaming = false
            self.pushedFrameCount = 0
            self.lastPushedFrameAtNs = 0
            self.lastPixelBuffer = nil
            self.stopFramePump()
            self.videoTrack.isEnabled = false
            self.sessions.values.forEach { $0.peerConnection.close() }
            self.sessions.removeAll()
            self.notifyViewerCountChanged()
        }
    }

    func handleSignal(_ envelope: WebViewerSignalEnvelope) {
        queue.async { [weak self] in
            guard let self, envelope.role == "viewer" else {
                return
            }

            guard let signal = try? JSONDecoder().decode(ViewerSignal.self, from: Data(envelope.payload.utf8)) else {
                return
            }

            switch signal.type {
            case "webrtc-offer":
                guard let sdp = signal.sdp else {
                    return
                }
                self.handleOffer(sdp, from: envelope.clientID)
            case "ice-candidate":
                guard let candidate = signal.candidate else {
                    return
                }
                self.handleRemoteCandidate(candidate, from: envelope.clientID)
            default:
                break
            }
        }
    }

    func push(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        queue.async { [weak self, imageBuffer] in
            guard let self, self.isStreaming else {
                return
            }

            self.lastPixelBuffer = imageBuffer
            guard !self.sessions.isEmpty else {
                return
            }

            self.push(pixelBuffer: imageBuffer)
        }
    }

    private func handleOffer(_ sdp: SessionDescriptionPayload, from clientID: String) {
        onStatusChanged?("收到 WebRTC offer")

        if let existingSession = sessions[clientID] {
            existingSession.peerConnection.close()
            sessions.removeValue(forKey: clientID)
        }

        guard let session = makeSession(for: clientID) else {
            return
        }
        sessions[clientID] = session
        notifyViewerCountChanged()

        let remoteDescription = RTCSessionDescription(type: .offer, sdp: sdp.sdp)
        session.peerConnection.setRemoteDescription(remoteDescription) { [weak self, weak session] error in
            guard let self, let session, error == nil else {
                self?.onStatusChanged?("设置 remote SDP 失败")
                return
            }

            let constraints = RTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: ["googCpuOveruseDetection": "false"]
            )
            session.peerConnection.answer(for: constraints) { [weak self, weak session] answer, error in
                guard let self, let session, let answer, error == nil else {
                    self?.onStatusChanged?("生成 WebRTC answer 失败")
                    return
                }

                let optimizedSDP = SDPOptimizer.optimize(
                    answer.sdp,
                    codec: self.preferredCodecName(for: self.config),
                    bitrate: self.config.bitrate
                )
                let preferredAnswer = RTCSessionDescription(
                    type: .answer,
                    sdp: optimizedSDP
                )
                session.peerConnection.setLocalDescription(preferredAnswer) { [weak self] error in
                    guard error == nil else {
                        self?.onStatusChanged?("设置 local SDP 失败")
                        return
                    }
                    self?.sendAnswer(preferredAnswer, to: clientID)
                    self?.pushCachedFrameBurst()
                    self?.onStatusChanged?("已发送 WebRTC answer")
                }
            }
        }
    }

    private func handleRemoteCandidate(_ candidate: IceCandidatePayload, from clientID: String) {
        guard let session = sessions[clientID] else {
            return
        }

        let rtcCandidate = RTCIceCandidate(
            sdp: candidate.candidate,
            sdpMLineIndex: candidate.sdpMLineIndex,
            sdpMid: candidate.sdpMid
        )
        session.peerConnection.add(rtcCandidate) { [weak self] error in
            if error != nil {
                self?.onStatusChanged?("添加 ICE candidate 失败")
            }
        }
    }

    private func makeSession(for clientID: String) -> ViewerSession? {
        let delegate = ViewerPeerDelegate()
        delegate.onStateChanged = { [weak self] state in
            self?.queue.async {
                self?.onStatusChanged?(state)
            }
        }
        delegate.onCandidate = { [weak self] candidate in
            self?.queue.async {
                guard self?.sessions[clientID]?.delegate === delegate else {
                    return
                }
                self?.sendCandidate(candidate, to: clientID)
            }
        }
        delegate.onClosed = { [weak self] in
            self?.queue.async {
                guard self?.sessions[clientID]?.delegate === delegate else {
                    return
                }
                self?.sessions.removeValue(forKey: clientID)
                self?.notifyViewerCountChanged()
            }
        }
        delegate.onConnected = { [weak self] in
            self?.queue.async {
                guard self?.sessions[clientID]?.delegate === delegate else {
                    return
                }
                self?.pushCachedFrameBurst()
            }
        }

        let rtcConfig = RTCConfiguration()
        rtcConfig.iceServers = []
        rtcConfig.bundlePolicy = .maxBundle
        rtcConfig.rtcpMuxPolicy = .require
        rtcConfig.sdpSemantics = .unifiedPlan
        rtcConfig.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        guard let peerConnection = factory.peerConnection(with: rtcConfig, constraints: constraints, delegate: delegate) else {
            return nil
        }
        guard let sender = peerConnection.add(videoTrack, streamIds: ["mirror-screen"]) else {
            return nil
        }
        applyEncodingParameters(to: sender)

        return ViewerSession(peerConnection: peerConnection, sender: sender, delegate: delegate)
    }

    private func pushCachedFrameBurst() {
        guard isStreaming, let lastPixelBuffer else {
            return
        }

        for index in 0..<12 {
            queue.asyncAfter(deadline: .now() + .milliseconds(index * 250)) { [weak self, lastPixelBuffer] in
                guard let self, self.isStreaming, !self.sessions.isEmpty else {
                    return
                }

                self.push(pixelBuffer: lastPixelBuffer)
            }
        }
    }

    private func push(pixelBuffer: CVPixelBuffer) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: Int64(nowNs))
        videoSource.capturer(capturer, didCapture: frame)
        lastPushedFrameAtNs = nowNs
        pushedFrameCount += 1
        if pushedFrameCount == 1 {
            onStatusChanged?("WebRTC 已推送首帧 \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
        }
    }

    private func startFramePump() {
        stopFramePump()

        let keepaliveFPS = max(1, min(config.framesPerSecond, 60))
        let intervalNs = UInt64(1_000_000_000 / keepaliveFPS)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .nanoseconds(Int(intervalNs)),
            repeating: .nanoseconds(Int(intervalNs)),
            leeway: .milliseconds(config.framesPerSecond > 30 ? 2 : 5)
        )
        timer.setEventHandler { [weak self] in
            guard
                let self,
                self.isStreaming,
                !self.sessions.isEmpty,
                let lastPixelBuffer = self.lastPixelBuffer
            else {
                return
            }

            let nowNs = DispatchTime.now().uptimeNanoseconds
            guard self.lastPushedFrameAtNs == 0 || nowNs - self.lastPushedFrameAtNs >= intervalNs else {
                return
            }

            self.push(pixelBuffer: lastPixelBuffer)
        }
        framePumpTimer = timer
        timer.resume()
    }

    private func stopFramePump() {
        framePumpTimer?.cancel()
        framePumpTimer = nil
    }

    private func applyEncodingParameters(to sender: RTCRtpSender) {
        let parameters = sender.parameters
        var encodings = parameters.encodings
        let encoding = encodings.first ?? RTCRtpEncodingParameters()

        encoding.isActive = true
        encoding.maxBitrateBps = NSNumber(value: config.bitrate)
        encoding.minBitrateBps = NSNumber(value: max(800_000, Int(Double(config.bitrate) * 0.25)))
        encoding.maxFramerate = NSNumber(value: config.framesPerSecond)
        encoding.scaleResolutionDownBy = NSNumber(value: 1.0)
        encoding.bitratePriority = 2.0
        encoding.networkPriority = .high

        if encodings.isEmpty {
            encodings = [encoding]
        } else {
            encodings[0] = encoding
        }
        parameters.encodings = encodings
        parameters.degradationPreference = NSNumber(value: 2)
        sender.parameters = parameters
    }

    private func preferredCodecName(for config: StreamConfig) -> String {
        switch config.codec {
        case .h264:
            return "H264"
        case .vp8:
            return "VP8"
        case .hevc:
            return "H264"
        }
    }

    private func sendAnswer(_ answer: RTCSessionDescription, to clientID: String) {
        let message = OutgoingAnswer(
            sdp: SessionDescriptionPayload(type: "answer", sdp: answer.sdp)
        )
        send(message, to: clientID)
    }

    private func sendCandidate(_ candidate: RTCIceCandidate, to clientID: String) {
        let message = OutgoingCandidate(
            candidate: IceCandidatePayload(
                candidate: candidate.sdp,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: candidate.sdpMLineIndex
            )
        )
        send(message, to: clientID)
    }

    private func send<T: Encodable>(_ message: T, to clientID: String) {
        guard
            let data = try? JSONEncoder().encode(message),
            let text = String(data: data, encoding: .utf8)
        else {
            return
        }
        onLocalSignal?(text, clientID)
    }

    private func notifyViewerCountChanged() {
        onViewerCountChanged?(sessions.count)
    }

}

private final class ViewerSession {
    let peerConnection: RTCPeerConnection
    let sender: RTCRtpSender
    let delegate: ViewerPeerDelegate

    init(peerConnection: RTCPeerConnection, sender: RTCRtpSender, delegate: ViewerPeerDelegate) {
        self.peerConnection = peerConnection
        self.sender = sender
        self.delegate = delegate
    }
}

private final class ViewerPeerDelegate: NSObject, RTCPeerConnectionDelegate {
    var onCandidate: ((RTCIceCandidate) -> Void)?
    var onConnected: (() -> Void)?
    var onClosed: (() -> Void)?
    var onStateChanged: ((String) -> Void)?

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        onStateChanged?("Signaling \(stateChanged.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        onStateChanged?("ICE \(newState.rawValue)")

        switch newState {
        case .closed, .failed:
            onClosed?()
        case .connected, .completed:
            onConnected?()
        case .new, .checking, .disconnected, .count:
            break
        @unknown default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        onStateChanged?("ICE gathering \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onCandidate?(candidate)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

private struct ViewerSignal: Decodable {
    var type: String
    var sdp: SessionDescriptionPayload?
    var candidate: IceCandidatePayload?
}

private struct SessionDescriptionPayload: Codable {
    var type: String
    var sdp: String
}

private struct IceCandidatePayload: Codable {
    var candidate: String
    var sdpMid: String?
    var sdpMLineIndex: Int32
}

private struct OutgoingAnswer: Encodable {
    let type = "webrtc-answer"
    var sdp: SessionDescriptionPayload
}

private struct OutgoingCandidate: Encodable {
    let type = "ice-candidate"
    var candidate: IceCandidatePayload
}

private enum SDPOptimizer {
    static func optimize(_ sdp: String, codec: String, bitrate: Int) -> String {
        let preferredSDP = preferCodec(codec, in: sdp)
        return applyBandwidthLimit(to: preferredSDP, bitrate: bitrate)
    }

    static func preferH264(_ sdp: String) -> String {
        preferCodec("H264", in: sdp)
    }

    static func preferVP8(_ sdp: String) -> String {
        preferCodec("VP8", in: sdp)
    }

    private static func preferCodec(_ codec: String, in sdp: String) -> String {
        var lines = sdp.components(separatedBy: "\r\n")
        guard let videoLineIndex = lines.firstIndex(where: { $0.hasPrefix("m=video ") }) else {
            return sdp
        }

        let preferredPayloads = payloads(forCodec: codec, in: lines)
        guard !preferredPayloads.isEmpty else {
            return sdp
        }

        let parts = lines[videoLineIndex].split(separator: " ").map(String.init)
        guard parts.count > 3 else {
            return sdp
        }

        let header = Array(parts.prefix(3))
        let payloads = Array(parts.dropFirst(3))
        let reorderedPayloads = preferredPayloads + payloads.filter { !preferredPayloads.contains($0) }
        lines[videoLineIndex] = (header + reorderedPayloads).joined(separator: " ")
        return lines.joined(separator: "\r\n")
    }

    private static func applyBandwidthLimit(to sdp: String, bitrate: Int) -> String {
        var lines = sdp.components(separatedBy: "\r\n")
        guard let videoLineIndex = lines.firstIndex(where: { $0.hasPrefix("m=video ") }) else {
            return sdp
        }

        let maxKbps = max(1_000, bitrate / 1_000)
        let initialSectionEnd = lines[(videoLineIndex + 1)...].firstIndex(where: { $0.hasPrefix("m=") }) ?? lines.endIndex
        if let bandwidthIndex = lines[videoLineIndex..<initialSectionEnd].firstIndex(where: { $0.hasPrefix("b=AS:") }) {
            lines[bandwidthIndex] = "b=AS:\(maxKbps)"
        } else {
            let insertIndex = lines[videoLineIndex..<initialSectionEnd].firstIndex(where: { $0.hasPrefix("a=") }) ?? initialSectionEnd
            lines.insert("b=AS:\(maxKbps)", at: insertIndex)
        }

        return lines.joined(separator: "\r\n")
    }

    private static func payloads(forCodec codec: String, in lines: [String]) -> [String] {
        lines.compactMap { line in
            guard line.localizedCaseInsensitiveContains(" \(codec)/") else {
                return nil
            }

            let prefix = "a=rtpmap:"
            guard line.hasPrefix(prefix) else {
                return nil
            }

            let remainder = line.dropFirst(prefix.count)
            return remainder.split(separator: " ").first.map(String.init)
        }
    }
}
