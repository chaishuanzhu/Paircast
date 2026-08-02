import Foundation

public protocol ListMoviesUseCase {
    var catalogGateway: MovieCatalogGateway { get }
    var metadataGateway: MetadataGateway { get }
    var configGateway: ConfigGateway { get }
}

public extension ListMoviesUseCase {
    func listMovies(enrichMetadata: Bool = true) async throws -> [Movie] {
        guard let config = try await configGateway.load() else {
            throw AppError.notConfigured
        }
        try ConfigValidation.validate(config)
        do {
            var movies = try await catalogGateway.listMovies(config: config)
            movies = movies.filter { MovieCatalogRules.isVideoObjectKey($0.objectKey) }
            guard enrichMetadata else { return movies }

            // Enrich concurrently with a modest limit; skip failures per item.
            return await withTaskGroup(of: Movie.self, returning: [Movie].self) { group in
                let concurrency = 4
                var iterator = movies.makeIterator()
                var results: [Movie] = []
                results.reserveCapacity(movies.count)

                func enqueueNext() {
                    guard let movie = iterator.next() else { return }
                    group.addTask {
                        await metadataGateway.enrich(movie, config: config)
                    }
                }

                for _ in 0..<min(concurrency, movies.count) {
                    enqueueNext()
                }
                for await enriched in group {
                    results.append(enriched)
                    enqueueNext()
                }
                // Preserve original order by objectKey.
                let byKey = Dictionary(uniqueKeysWithValues: results.map { ($0.objectKey, $0) })
                return movies.map { byKey[$0.objectKey] ?? $0 }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.catalogUnauthorized
        }
    }
}
