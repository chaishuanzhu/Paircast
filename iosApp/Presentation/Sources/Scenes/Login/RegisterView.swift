import SwiftUI
import PaircastShared

/// Email sign-up: request a code, then create the account and sign in.
@MainActor
public final class RegisterViewModel: ObservableObject {
    @Published public var email = ""
    @Published public var code = ""
    @Published public var password = ""
    @Published public var confirm = ""
    @Published public var nickname = ""
    @Published public var isSending = false
    @Published public var isSubmitting = false
    @Published public var codeSent = false
    @Published public var cooldown = 0
    @Published public var errorMessage: String?

    private let session: AppSession
    private var countdownTask: Task<Void, Never>?

    public init(session: AppSession) {
        self.session = session
    }

    deinit {
        countdownTask?.cancel()
    }

    public var canSendCode: Bool {
        !isSending && cooldown == 0 && !email.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var canSubmit: Bool {
        !isSubmitting && !email.isEmpty && code.count == Int(RegisterRules.shared.CODE_LENGTH)
            && !password.isEmpty && !confirm.isEmpty
    }

    public func sendCode() async {
        errorMessage = nil
        isSending = true
        defer { isSending = false }
        do {
            startCountdown(try await session.sendRegisterCode(email: email))
            codeSent = true
            session.showToast(TandemL10n.string("Verification code sent"))
        } catch {
            if let tooMany = AppErrors.from(error) as? AppError.TooManyCodeRequests,
               let retry = tooMany.retryAfterSeconds {
                startCountdown(Int(truncating: retry))
            }
            errorMessage = TandemL10n.message(for: error, fallback: .network)
        }
    }

    public func submit() async {
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await session.register(email: email, code: code, password: password, confirm: confirm, nickname: nickname)
        } catch {
            errorMessage = TandemL10n.message(for: error, fallback: .network)
        }
    }

    public func filterCode(_ raw: String) {
        let digits = String(raw.filter(\.isNumber).prefix(Int(RegisterRules.shared.CODE_LENGTH)))
        if digits != code { code = digits }
    }

    private func startCountdown(_ seconds: Int) {
        countdownTask?.cancel()
        cooldown = seconds
        countdownTask = Task { [weak self] in
            while let self, self.cooldown > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                self.cooldown -= 1
            }
        }
    }
}

public struct RegisterView: View {
    @ObservedObject var session: AppSession
    @StateObject private var viewModel: RegisterViewModel

    public init(session: AppSession) {
        self.session = session
        _viewModel = StateObject(wrappedValue: RegisterViewModel(session: session))
    }

    public var body: some View {
        ZStack {
            TandemColors.groupedBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text("Create Account")
                            .font(.system(size: 28, weight: .bold))
                        Text("Sign up with your email. We'll send you a verification code.")
                            .font(.system(size: 15))
                            .foregroundStyle(TandemColors.secondaryLabel)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 12) {
                        TandemTextField("Email", text: $viewModel.email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                        HStack(spacing: 8) {
                            TandemTextField("Verification code", text: $viewModel.code)
                                .textContentType(.oneTimeCode)
                                .keyboardType(.numberPad)
                                .onChange(of: viewModel.code) { _, value in viewModel.filterCode(value) }
                            Button {
                                Task { await viewModel.sendCode() }
                            } label: {
                                if viewModel.isSending {
                                    ProgressView()
                                } else if viewModel.cooldown > 0 {
                                    Text(TandemL10n.format("Resend in {{count}}s", ["count": "\(viewModel.cooldown)"]))
                                        .monospacedDigit()
                                } else {
                                    Text(viewModel.codeSent ? "Resend" : "Send Code")
                                }
                            }
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(viewModel.canSendCode ? TandemColors.systemBlue : TandemColors.tertiaryLabel)
                            .disabled(!viewModel.canSendCode)
                            .fixedSize()
                        }
                        TandemTextField("Password", text: $viewModel.password, isSecure: true)
                            .textContentType(.newPassword)
                        TandemTextField("Confirm password", text: $viewModel.confirm, isSecure: true)
                            .textContentType(.newPassword)
                        TandemTextField("Nickname (optional)", text: $viewModel.nickname)
                            .textContentType(.nickname)
                        if let error = viewModel.errorMessage {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(TandemColors.danger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button {
                            Task { await viewModel.submit() }
                        } label: {
                            if viewModel.isSubmitting {
                                ProgressView()
                            } else {
                                Text("Create Account")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!viewModel.canSubmit)

                        Button("Already have an account? Sign In") {
                            session.resetToLogin()
                        }
                        .font(.system(size: 15))
                        .foregroundStyle(TandemColors.systemBlue)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 48)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}
