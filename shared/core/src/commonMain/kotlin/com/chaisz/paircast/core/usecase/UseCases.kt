package com.chaisz.paircast.core.usecase

import com.chaisz.paircast.core.gateway.AccountAdminGateway
import com.chaisz.paircast.core.gateway.AuthGateway
import com.chaisz.paircast.core.gateway.ChatGateway
import com.chaisz.paircast.core.gateway.ConfigGateway
import com.chaisz.paircast.core.gateway.MetadataGateway
import com.chaisz.paircast.core.gateway.ModerationGateway
import com.chaisz.paircast.core.gateway.MovieCatalogGateway
import com.chaisz.paircast.core.gateway.PlaybackSyncGateway
import com.chaisz.paircast.core.gateway.RoomGateway
import com.chaisz.paircast.core.gateway.SubtitleGateway
import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.ChatMessage
import com.chaisz.paircast.core.model.CreatedAccount
import com.chaisz.paircast.core.model.LoginResult
import com.chaisz.paircast.core.model.ManagedUser
import com.chaisz.paircast.core.model.MediaSource
import com.chaisz.paircast.core.model.Movie
import com.chaisz.paircast.core.model.PlaybackAction
import com.chaisz.paircast.core.model.PlaybackSyncSignal
import com.chaisz.paircast.core.model.ReportAction
import com.chaisz.paircast.core.model.ReportFilter
import com.chaisz.paircast.core.model.ReportPage
import com.chaisz.paircast.core.model.SubtitleTrack
import com.chaisz.paircast.core.model.User
import com.chaisz.paircast.core.model.UserPage
import com.chaisz.paircast.core.model.UserReport
import com.chaisz.paircast.core.model.WatchRoom
import com.chaisz.paircast.core.rules.AccountRules
import com.chaisz.paircast.core.rules.ConfigValidation
import com.chaisz.paircast.core.rules.HostTransferRules
import com.chaisz.paircast.core.rules.LegalRules
import com.chaisz.paircast.core.rules.LoginRules
import com.chaisz.paircast.core.rules.ProfileRules
import com.chaisz.paircast.core.store.ChatSafetyStore
import kotlin.time.Clock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope

// region Auth

class LoginUseCase(private val configGateway: ConfigGateway, private val authGateway: AuthGateway) {
    @Throws(Exception::class)
    suspend operator fun invoke(account: String, password: String, agreedToTerms: Boolean): LoginResult {
        LegalRules.requireAgreement(agreedToTerms)
        LoginRules.validateAccount(account)
        LoginRules.validatePassword(password)
        val config = configGateway.load() ?: throw AppError.NotConfigured
        if (!config.im.isComplete) throw AppError.IncompleteConfig(listOf("Server"))
        return try {
            authGateway.login(account.trim(), password)
        } catch (e: CancellationException) {
            throw e
        } catch (e: AppError) {
            throw e
        } catch (_: Exception) {
            throw AppError.Network
        }
    }
}

/** Admin "Add User": accounts exist only when an admin creates them (no self sign-up). */
class CreateUserUseCase(private val authGateway: AuthGateway, private val accounts: AccountAdminGateway) {
    @Throws(Exception::class)
    suspend operator fun invoke(email: String, nickname: String): CreatedAccount {
        if (authGateway.currentUser.value?.isAdmin != true) throw AppError.AdminRequired
        val normalized = AccountRules.normalizedEmail(email)
        val name = AccountRules.normalizedNickname(nickname)
        return mapNetwork { accounts.createUser(normalized, name) }
    }
}

/** Admin console user list, newest first. */
class LoadUsersUseCase(private val authGateway: AuthGateway, private val accounts: AccountAdminGateway) {
    @Throws(Exception::class)
    suspend operator fun invoke(offset: Int = 0, limit: Int = PAGE_SIZE): UserPage {
        if (authGateway.currentUser.value?.isAdmin != true) throw AppError.AdminRequired
        return mapNetwork { accounts.users(offset, limit) }
    }

    companion object {
        const val PAGE_SIZE = 50
    }
}

/** Disable (sign out + block sign-in) or re-enable a regular user. */
class SetUserDisabledUseCase(private val authGateway: AuthGateway, private val accounts: AccountAdminGateway) {
    @Throws(Exception::class)
    suspend operator fun invoke(user: ManagedUser, disabled: Boolean) {
        requireManageable(authGateway, user)
        mapNetwork { accounts.setDisabled(user.id, disabled) }
    }
}

/** Permanently delete a regular user. */
class DeleteUserUseCase(private val authGateway: AuthGateway, private val accounts: AccountAdminGateway) {
    @Throws(Exception::class)
    suspend operator fun invoke(user: ManagedUser) {
        requireManageable(authGateway, user)
        mapNetwork { accounts.deleteUser(user.id) }
    }
}

private fun requireManageable(authGateway: AuthGateway, user: ManagedUser) {
    val me = authGateway.currentUser.value
    if (me?.isAdmin != true) throw AppError.AdminRequired
    if (!AccountRules.canManage(user, me.id)) throw AppError.CannotManageAccount
}

class DeleteAccountUseCase(private val authGateway: AuthGateway) {
    @Throws(Exception::class)
    suspend operator fun invoke(password: String) {
        LoginRules.validatePassword(password)
        mapNetwork { authGateway.deleteAccount(password) }
    }
}

private suspend fun <T> mapNetwork(block: suspend () -> T): T = try {
    block()
} catch (e: CancellationException) {
    throw e
} catch (e: AppError) {
    throw e
} catch (_: Exception) {
    throw AppError.Network
}

class ChangePasswordUseCase(private val authGateway: AuthGateway) {
    @Throws(Exception::class)
    suspend operator fun invoke(oldPassword: String, newPassword: String, confirm: String) {
        LoginRules.validatePassword(oldPassword)
        LoginRules.validateNewPassword(oldPassword, newPassword, confirm)
        authGateway.changePassword(oldPassword, newPassword)
    }
}

class UpdateProfileUseCase(private val authGateway: AuthGateway) {
    @Throws(Exception::class)
    suspend operator fun invoke(nickname: String, avatarJpeg: ByteArray?): User {
        val name = ProfileRules.validatedNickname(nickname)
        avatarJpeg?.let(ProfileRules::validatedAvatarData)
        return authGateway.updateProfile(name, avatarJpeg)
    }
}

// endregion

// region Moderation

/**
 * Brings the local block list in line with the server: uploads blocks that never reached it
 * (offline, or made before blocks were stored server-side), then adopts the server list.
 */
class SyncBlockListUseCase(private val moderation: ModerationGateway, private val chatSafety: ChatSafetyStore) {
    @Throws(Exception::class)
    suspend operator fun invoke(ownerId: String): Set<String> {
        val stillPending = chatSafety.pendingUploads(ownerId).filterTo(mutableSetOf()) { id ->
            !uploaded { moderation.block(id) }
        }
        val remote = mapNetwork { moderation.blockedUserIds() }.toSet()
        chatSafety.applyServerList(ownerId, remote, stillPending)
        return chatSafety.blockedUserIds(ownerId)
    }
}

/** Hides the sender locally right away; the server copy is retried by [SyncBlockListUseCase] if this upload fails. */
class BlockUserUseCase(private val moderation: ModerationGateway, private val chatSafety: ChatSafetyStore) {
    @Throws(Exception::class)
    suspend operator fun invoke(userId: String, ownerId: String) {
        if (!chatSafety.block(userId, ownerId)) return
        if (uploaded { moderation.block(userId) }) chatSafety.markUploaded(userId, ownerId)
    }
}

class ReportMessageUseCase(private val moderation: ModerationGateway) {
    @Throws(Exception::class)
    suspend operator fun invoke(message: ChatMessage) {
        val target = message.senderId?.takeIf { it.isNotBlank() } ?: throw AppError.Validation("This message can't be reported")
        val content = message.text.ifBlank { if (message.sticker != null) "[Sticker]" else "" }.take(REPORT_CONTENT_MAX)
        mapNetwork { moderation.report(target, content, message.id, message.roomId.ifBlank { null }) }
    }

    private companion object {
        const val REPORT_CONTENT_MAX = 500
    }
}

class LoadReportsUseCase(private val authGateway: AuthGateway, private val moderation: ModerationGateway) {
    @Throws(Exception::class)
    suspend operator fun invoke(filter: ReportFilter, offset: Int = 0, limit: Int = PAGE_SIZE): ReportPage {
        if (authGateway.currentUser.value?.isAdmin != true) throw AppError.AdminRequired
        return mapNetwork { moderation.reports(filter, offset, limit) }
    }

    companion object {
        const val PAGE_SIZE = 30
    }
}

class ResolveReportUseCase(private val authGateway: AuthGateway, private val moderation: ModerationGateway) {
    @Throws(Exception::class)
    suspend operator fun invoke(report: UserReport, action: ReportAction) {
        if (authGateway.currentUser.value?.isAdmin != true) throw AppError.AdminRequired
        if (action == ReportAction.BAN && report.targetId == authGateway.currentUser.value?.id) {
            throw AppError.Validation("You can't ban yourself")
        }
        mapNetwork { moderation.resolveReport(report.id, action) }
    }
}

private suspend fun uploaded(block: suspend () -> Unit): Boolean = try {
    block()
    true
} catch (e: CancellationException) {
    throw e
} catch (_: Exception) {
    false
}

// endregion

// region Config

class SaveCloudConfigUseCase(private val configGateway: ConfigGateway) {
    @Throws(Exception::class)
    suspend operator fun invoke(config: AppCloudConfig): AppCloudConfig {
        val stored = ConfigValidation.normalized(config).copy(
            updatedAtMs = Clock.System.now().toEpochMilliseconds(),
            configVersion = AppCloudConfig.CURRENT_VERSION,
        )
        configGateway.save(stored)
        return stored
    }
}

// endregion

// region Movies

class ListMoviesUseCase(
    private val configGateway: ConfigGateway,
    private val catalogGateway: MovieCatalogGateway,
    private val metadataGateway: MetadataGateway,
) {
    /** Movies of [sourceId] (server default when null). Only items without a poster are enriched. */
    @Throws(Exception::class)
    suspend operator fun invoke(enrichMetadata: Boolean = true, sourceId: String? = null): List<Movie> {
        val config = configGateway.load() ?: throw AppError.NotConfigured
        ConfigValidation.validate(config)
        return try {
            val movies = catalogGateway.listMovies(config, sourceId)
            if (enrichMetadata) enrich(movies, config) else movies
        } catch (e: CancellationException) {
            throw e
        } catch (e: AppError) {
            throw e
        } catch (_: Exception) {
            throw AppError.CatalogUnauthorized
        }
    }

    /** Server media sources; the library shows a picker only when there is more than one. */
    @Throws(Exception::class)
    suspend fun sources(): List<MediaSource> {
        val config = configGateway.load() ?: throw AppError.NotConfigured
        return catalogGateway.listSources(config)
    }

    /** Enriches in bounded batches of [CONCURRENCY]. */
    @Throws(Exception::class)
    suspend fun enrich(movies: List<Movie>, config: AppCloudConfig): List<Movie> = coroutineScope {
        movies.chunked(CONCURRENCY).flatMap { batch ->
            batch.map { movie ->
                async { if (movie.posterUrl != null) movie else metadataGateway.enrich(movie, config) }
            }.awaitAll()
        }
    }

    companion object {
        const val CONCURRENCY = 4
    }
}

// endregion

// region Room

class LeaveRoomUseCase(
    private val roomGateway: RoomGateway,
    private val chatGateway: ChatGateway,
    private val syncGateway: PlaybackSyncGateway,
) {
    @Throws(Exception::class)
    suspend operator fun invoke(
        room: WatchRoom,
        leavingUserId: String,
        positionMs: Long,
        nextTransferSeq: Long,
    ): HostTransferRules.Outcome {
        val outcome = HostTransferRules.resolveLeave(room, leavingUserId, nextTransferSeq)
        when (outcome) {
            HostTransferRules.Outcome.Unchanged -> Unit
            is HostTransferRules.Outcome.MemberLeft, is HostTransferRules.Outcome.EndRoom ->
                roomGateway.leaveRoom(room, leavingUserId, nextTransferSeq)
            is HostTransferRules.Outcome.Transfer -> {
                // The server applies the same join-order transfer on leave. Signal + system message
                // must go out while we are still a group member.
                syncGateway.send(
                    outcome.room,
                    PlaybackSyncSignal(
                        action = PlaybackAction.HOST_TRANSFER,
                        positionMs = positionMs,
                        movieId = outcome.room.movieId,
                        hostUserId = outcome.newHostUserId,
                        senderId = leavingUserId,
                        clientTs = Clock.System.now().toEpochMilliseconds(),
                        seq = nextTransferSeq,
                    ),
                )
                chatGateway.postSystemMessage(outcome.room, "Host transferred to ${outcome.newHostUserId}")
                roomGateway.leaveRoom(room, leavingUserId, nextTransferSeq)
            }
        }
        return outcome
    }
}

class ChangeMovieUseCase(
    private val roomGateway: RoomGateway,
    private val syncGateway: PlaybackSyncGateway,
    private val chatGateway: ChatGateway,
) {
    data class Result(val room: WatchRoom, val signal: PlaybackSyncSignal)

    @Throws(Exception::class)
    suspend operator fun invoke(room: WatchRoom, actorUserId: String, newMovie: Movie, seq: Long): Result {
        if (actorUserId != room.hostUserId) throw AppError.OnlyHostCanSwitchMovie
        if (newMovie.id == room.movieId) throw AppError.Validation("Already playing")
        val updated = room.copy(movieId = newMovie.id)
        roomGateway.updateRoom(updated)
        val signal = PlaybackSyncSignal(
            action = PlaybackAction.MOVIE_CHANGE,
            positionMs = 0,
            movieId = newMovie.id,
            hostUserId = room.hostUserId,
            senderId = actorUserId,
            clientTs = Clock.System.now().toEpochMilliseconds(),
            seq = seq,
        )
        syncGateway.send(updated, signal)
        chatGateway.postSystemMessage(updated, "Host switched the movie to “${newMovie.title}”")
        return Result(updated, signal)
    }
}

object InviteLinks {
    const val INVITE_BASE = "https://paircast.chaisz.com/invite/"

    fun inviteUrl(roomId: String, movieId: String, hostUserId: String, inviterName: String, movieTitle: String): String =
        INVITE_BASE + "?" + listOf(
            "roomId" to roomId,
            "movieId" to movieId,
            "hostUserId" to hostUserId,
            "inviter" to inviterName,
            "title" to movieTitle,
        ).joinToString("&") { (k, v) -> "$k=${percentEncode(v)}" }

    /** RFC 3986 unreserved set; everything else percent-encoded as UTF-8. */
    fun percentEncode(value: String): String = buildString {
        for (b in value.encodeToByteArray()) {
            val c = b.toInt() and 0xFF
            val ch = c.toChar()
            if (ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9' || ch == '-' || ch == '_' || ch == '.' || ch == '~') {
                append(ch)
            } else {
                append('%')
                append(HEX[c shr 4])
                append(HEX[c and 0xF])
            }
        }
    }

    private const val HEX = "0123456789ABCDEF"
}

// endregion

// region Sync

class EmitHostPlaybackUseCase(private val syncGateway: PlaybackSyncGateway) {
    @Throws(Exception::class)
    suspend operator fun invoke(
        room: WatchRoom,
        hostUserId: String,
        action: PlaybackAction,
        positionMs: Long,
        seq: Long,
        movieId: String? = null,
        subtitleObjectKey: String? = null,
        subtitleLabel: String? = null,
    ): PlaybackSyncSignal {
        if (hostUserId != room.hostUserId) throw AppError.OnlyHostCanSwitchMovie
        val signal = PlaybackSyncSignal(
            action = action,
            positionMs = positionMs,
            movieId = movieId ?: room.movieId,
            hostUserId = hostUserId,
            senderId = hostUserId,
            clientTs = Clock.System.now().toEpochMilliseconds(),
            seq = seq,
            subtitleObjectKey = subtitleObjectKey,
            subtitleLabel = subtitleLabel,
        )
        syncGateway.send(room, signal)
        return signal
    }
}

// endregion

// region Subtitles

class SearchOnlineSubtitlesUseCase(private val subtitleGateway: SubtitleGateway) {
    @Throws(Exception::class)
    suspend operator fun invoke(query: String, year: String?): List<SubtitleTrack> =
        subtitleGateway.searchOnline(query, year)
}

class ListSubtitleTracksUseCase(
    private val configGateway: ConfigGateway,
    private val subtitleGateway: SubtitleGateway,
) {
    /** `Off` + library sidecars. Embedded tracks come from the player and are merged by the session. */
    @Throws(Exception::class)
    suspend operator fun invoke(movie: Movie): List<SubtitleTrack> {
        val config = configGateway.load()
        return buildList {
            add(SubtitleTrack.OFF)
            if (config != null) addAll(subtitleGateway.listSidecars(movie, config))
        }
    }
}

// endregion
