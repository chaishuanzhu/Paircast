import Foundation

public enum AppError: Error, Equatable, Sendable {
    case notConfigured
    case incompleteConfig(missing: [String])
    case invalidCredentials
    case accountUnavailable
    case imInitFailed
    case network
    case userSigExpired
    case kickedOffline
    case invalidConfigQR
    case configQRTooLarge
    case catalogUnauthorized
    case playbackFailed
    case unsupportedContainer
    case movieChangeFailed
    case onlyHostCanSwitchMovie
    case roomEnded
    case roomNotFound
    case subtitleUnavailable
    case subtitleShareFailed
    case avatarUploadFailed
    /// Localization template key (may contain `{{name}}`) plus replacement values.
    case validation(String, args: [String: String] = [:])
    case unknown(String, args: [String: String] = [:])

    /// Catalog key / English template (placeholders not yet replaced).
    public var localizationKey: String {
        switch self {
        case .notConfigured:
            return "Please finish service configuration first"
        case .incompleteConfig:
            return "Incomplete configuration: {{fields}}"
        case .invalidCredentials:
            return "Invalid user ID or login failed"
        case .accountUnavailable:
            return "Account not found or not provisioned. Contact an admin"
        case .imInitFailed:
            return "Invalid IM configuration. Check SDKAppID and related settings"
        case .network:
            return "Network error. Please try again"
        case .userSigExpired:
            return "Session expired. Please sign in again"
        case .kickedOffline:
            return "Signed in on another device"
        case .invalidConfigQR:
            return "Invalid configuration link. Existing settings were not changed"
        case .configQRTooLarge:
            return "Configuration is too large to share or import"
        case .catalogUnauthorized:
            return "Library configuration is invalid"
        case .playbackFailed:
            return "Unable to play. Please try again later"
        case .unsupportedContainer:
            return "This container or codec is not supported on this device"
        case .movieChangeFailed:
            return "Failed to switch movie"
        case .onlyHostCanSwitchMovie:
            return "Only the host can switch movies"
        case .roomEnded:
            return "This room has ended"
        case .roomNotFound:
            return "Room not found or invite expired"
        case .subtitleUnavailable:
            return "No subtitles available"
        case .subtitleShareFailed:
            return "Failed to sync subtitles to members"
        case .avatarUploadFailed:
            return "Avatar upload failed. Please try again"
        case .validation(let key, _):
            return key
        case .unknown(let key, _):
            return key
        }
    }

    public var localizationArguments: [String: String] {
        switch self {
        case .incompleteConfig(let missing):
            return ["fields": missing.joined(separator: ", ")]
        case .validation(_, let args), .unknown(_, let args):
            return args
        default:
            return [:]
        }
    }

    /// English message with placeholders already replaced (logs / tests / fallback).
    public var userMessage: String {
        StringTemplate.apply(localizationKey, localizationArguments)
    }
}
