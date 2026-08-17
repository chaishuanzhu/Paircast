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

            // Enrich in bounded batches. Snapshot the Sendable gateway so child
            // tasks never capture the use-case conformer (`Self`).
            let gateway = metadataGateway
            var results = Array<Movie?>(repeating: nil, count: movies.count)
            let concurrency = 4
            for lowerBound in stride(from: 0, to: movies.count, by: concurrency) {
                let upperBound = min(lowerBound + concurrency, movies.count)
                await withTaskGroup(of: (Int, Movie).self) { group in
                    for index in lowerBound..<upperBound {
                        let movie = movies[index]
                        group.addTask {
                            (index, await gateway.enrich(movie, config: config))
                        }
                    }
                    for await (index, enriched) in group {
                        results[index] = enriched
                    }
                }
            }
            return results.enumerated().map { index, movie in movie ?? movies[index] }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.catalogUnauthorized
        }
    }
}
