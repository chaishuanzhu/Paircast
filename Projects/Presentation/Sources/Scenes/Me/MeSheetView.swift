import SwiftUI
import PhotosUI
import UIKit
import Domain

@MainActor
public final class MeViewModel: ObservableObject {
    @Published public var nickname = ""
    @Published public var statusMessage: String?
    @Published public var showLogoutConfirm = false
    @Published public var showDeleteConfirm = false
    @Published public var pendingAvatarData: Data?
    @Published public var pendingAvatarPreview: UIImage?
    @Published public var isSaving = false
    @Published public var pickerItem: PhotosPickerItem?

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

    public var displayedAvatarURL: URL? {
        pendingAvatarPreview == nil ? session.currentUser?.avatarURL : nil
    }

    public func applyPickedItem(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        statusMessage = nil
        do {
            let picked = try await item.loadTransferable(type: PickedImageData.self)
            guard let raw = picked?.data else {
                statusMessage = TandemL10n.string("Unable to read image")
                return
            }
            guard let jpeg = AvatarImageCompressor.jpegData(from: raw) else {
                statusMessage = TandemL10n.string("Unable to process this image, or it still exceeds 1MB after compression")
                return
            }
            pendingAvatarData = jpeg
            pendingAvatarPreview = UIImage(data: jpeg)
        } catch {
            statusMessage = TandemL10n.string("Unable to read image")
        }
    }

    public func save() async -> Bool {
        isSaving = true
        defer { isSaving = false }
        do {
            let harness = MeHarness(
                authGateway: session.authGateway,
                configGateway: session.configGateway
            )
            let user = try await harness.updateProfile(
                nickname: nickname,
                avatarData: pendingAvatarData
            )
            session.currentUser = user
            pendingAvatarData = nil
            pendingAvatarPreview = nil
            statusMessage = TandemL10n.string("Saved")
            return true
        } catch let error as AppError {
            statusMessage = TandemL10n.format(error)
            return false
        } catch {
            statusMessage = TandemL10n.format(AppError.network)
            return false
        }
    }

    public func logout() async {
        do {
            let harness = MeHarness(
                authGateway: session.authGateway,
                configGateway: session.configGateway
            )
            try await harness.logout()
            session.currentUser = nil
            session.resetToLogin()
        } catch {
            statusMessage = TandemL10n.format(AppError.network)
        }
    }

    public func deleteAccount() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let harness = MeHarness(
                authGateway: session.authGateway,
                configGateway: session.configGateway
            )
            if let userId = session.currentUser?.id {
                ChatSafetyStore().clear(ownerId: userId)
            }
            try await harness.deleteAccount()
            session.config = nil
            session.currentUser = nil
            session.resetToLogin()
        } catch {
            statusMessage = TandemL10n.format(AppError.network)
        }
    }
}

private struct MeHarness: UpdateProfileUseCase, LogoutUseCase, DeleteAccountUseCase {
    let authGateway: AuthGateway
    let configGateway: ConfigGateway
}

@MainActor
public struct MeSheetView: View {
    @ObservedObject var session: AppSession
    @ObservedObject var theme: ThemeStore
    @ObservedObject var language: LanguageStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: MeViewModel

    public init(session: AppSession, theme: ThemeStore, language: LanguageStore) {
        self.session = session
        self.theme = theme
        self.language = language
        _viewModel = StateObject(wrappedValue: MeViewModel(session: session))
    }

    public var body: some View {
        let avatarUserId = viewModel.nickname.isEmpty ? viewModel.userId : viewModel.nickname
        let avatarURL = viewModel.displayedAvatarURL
        let avatarImage = viewModel.pendingAvatarPreview

        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    PhotosPicker(selection: $viewModel.pickerItem, matching: .images, photoLibrary: .shared()) {
                        VStack(spacing: 10) {
                            TandemAvatarView(
                                userId: avatarUserId,
                                size: 80,
                                avatarURL: avatarURL,
                                localImage: avatarImage
                            )
                            Text("Tap to change avatar")
                                .font(.system(size: 13))
                                .foregroundStyle(TandemColors.secondaryLabel)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Change avatar")
                    .onChange(of: viewModel.pickerItem) { _, item in
                        Task { await viewModel.applyPickedItem(item) }
                    }

                    VStack(spacing: 0) {
                        meRow(title: "Nickname") {
                            TextField("Nickname", text: $viewModel.nickname)
                                .multilineTextAlignment(.trailing)
                                .font(.system(size: 17))
                        }
                        Divider().padding(.leading, 16)
                        meRow(title: "Username") {
                            Text(viewModel.userId)
                                .font(.system(size: 17))
                                .foregroundStyle(TandemColors.secondaryLabel)
                        }
                        Divider().padding(.leading, 16)
                        Button {
                            dismiss()
                            Task { @MainActor in
                                await Task.yield()
                                session.openLibraryConfig()
                            }
                        } label: {
                            meRow(title: "Service Configuration") {
                                HStack(spacing: 4) {
                                    Text(viewModel.isConfigured ? LocalizedStringKey("Configured") : LocalizedStringKey("Not configured"))
                                        .foregroundStyle(TandemColors.secondaryLabel)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(TandemColors.tertiaryLabel)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 16)
                        NavigationLink {
                            ThemeSettingsView(theme: theme)
                        } label: {
                            meRow(title: "Theme") {
                                HStack(spacing: 4) {
                                    Text(appearanceTitle(theme.appearance))
                                        .foregroundStyle(TandemColors.secondaryLabel)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(TandemColors.tertiaryLabel)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 16)
                        NavigationLink {
                            LanguageSettingsView(language: language)
                        } label: {
                            meRow(title: "Language") {
                                HStack(spacing: 4) {
                                    Text(language.language.title)
                                        .foregroundStyle(TandemColors.secondaryLabel)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(TandemColors.tertiaryLabel)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 16)
                        NavigationLink {
                            AcknowledgementsView()
                        } label: {
                            meRow(title: "Acknowledgements") {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(TandemColors.tertiaryLabel)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .background(TandemColors.secondaryGrouped)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button {
                        viewModel.showLogoutConfirm = true
                    } label: {
                        Text("Sign Out")
                            .font(.system(size: 17))
                            .foregroundStyle(TandemColors.danger)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(TandemColors.secondaryGrouped)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        viewModel.showDeleteConfirm = true
                    } label: {
                        Text("Delete Account")
                            .font(.system(size: 17))
                            .foregroundStyle(TandemColors.danger)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(TandemColors.secondaryGrouped)
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
            .navigationTitle("Me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    ToolbarDoneButton(disabled: viewModel.isSaving) {
                        Task {
                            if await viewModel.save() {
                                dismiss()
                            }
                        }
                    }
                }
            }
            .confirmationDialog("Sign out?", isPresented: $viewModel.showLogoutConfirm, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    Task { await viewModel.logout() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Local cloud service configuration will be kept")
            }
            .confirmationDialog("Delete account?", isPresented: $viewModel.showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete Account", role: .destructive) {
                    Task { await viewModel.deleteAccount() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears local cloud config, sign-in session, avatar, and nickname, then signs you out. Provisioned IM accounts must be disabled separately by an admin.")
            }
            .overlay {
                if viewModel.isSaving {
                    ProgressView("Saving…")
                        .padding(20)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .environment(\.locale, language.effectiveLocale)
        .id(language.effectiveLocale.identifier)
        .preferredColorScheme(theme.appearance.preferredColorScheme)
        .onAppear { ThemeWindowApplier.apply(theme.appearance) }
        .onChange(of: theme.appearance) { _, appearance in
            ThemeWindowApplier.apply(appearance)
        }
    }

    private func meRow<Content: View>(title: LocalizedStringKey, @ViewBuilder trailing: () -> Content) -> some View {
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

    private func appearanceTitle(_ option: AppAppearance) -> LocalizedStringKey {
        switch option {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}
