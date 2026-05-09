import Foundation

public enum MirrorDiscovery {
    public static let serviceType = "_mirror-display._tcp"
    public static let serviceDomain = "local."
    public static let defaultWebViewerPort: UInt16 = 48112

    public static func displayName(for hostName: String = ProcessInfo.processInfo.hostName) -> String {
        "\(hostName) 镜像主机"
    }
}
