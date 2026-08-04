import SwiftUI
import UIKit
import Domain

@MainActor
public final class ServiceConfigViewModel: ObservableObject {
    @Published public var sdkAppId = ""
    @Published public var imSecretKey = ""
    @Published public var accessKey = ""
    @Published public var secretKey = ""
    @Published public var bucket = ""
    @Published public var endpoint = ""
    @Published public var domain = ""
    @Published public var prefix = ""
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
        accessKey = config.qiniu.accessKey
        secretKey = config.qiniu.secretKey
        bucket = config.qiniu.bucket
        endpoint = config.qiniu.endpoint
        domain = config.qiniu.domain ?? ""
        prefix = config.qiniu.prefix ?? ""
        subtitleApiKey = config.subtitleApiKey ?? ""
        omdbApiKey = config.omdbApiKey ?? ""
    }

    /// Returns `true` when config was persisted successfully.
    @discardableResult
    public func save() async -> Bool {
        do {
            let config = try buildConfig()
            let harness = ConfigHarness(session: session)
            try await harness.saveCloudConfig(config)
            session.config = config
            statusMessage = "已保存"
            return true
        } catch let error as AppError {
            statusMessage = error.userMessage
            return false
        } catch {
            statusMessage = AppError.unknown(error.localizedDescription).userMessage
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
            let harness = ConfigHarness(session: session)
            try await harness.saveCloudConfig(config)
            session.config = config
            exportShareURL = try await harness.exportConfigQR()
            showExportSheet = true
            statusMessage = "已生成配置链接（含密钥，请勿公开分享）"
        } catch let error as AppError {
            statusMessage = error.userMessage
        } catch {
            statusMessage = AppError.invalidConfigQR.userMessage
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
            statusMessage = error.userMessage
        } catch {
            statusMessage = AppError.invalidConfigQR.userMessage
        }
    }

    public func confirmImport() async {
        guard let pendingImportConfig else { return }
        do {
            let raw = try ConfigShareLink.shareURL(for: pendingImportConfig).absoluteString
            let harness = ConfigHarness(session: session)
            let saved = try await harness.importConfigQR(raw)
            session.config = saved
            apply(saved)
            statusMessage = "配置成功"
            self.pendingImportConfig = nil
        } catch let error as AppError {
            statusMessage = error.userMessage
        } catch {
            statusMessage = AppError.invalidConfigQR.userMessage
        }
        showImportConfirm = false
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
        return AppCloudConfig(
            im: .init(sdkAppId: appId, secretKey: imSecretKey),
            qiniu: .init(
                accessKey: accessKey,
                secretKey: secretKey,
                bucket: bucket,
                endpoint: endpoint,
                domain: domain.isEmpty ? nil : domain,
                prefix: prefix.isEmpty ? nil : prefix
            ),
            subtitleApiKey: subtitleApiKey.isEmpty ? nil : subtitleApiKey,
            omdbApiKey: omdbApiKey.isEmpty ? nil : omdbApiKey
        )
    }
}

private struct ConfigHarness: SaveCloudConfigUseCase, ImportConfigQRUseCase, ExportConfigQRUseCase {
    let session: AppSession
    var configGateway: ConfigGateway { session.configGateway }
}

public struct ServiceConfigView: View {
    @ObservedObject var session: AppSession
    let fromLogin: Bool
    @StateObject private var viewModel: ServiceConfigViewModel

    public init(session: AppSession, fromLogin: Bool) {
        self.session = session
        self.fromLogin = fromLogin
        _viewModel = StateObject(wrappedValue: ServiceConfigViewModel(session: session))
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    ConfigTransferRow(
                        title: "粘贴导入",
                        subtitle: "粘贴 tandem://config?args=… 链接",
                        systemImage: "arrow.down.doc.fill",
                        tint: Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
                    ) {
                        viewModel.importRaw = ""
                        viewModel.showImportPaste = true
                    }
                    ConfigTransferRow(
                        title: "分享配置",
                        subtitle: "生成加密链接，复制或分享给好友",
                        systemImage: "square.and.arrow.up.fill",
                        tint: TandemColors.systemBlue
                    ) {
                        viewModel.prepareExport()
                    }
                } header: {
                    Text("分享与导入")
                } footer: {
                    Text("链接含密钥，仅发给可信好友")
                }

                Section("腾讯云 IM") {
                    TextField("SDKAppID", text: $viewModel.sdkAppId)
                        .keyboardType(.numberPad)
                    SecureField("SecretKey", text: $viewModel.imSecretKey)
                }
                Section("七牛云") {
                    SecureField("AccessKey", text: $viewModel.accessKey)
                    SecureField("SecretKey", text: $viewModel.secretKey)
                    TextField("Bucket", text: $viewModel.bucket)
                    TextField("Endpoint", text: $viewModel.endpoint)
                    TextField("自定义域名（可选）", text: $viewModel.domain)
                    TextField("Prefix（可选）", text: $viewModel.prefix)
                }
                Section("扩展") {
                    SecureField("OpenSubtitles API Key", text: $viewModel.subtitleApiKey)
                    SecureField("OMDb API Key", text: $viewModel.omdbApiKey)
                }
                if let status = viewModel.statusMessage {
                    Section {
                        Text(status).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("服务配置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") {
                        session.route = fromLogin ? .login : .library
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            if await viewModel.save() {
                                session.showToast("已保存")
                                session.route = fromLogin ? .login : .library
                            }
                        }
                    }
                }
            }
            .task {
                viewModel.consumePendingDeepLinkIfNeeded()
            }
            .alert("分享含密钥，勿发到公开场合", isPresented: $viewModel.showExportRisk) {
                Button("继续分享") { Task { await viewModel.confirmExport() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("链接内含腾讯云 IM 与七牛凭证，仅发给可信好友。")
            }
            .sheet(isPresented: $viewModel.showExportSheet) {
                if let shareURL = viewModel.exportShareURL {
                    ConfigExportShareView(shareURL: shareURL)
                }
            }
            .sheet(isPresented: $viewModel.showImportPaste) {
                ConfigPasteImportView(
                    text: $viewModel.importRaw,
                    onCancel: { viewModel.showImportPaste = false },
                    onContinue: { viewModel.prepareImport(raw: viewModel.importRaw) }
                )
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
                }
            }
        }
    }
}

private struct ConfigTransferRow: View {
    let title: String
    let subtitle: String
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
                        Text("AES-GCM 加密")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(TandemColors.systemBlue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(TandemColors.systemBlue.opacity(0.1))
                            .clipShape(Capsule())

                        Text("发给好友即可导入")
                            .font(.system(size: 20, weight: .bold))
                            .tracking(-0.3)

                        Text("对方打开链接或粘贴到「服务配置」即可写入同一套环境")
                            .font(.system(size: 14))
                            .foregroundStyle(TandemColors.secondaryLabel)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)

                        QRCodeView(payload: shareURL, dimension: 168)
                            .padding(10)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("配置链接")
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
                            Text("含 IM / 七牛密钥")
                                .font(.system(size: 13))
                                .foregroundStyle(TandemColors.secondaryLabel)
                            Spacer()
                            Button(copied ? "已复制" : "复制") {
                                UIPasteboard.general.string = shareURL
                                copied = true
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
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    TandemWarningBanner("链接含密钥，请勿发到公开群或社交平台")

                    Button {
                        UIPasteboard.general.string = shareURL
                        copied = true
                    } label: {
                        Text(copied ? "已复制链接" : "复制链接")
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    HStack(spacing: 10) {
                        if let url = URL(string: shareURL) {
                            ShareLink(item: url) {
                                Text("系统分享")
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 46)
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                        Button("保存二维码") {
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
            .navigationTitle("分享配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let url = URL(string: shareURL) {
                        ShareLink(item: url) {
                            Text("分享")
                        }
                    }
                }
            }
        }
    }

    private func saveQRToPhotos() {
        guard let image = QRCodeImageRenderer.image(from: shareURL, dimension: 1024) else {
            saveMessage = "无法生成二维码"
            return
        }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        saveMessage = "已保存到相册"
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

                        Text("粘贴配置链接")
                            .font(.system(size: 20, weight: .bold))
                            .tracking(-0.3)

                        Text("支持完整深链，或聊天消息中带有的 tandem://config?args=…")
                            .font(.system(size: 14))
                            .foregroundStyle(TandemColors.secondaryLabel)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                    .padding(.top, 8)

                    TextField("tandem://config?args=…", text: $text, axis: .vertical)
                        .font(.system(size: 15))
                        .lineLimit(5...10)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .padding(14)
                        .frame(minHeight: 140, alignment: .topLeading)
                        .background(Color.white)
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

                    Button("从剪贴板粘贴") {
                        if let clip = UIPasteboard.general.string, !clip.isEmpty {
                            text = clip
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button("继续解析") {
                        onContinue()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canContinue)
                    .opacity(canContinue ? 1 : 0.45)

                    Text("解析成功后会展示脱敏预览，确认才会覆盖本机配置")
                        .font(.system(size: 12))
                        .foregroundStyle(TandemColors.tertiaryLabel)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .background(TandemColors.groupedBackground.ignoresSafeArea())
            .navigationTitle("导入配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("继续") { onContinue() }
                        .disabled(!canContinue)
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
                    Text("加密链接已解析")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 36 / 255, green: 138 / 255, blue: 61 / 255))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255).opacity(0.12))
                        .clipShape(Capsule())

                    TandemWarningBanner("将覆盖本机现有云服务配置")

                    confirmSection(title: "腾讯云 IM", rows: [
                        ("SDKAppID", ConfigQRCodec.maskedSDKAppId(config.im.sdkAppId)),
                        ("SecretKey", ConfigQRCodec.maskSecret(config.im.secretKey)),
                    ])
                    confirmSection(title: "七牛云", rows: [
                        ("AccessKey", ConfigQRCodec.maskedAccessKey(config.qiniu.accessKey)),
                        ("Bucket", config.qiniu.bucket),
                        ("Endpoint", ConfigQRCodec.truncate(config.qiniu.endpoint, max: 22)),
                    ])

                    Button(action: onConfirm) {
                        Text("确认导入并覆盖")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding(16)
            }
            .background(TandemColors.groupedBackground.ignoresSafeArea())
            .navigationTitle("确认导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入", action: onConfirm)
                }
            }
            .accessibilityHint(preview)
        }
        .presentationDetents([.medium, .large])
    }

    private func confirmSection(title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(TandemColors.secondaryLabel)
                .padding(.horizontal, 4)
            VStack(spacing: 10) {
                ForEach(rows, id: \.0) { row in
                    HStack {
                        Text(row.0)
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
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
