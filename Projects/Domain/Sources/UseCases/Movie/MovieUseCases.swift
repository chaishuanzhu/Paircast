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
            var enriched: [Movie] = []
            for movie in movies {
                enriched.append(await metadataGateway.enrich(movie, config: config))
            }
            return enriched
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.catalogUnauthorized
        }
    }
}
