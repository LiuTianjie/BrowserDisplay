import CryptoKit
import Darwin
import Foundation
import MirrorProtocol
import Network

struct WebViewerSignalEnvelope: Codable, Sendable {
    var clientID: String
    var role: String
    var payload: String
}

final class WebViewerService {
    var onViewerConnected: (() -> Void)?
    var onViewerDisconnected: (() -> Void)?
    var onSignalMessage: ((WebViewerSignalEnvelope) -> Void)?

    private var listener: NWListener?
    private var httpConnections: [HTTPConnection] = []
    private var signalConnections: [SignalConnection] = []
    private var latestStreamState = StreamStatePayload(isStreaming: false, quality: "1080p60", codec: "H264", viewerCount: 0, sourceName: "未选择", sourceKind: "capture")
    private(set) var viewerURLString = WebViewerService.makeViewerURL()
    private(set) var pairingCode = WebViewerService.makePairingCode()

    var connectedViewerCount: Int {
        signalConnections.filter { $0.role == "viewer" }.count
    }

    func start(port: UInt16 = MirrorDiscovery.defaultWebViewerPort, serviceName: String? = nil) throws {
        stop()

        viewerURLString = WebViewerService.makeViewerURL(port: port)

        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        if let serviceName {
            listener.service = NWListener.Service(
                name: serviceName,
                type: "_http._tcp",
                domain: MirrorDiscovery.serviceDomain,
                txtRecord: NWTXTRecord(["path": "/viewer"])
            )
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        httpConnections.forEach { $0.cancel() }
        httpConnections.removeAll()
        signalConnections.forEach { $0.cancel() }
        signalConnections.removeAll()
    }

    func regeneratePairingCode() {
        pairingCode = WebViewerService.makePairingCode()
        signalConnections.forEach { connection in
            connection.sendServerMessage(type: "pairing-reset", body: ["message": "配对码已刷新"])
            connection.cancel()
        }
    }

    func updateStreamState(isStreaming: Bool, quality: String, codec: String = "H264", sourceName: String = "未选择", sourceKind: String = "capture") {
        latestStreamState = StreamStatePayload(
            isStreaming: isStreaming,
            quality: quality,
            codec: codec,
            viewerCount: connectedViewerCount,
            sourceName: sourceName,
            sourceKind: sourceKind
        )
        broadcastServerMessage(type: "stream-state", body: latestStreamState)
    }

    func sendSignal(_ payload: String, to clientID: String) {
        signalConnections
            .filter { $0.id == clientID }
            .forEach { $0.sendText(payload) }
    }

    private func accept(_ connection: NWConnection) {
        let httpConnection = HTTPConnection(connection: connection, service: self)
        httpConnections.append(httpConnection)
        httpConnection.start()
    }

    fileprivate func removeHTTPConnection(_ connection: HTTPConnection) {
        httpConnections.removeAll { $0 === connection }
    }

    fileprivate func removeSignalConnection(_ connection: SignalConnection) {
        signalConnections.removeAll { $0 === connection }
        latestStreamState.viewerCount = connectedViewerCount
        broadcastServerMessage(type: "stream-state", body: latestStreamState)
        onViewerDisconnected?()
    }

    fileprivate func handle(_ request: HTTPRequest, from httpConnection: HTTPConnection) {
        if request.path == "/signal", request.isWebSocketUpgrade {
            upgradeToWebSocket(request, from: httpConnection)
            return
        }

        let response: HTTPResponse
        switch request.path {
        case "/", "/viewer":
            response = .ok(contentType: "text/html; charset=utf-8", body: WebViewerAssets.html)
        case "/viewer.css":
            response = .ok(contentType: "text/css; charset=utf-8", body: WebViewerAssets.css)
        case "/viewer.js":
            response = .ok(contentType: "application/javascript; charset=utf-8", body: WebViewerAssets.javascript)
        case "/health":
            let payload = #"{"ok":true,"service":"webviewer"}"#
            response = .ok(contentType: "application/json; charset=utf-8", body: payload)
        default:
            response = .notFound()
        }

        httpConnection.send(response)
    }

    private func upgradeToWebSocket(_ request: HTTPRequest, from httpConnection: HTTPConnection) {
        guard let key = request.headers["sec-websocket-key"] else {
            httpConnection.send(.badRequest())
            return
        }

        let role = request.query["role"] ?? "viewer"
        guard role == "viewer" else {
            httpConnection.send(.badRequest())
            return
        }
        if !isPairingCodeValid(request.query["pairCode"] ?? request.query["pairingCode"]) {
            httpConnection.send(.unauthorized())
            return
        }

        let acceptKey = WebSocketCodec.acceptKey(for: key)
        let header = WebSocketCodec.upgradeResponseHeader(acceptKey: acceptKey)
        let signalConnection = SignalConnection(
            id: UUID().uuidString,
            role: role,
            connection: httpConnection.connection,
            service: self
        )

        signalConnections.append(signalConnection)
        httpConnection.sendRaw(header, closeAfterSend: false) { [weak self, weak httpConnection, weak signalConnection] in
            guard let self, let httpConnection, let signalConnection else {
                return
            }

            self.removeHTTPConnection(httpConnection)
            signalConnection.start()
            self.latestStreamState.viewerCount = self.connectedViewerCount
            signalConnection.sendServerMessage(type: "hello", body: ["clientID": signalConnection.id])
            signalConnection.sendServerMessage(type: "stream-state", body: self.latestStreamState)
            self.broadcastServerMessage(type: "stream-state", body: self.latestStreamState)
            self.onViewerConnected?()
        }
    }

    fileprivate func handleSignalText(_ text: String, from connection: SignalConnection) {
        onSignalMessage?(WebViewerSignalEnvelope(clientID: connection.id, role: connection.role, payload: text))
    }

    private func broadcastServerMessage<T: Encodable>(type: String, body: T) {
        for connection in signalConnections {
            connection.sendServerMessage(type: type, body: body)
        }
    }

    private static func makeViewerURL(port: UInt16 = MirrorDiscovery.defaultWebViewerPort) -> String {
        if let address = localIPv4Address() {
            return "http://\(address):\(port)/viewer"
        }

        var host = ProcessInfo.processInfo.hostName
        if host.isEmpty {
            host = Host.current().localizedName ?? "localhost"
        }
        if !host.contains(".") && host != "localhost" {
            host += ".local"
        }
        return "http://\(host):\(port)/viewer"
    }

    private static func localIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return nil
        }
        defer { freeifaddrs(interfaces) }

        var fallbackAddress: String?
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstInterface

        while let interface = pointer {
            defer { pointer = interface.pointee.ifa_next }

            let flags = Int32(interface.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            guard isUp, !isLoopback else {
                continue
            }

            guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else {
                continue
            }

            let addressString = String(cString: hostname)
            guard !addressString.hasPrefix("169.254.") else {
                continue
            }

            let interfaceName = String(cString: interface.pointee.ifa_name)
            if ["en0", "en1", "en2"].contains(interfaceName) {
                return addressString
            }

            fallbackAddress = fallbackAddress ?? addressString
        }

        return fallbackAddress
    }

    private func isPairingCodeValid(_ code: String?) -> Bool {
        guard let code else {
            return false
        }

        let normalized = code.filter(\.isNumber)
        return normalized == pairingCode
    }

    private static func makePairingCode() -> String {
        String(format: "%06d", Int.random(in: 100_000...999_999))
    }
}

private final class HTTPConnection {
    let connection: NWConnection
    private weak var service: WebViewerService?
    private var buffer = Data()

    init(connection: NWConnection, service: WebViewerService) {
        self.connection = connection
        self.service = service
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else {
                return
            }
            if case .failed = state {
                self.cancel()
            }
            if case .cancelled = state {
                self.service?.removeHTTPConnection(self)
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func cancel() {
        connection.cancel()
    }

    func send(_ response: HTTPResponse) {
        sendRaw(response.data, closeAfterSend: true)
    }

    func sendRaw(_ data: Data, closeAfterSend: Bool, completion: (() -> Void)? = nil) {
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self else {
                return
            }
            if closeAfterSend {
                self.close()
            } else {
                completion?()
            }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            if let data, !data.isEmpty {
                self.buffer.append(data)
                if let request = HTTPRequest.parse(from: self.buffer) {
                    self.service?.handle(request, from: self)
                    return
                }
            }

            if isComplete || error != nil {
                self.close()
            } else {
                self.receive()
            }
        }
    }

    private func close() {
        connection.cancel()
        service?.removeHTTPConnection(self)
    }
}

private final class SignalConnection {
    let id: String
    let role: String

    private let connection: NWConnection
    private weak var service: WebViewerService?
    private var buffer = Data()
    private var isClosed = false

    init(id: String, role: String, connection: NWConnection, service: WebViewerService) {
        self.id = id
        self.role = role
        self.connection = connection
        self.service = service
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else {
                return
            }
            switch state {
            case .failed, .cancelled:
                self.close()
            case .setup, .waiting, .preparing, .ready:
                break
            @unknown default:
                break
            }
        }
        receive()
    }

    func cancel() {
        close()
    }

    func sendText(_ text: String) {
        let frame = WebSocketCodec.encode(text: text)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    func sendServerMessage<T: Encodable>(type: String, body: T) {
        let message = ServerMessage(type: type, body: body)
        guard
            let data = try? JSONEncoder().encode(message),
            let text = String(data: data, encoding: .utf8)
        else {
            return
        }
        sendText(text)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainFrames()
            }

            if isComplete || error != nil {
                self.close()
            } else {
                self.receive()
            }
        }
    }

    private func drainFrames() {
        while let frame = WebSocketCodec.decode(from: &buffer) {
            switch frame.opcode {
            case .text:
                if let text = String(data: frame.payload, encoding: .utf8) {
                    service?.handleSignalText(text, from: self)
                }
            case .ping:
                let pong = WebSocketCodec.encode(opcode: .pong, payload: frame.payload)
                connection.send(content: pong, completion: .contentProcessed { _ in })
            case .close:
                connection.send(content: WebSocketCodec.encode(opcode: .close, payload: Data()), completion: .contentProcessed { [weak self] _ in
                    self?.close()
                })
            case .binary, .pong:
                break
            }
        }
    }

    private func close() {
        guard !isClosed else {
            return
        }

        isClosed = true
        connection.cancel()
        service?.removeSignalConnection(self)
    }
}

private struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]

    var isWebSocketUpgrade: Bool {
        headers["upgrade"]?.lowercased() == "websocket"
    }

    static func parse(from data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let headerData = data[..<headerEnd.lowerBound]
        guard let text = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let target = requestParts[1]
        let path: String
        let query: [String: String]
        if
            let components = URLComponents(string: target),
            components.scheme != nil
        {
            path = components.path.isEmpty ? "/" : components.path
            query = parseQuery(components.percentEncodedQuery ?? "")
        } else {
            let pieces = target.split(separator: "?", maxSplits: 1).map(String.init)
            path = pieces.first ?? "/"
            query = pieces.count > 1 ? parseQuery(pieces[1]) : [:]
        }

        return HTTPRequest(method: requestParts[0], path: path, query: query, headers: headers)
    }

    private static func parseQuery(_ queryString: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first?.removingPercentEncoding else {
                continue
            }
            result[key] = (parts.count > 1 ? parts[1] : "").removingPercentEncoding
        }
        return result
    }
}

private struct HTTPResponse {
    var status: String
    var contentType: String
    var body: Data

    var data: Data {
        var response = Data()
        response.appendString("HTTP/1.1 \(status)\r\n")
        response.appendString("Content-Type: \(contentType)\r\n")
        response.appendString("Content-Length: \(body.count)\r\n")
        response.appendString("Cache-Control: no-store\r\n")
        response.appendString("Connection: close\r\n")
        response.appendString("\r\n")
        response.append(body)
        return response
    }

    static func ok(contentType: String, body: String) -> HTTPResponse {
        HTTPResponse(status: "200 OK", contentType: contentType, body: Data(body.utf8))
    }

    static func notFound() -> HTTPResponse {
        HTTPResponse(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("Not found".utf8))
    }

    static func badRequest() -> HTTPResponse {
        HTTPResponse(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: Data("Bad request".utf8))
    }

    static func unauthorized() -> HTTPResponse {
        HTTPResponse(status: "401 Unauthorized", contentType: "text/plain; charset=utf-8", body: Data("Pairing required".utf8))
    }
}

private enum WebSocketOpcode: UInt8 {
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
}

private struct WebSocketFrame {
    var opcode: WebSocketOpcode
    var payload: Data
}

private enum WebSocketCodec {
    static func acceptKey(for key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }

    static func upgradeResponseHeader(acceptKey: String) -> Data {
        var data = Data()
        data.appendString("HTTP/1.1 101 Switching Protocols\r\n")
        data.appendString("Upgrade: websocket\r\n")
        data.appendString("Connection: Upgrade\r\n")
        data.appendString("Sec-WebSocket-Accept: \(acceptKey)\r\n")
        data.appendString("Sec-WebSocket-Version: 13\r\n")
        data.appendString("\r\n")
        return data
    }

    static func encode(text: String) -> Data {
        encode(opcode: .text, payload: Data(text.utf8))
    }

    static func encode(opcode: WebSocketOpcode, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode.rawValue)

        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= UInt16.max {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xff))
            frame.append(UInt8(payload.count & 0xff))
        } else {
            frame.append(127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> UInt64(shift)) & 0xff))
            }
        }

        frame.append(payload)
        return frame
    }

    static func decode(from buffer: inout Data) -> WebSocketFrame? {
        guard buffer.count >= 2 else {
            return nil
        }

        let bytes = [UInt8](buffer)
        guard let opcode = WebSocketOpcode(rawValue: bytes[0] & 0x0f) else {
            return nil
        }

        let isMasked = (bytes[1] & 0x80) != 0
        var length = Int(bytes[1] & 0x7f)
        var offset = 2

        if length == 126 {
            guard bytes.count >= offset + 2 else {
                return nil
            }
            length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
        } else if length == 127 {
            guard bytes.count >= offset + 8 else {
                return nil
            }
            var wideLength: UInt64 = 0
            for index in 0..<8 {
                wideLength = (wideLength << 8) | UInt64(bytes[offset + index])
            }
            guard wideLength <= UInt64(Int.max) else {
                buffer.removeAll()
                return nil
            }
            length = Int(wideLength)
            offset += 8
        }

        var mask: [UInt8] = []
        if isMasked {
            guard bytes.count >= offset + 4 else {
                return nil
            }
            mask = Array(bytes[offset..<offset + 4])
            offset += 4
        }

        guard bytes.count >= offset + length else {
            return nil
        }

        var payloadBytes = Array(bytes[offset..<offset + length])
        if isMasked {
            for index in payloadBytes.indices {
                payloadBytes[index] ^= mask[index % 4]
            }
        }
        buffer.removeSubrange(0..<(offset + length))

        return WebSocketFrame(opcode: opcode, payload: Data(payloadBytes))
    }
}

private struct StreamStatePayload: Codable {
    var isStreaming: Bool
    var quality: String
    var codec: String
    var viewerCount: Int
    var sourceName: String
    var sourceKind: String
}

private struct ServerMessage<T: Encodable>: Encodable {
    var type: String
    var body: T
}

private enum WebViewerAssets {
    static let html = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
      <meta name="theme-color" content="#000000">
      <title>BrowserDisplay WebViewer</title>
      <link rel="stylesheet" href="/viewer.css?v=12">
    </head>
    <body>
      <main class="stage" data-state="idle" data-fullscreen="inline" data-orientation="portrait" data-paired="false">
        <video id="screen" playsinline autoplay muted></video>
        <div class="veil" id="veil">
          <form class="pairing" id="pairingForm" autocomplete="one-time-code">
            <div class="pairing-head">
              <div class="pairing-mark" aria-hidden="true">
                <span></span>
              </div>
              <div>
                <p class="pairing-kicker" data-i18n="secureViewer">Secure Viewer</p>
                <h1 data-i18n="enterPairingCode">Enter pairing code</h1>
              </div>
            </div>
            <p class="pairing-note" data-i18n="pairingNote">Find the 6-digit code in the WebViewer panel on your Mac.</p>
            <label class="sr-only" for="pairingCode" data-i18n="pairingLabel">Enter the Mac pairing code</label>
            <div class="pairing-row">
              <input id="pairingCode" name="pairingCode" type="text" inputmode="numeric" pattern="[0-9]*" maxlength="6" placeholder="000000" autocomplete="one-time-code">
              <button id="pairingSubmit" type="submit" data-i18n="pair">Pair</button>
            </div>
            <p id="pairingError"></p>
          </form>
          <button class="play" id="play" type="button" aria-label="Start watching">
            <span></span>
          </button>
          <p id="status">Enter the pairing code to connect</p>
        </div>
        <header class="toolbar" id="toolbar">
          <span id="badge">WebViewer</span>
          <span id="source">Source: None selected</span>
          <strong id="quality">--</strong>
          <button id="languageToggle" type="button" aria-label="Switch language">中文</button>
          <button id="fullscreen" type="button" aria-label="Enter fullscreen" title="Enter fullscreen">
            <span></span>
          </button>
        </header>
        <div class="rotate-hint" id="rotateHint">Rotate for landscape viewing</div>
      </main>
      <script src="/viewer.js?v=12"></script>
    </body>
    </html>
    """

    static let css = """
    :root {
      color-scheme: dark;
      background: #000;
      font-family: ui-rounded, "SF Pro Rounded", "SF Pro Display", -apple-system, BlinkMacSystemFont, sans-serif;
      -webkit-font-smoothing: antialiased;
    }

    * {
      box-sizing: border-box;
    }

    html,
    body {
      width: 100%;
      height: 100dvh;
      margin: 0;
      overflow: hidden;
      background: #000;
      color: #fff;
      touch-action: manipulation;
    }

    .stage {
      position: fixed;
      inset: 0;
      display: grid;
      place-items: center;
      background:
        radial-gradient(circle at 50% 42%, rgba(255,255,255,0.065), transparent 34%),
        #000;
    }

    .stage[data-fullscreen="immersive"] {
      height: 100dvh;
    }

    video {
      width: 100vw;
      height: 100dvh;
      object-fit: contain;
      background: #000;
    }

    .stage[data-state="playing"][data-orientation="landscape"] video {
      width: 100dvw;
      height: 100dvh;
    }

    .stage[data-fullscreen="immersive"] video,
    .stage[data-fullscreen="native"] video {
      width: 100dvw;
      height: 100dvh;
      object-fit: cover;
    }

    .veil {
      position: absolute;
      inset: 0;
      display: grid;
      place-items: center;
      align-content: center;
      gap: 20px;
      padding: max(22px, env(safe-area-inset-top)) max(22px, env(safe-area-inset-right)) max(22px, env(safe-area-inset-bottom)) max(22px, env(safe-area-inset-left));
      background:
        linear-gradient(135deg, rgba(8,11,16,0.86), rgba(0,0,0,0.76)),
        repeating-linear-gradient(90deg, rgba(255,255,255,0.04) 0 1px, transparent 1px 24px);
      transition: opacity 220ms ease, visibility 220ms ease;
    }

    .stage[data-state="playing"] .veil {
      opacity: 0;
      visibility: hidden;
      pointer-events: none;
    }

    .pairing {
      position: relative;
      width: min(91vw, 390px);
      display: grid;
      gap: 16px;
      padding: 22px;
      overflow: hidden;
      border: 1px solid rgba(255,255,255,0.16);
      border-radius: 26px;
      background:
        linear-gradient(180deg, rgba(255,255,255,0.12), rgba(255,255,255,0.035)),
        rgba(9,13,20,0.78);
      box-shadow:
        0 28px 90px rgba(0,0,0,0.56),
        0 0 0 1px rgba(255,255,255,0.045) inset,
        0 1px 0 rgba(255,255,255,0.18) inset;
      -webkit-backdrop-filter: blur(28px) saturate(1.16);
      backdrop-filter: blur(28px) saturate(1.16);
      animation: pairingEnter 420ms cubic-bezier(.2,.8,.2,1) both;
    }

    .pairing::before {
      content: "";
      position: absolute;
      inset: 0;
      pointer-events: none;
      background:
        linear-gradient(120deg, rgba(255,255,255,0.18), transparent 28%),
        linear-gradient(0deg, transparent, rgba(105,170,255,0.08));
      opacity: 0.78;
    }

    .stage[data-paired="true"] .pairing {
      display: none;
    }

    .pairing > * {
      position: relative;
      z-index: 1;
    }

    .pairing-head {
      display: flex;
      align-items: center;
      gap: 13px;
    }

    .pairing-mark {
      width: 48px;
      height: 48px;
      display: grid;
      place-items: center;
      border: 1px solid rgba(255,255,255,0.16);
      border-radius: 16px;
      background:
        linear-gradient(145deg, rgba(80,151,255,0.30), rgba(255,255,255,0.075)),
        rgba(255,255,255,0.08);
      box-shadow: 0 14px 38px rgba(31,111,235,0.20), inset 0 1px 0 rgba(255,255,255,0.20);
    }

    .pairing-mark span {
      width: 22px;
      height: 16px;
      border: 2px solid rgba(255,255,255,0.88);
      border-radius: 5px;
      position: relative;
    }

    .pairing-mark span::before {
      content: "";
      position: absolute;
      left: 50%;
      bottom: -7px;
      width: 12px;
      height: 2px;
      transform: translateX(-50%);
      border-radius: 99px;
      background: rgba(255,255,255,0.88);
    }

    .pairing-kicker {
      margin: 0 0 3px;
      color: rgba(138,187,255,0.90);
      font-size: 11px;
      font-weight: 900;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }

    .pairing h1 {
      margin: 0;
      color: rgba(255,255,255,0.96);
      font-size: 28px;
      line-height: 1;
      font-weight: 900;
      letter-spacing: 0;
    }

    .pairing-note {
      margin: -2px 0 2px;
      color: rgba(255,255,255,0.66);
      font-size: 14px;
      line-height: 1.45;
      text-align: left;
    }

    .sr-only {
      position: absolute;
      width: 1px;
      height: 1px;
      padding: 0;
      margin: -1px;
      overflow: hidden;
      clip: rect(0,0,0,0);
      white-space: nowrap;
      border: 0;
    }

    .pairing-row {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 11px;
    }

    #pairingCode {
      width: 100%;
      min-width: 0;
      height: 54px;
      border: 1px solid rgba(255,255,255,0.16);
      border-radius: 16px;
      padding: 0 15px;
      background: rgba(0,0,0,0.26);
      color: #fff;
      font-size: 25px;
      font-weight: 900;
      letter-spacing: 0.13em;
      font-variant-numeric: tabular-nums;
      text-align: center;
      outline: none;
      box-shadow: inset 0 1px 0 rgba(255,255,255,0.07);
      transition: border-color 160ms ease, box-shadow 160ms ease, background 160ms ease;
    }

    #pairingCode:focus {
      border-color: rgba(105,170,255,0.88);
      background: rgba(8,15,27,0.62);
      box-shadow: 0 0 0 4px rgba(31,111,235,0.24), inset 0 1px 0 rgba(255,255,255,0.10);
    }

    #pairingSubmit {
      height: 54px;
      border: 0;
      border-radius: 16px;
      padding: 0 18px;
      background: linear-gradient(180deg, #ffffff, #dbeaff);
      color: #08111e;
      font-size: 15px;
      font-weight: 900;
      box-shadow: 0 12px 26px rgba(31,111,235,0.20), inset 0 1px 0 rgba(255,255,255,0.70);
      transition: transform 120ms ease, filter 120ms ease;
    }

    #pairingSubmit:active {
      transform: translateY(1px) scale(0.99);
      filter: brightness(0.96);
    }

    #pairingError {
      min-height: 20px;
      margin: -5px 0 0;
      color: rgba(255,194,130,0.96);
      font-size: 13px;
      line-height: 1.4;
      font-weight: 800;
      text-align: left;
    }

    @keyframes pairingEnter {
      from { opacity: 0; transform: translateY(14px) scale(0.985); }
      to { opacity: 1; transform: translateY(0) scale(1); }
    }

    @media (max-width: 360px) {
      .pairing {
        padding: 18px;
        border-radius: 22px;
      }

      .pairing-row {
        grid-template-columns: 1fr;
      }

      #pairingSubmit {
        width: 100%;
      }
    }

    .play {
      width: clamp(82px, 24vw, 118px);
      aspect-ratio: 1;
      border: 1px solid rgba(255,255,255,0.22);
      border-radius: 999px;
      display: grid;
      place-items: center;
      background: rgba(255,255,255,0.12);
      box-shadow: 0 18px 70px rgba(0,0,0,0.45), inset 0 1px 0 rgba(255,255,255,0.18);
      -webkit-backdrop-filter: blur(24px);
      backdrop-filter: blur(24px);
    }

    .stage[data-paired="false"] .play {
      display: none;
    }

    .play span {
      width: 0;
      height: 0;
      margin-left: 8px;
      border-top: 18px solid transparent;
      border-bottom: 18px solid transparent;
      border-left: 27px solid #fff;
    }

    .veil > p {
      max-width: min(72vw, 420px);
      margin: 0;
      color: rgba(255,255,255,0.76);
      font-size: 16px;
      line-height: 1.35;
      text-align: center;
    }

    .toolbar {
      position: absolute;
      top: max(12px, env(safe-area-inset-top));
      left: max(12px, env(safe-area-inset-left));
      right: max(12px, env(safe-area-inset-right));
      height: 42px;
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 0 8px 0 14px;
      border: 1px solid rgba(255,255,255,0.16);
      border-radius: 999px;
      background: rgba(0,0,0,0.42);
      -webkit-backdrop-filter: blur(18px);
      backdrop-filter: blur(18px);
      transition: opacity 200ms ease, transform 200ms ease;
    }

    .stage[data-state="playing"] .toolbar.is-hidden {
      opacity: 0;
      transform: translateY(-12px);
      pointer-events: none;
    }

    .stage:not([data-state="playing"]) #quality,
    .stage:not([data-state="playing"]) #source,
    .stage:not([data-state="playing"]) #fullscreen {
      opacity: 0;
      visibility: hidden;
      pointer-events: none;
    }

    .stage[data-state="playing"][data-orientation="landscape"] .toolbar {
      top: max(8px, env(safe-area-inset-top));
      left: max(16px, env(safe-area-inset-left));
      right: max(16px, env(safe-area-inset-right));
    }

    #badge {
      min-width: 0;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      color: rgba(255,255,255,0.72);
      font-size: 13px;
      font-weight: 700;
    }

    #quality {
      margin-left: auto;
      font-size: 13px;
      font-variant-numeric: tabular-nums;
      color: rgba(255,255,255,0.86);
    }

    #source {
      min-width: 0;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      font-size: 12px;
      font-weight: 700;
      color: rgba(255,255,255,0.70);
    }

    #languageToggle {
      height: 32px;
      min-width: 46px;
      border: 0;
      border-radius: 999px;
      padding: 0 10px;
      background: rgba(255,255,255,0.10);
      color: rgba(255,255,255,0.86);
      font-size: 12px;
      font-weight: 900;
      letter-spacing: 0;
    }

    #fullscreen {
      width: 32px;
      height: 32px;
      border: 0;
      border-radius: 999px;
      background: rgba(255,255,255,0.10);
      position: relative;
      display: grid;
      place-items: center;
    }

    #fullscreen span,
    #fullscreen span::before,
    #fullscreen span::after {
      content: "";
      position: absolute;
      width: 14px;
      height: 14px;
    }

    #fullscreen span::before {
      border-top: 2px solid #fff;
      border-left: 2px solid #fff;
      transform: translate(-3px, -3px);
    }

    #fullscreen span::after {
      border-right: 2px solid #fff;
      border-bottom: 2px solid #fff;
      transform: translate(3px, 3px);
    }

    .rotate-hint {
      position: absolute;
      left: 50%;
      bottom: max(24px, env(safe-area-inset-bottom));
      transform: translateX(-50%);
      padding: 8px 12px;
      border: 1px solid rgba(255,255,255,0.16);
      border-radius: 999px;
      background: rgba(0,0,0,0.46);
      color: rgba(255,255,255,0.78);
      font-size: 13px;
      font-weight: 700;
      letter-spacing: 0;
      opacity: 0;
      visibility: hidden;
      pointer-events: none;
      -webkit-backdrop-filter: blur(18px);
      backdrop-filter: blur(18px);
    }

    .stage[data-state="playing"][data-orientation="portrait"]:not([data-fullscreen="native"]) .rotate-hint {
      visibility: visible;
      animation: rotateHintFade 3.2s ease forwards;
    }

    @keyframes rotateHintFade {
      0%, 18% { opacity: 0; transform: translate(-50%, 8px); }
      30%, 72% { opacity: 1; transform: translate(-50%, 0); }
      100% { opacity: 0; transform: translate(-50%, 0); }
    }
    """

    static let javascript = """
    (() => {
      const stage = document.querySelector(".stage");
      const video = document.getElementById("screen");
      const play = document.getElementById("play");
      const status = document.getElementById("status");
      const quality = document.getElementById("quality");
      const source = document.getElementById("source");
      const toolbar = document.getElementById("toolbar");
      const fullscreen = document.getElementById("fullscreen");
      const languageToggle = document.getElementById("languageToggle");
      const rotateHint = document.getElementById("rotateHint");
      const pairingForm = document.getElementById("pairingForm");
      const pairingCodeInput = document.getElementById("pairingCode");
      const pairingError = document.getElementById("pairingError");

      let socket;
      let peer;
      let hideTimer;
      let started = false;
      let pairingCode = "";
      let firstFrameSeen = false;
      let streamActive = false;
      let offerInFlight = false;
      let streamStateReady = { value: false };
      let currentQuality = { value: "720p30" };
      let currentCodec = { value: "H264" };
      let reconnectDelayMs = 1200;
      let signalTimeoutMs = 4500;
      let disconnectGraceMs = 8000;
      let firstFrameTimeoutMs = 18000;
      let currentLanguage = { value: "en" };
      let currentStatusRenderer = { value: () => "" };
      let currentPairingErrorRenderer = { value: () => "" };
      let latestSource = { name: "", kind: "capture" };
      let reconnectTimer = { value: null };
      let signalTimer = { value: null };
      let disconnectTimer = { value: null };
      let firstFrameTimer = { value: null };
      let lastRenderedFrameAt = { value: Date.now() };
      const pairingStorageKey = `BrowserDisplay.pairingCode.${location.host}`;
      const languageStorageKey = "BrowserDisplay.viewerLanguage";

      const messages = {
        en: {
          secureViewer: "Secure Viewer",
          enterPairingCode: "Enter pairing code",
          pairingNote: "Find the 6-digit code in the WebViewer panel on your Mac.",
          pairingLabel: "Enter the Mac pairing code",
          pair: "Pair",
          startWatching: "Start watching",
          enterPairingCodeToConnect: "Enter the pairing code to connect",
          sourcePrefix: "Source",
          noneSelected: "None selected",
          enterFullscreen: "Enter fullscreen",
          exitFullscreen: "Exit fullscreen",
          rotateHint: "Rotate for landscape viewing",
          languageButton: "中文",
          switchLanguage: "Switch language to Chinese",
          firstFrameTimeout: "First frame timed out",
          reconnecting: "Reconnecting",
          reconnectingSuffix: ", reconnecting",
          syncingQuality: "Syncing quality",
          createConnectionFailed: "Failed to create connection",
          safariWebRTCUnavailable: "WebRTC is unavailable in this browser",
          signalingTimeout: "Signaling timed out",
          signalingConnectedSyncingQuality: "Signaling connected, syncing quality",
          pairingFailed: "Pairing failed. Check the 6-digit code shown on the Mac.",
          disconnected: "Disconnected",
          connectionFailed: "Connection failed",
          receivedVideoTrack: "Received video track, waiting for video",
          playbackBlocked: "Playback was blocked: {error}",
          connectedWaitingFrames: "Connected, waiting for video frames",
          connectionInterrupted: "Connection interrupted",
          offerSent: "Offer sent, waiting for Mac answer",
          pairingCodeRefreshedReconnect: "Pairing code refreshed. Pair again.",
          macPairingCodeRefreshed: "The Mac refreshed the pairing code",
          paused: "Paused",
          answerReceived: "Answer received, connecting",
          connecting: "Connecting",
          enterSixDigitCode: "Enter a 6-digit pairing code",
          rememberedPairingConnecting: "Pairing remembered, connecting",
          browserDisplayVirtualDisplay: "BrowserDisplay Virtual Display"
        },
        zh: {
          secureViewer: "Secure Viewer",
          enterPairingCode: "输入配对码",
          pairingNote: "在 Mac 端 WebViewer 面板查看 6 位数字。",
          pairingLabel: "输入 Mac 端配对码",
          pair: "配对",
          startWatching: "开始观看",
          enterPairingCodeToConnect: "输入配对码后连接",
          sourcePrefix: "当前来源",
          noneSelected: "未选择",
          enterFullscreen: "全屏观看",
          exitFullscreen: "退出全屏",
          rotateHint: "横屏观看",
          languageButton: "EN",
          switchLanguage: "切换语言为英文",
          firstFrameTimeout: "等待首帧超时",
          reconnecting: "重连中",
          reconnectingSuffix: "，重连中",
          syncingQuality: "正在同步画质",
          createConnectionFailed: "创建连接失败",
          safariWebRTCUnavailable: "Safari 当前不可用 WebRTC",
          signalingTimeout: "信令超时",
          signalingConnectedSyncingQuality: "信令已连接，正在同步画质",
          pairingFailed: "配对失败，请检查 Mac 端显示的 6 位配对码",
          disconnected: "已断开",
          connectionFailed: "连接失败",
          receivedVideoTrack: "收到视频轨道，等待画面",
          playbackBlocked: "播放被拦截：{error}",
          connectedWaitingFrames: "已连接，等待视频帧",
          connectionInterrupted: "连接中断",
          offerSent: "已发送 offer，等待 Mac answer",
          pairingCodeRefreshedReconnect: "配对码已刷新，请重新配对",
          macPairingCodeRefreshed: "Mac 端已刷新配对码",
          paused: "已暂停",
          answerReceived: "收到 answer，连接中",
          connecting: "连接中",
          enterSixDigitCode: "请输入 6 位配对码",
          rememberedPairingConnecting: "已记住配对，正在连接",
          browserDisplayVirtualDisplay: "BrowserDisplay 虚拟屏"
        }
      };

      const template = (value, params = {}) => Object.entries(params).reduce(
        (result, [key, replacement]) => result.replaceAll(`{${key}}`, replacement),
        value
      );

      const t = (key, params = {}) => template((messages[currentLanguage.value] || messages.en)[key] || messages.en[key] || key, params);

      const localized = (key, params = {}) => () => t(key, params);

      const detectLanguage = () => {
        try {
          const saved = localStorage.getItem(languageStorageKey);
          if (saved === "en" || saved === "zh") return saved;
        } catch {}
        return (navigator.languages || [navigator.language || "en"]).some((language) => String(language).toLowerCase().startsWith("zh")) ? "zh" : "en";
      };

      const normalizeSourceName = (name, kind) => {
        if (kind === "virtual-display") return t("browserDisplayVirtualDisplay");
        if (!name || name === "未选择" || name === "None selected") return t("noneSelected");
        return name;
      };

      const updateSource = () => {
        source.textContent = `${t("sourcePrefix")}: ${normalizeSourceName(latestSource.name, latestSource.kind)}`;
      };

      const setFullscreenModeLabels = (mode) => {
        fullscreen.setAttribute("aria-label", mode === "inline" ? t("enterFullscreen") : t("exitFullscreen"));
        fullscreen.title = mode === "inline" ? t("enterFullscreen") : t("exitFullscreen");
      };

      const applyLanguage = () => {
        document.documentElement.lang = currentLanguage.value === "zh" ? "zh-CN" : "en";
        document.querySelectorAll("[data-i18n]").forEach((node) => {
          node.textContent = t(node.dataset.i18n);
        });
        play.setAttribute("aria-label", t("startWatching"));
        languageToggle.textContent = t("languageButton");
        languageToggle.setAttribute("aria-label", t("switchLanguage"));
        rotateHint.textContent = t("rotateHint");
        setFullscreenModeLabels(stage.dataset.fullscreen || "inline");
        updateSource();
        status.textContent = currentStatusRenderer.value();
        pairingError.textContent = currentPairingErrorRenderer.value();
      };

      const render = (message) => typeof message === "function" ? message() : message;

      const setStatus = (message, state = "idle") => {
        currentStatusRenderer.value = typeof message === "function" ? message : () => message;
        status.textContent = currentStatusRenderer.value();
        stage.dataset.state = state;
      };

      const setPairingError = (message) => {
        currentPairingErrorRenderer.value = typeof message === "function" ? message : () => message;
        pairingError.textContent = currentPairingErrorRenderer.value();
      };

      const normalizePairingCode = (value) => (value || "").replace(/\\D/g, "").slice(0, 6);

      const loadStoredPairingCode = () => {
        try {
          return normalizePairingCode(localStorage.getItem(pairingStorageKey));
        } catch {
          return "";
        }
      };

      const savePairingCode = () => {
        if (!pairingCode) return;
        try {
          localStorage.setItem(pairingStorageKey, pairingCode);
        } catch {}
      };

      const clearStoredPairingCode = () => {
        try {
          localStorage.removeItem(pairingStorageKey);
        } catch {}
      };

      const setPaired = (paired, options = {}) => {
        stage.dataset.paired = paired ? "true" : "false";
        if (!paired) {
          if (options.forget !== false) {
            clearStoredPairingCode();
          }
          pairingCode = "";
          pairingCodeInput.value = "";
          setStatus(localized("enterPairingCodeToConnect"));
          setTimeout(() => pairingCodeInput.focus(), 60);
        }
      };

      const send = (message) => {
        if (socket && socket.readyState === WebSocket.OPEN) {
          socket.send(JSON.stringify(message));
        }
      };

      const resetPeer = () => {
        clearDisconnectTimer();
        clearFirstFrameTimer();
        if (peer) {
          peer.close();
          peer = null;
        }
        video.srcObject = null;
        firstFrameSeen = false;
        offerInFlight = false;
      };

      const exitFullscreen = async () => {
        try {
          if (video.webkitDisplayingFullscreen && video.webkitExitFullscreen) {
            video.webkitExitFullscreen();
          }
        } catch {}
        try {
          if (document.fullscreenElement && document.exitFullscreen) {
            await document.exitFullscreen();
          }
        } catch {}
        try {
          if (screen.orientation && screen.orientation.unlock) {
            screen.orientation.unlock();
          }
        } catch {}
        setFullscreenMode("inline");
      };

      const resetPlayback = async (message, keepStarted = true) => {
        resetPeer();
        await exitFullscreen();
        setStatus(message);
        started = keepStarted ? started : false;
        if (!keepStarted) {
          setPaired(false);
        }
      };

      const clearSignalTimer = () => {
        if (signalTimer.value) {
          clearTimeout(signalTimer.value);
          signalTimer.value = null;
        }
      };

      const clearReconnectTimer = () => {
        if (reconnectTimer.value) {
          clearTimeout(reconnectTimer.value);
          reconnectTimer.value = null;
        }
      };

      const clearDisconnectTimer = () => {
        if (disconnectTimer.value) {
          clearTimeout(disconnectTimer.value);
          disconnectTimer.value = null;
        }
      };

      const clearFirstFrameTimer = () => {
        if (firstFrameTimer.value) {
          clearTimeout(firstFrameTimer.value);
          firstFrameTimer.value = null;
        }
      };

      const startFirstFrameTimer = (candidatePeer) => {
        clearFirstFrameTimer();
        firstFrameTimer.value = setTimeout(() => {
          if (peer !== candidatePeer || firstFrameSeen) return;
          resetPeer();
          exitFullscreen();
          scheduleReconnect(localized("firstFrameTimeout"));
        }, firstFrameTimeoutMs);
      };

      const scheduleReconnect = (reason) => {
        if (!started) return;
        if (!pairingCode) {
          setPaired(false);
          return;
        }
        clearReconnectTimer();
        setStatus(reason ? () => `${render(reason)}${t("reconnectingSuffix")}` : localized("reconnecting"));
        reconnectTimer.value = setTimeout(() => {
          reconnectTimer.value = null;
          if (socket && socket.readyState === WebSocket.OPEN) {
            ensurePeer();
          } else {
            connect();
          }
        }, reconnectDelayMs);
      };

      const closeSocket = () => {
        clearSignalTimer();
        clearDisconnectTimer();
        streamStateReady.value = false;
        if (socket) {
          socket.onclose = null;
          socket.onerror = null;
          socket.close();
          socket = null;
        }
      };

      const setFullscreenMode = (mode) => {
        stage.dataset.fullscreen = mode;
        setFullscreenModeLabels(mode);
      };

      const updateOrientation = () => {
        const portrait = window.matchMedia && window.matchMedia("(orientation: portrait)").matches;
        stage.dataset.orientation = portrait ? "portrait" : "landscape";
      };

      const requestLandscape = async () => {
        try {
          if (screen.orientation && screen.orientation.lock) {
            await screen.orientation.lock("landscape");
          }
        } catch {}
      };

      const preferVideoCodec = (transceiver, codecName) => {
        try {
          if (!transceiver.setCodecPreferences || !window.RTCRtpReceiver || !RTCRtpReceiver.getCapabilities) return;
          const capabilities = RTCRtpReceiver.getCapabilities("video");
          const codecs = capabilities && capabilities.codecs ? capabilities.codecs : [];
          const preferred = codecs.filter((codec) => (codec.mimeType || "").toLowerCase() === `video/${codecName.toLowerCase()}`);
          if (!preferred.length) return;
          const fallback = codecs.filter((codec) => (codec.mimeType || "").toLowerCase() !== `video/${codecName.toLowerCase()}`);
          transceiver.setCodecPreferences([...preferred, ...fallback]);
        } catch {}
      };

      const ensurePeer = async () => {
        if (!started || peer || offerInFlight) return;
        if (!streamStateReady.value) {
          setStatus(localized("syncingQuality"));
          return;
        }
        if (!socket || socket.readyState !== WebSocket.OPEN) {
          connect();
          return;
        }

        offerInFlight = true;
        try {
          await createOffer();
        } catch (error) {
          resetPeer();
          setStatus(() => `${t("createConnectionFailed")}: ${error.name || "Error"}`);
          scheduleReconnect(localized("createConnectionFailed"));
        } finally {
          offerInFlight = false;
        }
      };

      const connect = () => {
        if (!window.RTCPeerConnection) {
          setStatus(localized("safariWebRTCUnavailable"));
          return;
        }
        if (!pairingCode) {
          setPaired(false);
          return;
        }
        if (socket && socket.readyState === WebSocket.OPEN) {
          if (streamStateReady.value) ensurePeer();
          return;
        }
        if (socket && socket.readyState === WebSocket.CONNECTING) return;
        if (socket && socket.readyState >= WebSocket.CLOSING) {
          socket = null;
        }
        clearReconnectTimer();
        const scheme = location.protocol === "https:" ? "wss" : "ws";
        let opened = false;
        socket = new WebSocket(`${scheme}://${location.host}/signal?role=viewer&pairCode=${encodeURIComponent(pairingCode)}`);
        signalTimer.value = setTimeout(() => {
          if (socket && socket.readyState !== WebSocket.OPEN) {
            closeSocket();
            scheduleReconnect(localized("signalingTimeout"));
          }
        }, signalTimeoutMs);
        socket.onopen = async () => {
          opened = true;
          clearSignalTimer();
          setPairingError("");
          stage.dataset.paired = "true";
          savePairingCode();
          streamStateReady.value = false;
          setStatus(localized("signalingConnectedSyncingQuality"));
        };
        socket.onmessage = (event) => handleMessage(event.data);
        socket.onclose = async (event) => {
          clearSignalTimer();
          socket = null;
          if (!opened) {
            started = false;
            clearStoredPairingCode();
            setPairingError(localized("pairingFailed"));
            setPaired(false);
            return;
          }
          await resetPlayback(localized("disconnected"));
          const reason = event.code ? () => `${t("disconnected")} WS ${event.code}` : localized("disconnected");
          scheduleReconnect(reason);
        };
        socket.onerror = () => {
          clearSignalTimer();
          if (!opened) {
            started = false;
            clearStoredPairingCode();
            setPairingError(localized("pairingFailed"));
            setPaired(false);
            closeSocket();
            return;
          }
          closeSocket();
          resetPlayback(localized("connectionFailed"));
          scheduleReconnect(localized("connectionFailed"));
        };
      };

      const createOffer = async () => {
        resetPeer();
        const nextPeer = new RTCPeerConnection({ iceServers: [] });
        peer = nextPeer;
        const transceiver = nextPeer.addTransceiver("video", { direction: "recvonly" });
        preferVideoCodec(transceiver, currentCodec.value || "H264");
        nextPeer.ontrack = (event) => {
          const stream = event.streams[0] || new MediaStream([event.track]);
          video.srcObject = stream;
          setStatus(localized("receivedVideoTrack"));
          video.play().catch((error) => setStatus(() => t("playbackBlocked", { error: error.name || "Error" })));
          startFirstFrameTimer(nextPeer);
          waitForFirstFrame();
          scheduleToolbarHide();
        };
        nextPeer.oniceconnectionstatechange = () => {
          if (peer !== nextPeer) return;
          if (!firstFrameSeen) setStatus(`ICE ${nextPeer.iceConnectionState}`);
        };
        nextPeer.onconnectionstatechange = () => {
          if (peer !== nextPeer) return;
          if (nextPeer.connectionState === "connected") {
            clearDisconnectTimer();
            if (!firstFrameSeen) setStatus(localized("connectedWaitingFrames"));
          } else if (nextPeer.connectionState === "disconnected") {
            clearDisconnectTimer();
            disconnectTimer.value = setTimeout(() => {
              if (peer !== nextPeer || nextPeer.connectionState !== "disconnected") return;
              resetPeer();
              exitFullscreen();
              scheduleReconnect(localized("connectionInterrupted"));
            }, disconnectGraceMs);
          } else if (nextPeer.connectionState === "failed" || nextPeer.connectionState === "closed") {
            clearDisconnectTimer();
            resetPeer();
            exitFullscreen();
            scheduleReconnect(localized("connectionInterrupted"));
          }
          scheduleToolbarHide();
        };
        nextPeer.onicecandidate = (event) => {
          if (event.candidate) {
            send({ type: "ice-candidate", candidate: event.candidate });
          }
        };
        const offer = await nextPeer.createOffer();
        if (peer !== nextPeer) return;
        await nextPeer.setLocalDescription(offer);
        if (peer !== nextPeer) return;
        send({ type: "webrtc-offer", sdp: nextPeer.localDescription });
        setStatus(localized("offerSent"));
        startFirstFrameTimer(nextPeer);
      };

      const handleMessage = async (raw) => {
        let message;
        try {
          message = JSON.parse(raw);
        } catch {
          return;
        }

        if (message.type === "pairing-reset") {
          closeSocket();
          clearStoredPairingCode();
          await resetPlayback(localized("pairingCodeRefreshedReconnect"), false);
          setPairingError(localized("macPairingCodeRefreshed"));
          return;
        }

        if (message.type === "stream-state") {
          const body = message.body || {};
          streamActive = !!body.isStreaming;
          streamStateReady.value = true;
          currentQuality.value = body.quality || currentQuality.value;
          currentCodec.value = body.codec || currentCodec.value;
          quality.textContent = body.quality || "--";
          latestSource.name = body.sourceName || "";
          latestSource.kind = body.sourceKind || "capture";
          updateSource();
          if (!streamActive) {
            await resetPlayback(localized("paused"));
          } else if (started && !peer) {
            await ensurePeer();
          }
          return;
        }

        if (!peer && (message.type === "webrtc-answer" || message.type === "ice-candidate")) {
          return;
        }

        if (message.type === "webrtc-answer") {
          await peer.setRemoteDescription(message.sdp);
          setStatus(localized("answerReceived"));
        } else if (message.type === "ice-candidate" && message.candidate) {
          await peer.addIceCandidate(message.candidate).catch(() => {});
        }
      };

      const waitForFirstFrame = () => {
        if ("requestVideoFrameCallback" in HTMLVideoElement.prototype) {
          video.requestVideoFrameCallback(() => {
            if (!peer) return;
            firstFrameSeen = true;
            lastRenderedFrameAt.value = Date.now();
            clearFirstFrameTimer();
            setStatus("", "playing");
            scheduleToolbarHide();
            waitForFirstFrame();
          });
          return;
        }

        const markPlaying = () => {
          firstFrameSeen = true;
          lastRenderedFrameAt.value = Date.now();
          clearFirstFrameTimer();
          setStatus("", "playing");
          scheduleToolbarHide();
          video.removeEventListener("loadeddata", markPlaying);
          video.removeEventListener("playing", markPlaying);
        };
        video.addEventListener("loadeddata", markPlaying);
        video.addEventListener("playing", markPlaying);
      };

      const scheduleToolbarHide = () => {
        clearTimeout(hideTimer);
        toolbar.classList.remove("is-hidden");
        hideTimer = setTimeout(() => toolbar.classList.add("is-hidden"), 1800);
      };

      const beginConnection = async () => {
        started = true;
        stage.dataset.paired = "true";
        setStatus(localized("connecting"));
        try {
          const playAttempt = video.play();
          if (playAttempt && playAttempt.catch) playAttempt.catch(() => {});
        } catch {}
        connect();
      };

      pairingCodeInput.addEventListener("input", () => {
        pairingCodeInput.value = normalizePairingCode(pairingCodeInput.value);
        setPairingError("");
      });

      pairingForm.addEventListener("submit", async (event) => {
        event.preventDefault();
        pairingCode = normalizePairingCode(pairingCodeInput.value);
        if (pairingCode.length !== 6) {
          setPairingError(localized("enterSixDigitCode"));
          return;
        }
        setPairingError("");
        await beginConnection();
      });

      play.addEventListener("click", async () => {
        if (!pairingCode) {
          setPaired(false);
          return;
        }
        await beginConnection();
      });

      fullscreen.addEventListener("click", async () => {
        if (!firstFrameSeen) return;

        if (document.fullscreenElement && document.exitFullscreen) {
          await document.exitFullscreen().then(() => setFullscreenMode("inline")).catch(() => {});
        } else if (stage.dataset.fullscreen === "immersive") {
          setFullscreenMode("inline");
        } else if (!document.fullscreenElement && stage.requestFullscreen) {
          await requestLandscape();
          await stage.requestFullscreen().then(async () => {
            setFullscreenMode("native");
            await requestLandscape();
          }).catch(() => setFullscreenMode("immersive"));
        } else {
          await requestLandscape();
          setFullscreenMode("immersive");
        }
        scheduleToolbarHide();
      });

      document.addEventListener("fullscreenchange", () => {
        setFullscreenMode(document.fullscreenElement ? "native" : "inline");
      });

      video.addEventListener("webkitbeginfullscreen", () => setFullscreenMode("native"));
      video.addEventListener("webkitendfullscreen", () => setFullscreenMode("inline"));

      languageToggle.addEventListener("click", () => {
        currentLanguage.value = currentLanguage.value === "zh" ? "en" : "zh";
        try {
          localStorage.setItem(languageStorageKey, currentLanguage.value);
        } catch {}
        applyLanguage();
      });

      currentLanguage.value = detectLanguage();
      setStatus(localized("enterPairingCodeToConnect"));
      updateSource();
      applyLanguage();

      const storedPairingCode = loadStoredPairingCode();
      if (storedPairingCode.length === 6) {
        pairingCode = storedPairingCode;
        pairingCodeInput.value = storedPairingCode;
        setPaired(true, { forget: false });
        setStatus(localized("rememberedPairingConnecting"));
        beginConnection();
      } else {
        setPaired(false);
      }
      updateOrientation();
      window.addEventListener("resize", updateOrientation, { passive: true });
      window.addEventListener("orientationchange", () => setTimeout(updateOrientation, 180), { passive: true });

      ["pointerdown", "touchstart", "mousemove"].forEach((name) => {
        document.addEventListener(name, scheduleToolbarHide, { passive: true });
      });
    })();
    """
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
