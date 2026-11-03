import SwiftUI
import PaircastShared

@MainActor
public final class LoginViewModel: ObservableObject {
    @Published public var account = ""
    @Published public var password = ""
    @Published public var isLoading = false
    @Published public var errorMessage: String?
    @Published public var showConfigAlert = false

    private let session: AppSession

    public init(session: AppSession) {
        self.session = session
    }

    public var configSummary: String? {
        guard let config = session.config, config.im.isComplete else { return nil }
        return config.im.maskedSummary
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
            try await session.login(account: account, password: password)
            password = ""
        } catch {
            errorMessage = TandemL10n.message(for: error, fallback: .network)
        }
    }
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
                    Text("Paircast")
                        .font(.system(size: 34, weight: .bold))
                        .tracking(-0.4)
                    Text("Watch together")
                        .font(.system(size: 15))
                        .foregroundStyle(TandemColors.secondaryLabel)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 12) {
                    TandemTextField("Account", text: $viewModel.account)
                        .textContentType(.username)
                    TandemTextField("Password", text: $viewModel.password, isSecure: true)
                        .textContentType(.password)
                        .onSubmit { Task { await viewModel.login() } }
                    if let summary = viewModel.configSummary {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(TandemColors.secondaryLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Finish service configuration first")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    TermsAgreementView(session: session)
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
                            Text("Sign In")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(viewModel.isLoading)

                    Button("Service Configuration") {
                        session.route = .config(fromLogin: true)
                    }
                    .font(.system(size: 17))
                    .foregroundStyle(TandemColors.systemBlue)
                    .accessibilityLabel("Service Configuration")

                    if viewModel.isConfigured {
                        Text("Accounts are assigned by an admin · No sign-up")
                            .font(.system(size: 13))
                            .foregroundStyle(TandemColors.tertiaryLabel)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 24)
                Spacer()
            }
            .padding(.top, 32)
            .padding(.bottom, 40)
        }
        .alert("Finish service configuration first", isPresented: $viewModel.showConfigAlert) {
            Button("Configure") { session.route = .config(fromLogin: true) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $session.mustChangePassword) {
            ChangePasswordView(session: session, isForced: true)
                .interactiveDismissDisabled()
        }
    }
}

/// Change password. `isForced` is used right after a login the server flagged `must_change_password`.
public struct ChangePasswordView: View {
    @ObservedObject var session: AppSession
    let isForced: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    public init(session: AppSession, isForced: Bool) {
        self.session = session
        self.isForced = isForced
    }

    public var body: some View {
        NavigationStack {
            Form {
                if isForced {
                    Section {
                        Text("Your administrator requires a new password before you continue.")
                            .font(.footnote)
                            .foregroundStyle(TandemColors.secondaryLabel)
                    }
                }
                Section {
                    SecureField("Current password", text: $oldPassword)
                        .textContentType(.password)
                    SecureField("New password", text: $newPassword)
                        .textContentType(.newPassword)
                    SecureField("Confirm new password", text: $confirmPassword)
                        .textContentType(.newPassword)
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(TandemColors.danger)
                    }
                }
            }
            .navigationTitle("Change Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isForced ? "Sign Out" : "Cancel") {
                        if isForced {
                            Task { await session.cancelForcedPasswordChange() }
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(oldPassword.isEmpty || newPassword.isEmpty)
                    }
                }
            }
        }
    }

    private func save() async {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        do {
            try await session.changePassword(old: oldPassword, new: newPassword, confirm: confirmPassword)
            if !isForced { dismiss() }
        } catch {
            errorMessage = TandemL10n.message(for: error, fallback: .passwordChangeFailed)
        }
    }
}
