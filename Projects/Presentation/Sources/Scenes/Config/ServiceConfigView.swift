import SwiftUI
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
    @Published public var exportPayload: String?
    @Published public var showExportRisk = false
    @Published public var importRaw = ""
    @Published public var showImportConfirm = false
    @Published public var importPreview = ""

    private let session: AppSession
    private var pendingImport: AppCloudConfig?

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

    public func save() async {
        do {
            let config = try buildConfig()
            let harness = ConfigHarness(session: session)
            try await harness.saveCloudConfig(config)
            session.config = config
            statusMessage = "已保存"
        } catch let error as AppError {
            statusMessage = error.userMessage
        } catch {
            statusMessage = AppError.unknown(error.localizedDescription).userMessage
        }
    }

    public func prepareExport() {
        showExportRisk = true
    }

    public func confirmExport() async {
        do {
            let harness = ConfigHarness(session: session)
            exportPayload = try await harness.exportConfigQR()
            statusMessage = "已生成配置码（含密钥，请勿公开分享）"
        } catch let error as AppError {
            statusMessage = error.userMessage
        } catch {
            statusMessage = AppError.invalidConfigQR.userMessage
        }
    }

    public func prepareImport(raw: String) {
        do {
            let config = try ConfigQRCodec.decode(raw)
            pendingImport = config
            importPreview = ConfigQRCodec.maskedPreview(of: config)
            showImportConfirm = true
        } catch let error as AppError {
            statusMessage = error.userMessage
        } catch {
            statusMessage = AppError.invalidConfigQR.userMessage
        }
    }

    public func confirmImport() async {
        guard let pendingImport else { return }
        do {
            let raw = try ConfigQRCodec.encode(pendingImport)
            let harness = ConfigHarness(session: session)
            let saved = try await harness.importConfigQR(raw)
            session.config = saved
            apply(saved)
            statusMessage = "配置成功"
        } catch let error as AppError {
            statusMessage = error.userMessage
        } catch {
            statusMessage = AppError.invalidConfigQR.userMessage
        }
        showImportConfirm = false
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
                Section("操作") {
                    Button("扫码导入（粘贴码内容）") {
                        viewModel.prepareImport(raw: viewModel.importRaw)
                    }
                    TextField("粘贴配置 JSON", text: $viewModel.importRaw, axis: .vertical)
                        .lineLimit(3...6)
                    Button("导出二维码内容") {
                        viewModel.prepareExport()
                    }
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
                if let payload = viewModel.exportPayload {
                    Section("导出二维码（含密钥）") {
                        QRCodeView(payload: payload)
                            .frame(maxWidth: .infinity)
                        Text(payload)
                            .font(.caption2)
                            .textSelection(.enabled)
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
                        Task { await viewModel.save() }
                    }
                }
            }
            .alert("导出含密钥，勿分享到公开场合", isPresented: $viewModel.showExportRisk) {
                Button("继续导出") { Task { await viewModel.confirmExport() } }
                Button("取消", role: .cancel) {}
            }
            .alert("确认导入配置？", isPresented: $viewModel.showImportConfirm) {
                Button("覆盖导入") { Task { await viewModel.confirmImport() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text(viewModel.importPreview)
            }
        }
    }
}
