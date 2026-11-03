package com.chaisz.paircast.core.model

import com.chaisz.paircast.core.rules.StringTemplate

/**
 * User-facing error. [localizationKey] is the English template used as the catalog key on both
 * platforms (iOS `Localizable.xcstrings`, Android `strings` lookup), so keys must stay stable.
 */
sealed class AppError(key: String) : Exception(key) {
    data object NotConfigured : AppError("Please finish service configuration first")
    data class IncompleteConfig(val missing: List<String>) : AppError("Incomplete configuration: {{fields}}")
    data object InvalidCredentials : AppError("Incorrect account or password")
    data object AccountUnavailable : AppError("Account not found or not provisioned. Contact an admin")
    data object ServerUnreachable : AppError("Cannot reach the server. Check the server address")
    data object Network : AppError("Network error. Please try again")
    data object SessionExpired : AppError("Session expired. Please sign in again")
    data object KickedOffline : AppError("Signed in on another device")
    data object CatalogUnauthorized : AppError("Library configuration is invalid")
    data object MediaLibraryUnavailable : AppError("The server has no media library configured. Contact an admin")
    data object OnlineSubtitlesUnavailable : AppError("Online subtitle search is not enabled on the server")
    data object PlaybackFailed : AppError("Unable to play. Please try again later")
    data object UnsupportedContainer : AppError("This container or codec is not supported on this device")
    data object MovieChangeFailed : AppError("Failed to switch movie")
    data object OnlyHostCanSwitchMovie : AppError("Only the host can switch movies")
    data object RoomEnded : AppError("This room has ended")
    data object RoomNotFound : AppError("Room not found or invite expired")
    data object SubtitleUnavailable : AppError("No subtitles available")
    data object SubtitleShareFailed : AppError("Failed to sync subtitles to members")
    data object AvatarUploadFailed : AppError("Avatar upload failed. Please try again")
    data object PasswordChangeFailed : AppError("Failed to change password")
    data object RegistrationClosed : AppError("Registration is closed on this server. Contact an admin for an account")
    data object EmailVerificationUnavailable : AppError("Email verification is not configured on the server")
    data object EmailAlreadyRegistered : AppError("This email is already registered")
    data object InvalidVerificationCode : AppError("Invalid or expired verification code")
    data class TooManyCodeRequests(val retryAfterSeconds: Int?) : AppError("Too many code requests. Please try again later")
    data object EmailSendFailed : AppError("Failed to send the email. Please try again later")
    data object AdminAccountDeletion : AppError("Admin accounts cannot be deleted in the app")
    data object AccountDeletionFailed : AppError("Failed to delete account")
    data object ModerationUnavailable : AppError("The server does not support reports yet. Ask an admin to update it")
    data object AdminRequired : AppError("Only admins can do this")
    data object CannotBanAdmin : AppError("Admin accounts cannot be banned")
    data object ReportNotFound : AppError("This report no longer exists")

    /** Localization template key (may contain `{{name}}`) plus replacement values. */
    data class Validation(val key: String, val args: Map<String, String> = emptyMap()) : AppError(key)
    data class Unknown(val key: String, val args: Map<String, String> = emptyMap()) : AppError(key)

    /** Catalog key / English template (placeholders not yet replaced). */
    val localizationKey: String
        get() = when (this) {
            is Validation -> key
            is Unknown -> key
            else -> super.message ?: ""
        }

    val localizationArguments: Map<String, String>
        get() = when (this) {
            is IncompleteConfig -> mapOf("fields" to missing.joinToString(", "))
            is Validation -> args
            is Unknown -> args
            else -> emptyMap()
        }

    /** English message with placeholders already replaced (logs / tests / fallback). */
    val userMessage: String
        get() = StringTemplate.apply(localizationKey, localizationArguments)

    fun toUiText(): UiText = UiText(localizationKey, localizationArguments)

    companion object {
        /** Maps any throwable to an [AppError], defaulting to [fallback]. */
        fun from(error: Throwable, fallback: AppError = Network): AppError =
            error as? AppError ?: fallback
    }
}

/** Localizable text: catalog key (English template) + named `{{placeholders}}`. */
data class UiText(val key: String, val args: Map<String, String> = emptyMap()) {
    val english: String get() = StringTemplate.apply(key, args)
}
