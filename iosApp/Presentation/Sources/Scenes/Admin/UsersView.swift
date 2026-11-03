import SwiftUI
import PaircastShared

@MainActor
final class UsersViewModel: ObservableObject {
    @Published private(set) var users: [ManagedUser] = []
    @Published private(set) var total = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var busyId: String?

    let session: AppSession

    init(session: AppSession) {
        self.session = session
    }

    var hasMore: Bool { users.count < total }
    var selfId: String? { session.currentUser?.id }

    func canManage(_ user: ManagedUser) -> Bool {
        AccountRules.shared.canManage(user: user, currentUserId: selfId)
    }

    func load(append: Bool = false) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await session.graph.loadUsers.invoke(
                offset: append ? Int32(users.count) : 0,
                limit: LoadUsersUseCase.companion.PAGE_SIZE
            )
            let known = append ? Set(users.map(\.id)) : []
            let fresh = page.users.filter { !known.contains($0.id) }
            users = append ? users + fresh : fresh
            total = Int(page.total)
        } catch {
            errorMessage = TandemL10n.message(for: error, fallback: .network)
        }
    }

    func setDisabled(_ user: ManagedUser, disabled: Bool) async {
        busyId = user.id
        defer { busyId = nil }
        do {
            try await session.graph.setUserDisabled.invoke(user: user, disabled: disabled)
            if let index = users.firstIndex(where: { $0.id == user.id }) {
                users[index] = user.doCopy(
                    id: user.id,
                    nickname: user.nickname,
                    email: user.email,
                    avatarUrl: user.avatarUrl,
                    isAdmin: user.isAdmin,
                    isDisabled: disabled,
                    createdAtMs: user.createdAtMs
                )
            }
            session.showToast(TandemL10n.format(
                disabled ? "Disabled {{name}}" : "Enabled {{name}}",
                ["name": user.displayName]
            ))
        } catch {
            session.showToast(TandemL10n.message(for: error, fallback: .network))
        }
    }

    func delete(_ user: ManagedUser) async {
        busyId = user.id
        defer { busyId = nil }
        do {
            try await session.graph.deleteUser.invoke(user: user)
            users.removeAll { $0.id == user.id }
            total = max(0, total - 1)
            session.showToast(TandemL10n.format("Deleted {{name}}", ["name": user.displayName]))
        } catch {
            session.showToast(TandemL10n.message(for: error, fallback: .network))
        }
    }
}

private struct PendingUserAction: Identifiable {
    enum Kind { case disable, delete }
    let user: ManagedUser
    let kind: Kind
    var id: String { "\(user.id)-\(kind)" }
}

/// Admin-only: list accounts, disable / enable or delete regular users.
struct UsersView: View {
    @StateObject private var viewModel: UsersViewModel
    @State private var pending: PendingUserAction?

    init(session: AppSession) {
        _viewModel = StateObject(wrappedValue: UsersViewModel(session: session))
    }

    var body: some View {
        List {
            if viewModel.users.isEmpty {
                placeholder
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(viewModel.users, id: \.id) { user in
                        UserRow(
                            user: user,
                            isSelf: user.id == viewModel.selfId,
                            manageable: viewModel.canManage(user),
                            busy: viewModel.busyId == user.id,
                            onToggleDisabled: {
                                if user.isDisabled {
                                    Task { await viewModel.setDisabled(user, disabled: false) }
                                } else {
                                    pending = PendingUserAction(user: user, kind: .disable)
                                }
                            },
                            onDelete: { pending = PendingUserAction(user: user, kind: .delete) }
                        )
                    }
                } header: {
                    Text(TandemL10n.format("Total: {{count}}", ["count": String(viewModel.total)]))
                }
                if viewModel.hasMore {
                    Section {
                        Button {
                            Task { await viewModel.load(append: true) }
                        } label: {
                            HStack {
                                Spacer()
                                if viewModel.isLoading { ProgressView() } else { Text("Load more") }
                                Spacer()
                            }
                        }
                        .disabled(viewModel.isLoading)
                    }
                }
            }
        }
        .navigationTitle("User Management")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    AddUserView(session: viewModel.session)
                } label: {
                    Image(systemName: "person.badge.plus")
                }
                .accessibilityLabel("Add User")
            }
        }
        .refreshable { await viewModel.load() }
        .task { await viewModel.load() }
        .confirmationDialog(
            pending.map(confirmTitle) ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { action in
            switch action.kind {
            case .disable:
                Button("Disable", role: .destructive) {
                    Task { await viewModel.setDisabled(action.user, disabled: true) }
                }
            case .delete:
                Button("Delete", role: .destructive) {
                    Task { await viewModel.delete(action.user) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            switch action.kind {
            case .disable:
                Text("They are signed out right away and can't sign in until you enable the account again.")
            case .delete:
                Text("This permanently deletes the account and signs it out. The email can be added again later.")
            }
        }
    }

    private func confirmTitle(_ action: PendingUserAction) -> String {
        switch action.kind {
        case .disable: TandemL10n.format("Disable {{name}}?", ["name": action.user.displayName])
        case .delete: TandemL10n.format("Delete {{name}}?", ["name": action.user.displayName])
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if viewModel.isLoading {
            ProgressView()
        } else if let error = viewModel.errorMessage {
            VStack(spacing: 8) {
                Text(error)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(TandemColors.secondaryLabel)
                Button("Retry") { Task { await viewModel.load() } }
            }
        } else {
            Text("No users yet")
                .foregroundStyle(TandemColors.secondaryLabel)
        }
    }
}

private struct UserRow: View {
    let user: ManagedUser
    let isSelf: Bool
    let manageable: Bool
    let busy: Bool
    let onToggleDisabled: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TandemAvatarView(
                initial: user.displayName.first.map { String($0).uppercased() } ?? "?",
                size: 40,
                color: TandemColors.avatarColor(for: user.id),
                avatarURL: user.avatarUrl.flatMap(URL.init(string:))
            )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: user.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    if isSelf { badge("You", color: TandemColors.secondaryLabel) }
                    if user.isAdmin { badge("Admin", color: TandemColors.systemBlue) }
                    if user.isDisabled { badge("Disabled", color: TandemColors.danger) }
                }
                Text(verbatim: [user.email, "UID \(user.id)"].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 13))
                    .foregroundStyle(TandemColors.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if busy {
                ProgressView()
            } else if manageable {
                Menu {
                    Button(toggleTitle, action: onToggleDisabled)
                    Button("Delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(TandemColors.secondaryLabel)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("More")
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if manageable && !busy {
                Button("Delete", role: .destructive, action: onDelete)
                Button(toggleTitle, action: onToggleDisabled)
                    .tint(.orange)
            }
        }
    }

    private var toggleTitle: LocalizedStringKey { user.isDisabled ? "Enable" : "Disable" }

    private func badge(_ label: LocalizedStringKey, color: Color) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}
