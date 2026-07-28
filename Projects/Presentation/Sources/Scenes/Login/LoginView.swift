import SwiftUI
import Domain

@MainActor
public final class LoginViewModel: ObservableObject {
    @Published public var userId = ""
    @Published public var password = ""
    @Published public var isLoading = false
    @Published public var errorMessage: String?
    @Published public var showConfigAlert = false

    private let session: AppSession

    public init(session: AppSession) {
        self.session = session
    }

    public var configSummary: String? {
        session.config?.im.maskedSummary
    }

    public var isConfigured: Bool {
        session.config?.isComplete == true
    }

    public func login() async {
        errorMessage = nil
        guard isConfigured else {
            showConfigAlert = true
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let harness = LoginHarness(session: session)
            try await harness.login(userId: userId, password: password)
            session.currentUser = try await session.authGateway.fetchProfile()
            session.route = .library
        } catch let error as AppError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = AppError.network.userMessage
        }
    }
}

private struct LoginHarness: LoginUseCase {
    let session: AppSession
    var configGateway: ConfigGateway { session.configGateway }
    var authGateway: AuthGateway { session.authGateway }
    var userSigGateway: UserSigGateway { session.userSigGateway }
}

public struct LoginView: View {
    @ObservedObject var session: AppSession
    @StateObject private var viewModel: LoginViewModel

    public init(session: AppSession) {
        self.session = session
        _viewModel = StateObject(wrappedValue: LoginViewModel(session: session))
    }

    public var body: some View {
        ZStack {
            TandemColors.groupedBackground.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                VStack(spacing: 8) {
                    Text("Tandem")
                        .font(.system(size: 34, weight: .bold))
                    Text("一起看电影")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 12) {
                    TandemTextField("用户名", text: $viewModel.userId)
                    TandemTextField("密码", text: $viewModel.password, isSecure: true)
                    if let summary = viewModel.configSummary {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("请先完成服务配置")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(TandemColors.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button {
                        Task { await viewModel.login() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                        } else {
                            Text("登录")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(viewModel.isLoading)

                    Button("服务配置") {
                        session.route = .config(fromLogin: true)
                    }
                    .font(.body)
                    .foregroundStyle(TandemColors.systemBlue)
                    .accessibilityLabel("服务配置")
                }
                .padding(.horizontal, 20)
                Spacer()
            }
        }
        .alert("请先完成服务配置", isPresented: $viewModel.showConfigAlert) {
            Button("去配置") { session.route = .config(fromLogin: true) }
            Button("取消", role: .cancel) {}
        }
    }
}
