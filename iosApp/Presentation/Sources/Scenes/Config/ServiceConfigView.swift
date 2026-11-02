import SwiftUI
import PaircastShared

@MainActor
public final class ServiceConfigViewModel: ObservableObject {
    @Published public var serverUrl = ""
    @Published public var statusMessage: String?

    private let session: AppSession

    public init(session: AppSession) {
        self.session = session
        if let config = session.config, !config.im.serverUrl.isEmpty {
            serverUrl = config.im.serverUrl
        }
    }

    /// Returns `true` when config was persisted successfully.
    @discardableResult
    public func save() async -> Bool {
        do {
            let previousServer = session.config?.im.serverUrl
            let stored = try await session.graph.saveConfig.invoke(config: draftConfig())
            if session.currentUser != nil, previousServer != stored.im.serverUrl {
                // A different server invalidates the current account session.
                await session.applyServerChange(stored)
            } else {
                session.config = stored
                try? await session.graph.clearMetadataCache()
            }
            statusMessage = TandemL10n.string("Saved")
            return true
        } catch {
            statusMessage = TandemL10n.message(for: error, fallback: .unknown("Unable to save configuration"))
            return false
        }
    }

    private func draftConfig() -> AppCloudConfig {
        AppCloudConfig(
            im: IMConfig(serverUrl: serverUrl),
            updatedAtMs: 0,
            configVersion: AppCloudConfig.companion.CURRENT_VERSION
        )
    }
}

public struct ServiceConfigView: View {
    @ObservedObject var session: AppSession
    let fromLogin: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @StateObject private var viewModel: ServiceConfigViewModel

    public init(session: AppSession, fromLogin: Bool) {
        self.session = session
        self.fromLogin = fromLogin
        _viewModel = StateObject(wrappedValue: ServiceConfigViewModel(session: session))
    }

    public var body: some View {
        if fromLogin {
            NavigationStack {
                formContent
            }
        } else {
            formContent
        }
    }

    private var formContent: some View {
            Form {
                Section {
                    TextField("im.example.com", text: $viewModel.serverUrl)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    Text("The address of the server you or a friend deployed. HTTPS is assumed unless you enter http:// (LAN only).")
                }

                Section {
                    Link(destination: docsURL("guide")) {
                        Label("Configuration Guide", systemImage: "book.fill")
                    }
                    Link(destination: docsURL("deploy")) {
                        Label("Server Deployment Guide", systemImage: "server.rack")
                    }
                } footer: {
                    Text("Fill in the server address, save, then sign in with the account the server admin created for you")
                }

                Section {
                    LabeledContent("Media Library", value: TandemL10n.string("Managed by the server"))
                } footer: {
                    Text("Videos, subtitles, posters and stickers come from the media library the server admin configures.")
                }
                if let status = viewModel.statusMessage {
                    Section {
                        Text(status).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Service Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if fromLogin {
                    ToolbarItem(placement: .cancellationAction) {
                        ToolbarBackButton {
                            session.resetToLogin()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ToolbarDoneButton(accessibilityLabel: "Save") {
                        Task {
                            if await viewModel.save() {
                                session.showToast(TandemL10n.string("Saved"))
                                if fromLogin {
                                    session.resetToLogin()
                                } else {
                                    dismiss()
                                }
                            }
                        }
                    }
                }
            }
    }

    private var docsLocalePath: String {
        if locale.identifier.hasPrefix("zh") {
            return "zh-Hans"
        }
        return "en-US"
    }

    private func docsURL(_ page: String) -> URL {
        URL(string: "https://paircast.chaisz.com/\(docsLocalePath)/\(page)/")!
    }
}
