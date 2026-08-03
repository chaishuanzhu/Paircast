import SwiftUI
import Domain

@MainActor
public final class MeViewModel: ObservableObject {
    @Published public var nickname = ""
    @Published public var statusMessage: String?
    @Published public var showLogoutConfirm = false

    private let session: AppSession

    public init(session: AppSession) {
        self.session = session
        nickname = session.currentUser?.nickname ?? ""
    }

    public var userId: String {
        session.currentUser?.id ?? ""
    }

    public var isConfigured: Bool {
        session.config?.isComplete == true
    }

    public func save() async {
        do {
            let harness = MeHarness(session: session)
            let user = try await harness.updateProfile(nickname: nickname, avatarData: nil)
            session.currentUser = user
            statusMessage = "已保存"
        } catch let error as AppError {
            statusMessage = error.userMessage
        } catch {
            statusMessage = AppError.network.userMessage
        }
    }

    public func logout() async {
        do {
            let harness = MeHarness(session: session)
            try await harness.logout()
            session.currentUser = nil
            session.route = .login
        } catch {
            statusMessage = AppError.network.userMessage
        }
    }
}

private struct MeHarness: UpdateProfileUseCase, LogoutUseCase {
    let session: AppSession
    var authGateway: AuthGateway { session.authGateway }
    var configGateway: ConfigGateway { session.configGateway }
}

public struct MeSheetView: View {
    @ObservedObject var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: MeViewModel

    public init(session: AppSession) {
        self.session = session
        _viewModel = StateObject(wrappedValue: MeViewModel(session: session))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 10) {
                        TandemAvatarView(
                            userId: viewModel.nickname.isEmpty ? viewModel.userId : viewModel.nickname,
                            size: 80
                        )
                        Text("轻点更换头像")
                            .font(.system(size: 13))
                            .foregroundStyle(TandemColors.secondaryLabel)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                    VStack(spacing: 0) {
                        meRow(title: "昵称") {
                            TextField("昵称", text: $viewModel.nickname)
                                .multilineTextAlignment(.trailing)
                                .font(.system(size: 17))
                        }
                        Divider().padding(.leading, 16)
                        meRow(title: "用户名") {
                            Text(viewModel.userId)
                                .font(.system(size: 17))
                                .foregroundStyle(TandemColors.secondaryLabel)
                        }
                        Divider().padding(.leading, 16)
                        Button {
                            dismiss()
                            session.route = .config(fromLogin: false)
                        } label: {
                            meRow(title: "服务配置") {
                                HStack(spacing: 4) {
                                    Text(viewModel.isConfigured ? "已配置" : "未配置")
                                        .foregroundStyle(TandemColors.secondaryLabel)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(TandemColors.tertiaryLabel)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button {
                        viewModel.showLogoutConfirm = true
                    } label: {
                        Text("退出登录")
                            .font(.system(size: 17))
                            .foregroundStyle(TandemColors.danger)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    if let status = viewModel.statusMessage {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(TandemColors.secondaryLabel)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(TandemColors.groupedBackground.ignoresSafeArea())
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        Task {
                            await viewModel.save()
                            dismiss()
                        }
                    }
                }
            }
            .confirmationDialog("确定退出登录？", isPresented: $viewModel.showLogoutConfirm, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    Task { await viewModel.logout() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将保留本地云服务配置")
            }
        }
    }

    private func meRow<Content: View>(title: String, @ViewBuilder trailing: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 17))
                .foregroundStyle(Color.primary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
