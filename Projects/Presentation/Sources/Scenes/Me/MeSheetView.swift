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
            Form {
                Section {
                    HStack {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            TextField("昵称", text: $viewModel.nickname)
                            Text(viewModel.userId)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button("服务配置") {
                        dismiss()
                        session.route = .config(fromLogin: false)
                    }
                }
                Section {
                    Button("退出登录", role: .destructive) {
                        viewModel.showLogoutConfirm = true
                    }
                }
                if let status = viewModel.statusMessage {
                    Text(status).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("我的")
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
}
