import SwiftUI
import UIKit
import PaircastShared

@MainActor
final class AddUserViewModel: ObservableObject {
    @Published var email = ""
    @Published var nickname = ""
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?
    @Published private(set) var created: CreatedAccount?

    private let session: AppSession

    init(session: AppSession) {
        self.session = session
    }

    func submit() async {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        do {
            created = try await session.createUser(email: email, nickname: nickname)
        } catch {
            errorMessage = TandemL10n.message(for: error, fallback: .network)
        }
    }

    func copyPassword() {
        guard let password = created?.initialPassword else { return }
        UIPasteboard.general.string = password
        session.showToast(TandemL10n.string("Copied"))
    }

    func reset() {
        created = nil
        email = ""
        nickname = ""
        errorMessage = nil
    }
}

/// Admin-only: accounts exist only when an admin adds them (no self sign-up).
struct AddUserView: View {
    @StateObject private var viewModel: AddUserViewModel

    init(session: AppSession) {
        _viewModel = StateObject(wrappedValue: AddUserViewModel(session: session))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let created = viewModel.created {
                    result(created)
                } else {
                    form
                }
            }
            .padding(16)
        }
        .background(TandemColors.groupedBackground)
        .navigationTitle("Add User")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var form: some View {
        VStack(spacing: 12) {
            TandemTextField("Email", text: $viewModel.email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
            TandemTextField("Nickname (optional)", text: $viewModel.nickname)
            Text("A random initial password is created. If the server can send email, it goes to this address; otherwise it's shown here for you to pass on. The user must change it at first sign-in.")
                .font(.footnote)
                .foregroundStyle(TandemColors.secondaryLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let error = viewModel.errorMessage {
                Text(verbatim: error)
                    .font(.footnote)
                    .foregroundStyle(TandemColors.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                Task { await viewModel.submit() }
            } label: {
                if viewModel.isSaving {
                    ProgressView().tint(.white)
                } else {
                    Text("Add")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(viewModel.isSaving || viewModel.email.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func result(_ created: CreatedAccount) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                Text("User added")
                    .font(.system(size: 20, weight: .semibold))
                Text(verbatim: "\(created.nickname) · \(created.email)")
                    .font(.system(size: 15))
                    .foregroundStyle(TandemColors.secondaryLabel)
            }
            .padding(.top, 12)

            if let password = created.initialPassword {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Initial password")
                        .font(.system(size: 13))
                        .foregroundStyle(TandemColors.secondaryLabel)
                    HStack {
                        Text(verbatim: password)
                            .font(.system(size: 20, weight: .medium, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button("Copy") { viewModel.copyPassword() }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(TandemColors.systemBlue)
                    }
                }
                .padding(16)
                .background(TandemColors.secondaryGrouped)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("Send this password to the user yourself. It isn't shown again; they must change it at first sign-in.")
                    .font(.footnote)
                    .foregroundStyle(TandemColors.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(TandemL10n.format("The initial password was emailed to {{email}}. They must change it at first sign-in.", ["email": created.email]))
                    .font(.footnote)
                    .foregroundStyle(TandemColors.secondaryLabel)
                    .multilineTextAlignment(.center)
            }

            Button("Add Another") { viewModel.reset() }
                .buttonStyle(SecondaryButtonStyle())
        }
    }
}
