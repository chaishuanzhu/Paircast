import SwiftUI
import UIKit
import PaircastShared

@MainActor
public final class ServiceConfigViewModel: ObservableObject {
    @Published public var serverUrl = ""
    @Published public var statusMessage: String?
    @Published public var exportShareURL: String?
    @Published public var showExportSheet = false
    @Published public var showImportPaste = false
    @Published public var importRaw = ""
    @Published public var showImportConfirm = false
    @Published public var importPreview = ""
    @Published public var pendingImportConfig: AppCloudConfig?
    /// Bumped after import so fields recreate with the imported values.
    @Published public var formEpoch = 0

    private let session: AppSession

    public init(session: AppSession) {
        self.session = session
        if let config = session.config {
            apply(config)
        }
    }

    private func apply(_ config: AppCloudConfig) {
        if !config.im.serverUrl.isEmpty {
            serverUrl = config.im.serverUrl
        }
    }

    /// Returns `true` when config was persisted successfully.
    @discardableResult
    public func save() async -> Bool {
        do {
            let previousServer = session.config?.im.serverUrl
            let stored = try await session.graph.saveConfig.invoke(config: draftConfig())
            if session.currentUser != nil, previousServer != stored.im.serverUrl {
                // A different GO-IM server invalidates the current account session.
                await session.applyImportedCloudConfig(stored)
            } else {
                session.config = stored
                try? await session.graph.clearMetadataCache()
            }
            statusMessage = TandemL10n.string("Saved")
            return true
        } catch {
            statusMessage = TandemL10n.message(for: error, fallback: .unknown("Unable to save configuration"))
            return false
        }
    }

    public func confirmExport() async {
        do {
            // Persist current form first so export matches what the user sees.
            let stored = try await session.graph.saveConfig.invoke(config: draftConfig())
            session.config = stored
            exportShareURL = try session.graph.configLinkCodec.shareUrl(config: stored)
            showExportSheet = true
            statusMessage = TandemL10n.string("Configuration link generated")
        } catch {
            statusMessage = TandemL10n.message(for: error, fallback: .invalidConfigQR)
        }
    }

    public func prepareImport(raw: String) {
        do {
            let config = try session.graph.configLinkCodec.decode(input: raw)
            pendingImportConfig = config
            importPreview = ConfigQRCodec.shared.maskedPreview(config: config)
            showImportPaste = false
            showImportConfirm = true
        } catch {
            statusMessage = TandemL10n.message(for: error, fallback: .invalidConfigQR)
        }
    }

    public func confirmImport() async {
        guard let pendingImportConfig else { return }
        showImportConfirm = false
        self.pendingImportConfig = nil
        var incoming = pendingImportConfig
        if ConfigQRCodec.shared.needsServerUrl(config: incoming) {
            // Pre-GO-IM links carry no server address: reuse the one in the form, if any.
            let server = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !server.isEmpty else {
                statusMessage = TandemL10n.string("This link has no IM server address. Enter it, then Save")
                return
            }
            incoming = incoming.doCopy(
                im: IMConfig(serverUrl: server),
                updatedAtMs: incoming.updatedAtMs,
                configVersion: incoming.configVersion
            )
        }
        do {
            // Persist directly — avoid a re-encrypt round-trip via Save.
            let saved = try await session.graph.saveConfig.invoke(config: incoming)
            apply(saved)
            formEpoch += 1
            await session.applyImportedCloudConfig(saved)
            statusMessage = TandemL10n.string(
                ConfigQRCodec.shared.isLegacy(config: pendingImportConfig)
                    ? "Storage settings in this link were ignored — the media library is now configured on the server"
                    : "Configuration imported. Please sign in again"
            )
        } catch {
            statusMessage = TandemL10n.message(for: error, fallback: .invalidConfigQR)
        }
    }

    public func consumePendingDeepLinkIfNeeded() {
        if let raw = session.consumePendingConfigImport() {
            prepareImport(raw: raw)
        }
    }

    private func draftConfig() -> AppCloudConfig {
        AppCloudConfig(
            im: IMConfig(serverUrl: serverUrl),
            updatedAtMs: 0,
            configVersion: AppCloudConfig.companion.CURRENT_VERSION
        )
    }
}

public struct ServiceConfigView: View {
    @ObservedObject var session: AppSession
    let fromLogin: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @StateObject private var viewModel: ServiceConfigViewModel

    public init(session: AppSession, fromLogin: Bool) {
        self.session = session
        self.fromLogin = fromLogin
        _viewModel = StateObject(wrappedValue: ServiceConfigViewModel(session: session))
    }

    public var body: some View {
        if fromLogin {
            NavigationStack {
                formContent
            }
        } else {
            formContent
        }
    }

    private var formContent: some View {
            Form {
                Section {
                    Link(destination: configurationGuideURL) {
                        Label("Configuration Guide", systemImage: "book.fill")
                    }
                } footer: {
                    Text("Where to get the IM server address and how to use Paircast")
                }

                Section {
                    ConfigTransferRow(
                        title: "Paste to Import",
                        subtitle: "Paste a paircast://config?args=… link",
                        systemImage: "arrow.down.doc.fill",
                        tint: Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
                    ) {
                        viewModel.importRaw = ""
                        viewModel.showImportPaste = true
                    }
                    ConfigTransferRow(
                        title: "Share Configuration",
                        subtitle: "Generate an encrypted link to copy or share with friends",
                        systemImage: "square.and.arrow.up.fill",
                        tint: TandemColors.systemBlue
                    ) {
                        Task { await viewModel.confirmExport() }
                    }
                } header: {
                    Text("Share & Import")
                } footer: {
                    Text("Links contain only the IM server address; friends still sign in with their own account")
                }

                Section {
                    TextField("im.example.com", text: $viewModel.serverUrl)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("IM Server")
                } footer: {
                    Text("Your self-hosted GO-IM address. HTTPS is assumed unless you enter http:// (LAN only).")
                }
                Section {
                    LabeledContent("Media Library", value: TandemL10n.string("Managed by the server"))
                } footer: {
                    Text("Videos, subtitles, posters and stickers come from the media library your GO-IM admin configures on the server.")
                }
                if let status = viewModel.statusMessage {
                    Section {
                        Text(status).foregroundStyle(.secondary)
                    }
                }
            }
            .id(viewModel.formEpoch)
            .navigationTitle("Service Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if fromLogin {
                    ToolbarItem(placement: .cancellationAction) {
                        ToolbarBackButton {
                            session.resetToLogin()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ToolbarDoneButton(accessibilityLabel: "Save") {
                        Task {
                            if await viewModel.save() {
                                session.showToast(TandemL10n.string("Saved"))
                                if fromLogin {
                                    session.resetToLogin()
                                } else {
                                    dismiss()
                                }
                            }
                        }
                    }
                }
            }
            .task {
                viewModel.consumePendingDeepLinkIfNeeded()
            }
            .sheet(isPresented: $viewModel.showExportSheet) {
                if let shareURL = viewModel.exportShareURL {
                    ConfigExportShareView(shareURL: shareURL)
                        .environment(\.locale, locale)
                }
            }
            .sheet(isPresented: $viewModel.showImportPaste) {
                ConfigPasteImportView(
                    text: $viewModel.importRaw,
                    onCancel: { viewModel.showImportPaste = false },
                    onContinue: { viewModel.prepareImport(raw: viewModel.importRaw) }
                )
                .environment(\.locale, locale)
            }
            .sheet(isPresented: $viewModel.showImportConfirm) {
                if let config = viewModel.pendingImportConfig {
                    ConfigImportConfirmView(
                        config: config,
                        preview: viewModel.importPreview,
                        onCancel: {
                            viewModel.showImportConfirm = false
                            viewModel.pendingImportConfig = nil
                        },
                        onConfirm: {
                            Task { await viewModel.confirmImport() }
                        }
                    )
                    .environment(\.locale, locale)
                }
            }
    }

    private var docsLocalePath: String {
        if locale.identifier.hasPrefix("zh") {
            return "zh-Hans"
        }
        return "en-US"
    }

    private var configurationGuideURL: URL {
        URL(string: "https://paircast.chaisz.com/\(docsLocalePath)/guide/")!
    }

}

private struct ConfigTransferRow: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(tint)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(TandemColors.secondaryLabel)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TandemColors.tertiaryLabel)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ConfigExportShareView: View {
    let shareURL: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var saveMessage: String?

    private var truncatedURL: String {
        guard shareURL.count > 48 else { return shareURL }
        let head = shareURL.prefix(28)
        let tail = shareURL.suffix(12)
        return "\(head)…\(tail)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 12) {
                        Text("AES-GCM encrypted")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(TandemColors.systemBlue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(TandemColors.systemBlue.opacity(0.1))
                            .clipShape(Capsule())

                        Text("Send to a friend to import")
                            .font(.system(size: 20, weight: .bold))
                            .tracking(-0.3)

                        Text("They can open the link or paste it into Service Configuration to apply the same environment")
                            .font(.system(size: 14))
                            .foregroundStyle(TandemColors.secondaryLabel)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)

                        QRCodeView(payload: shareURL, dimension: 168)
                            .padding(10)
                            .background(TandemColors.secondaryGrouped)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                    .background(TandemColors.secondaryGrouped)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Configuration link")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(TandemColors.secondaryLabel)
                            .textCase(.uppercase)

                        Text(shareURL)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.primary)
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(TandemColors.groupedBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .accessibilityLabel(truncatedURL)

                        HStack {
                            Text("Includes the IM server address only")
                                .font(.system(size: 13))
                                .foregroundStyle(TandemColors.secondaryLabel)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = shareURL
                                copied = true
                            } label: {
                                Text(copied ? LocalizedStringKey("Copied") : LocalizedStringKey("Copy"))
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(TandemColors.systemBlue)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(TandemColors.systemBlue.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    .padding(14)
                    .background(TandemColors.secondaryGrouped)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Button {
                        UIPasteboard.general.string = shareURL
                        copied = true
                    } label: {
                        Text(copied ? LocalizedStringKey("Link copied") : LocalizedStringKey("Copy Link"))
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    HStack(spacing: 10) {
                        if let url = URL(string: shareURL) {
                            ShareLink(item: url) {
                                Text("System Share")
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 46)
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                        Button("Save QR Code") {
                            saveQRToPhotos()
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }

                    if let saveMessage {
                        Text(saveMessage)
                            .font(.footnote)
                            .foregroundStyle(TandemColors.secondaryLabel)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(TandemColors.groupedBackground.ignoresSafeArea())
            .navigationTitle("Share Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ToolbarBackButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let url = URL(string: shareURL) {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .accessibilityLabel("Share")
                    }
                }
            }
        }
    }

    private func saveQRToPhotos() {
        guard let image = QRCodeImageRenderer.image(from: shareURL, dimension: 1024) else {
            saveMessage = TandemL10n.string("Unable to generate QR code")
            return
        }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        saveMessage = TandemL10n.string("Saved to Photos")
    }
}

private struct ConfigPasteImportView: View {
    @Binding var text: String
    var onCancel: () -> Void
    var onContinue: () -> Void
    @FocusState private var focused: Bool

    private var canContinue: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        Text("Paste configuration link")
                            .font(.system(size: 20, weight: .bold))
                            .tracking(-0.3)

                        Text("Supports a full deep link, or a paircast://config?args=… link found in a chat message")
                            .font(.system(size: 14))
                            .foregroundStyle(TandemColors.secondaryLabel)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                    .padding(.top, 8)

                    TextField("paircast://config?args=…", text: $text, axis: .vertical)
                        .font(.system(size: 15))
                        .lineLimit(5...10)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .padding(14)
                        .frame(minHeight: 140, alignment: .topLeading)
                        .background(TandemColors.secondaryGrouped)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(
                                    canContinue
                                        ? Color.clear
                                        : Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.22),
                                    style: StrokeStyle(lineWidth: 1.5, dash: canContinue ? [] : [6, 4])
                                )
                        }

                    Button("Paste from Clipboard") {
                        if let clip = UIPasteboard.general.string, !clip.isEmpty {
                            text = clip
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button("Continue") {
                        onContinue()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canContinue)
                    .opacity(canContinue ? 1 : 0.45)

                    Text("After parsing, a masked preview is shown. Local configuration is overwritten only after you confirm.")
                        .font(.system(size: 12))
                        .foregroundStyle(TandemColors.tertiaryLabel)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .background(TandemColors.groupedBackground.ignoresSafeArea())
            .navigationTitle("Import Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ToolbarCloseButton(action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    ToolbarDoneButton(accessibilityLabel: "Continue", disabled: !canContinue) {
                        onContinue()
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct ConfigImportConfirmView: View {
    let config: AppCloudConfig
    let preview: String
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Encrypted link parsed")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 36 / 255, green: 138 / 255, blue: 61 / 255))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255).opacity(0.12))
                        .clipShape(Capsule())

                    TandemWarningBanner("This will overwrite your local cloud service configuration")

                    confirmSection(title: "IM Server", rows: [
                        ("Address", config.im.isComplete
                            ? config.im.maskedSummary
                            : TandemL10n.string("Not included — enter it in the form")),
                    ])
                    if ConfigQRCodec.shared.isLegacy(config: config) {
                        Text("This link is from an older version. Its storage settings will be ignored — the media library is now configured on the server")
                            .font(.system(size: 13))
                            .foregroundStyle(TandemColors.secondaryLabel)
                    }

                    Button(action: onConfirm) {
                        Text("Confirm Import & Overwrite")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding(16)
            }
            .background(TandemColors.groupedBackground.ignoresSafeArea())
            .navigationTitle("Confirm Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ToolbarCloseButton(action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    ToolbarDoneButton(accessibilityLabel: "Import", action: onConfirm)
                }
            }
            .accessibilityHint(preview)
        }
        .presentationDetents([.medium, .large])
    }

    private func confirmSection(title: LocalizedStringKey, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(TandemColors.secondaryLabel)
                .padding(.horizontal, 4)
            VStack(spacing: 10) {
                ForEach(rows, id: \.0) { row in
                    HStack {
                        Text(LocalizedStringKey(row.0))
                            .font(.system(size: 15))
                            .foregroundStyle(TandemColors.secondaryLabel)
                        Spacer()
                        Text(row.1)
                            .font(.system(size: 15, weight: .medium))
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(TandemColors.secondaryGrouped)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
