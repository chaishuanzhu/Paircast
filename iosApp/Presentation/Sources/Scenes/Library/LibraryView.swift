import SwiftUI
import PaircastShared

@MainActor
public final class LibraryViewModel: ObservableObject {
    @Published public var movies: [Movie] = []
    @Published public var isLoading = false
    @Published public var errorMessage: String?
    @Published public var showMe = false
    @Published public var sources: [MediaSource] = []
    @Published public var sourceId: String?

    private let session: AppSession

    public init(session: AppSession) {
        self.session = session
    }

    public func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let useCase = session.graph.listMovies
            if sources.isEmpty {
                sources = (try? await useCase.sources()) ?? []
            }
            let listed = try await useCase.invoke(enrichMetadata: false, sourceId: sourceId)
            movies = listed
            errorMessage = nil

            guard !listed.isEmpty, !Task.isCancelled,
                  let config = try? await session.configGateway.load() else { return }
            let enriched = (try? await useCase.enrich(movies: listed, config: config)) ?? listed
            if !Task.isCancelled {
                movies = enriched
            }
        } catch {
            // Pull-to-refresh / task cancellation: keep current movies.
            if Task.isCancelled || AppErrors.isCancellation(error) { return }
            let message = TandemL10n.message(for: error, fallback: .catalogUnauthorized)
            if movies.isEmpty {
                errorMessage = message
            } else {
                session.showToast(message)
            }
        }
    }

    public func selectSource(_ id: String) async {
        guard id != (sourceId ?? sources.first?.id) else { return }
        sourceId = id
        movies = []
        await load()
    }

    public func openMovie(_ movie: Movie) async {
        guard let user = session.currentUser else { return }
        do {
            let room = try await session.roomGateway.createRoom(movieId: movie.id, hostUserId: user.id)
            session.openWatch(roomId: room.id, movieId: movie.id, hostUserId: user.id)
        } catch {
            session.showToast(TandemL10n.message(for: error, fallback: .unknown("Failed to create room")))
        }
    }
}

public struct LibraryView: View {
    @ObservedObject var session: AppSession
    @ObservedObject var theme: ThemeStore
    @ObservedObject var language: LanguageStore
    @StateObject private var viewModel: LibraryViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(session: AppSession, theme: ThemeStore, language: LanguageStore) {
        self.session = session
        self.theme = theme
        self.language = language
        _viewModel = StateObject(wrappedValue: LibraryViewModel(session: session))
    }

    private var contentHorizontalPadding: CGFloat {
        horizontalSizeClass == .regular ? 24 : 16
    }

    /// iPad presents the sheet as a centered form; a medium detent leaves it half empty.
    private var meSheetDetents: Set<PresentationDetent> {
        horizontalSizeClass == .regular ? [.large] : [.medium, .large]
    }

    public var body: some View {
        NavigationStack(path: $session.libraryPath) {
            Group {
                if viewModel.isLoading && viewModel.movies.isEmpty {
                    ProgressView("Loading library…")
                } else if let error = viewModel.errorMessage, viewModel.movies.isEmpty {
                    ContentUnavailableView {
                        Label("Library unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { Task { await viewModel.load() } }
                        Button("Configure") { session.openLibraryConfig() }
                    }
                } else if viewModel.movies.isEmpty {
                    ContentUnavailableView(
                        "No movies",
                        systemImage: "film",
                        description: Text("Ask your admin to add mp4/m4v/mkv files to the server media library")
                    )
                } else {
                    ScrollView {
                        WaterfallLayout(minColumnWidth: 168, maxColumns: 5, spacing: 12) {
                            ForEach(viewModel.movies) { movie in
                                Button {
                                    Task { await viewModel.openMovie(movie) }
                                } label: {
                                    MovieCardView(movie: movie)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, contentHorizontalPadding)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                    }
                    .refreshable { await viewModel.load() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TandemColors.groupedBackground.ignoresSafeArea())
            .navigationTitle("Paircast")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if viewModel.sources.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Picker(
                                "Source",
                                selection: Binding(
                                    get: { viewModel.sourceId ?? viewModel.sources.first?.id ?? "" },
                                    set: { id in Task { await viewModel.selectSource(id) } }
                                )
                            ) {
                                ForEach(viewModel.sources, id: \.id) { source in
                                    Text(source.name).tag(source.id)
                                }
                            }
                        } label: {
                            Image(systemName: "square.stack.3d.up")
                                .accessibilityLabel("Source")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.showMe = true
                    } label: {
                        TandemAvatarView(
                            userId: session.currentUser?.nickname ?? session.currentUser?.id ?? "?",
                            size: 36,
                            avatarURL: session.currentUser?.avatarURL
                        )
                        .accessibilityLabel("Me")
                    }
                    .buttonStyle(.plain)
                }
            }
            .sheet(isPresented: $viewModel.showMe) {
                MeSheetView(session: session, theme: theme, language: language)
                    .environment(\.locale, language.effectiveLocale)
                    .presentationDetents(meSheetDetents)
                    .presentationDragIndicator(.visible)
            }
            .navigationDestination(for: LibraryRoute.self) { destination in
                switch destination {
                case .config:
                    ServiceConfigView(session: session, fromLogin: false)
                case .watch(let roomId, let movieId, let hostUserId):
                    WatchView(
                        session: session,
                        theme: theme,
                        roomId: roomId,
                        movieId: movieId,
                        hostUserId: hostUserId
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationBarBackButtonHidden(true)
                }
            }
            .task { await viewModel.load() }
        }
    }
}

private struct MovieCardView: View {
    let movie: Movie

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.gray.opacity(0.2))
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    PosterImage(url: movie.posterURL)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(movie.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if let year = movie.year, !year.isEmpty {
                Text(year)
                    .font(.system(size: 13))
                    .foregroundStyle(TandemColors.secondaryLabel)
            }

            if let overview = movie.overview, !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 12))
                    .foregroundStyle(TandemColors.tertiaryLabel)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
