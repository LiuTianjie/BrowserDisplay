import CoreImage.CIFilterBuiltins
import SwiftUI
import MirrorProtocol

enum BrowserDisplayLayout {
    static let minimumWindowWidth: CGFloat = 1180
    static let minimumWindowHeight: CGFloat = 980
    static let controlPanelWidth: CGFloat = 320
}

struct ContentView: View {
    @ObservedObject var viewModel: HostViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedConfig: StreamConfig {
        StreamConfig.presets.first(where: { $0.id == viewModel.selectedConfigID }) ?? StreamConfig.presets[0]
    }

    private var s: AppStrings {
        viewModel.strings
    }

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 0) {
                topBar

                HStack(alignment: .top, spacing: 20) {
                    sourcePanel
                    controlPanel
                }
                .padding(24)
            }
        }
        .background(WindowChromeConfigurator())
        .foregroundStyle(.white)
        .tint(.blue)
        .ignoresSafeArea(.container, edges: .top)
        .task {
            await viewModel.prepare()
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 14) {
                AppIconView()
                    .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 4) {
                    Text("BrowserDisplay")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(s.subtitle)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.68))
                }
            }

            Spacer()

            Button {
                viewModel.toggleLanguage()
            } label: {
                Text(viewModel.language.switchTitle)
                    .font(.caption.weight(.bold))
                    .frame(minWidth: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(viewModel.language.switchAccessibilityLabel)

            StatusPill(text: viewModel.connectionStatus, color: viewModel.isStreaming ? .green : .blue)
        }
        .padding(.leading, 96)
        .padding(.trailing, 24)
        .padding(.top, 28)
        .padding(.bottom, 8)
    }

    private var sourcePanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label(s.captureSources, systemImage: "rectangle.on.rectangle")
                        .font(.title3.bold())
                    CountBadge(count: viewModel.captureSources.count, labelPrefix: s.sourceCount)
                    Spacer()
                    if viewModel.hasScreenRecordingAccess {
                        if viewModel.isStreaming {
                            LockedPill(text: s.lockedWhileStreaming)
                        }

                        ScopeSegmentedControl(selection: $viewModel.selectedSourceScope, strings: s)
                            .onChange(of: viewModel.selectedSourceScope) { _, _ in
                                Task<Void, Never> { await viewModel.refreshCaptureSources() }
                            }
                            .disabled(viewModel.isStreaming)
                            .opacity(viewModel.isStreaming ? 0.54 : 1)

                        Button {
                            Task<Void, Never> { await viewModel.refreshCaptureSources() }
                        } label: {
                            Label(s.refresh, systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isStreaming)
                    } else {
                        Button {
                            Task<Void, Never> { await viewModel.requestScreenRecordingAccess() }
                        } label: {
                            Label(s.authorizeAccess, systemImage: "lock.open")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if viewModel.captureSources.isEmpty {
                    EmptySourceView(message: viewModel.screenRecordingStatus, strings: s)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 280), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                            ForEach(viewModel.captureSources) { source in
                                CaptureSourceCard(
                                    source: source,
                                    isSelected: source.id == viewModel.selectedSourceID,
                                    strings: s
                                ) {
                                    withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)) {
                                        viewModel.selectCaptureSource(source.id)
                                    }
                                }
                                .disabled(viewModel.isStreaming)
                                .opacity(viewModel.isStreaming && source.id != viewModel.selectedSourceID ? 0.62 : 1)
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(2)
                    }
                }
            }
        }
        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controlPanel: some View {
        VStack(spacing: 16) {
            GlassPanel {
                VStack(alignment: .leading, spacing: 16) {
                    Label(s.session, systemImage: "dot.radiowaves.left.and.right")
                        .font(.title3.bold())

                    InfoRow(title: s.host, value: viewModel.hostName)
                    InfoRow(title: "WebViewer", value: "HTTP \(MirrorDiscovery.defaultWebViewerPort)")
                    InfoRow(title: s.permission, value: viewModel.screenRecordingStatus)
                }
            }

            virtualDisplayPanel

            GlassPanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("WebViewer", systemImage: "display")
                            .font(.title3.bold())
                        Spacer()
                        StatusPill(text: viewModel.webViewerStatus, color: viewModel.connectedWebViewers > 0 ? .green : .blue)
                    }

                    HStack(alignment: .center, spacing: 14) {
                        QRCodeView(value: viewModel.webViewerURL)
                            .frame(width: 106, height: 106)

                        VStack(alignment: .leading, spacing: 10) {
                            Text(viewModel.webViewerURL.isEmpty ? s.generatingAddress : viewModel.webViewerURL)
                                .font(.caption.monospaced())
                                .foregroundStyle(.white.opacity(0.78))
                                .lineLimit(3)
                                .textSelection(.enabled)

                            HStack(spacing: 8) {
                                Button {
                                    viewModel.copyWebViewerURL()
                                } label: {
                                    Label(s.copy, systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)
                                .disabled(viewModel.webViewerURL.isEmpty)

                                Button {
                                    viewModel.openWebViewerURL()
                                } label: {
                                    Label(s.open, systemImage: "safari")
                                }
                                .buttonStyle(.bordered)
                                .disabled(viewModel.webViewerURL.isEmpty)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(s.pairingCode)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.62))
                        HStack(alignment: .center, spacing: 10) {
                            Text(viewModel.webViewerPairingCode.isEmpty ? "------" : viewModel.webViewerPairingCode)
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .tracking(3)
                                .foregroundStyle(.white)
                            Spacer()
                            Button {
                                viewModel.copyWebViewerPairingCode()
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                            .disabled(viewModel.webViewerPairingCode.isEmpty)
                            .help(s.copyPairingCode)

                            Button {
                                viewModel.regenerateWebViewerPairingCode()
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.bordered)
                            .help(s.refreshPairingCode)
                        }
                    }
                }
            }

            GlassPanel {
                VStack(alignment: .leading, spacing: 16) {
                    Label(s.quality, systemImage: "slider.horizontal.3")
                        .font(.title3.bold())

                    QualitySummary(config: selectedConfig, strings: s)

                    QualityMenu(selection: $viewModel.selectedConfigID, strings: s)
                        .disabled(viewModel.isStreaming)
                        .opacity(viewModel.isStreaming ? 0.58 : 1)

                    Button {
                        Task<Void, Never> {
                            await viewModel.toggleStreaming()
                        }
                    } label: {
                        HStack {
                            Image(systemName: viewModel.isStreaming ? "stop.fill" : "play.fill")
                            Text(viewModel.isStreaming ? s.stopStreaming : s.startStreaming)
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canStream)
                    .accessibilityLabel(viewModel.isStreaming ? s.stopStreaming : s.startStreaming)

                    HStack {
                        Button(s.openSystemSettings) {
                            viewModel.openScreenRecordingSettings()
                        }
                        .buttonStyle(.link)

                        Spacer()

                        Button(s.recheck) {
                            Task<Void, Never> { await viewModel.refreshCaptureSources() }
                        }
                        .buttonStyle(.link)
                        .disabled(viewModel.isStreaming)

                        Button(s.refreshSources) {
                            Task<Void, Never> { await viewModel.refreshCaptureSources() }
                        }
                        .buttonStyle(.link)
                        .disabled(viewModel.isStreaming)
                    }
                }
            }
        }
        .frame(width: BrowserDisplayLayout.controlPanelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var virtualDisplayPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    Label(s.virtualDisplayMode, systemImage: "display.badge.plus")
                        .font(.title3.bold())
                    Spacer()
                    StatusPill(text: s.virtualDisplayStateTitle(viewModel.virtualDisplayState), color: virtualDisplayStateColor)
                }

                if let record = viewModel.currentVirtualDisplayRecord, record.cleanupStatus != .removed {
                    InfoRow(title: s.virtualDisplay, value: record.displayName)
                }

                if let message = viewModel.virtualDisplayErrorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(s.virtualDisplayNote)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: cleanupOnExitBinding) {
                    Text(s.removeOnExit)
                        .font(.caption.weight(.semibold))
                }
                .toggleStyle(.switch)
                .tint(.blue)
                .disabled(viewModel.virtualDisplayState == .creating || viewModel.virtualDisplayState == .removing)

                VStack(spacing: 8) {
                    if viewModel.currentVirtualDisplayRecord == nil {
                        Button {
                            Task<Void, Never> {
                                await viewModel.createVirtualDisplayAndStart()
                            }
                        } label: {
                            Label(primaryVirtualDisplayButtonTitle, systemImage: "display.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isStreaming || viewModel.virtualDisplayState == .unavailable || viewModel.virtualDisplayState == .creating || viewModel.virtualDisplayState == .removing)
                    } else {
                        Button {
                            Task<Void, Never> {
                                await viewModel.removeVirtualDisplay()
                            }
                        } label: {
                            Label(s.removeVirtualDisplay, systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.virtualDisplayState == .creating || viewModel.virtualDisplayState == .removing)
                    }

                    HStack(spacing: 8) {
                        Button(s.check) {
                            Task<Void, Never> { await viewModel.refreshVirtualDisplayAvailability() }
                        }
                        .buttonStyle(.link)
                        .disabled(viewModel.virtualDisplayState == .creating || viewModel.virtualDisplayState == .removing)

                        Spacer()

                        Button(s.installGuide) {
                            viewModel.openBetterDisplayInstallPage()
                        }
                        .buttonStyle(.link)

                        Button(s.displaySettings) {
                            viewModel.openDisplaySettings()
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
    }

    private var primaryVirtualDisplayButtonTitle: String {
        switch viewModel.virtualDisplayState {
        case .installedNotRunning:
            return s.startAndCreateVirtualDisplay
        case .creating:
            return s.creating
        default:
            return s.createVirtualDisplayAndStart
        }
    }

    private var virtualDisplayStateColor: Color {
        switch viewModel.virtualDisplayState {
        case .ready, .readyToCreate:
            return .green
        case .creating, .removing, .installedNotRunning:
            return .blue
        case .unavailable, .createFailed, .cleanupFailed:
            return .orange
        }
    }

    private var cleanupOnExitBinding: Binding<Bool> {
        Binding(
            get: { viewModel.shouldCleanupVirtualDisplayOnExit },
            set: { viewModel.setCleanupVirtualDisplayOnExit($0) }
        )
    }
}

private struct LockedPill: View {
    var text: String

    var body: some View {
        Label(text, systemImage: "lock.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.74))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.white.opacity(0.10), in: Capsule())
            .overlay {
                Capsule().stroke(.white.opacity(0.08), lineWidth: 1)
            }
    }
}

private struct ScopeSegmentedControl: View {
    @Binding var selection: CaptureSourceScope
    var strings: AppStrings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Text(strings.scope)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.62))
                .padding(.horizontal, 8)

            ForEach(CaptureSourceScope.allCases) { scope in
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.16)) {
                        selection = scope
                    }
                } label: {
                    Text(scope.title(language: strings.language))
                        .font(.caption.weight(.semibold))
                        .frame(height: 30)
                        .padding(.horizontal, 10)
                        .foregroundStyle(selection == scope ? .white : .white.opacity(0.58))
                        .background {
                            if selection == scope {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(.blue)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityValue(selection == scope ? strings.selected : "")
            }
        }
        .padding(4)
        .background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 1)
        }
    }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else {
                return
            }

            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.backgroundColor = .clear
            window.minSize = NSSize(
                width: BrowserDisplayLayout.minimumWindowWidth,
                height: BrowserDisplayLayout.minimumWindowHeight
            )
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct AppBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.03, green: 0.05, blue: 0.12), Color(red: 0.06, green: 0.12, blue: 0.26), Color(red: 0.02, green: 0.03, blue: 0.07)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(.blue.opacity(0.28))
                .frame(width: 360, height: 360)
                .blur(radius: 70)
                .offset(x: 120, y: -120)
        }
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(.cyan.opacity(0.16))
                .frame(width: 300, height: 300)
                .blur(radius: 60)
                .offset(x: -80, y: 120)
        }
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [.white.opacity(0.12), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 110)
        }
        .ignoresSafeArea()
    }
}

private struct GlassPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.20), radius: 24, x: 0, y: 16)
    }
}

private struct CountBadge: View {
    var count: Int
    var labelPrefix: String

    var body: some View {
        Text("\(count)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.82))
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(0.12), in: Capsule())
            .accessibilityLabel("\(labelPrefix) \(count)")
    }
}

private struct CaptureSourceCard: View {
    var source: CaptureSource
    var isSelected: Bool
    var strings: AppStrings
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.black.opacity(0.38))

                    if let thumbnail = source.thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .padding(8)
                    } else {
                        Image(systemName: source.id.hasPrefix("display-") ? "display" : "macwindow")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.58))
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .blue)
                            .padding(10)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(source.name)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        SourceKindChip(text: source.id.hasPrefix("display-") ? strings.fullScreen : strings.window)
                    }
                    Text(sourceKindText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
                .frame(height: 44, alignment: .top)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .frame(height: 218, alignment: .top)
            .background(
                LinearGradient(
                    colors: isSelected
                        ? [.blue.opacity(0.30), .white.opacity(0.09)]
                        : [.white.opacity(0.10), .white.opacity(0.055)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(isSelected ? .blue.opacity(0.9) : .white.opacity(0.12), lineWidth: isSelected ? 2 : 1)
            }
            .shadow(color: isSelected ? .blue.opacity(0.20) : .clear, radius: 16, x: 0, y: 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(strings.select) \(source.name)")
    }

    private var sourceKindText: String {
        source.id.hasPrefix("display-") ? strings.fullScreen : source.kind
    }
}

private struct SourceKindChip: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.86))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.42), in: Capsule())
    }
}

private struct QualitySummary: View {
    var config: StreamConfig
    var strings: AppStrings

    var body: some View {
        HStack(spacing: 0) {
            MetricPill(title: strings.resolution, value: "\(config.width)×\(config.height)")
            Divider().overlay(.white.opacity(0.08))
            MetricPill(title: strings.frameRate, value: "\(config.framesPerSecond)fps")
            Divider().overlay(.white.opacity(0.08))
            MetricPill(title: strings.bitrate, value: "\(config.bitrate / 1_000_000)M")
        }
        .frame(height: 54)
        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct MetricPill: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.50))
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }
}

private struct QualityMenu: View {
    @Binding var selection: String
    var strings: AppStrings

    private var selectedConfig: StreamConfig {
        StreamConfig.presets.first(where: { $0.id == selection }) ?? StreamConfig.presets[0]
    }

    var body: some View {
        Menu {
            ForEach(StreamConfig.presets) { preset in
                Button {
                    selection = preset.id
                } label: {
                    Text(menuTitle(for: preset))
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(strings.quality)
                    .foregroundStyle(.white.opacity(0.62))
                Text(selectedTitle(for: selectedConfig))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func menuTitle(for preset: StreamConfig) -> String {
        let base = "\(preset.width)×\(preset.height) · \(preset.framesPerSecond)fps · \(preset.bitrate / 1_000_000)Mbps"
        if ["1440p60", "1600p60", "2160p30"].contains(preset.id) {
            return "\(base) · \(strings.highLoad)"
        }

        if preset.id == "1080p60" {
            return "\(base) · \(strings.recommended)"
        }

        return base
    }

    private func selectedTitle(for preset: StreamConfig) -> String {
        "\(preset.height)p · \(preset.framesPerSecond)fps · \(preset.bitrate / 1_000_000)Mbps"
    }
}

private struct QRCodeView: View {
    var value: String

    var body: some View {
        Group {
            if let image = makeQRCode(from: value) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.10))
                    .overlay {
                        Image(systemName: "qrcode")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.54))
                    }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private func makeQRCode(from value: String) -> NSImage? {
        guard !value.isEmpty else {
            return nil
        }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else {
            return nil
        }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

private struct EmptySourceView: View {
    var message: String
    var strings: AppStrings

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.display")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.blue)
            Text(strings.noCaptureSources)
                .font(.title3.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.65))
            Text(strings.permissionRestartHint)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.48))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

private struct AppIconView: View {
    var body: some View {
        if let image = NSImage(named: "AppIconPreview") {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .shadow(color: .blue.opacity(0.22), radius: 12, x: 0, y: 6)
        } else {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.white.opacity(0.16))
                .overlay {
                    Image(systemName: "display")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
        }
    }
}

private struct InfoRow: View {
    var title: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.white.opacity(0.58))
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.callout)
    }
}

private struct StatusPill: View {
    var text: String
    var color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.white.opacity(0.12), in: Capsule())
        .overlay {
            Capsule().stroke(.white.opacity(0.16), lineWidth: 1)
        }
    }
}
