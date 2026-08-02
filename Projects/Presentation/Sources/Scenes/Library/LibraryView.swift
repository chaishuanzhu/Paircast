import SwiftUI
import Domain

@MainActor
public final class LibraryViewModel: ObservableObject {
    @Published public var movies: [Movie] = []
    @Published public var isLoading = false
    @Published public var errorMessage: String?
    @Published public var showMe = false

    private let session: AppSession

    public init(session: AppSession) {
        self.session = session
    }

    public func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let harness = LibraryHarness(session: session)
            let listed = try await harness.listMovies(enrichMetadata: false)
            movies = listed
            errorMessage = nil

            guard !listed.isEmpty, !Task.isCancelled else { return }
            let enriched = await harness.enrich(listed)
            if !Task.isCancelled {
                movies = enriched
            }
        } catch is CancellationError {
            // Pull-to-refresh / task cancellation: keep current movies.
            return
        } catch let error as AppError {
            if movies.isEmpty {
                errorMessage = error.userMessage
            } else {
                session.showToast(error.userMessage)
            }
        } catch {
            if movies.isEmpty {
                errorMessage = AppError.catalogUnauthorized.userMessage
            } else {
                session.showToast(AppError.catalogUnauthorized.userMessage)
            }
        }
    }

    public func openMovie(_ movie: Movie) async {
        guard let user = session.currentUser else { return }
        do {
            let room = try await session.roomGateway.createRoom(movieId: movie.id, hostUserId: user.id)
            session.route = .watch(roomId: room.id, movieId: movie.id)
        } catch {
            session.showToast(AppError.unknown("建房失败").userMessage)
        }
    }
}

private struct LibraryHarness: ListMoviesUseCase {
    let session: AppSession
    var catalogGateway: MovieCatalogGateway { session.catalogGateway }
    var metadataGateway: MetadataGateway { session.metadataGateway }
    var configGateway: ConfigGateway { session.configGateway }

    func enrich(_ movies: [Movie]) async -> [Movie] {
        guard let config = try? await configGateway.load() else { return movies }
        return await withTaskGroup(of: (Int, Movie).self, returning: [Movie].self) { group in
            let concurrency = 4
            var index = 0
            var results = Array(repeating: Optional<Movie>.none, count: movies.count)

            func enqueue() {
                guard index < movies.count else { return }
                let i = index
                let movie = movies[i]
                index += 1
                group.addTask {
                    let enriched = await metadataGateway.enrich(movie, config: config)
                    return (i, enriched)
                }
            }

            for _ in 0..<min(concurrency, movies.count) {
                enqueue()
            }
            for await (i, movie) in group {
                results[i] = movie
                enqueue()
            }
            return results.enumerated().map { offset, value in value ?? movies[offset] }
        }
    }
}

public struct LibraryView: View {
    @ObservedObject var session: AppSession
    @StateObject private var viewModel: LibraryViewModel

    public init(session: AppSession) {
        self.session = session
        _viewModel = StateObject(wrappedValue: LibraryViewModel(session: session))
    }

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    public var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.movies.isEmpty {
                    ProgressView("加载片库…")
                } else if let error = viewModel.errorMessage, viewModel.movies.isEmpty {
                    ContentUnavailableView {
                        Label("片库不可用", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重试") { Task { await viewModel.load() } }
                        Button("去配置") { session.route = .config(fromLogin: false) }
                    }
                } else if viewModel.movies.isEmpty {
                    ContentUnavailableView("暂无影片", systemImage: "film", description: Text("确认七牛 Bucket 中有 mp4/m4v/mkv"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(viewModel.movies) { movie in
                                Button {
                                    Task { await viewModel.openMovie(movie) }
                                } label: {
                                    MovieCardView(movie: movie)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                    .refreshable { await viewModel.load() }
                }
            }
            .background(TandemColors.groupedBackground.ignoresSafeArea())
            .navigationTitle("Tandem")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.showMe = true
                    } label: {
                        Image(systemName: "person.crop.circle")
                            .accessibilityLabel("我的")
                    }
                }
            }
            .sheet(isPresented: $viewModel.showMe) {
                MeSheetView(session: session)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .task { await viewModel.load() }
        }
    }
}

private struct MovieCardView: View {
    let movie: Movie

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.gray.opacity(0.2))
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .overlay {
                        PosterImage(url: movie.posterURL)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(movie.format.rawValue.uppercased())
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(8)
            }
            Text(movie.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(movie.year ?? "未知")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let overview = movie.overview, !overview.isEmpty {
                Text(overview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}
