import SwiftUI
import Domain

@MainActor
public final class LoginViewModel: ObservableObject {
    @Published public var userId = ""
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
            let harness = LoginHarness(
                configGateway: session.configGateway,
                authGateway: session.authGateway,
                userSigGateway: session.userSigGateway
            )
            try await harness.login(userId: userId)
            session.currentUser = try await session.authGateway.fetchProfile()
            session.consumePendingInviteIfPossible()
            session.route = .library
        } catch let error as AppError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = AppError.network.userMessage
        }
    }
}

private struct LoginHarness: LoginUseCase {
    let configGateway: ConfigGateway
    let authGateway: AuthGateway
    let userSigGateway: UserSigGateway
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
            VStack(spacing: 28) {
                Spacer(minLength: 24)
                VStack(spacing: 10) {
                    Image("BrandMark", bundle: .main)
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: TandemColors.systemBlue.opacity(0.28), radius: 12, y: 6)
                        .accessibilityHidden(true)
                    Text("Tandem")
                        .font(.system(size: 34, weight: .bold))
                        .tracking(-0.4)
                    Text("一起看电影")
                        .font(.system(size: 15))
                        .foregroundStyle(TandemColors.secondaryLabel)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 12) {
                    TandemTextField("用户 ID", text: $viewModel.userId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let summary = viewModel.configSummary {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(TandemColors.secondaryLabel)
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
                    .font(.system(size: 17))
                    .foregroundStyle(TandemColors.systemBlue)
                    .accessibilityLabel("服务配置")

                    Text("账号由管理员分配 · 不提供注册")
                        .font(.system(size: 13))
                        .foregroundStyle(TandemColors.tertiaryLabel)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 24)
                Spacer()
            }
            .padding(.top, 32)
            .padding(.bottom, 40)
        }
        .alert("请先完成服务配置", isPresented: $viewModel.showConfigAlert) {
            Button("去配置") { session.route = .config(fromLogin: true) }
            Button("取消", role: .cancel) {}
        }
    }
}
