import SwiftUI
import UIKit
import Domain

@MainActor
public final class ServiceConfigViewModel: ObservableObject {
    @Published public var sdkAppId = ""
    @Published public var imSecretKey = ""
    @Published public var provider: ObjectStorageProvider = .qiniu
    @Published public var accessKey = ""
    @Published public var secretKey = ""
    @Published public var bucket = ""
    @Published public var endpoint = ""
    @Published public var region = ""
    @Published public var domain = ""
    @Published public var prefix = ""
    @Published public var useSSL = true
    @Published public var forcePathStyle = true
    @Published public var subtitleApiKey = ""
    @Published public var omdbApiKey = ""
    @Published public var statusMessage: String?
    @Published public var exportShareURL: String?
    @Published public var showExportRisk = false
    @Published public var showExportSheet = false
    @Published public var showImportPaste = false
    @Published public var importRaw = ""
    @Published public var showImportConfirm = false
    @Published public var importPreview = ""
    @Published public var pendingImportConfig: AppCloudConfig?
    /// Bumped after import so SecureFields recreate and do not write stale empty values back.
    @Published public var formEpoch = 0

    private let session: AppSession

    public init(session: AppSession) {
        self.session = session
        if let config = session.config {
            apply(config)
        }
    }

    private func apply(_ config: AppCloudConfig) {
        sdkAppId = String(config.im.sdkAppId)
        imSecretKey = config.im.secretKey
        provider = config.storage.provider
        accessKey = config.storage.accessKey
        secretKey = config.storage.secretKey
        bucket = config.storage.bucket
        endpoint = config.storage.endpoint
        region = config.storage.region ?? ""
        domain = config.storage.domain ?? ""
        prefix = config.storage.prefix ?? ""
        useSSL = config.storage.useSSL
        forcePathStyle = config.storage.forcePathStyle
        subtitleApiKey = config.subtitleApiKey ?? ""
        omdbApiKey = config.omdbApiKey ?? ""
    }

    public func selectProvider(_ newProvider: ObjectStorageProvider) {
        guard newProvider != provider else { return }
        provider = newProvider
        applyProviderDefaults(newProvider)
    }

    public func applyProviderDefaults(_ newProvider: ObjectStorageProvider) {
        useSSL = newProvider.defaultUseSSL
        forcePathStyle = newProvider.defaultForcePathStyle
        if region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let defaultRegion = newProvider.defaultRegion {
            region = defaultRegion
        }
    }

    /// Returns `true` when config was persisted successfully.
    @discardableResult
    public func save() async -> Bool {
        do {
            let config = try buildConfig()
            let harness = ConfigHarness(configGateway: session.configGateway)
            try await harness.saveCloudConfig(config)
            session.config = config
            statusMessage = TandemL10n.string("Saved")
            return true
        } catch let error as AppError {
            statusMessage = TandemL10n.format(error)
            return false
        } catch {
            statusMessage = TandemL10n.format(AppError.unknown(error.localizedDescription))
            return false
        }
    }

    public func prepareExport() {
        showExportRisk = true
    }

    public func confirmExport() async {
        do {
            // Persist current form first so export matches what the user sees.
            let config = try buildConfig()
            let harness = ConfigHarness(configGateway: session.configGateway)
            try await harness.saveCloudConfig(config)
            session.config = config
            exportShareURL = try await harness.exportConfigQR()
            showExportSheet = true
            statusMessage = TandemL10n.string("Configuration link generated (contains secrets — do not share publicly)")
        } catch let error as AppError {
            statusMessage = TandemL10n.format(error)
        } catch {
            statusMessage = TandemL10n.format(AppError.invalidConfigQR)
        }
    }

    public func prepareImport(raw: String) {
        do {
            let config = try ConfigShareLink.decode(raw)
            pendingImportConfig = config
            importPreview = ConfigQRCodec.maskedPreview(of: config)
            showImportPaste = false
            showImportConfirm = true
        } catch let error as AppError {
            statusMessage = TandemL10n.format(error)
        } catch {
            statusMessage = TandemL10n.format(AppError.invalidConfigQR)
        }
    }

    public func confirmImport() async {
        guard let pendingImportConfig else { return }
        do {
            let harness = ConfigHarness(configGateway: session.configGateway)
            // Persist directly — avoid re-encrypt round-trip and SecureField clobbering via Save.
            try await harness.saveCloudConfig(pendingImportConfig)
            let saved = try await session.configGateway.load() ?? pendingImportConfig
            apply(saved)
            formEpoch += 1
            self.pendingImportConfig = nil
            showImportConfirm = false
            await session.applyImportedCloudConfig(saved)
            statusMessage = TandemL10n.string("Configuration imported. Please sign in again")
        } catch let error as AppError {
            statusMessage = TandemL10n.format(error)
            showImportConfirm = false
        } catch {
            statusMessage = TandemL10n.format(AppError.invalidConfigQR)
            showImportConfirm = false
        }
    }

    public func consumePendingDeepLinkIfNeeded() {
        if let raw = session.consumePendingConfigImport() {
            prepareImport(raw: raw)
        }
    }

    private func buildConfig() throws -> AppCloudConfig {
        guard let appId = Int(sdkAppId) else {
            throw AppError.incompleteConfig(missing: ["IM SDKAppID"])
        }
        let draft = AppCloudConfig(
            im: .init(sdkAppId: appId, secretKey: imSecretKey),
            storage: .init(
                provider: provider,
                accessKey: accessKey,
                secretKey: secretKey,
                bucket: bucket,
                endpoint: endpoint,
                region: region.isEmpty ? nil : region,
                domain: domain.isEmpty ? nil : domain,
                prefix: prefix.isEmpty ? nil : prefix,
                useSSL: useSSL,
                forcePathStyle: forcePathStyle
            ),
            subtitleApiKey: subtitleApiKey.isEmpty ? nil : subtitleApiKey,
            omdbApiKey: omdbApiKey.isEmpty ? nil : omdbApiKey
        )
        return try ConfigValidation.normalized(draft)
    }
}

private struct ConfigHarness: SaveCloudConfigUseCase, ImportConfigQRUseCase, ExportConfigQRUseCase {
    let configGateway: ConfigGateway
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
                        viewModel.prepareExport()
                    }
                } header: {
                    Text("Share & Import")
                } footer: {
                    Text("Links contain secrets — share only with trusted friends")
                }

                Section("Tencent Cloud IM") {
                    TextField("SDKAppID", text: $viewModel.sdkAppId)
                        .keyboardType(.numberPad)
                    SecureField("SecretKey", text: $viewModel.imSecretKey)
                }
                Section {
                    Picker(
                        "Provider",
                        selection: Binding(
                            get: { viewModel.provider },
                            set: { viewModel.selectProvider($0) }
                        )
                    ) {
                        ForEach(ObjectStorageProvider.allCases, id: \.self) { item in
                            Text(LocalizedStringKey(item.displayName)).tag(item)
                        }
                    }
                    SecureField("AccessKey", text: $viewModel.accessKey)
                    SecureField("SecretKey", text: $viewModel.secretKey)
                    TextField("Bucket", text: $viewModel.bucket)
                    TextField(
                        TandemL10n.format(
                            "Endpoint ({{example}})",
                            ["example": viewModel.provider.endpointPlaceholder]
                        ),
                        text: $viewModel.endpoint
                    )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(
                        TandemL10n.format(
                            "Region (optional, {{example}})",
                            ["example": viewModel.provider.regionPlaceholder]
                        ),
                        text: $viewModel.region
                    )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Custom domain (optional)", text: $viewModel.domain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Prefix (optional)", text: $viewModel.prefix)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("HTTPS", isOn: $viewModel.useSSL)
                    Toggle("Path-Style URL", isOn: $viewModel.forcePathStyle)
                } header: {
                    Text("Object Storage")
                } footer: {
                    Text(LocalizedStringKey(storageFooter(for: viewModel.provider)))
                }
                Section {
                    SecureField("OpenSubtitles API Key", text: $viewModel.subtitleApiKey)
                    SecureField("OMDb API Key", text: $viewModel.omdbApiKey)
                } header: {
                    Text("Extensions")
                } footer: {
                    Text("Paircast only plays files from your own cloud storage and does not scrape movie posters from the public web. With an OMDb key, filenames are used to fetch posters and overviews.")
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
                                session.showToast("Saved")
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
            .alert("Sharing includes secrets — do not post publicly", isPresented: $viewModel.showExportRisk) {
                Button("Continue Sharing") { Task { await viewModel.confirmExport() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The link includes Tencent Cloud IM and object storage credentials. Share only with trusted friends.")
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

    private func storageFooter(for provider: ObjectStorageProvider) -> String {
        switch provider {
        case .qiniu:
            return "Use a Qiniu S3 endpoint (e.g. s3.cn-south-1.qiniucs.com). Custom domains are for avatar downloads only — do not put them in Endpoint."
        case .aliyunOSS:
            return "Use an OSS regional endpoint (e.g. oss-cn-hangzhou.aliyuncs.com). Region can be left blank and inferred from Endpoint."
        case .tencentCOS:
            return "Use a COS regional endpoint (e.g. cos.ap-guangzhou.myqcloud.com). Region can be left blank and inferred from Endpoint."
        case .minio:
            return "Use host:port (e.g. 192.168.1.10:9000). Self-hosted MinIO usually disables HTTPS and enables Path-Style; Region defaults to us-east-1."
        }
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
                            Text("Includes IM / object storage secrets")
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

                    TandemWarningBanner("Link contains secrets — do not post to public groups or social media")

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

                    confirmSection(title: "Tencent Cloud IM", rows: [
                        ("SDKAppID", ConfigQRCodec.maskedSDKAppId(config.im.sdkAppId)),
                        ("SecretKey", ConfigQRCodec.maskSecret(config.im.secretKey)),
                    ])
                    confirmSection(title: LocalizedStringKey(config.storage.provider.displayName), rows: [
                        ("AccessKey", ConfigQRCodec.maskedAccessKey(config.storage.accessKey)),
                        ("Bucket", config.storage.bucket),
                        ("Endpoint", ConfigQRCodec.truncate(config.storage.endpoint, max: 22)),
                        ("Region", config.storage.region ?? config.storage.signingRegion),
                    ])

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
