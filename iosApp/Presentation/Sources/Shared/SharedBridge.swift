import Foundation
import os
import PaircastShared

/// Shared app loggers. Prefer these over `print` so Console.app can filter by category.
public enum PaircastLog {
    public static let app = Logger(subsystem: "com.chaisz.tandem", category: "app")
    public static let catalog = Logger(subsystem: "com.chaisz.tandem", category: "catalog")
    public static let playback = Logger(subsystem: "com.chaisz.tandem", category: "playback")

    /// Routes Kotlin shared-module logs into os_log.
    public static func installSharedSink() {
        let shared = Logger(subsystem: "com.chaisz.tandem", category: "shared")
        IosInterop.shared.installLogSink { level, tag, message in
            switch level {
            case "error": shared.error("[\(tag, privacy: .public)] \(message, privacy: .public)")
            case "debug": shared.debug("[\(tag, privacy: .public)] \(message, privacy: .public)")
            default: shared.info("[\(tag, privacy: .public)] \(message, privacy: .public)")
            }
        }
    }

    /// Host + path only; signing / token query values are dropped.
    public static func redactedURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<invalid-url>"
        }
        components.query = nil
        return components.string ?? "<invalid-url>"
    }
}

/// Kotlin exceptions arrive as `NSError` with the original throwable in `userInfo["KotlinException"]`.
public enum AppErrors {
    public static func from(_ error: Error) -> AppError? {
        if let appError = error as? AppError { return appError }
        return (error as NSError).userInfo["KotlinException"] as? AppError
    }

    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as NSError).userInfo["KotlinException"] is KotlinCancellationException
    }
}

public extension AppError {
    static var notConfigured: AppError { AppError.NotConfigured.shared }
    static var network: AppError { AppError.Network.shared }
    static var playbackFailed: AppError { AppError.PlaybackFailed.shared }
    static var catalogUnauthorized: AppError { AppError.CatalogUnauthorized.shared }
    static var onlyHostCanSwitchMovie: AppError { AppError.OnlyHostCanSwitchMovie.shared }
    static var kickedOffline: AppError { AppError.KickedOffline.shared }
    static var sessionExpired: AppError { AppError.SessionExpired.shared }
    static var avatarUploadFailed: AppError { AppError.AvatarUploadFailed.shared }
    static var passwordChangeFailed: AppError { AppError.PasswordChangeFailed.shared }
    static var subtitleUnavailable: AppError { AppError.SubtitleUnavailable.shared }
    static var accountDeletionFailed: AppError { AppError.AccountDeletionFailed.shared }

    static func validation(_ key: String, _ args: [String: String] = [:]) -> AppError {
        AppError.Validation(key: key, args: args)
    }

    static func unknown(_ key: String, _ args: [String: String] = [:]) -> AppError {
        AppError.Unknown(key: key, args: args)
    }
}

public extension Data {
    var kotlinBytes: KotlinByteArray { IosInterop.shared.toByteArray(data: self) }
}

public extension KotlinByteArray {
    var data: Data { IosInterop.shared.toData(bytes: self) }
}

private func url(_ string: String?) -> URL? {
    guard let string, !string.isEmpty else { return nil }
    return URL(string: string)
}

public extension User {
    var avatarURL: URL? { url(avatarUrl) }
}

public extension Movie {
    var posterURL: URL? { url(posterUrl) }
    var backdropURL: URL? { url(backdropUrl) }
}

extension Movie: @retroactive Identifiable { public typealias ID = String }
extension ChatMessage: @retroactive Identifiable { public typealias ID = String }
extension SubtitleTrack: @retroactive Identifiable { public typealias ID = String }
extension StickerItem: @retroactive Identifiable { public typealias ID = String }
extension StickerPack: @retroactive Identifiable { public typealias ID = String }
extension StickerPackSummary: @retroactive Identifiable { public typealias ID = String }
