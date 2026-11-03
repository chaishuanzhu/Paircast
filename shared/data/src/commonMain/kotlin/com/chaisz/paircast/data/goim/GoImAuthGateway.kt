package com.chaisz.paircast.data.goim

import com.chaisz.paircast.core.gateway.AuthGateway
import com.chaisz.paircast.core.gateway.ConfigGateway
import com.chaisz.paircast.core.gateway.ConnectionState
import com.chaisz.paircast.core.gateway.SessionEvent
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.LoginResult
import com.chaisz.paircast.core.model.User
import com.chaisz.paircast.core.rules.ConfigValidation
import com.chaisz.paircast.data.secure.GoImSession
import com.chaisz.paircast.data.secure.SessionStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.time.Clock

/** Password login against GO-IM; persists `uid` + JWT in the secure store and owns the WS link. */
class GoImAuthGateway(
    private val configGateway: ConfigGateway,
    private val sessions: SessionStore,
    private val api: GoImApi,
    private val connectionLink: GoImConnection,
) : AuthGateway {
    private val _currentUser = MutableStateFlow<User?>(null)
    override val currentUser: StateFlow<User?> = _currentUser.asStateFlow()
    override val connection: StateFlow<ConnectionState> get() = connectionLink.state
    override val events: Flow<SessionEvent> get() = connectionLink.events

    private val profileLock = Mutex()
    private val profileCache = mutableMapOf<String, Pair<User, Long>>()

    /** Active session; null when signed out. */
    var session: GoImSession? = null
        private set

    init {
        // Kicked / expired: drop the stored token too, or the next launch would restore it and
        // kick the other device back.
        connectionLink.onSessionEnded = { ended ->
            if (sessions.load()?.token == ended.token) sessions.clear()
            if (session?.token == ended.token) {
                session = null
                _currentUser.value = null
            }
        }
    }

    override suspend fun login(account: String, password: String): LoginResult {
        val serverUrl = configuredServerUrl()
        val dto = try {
            api.login(serverUrl, account, password)
        } catch (e: GoImHttpException) {
            throw when (e.status) {
                400, 401 -> AppError.InvalidCredentials
                403 -> AppError.AccountUnavailable
                404 -> AppError.ServerUnreachable
                else -> serverError(e)
            }
        }
        return startSession(serverUrl, dto)
    }

    private suspend fun configuredServerUrl(): String {
        val config = configGateway.load() ?: throw AppError.NotConfigured
        return ConfigValidation.normalizedServerUrl(config.im.serverUrl)
            ?: throw AppError.IncompleteConfig(listOf("Server"))
    }

    private fun serverError(e: GoImHttpException) =
        AppError.Unknown("Server error {{code}}", mapOf("code" to e.status.toString()))

    private suspend fun startSession(serverUrl: String, dto: LoginResponseDto): LoginResult {
        val newSession = GoImSession(serverUrl = serverUrl, uid = dto.uid, token = dto.token)
        sessions.save(newSession)
        session = newSession
        val user = User(
            id = dto.uid,
            nickname = (dto.nickname ?: dto.username).orEmpty().ifEmpty { dto.uid },
            avatarUrl = GoImApi.absoluteUrl(serverUrl, dto.avatarUrl),
            username = dto.username,
            email = dto.email,
            isAdmin = dto.role == ADMIN_ROLE,
        )
        _currentUser.value = user
        // First login with an admin-issued password: link comes up after the forced change.
        if (!dto.mustChangePassword) connectionLink.connect(newSession)
        return LoginResult(user, dto.mustChangePassword)
    }

    override suspend fun restoreSession(): User? {
        val stored = sessions.load() ?: return null
        val configured = configGateway.load()?.im?.serverUrl?.let(ConfigValidation::normalizedServerUrl)
        if (configured != null && configured != stored.serverUrl) {
            // Server address changed in settings — the old token belongs to another gateway.
            sessions.clear()
            return null
        }
        if (api.validateToken(stored) == false) {
            sessions.clear()
            return null
        }
        session = stored
        val user = runCatching { api.myProfile(stored) }.getOrNull()
            ?.let { ownUser(stored, it) }
            ?: User(stored.uid, stored.uid)
        _currentUser.value = user
        connectionLink.connect(stored)
        return user
    }

    override suspend fun changePassword(oldPassword: String, newPassword: String) {
        val s = requireSession()
        try {
            api.changePassword(s, oldPassword, newPassword)
        } catch (e: GoImHttpException) {
            throw when (e.status) {
                401, 403 -> AppError.Validation("Current password is incorrect")
                else -> AppError.PasswordChangeFailed
            }
        }
        connectionLink.connect(s)
    }

    override suspend fun logout() {
        connectionLink.disconnect()
        sessions.clear()
        session = null
        _currentUser.value = null
        profileLock.withLock { profileCache.clear() }
    }

    override suspend fun updateProfile(nickname: String, avatarJpeg: ByteArray?): User {
        val s = requireSession()
        val fileId = avatarJpeg?.let {
            try {
                api.upload(s, it, "avatar.jpg", "image/jpeg")
            } catch (e: CancellationException) {
                throw e
            } catch (e: AppError) {
                throw e
            } catch (_: Exception) {
                throw AppError.AvatarUploadFailed
            }
        }
        val dto = authed { api.updateProfile(s, nickname, fileId) }
        val user = ownUser(s, dto, fallbackNickname = nickname)
        _currentUser.value = user
        remember(user)
        return user
    }

    override suspend fun fetchProfile(): User {
        val s = requireSession()
        val dto = authed { api.myProfile(s) }
        val user = ownUser(s, dto)
        _currentUser.value = user
        remember(user)
        return user
    }

    override suspend fun fetchUsers(userIds: List<String>): List<User> {
        val ids = userIds.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        if (ids.isEmpty()) return emptyList()
        val s = requireSession()
        val now = Clock.System.now().toEpochMilliseconds()
        val missing = profileLock.withLock { ids.filter { id -> profileCache[id]?.let { now - it.second > PROFILE_TTL_MS } ?: true } }
        if (missing.isNotEmpty()) {
            val fetched = authed { api.profiles(s, missing) }
            profileLock.withLock {
                fetched.forEach { dto ->
                    profileCache[dto.uid] = User(dto.uid, dto.nickname.ifEmpty { dto.uid }, GoImApi.absoluteUrl(s.serverUrl, dto.avatarUrl)) to now
                }
            }
        }
        return profileLock.withLock { ids.map { profileCache[it]?.first ?: User(it, it) } }
    }

    /** Cached nickname for chat rendering (falls back to the UID). */
    suspend fun nickname(uid: String): String =
        runCatching { fetchUsers(listOf(uid)).firstOrNull()?.nickname }.getOrNull() ?: uid

    override suspend fun deleteAccount(password: String) {
        val s = requireSession()
        try {
            api.deleteAccount(s, password)
        } catch (e: GoImHttpException) {
            throw when (e.status) {
                401 -> if (e.body.contains("invalid password")) {
                    AppError.Validation("Current password is incorrect")
                } else {
                    AppError.SessionExpired
                }
                403 -> AppError.AdminAccountDeletion
                404 -> AppError.SessionExpired
                else -> AppError.AccountDeletionFailed
            }
        }
        logout()
        configGateway.clearAll()
    }

    private suspend fun remember(user: User) {
        profileLock.withLock { profileCache[user.id] = user to Clock.System.now().toEpochMilliseconds() }
    }

    internal fun requireSession(): GoImSession = session ?: throw AppError.SessionExpired

    /** Own profile → [User]; a response without `role` keeps the admin flag we already had. */
    private fun ownUser(s: GoImSession, dto: ProfileDto, fallbackNickname: String = dto.uid) = User(
        id = dto.uid,
        nickname = dto.nickname.ifEmpty { fallbackNickname },
        avatarUrl = GoImApi.absoluteUrl(s.serverUrl, dto.avatarUrl),
        email = dto.email,
        isAdmin = dto.role?.let { it == ADMIN_ROLE } ?: (_currentUser.value?.isAdmin == true),
    )

    private suspend fun <T> authed(block: suspend () -> T): T = try {
        block()
    } catch (e: GoImHttpException) {
        if (e.status == 401) throw AppError.SessionExpired
        throw AppError.Unknown("Server error {{code}}", mapOf("code" to e.status.toString()))
    }

    internal companion object {
        private const val PROFILE_TTL_MS = 5 * 60_000L
        const val ADMIN_ROLE = "admin"
    }
}
