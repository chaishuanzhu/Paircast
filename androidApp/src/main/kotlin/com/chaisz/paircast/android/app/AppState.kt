package com.chaisz.paircast.android.app

import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.chaisz.paircast.PaircastGraph
import com.chaisz.paircast.core.gateway.SessionEvent
import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.AuthOptions
import com.chaisz.paircast.core.model.User
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.TimeSource

sealed interface AppRoute {
    data object Splash : AppRoute
    data object Login : AppRoute
    data object Register : AppRoute
    data class Config(val fromLogin: Boolean) : AppRoute
    data object Library : AppRoute
}

sealed interface LibraryRoute {
    data object Config : LibraryRoute
    data class Watch(val roomId: String?, val movieId: String?, val hostUserId: String?) : LibraryRoute
}

data class RoomInvite(val roomId: String, val movieId: String?, val hostUserId: String?) {
    companion object {
        /** `paircast://watch?roomId=…` or the public `https://paircast.chaisz.com/invite/?roomId=…` page. */
        fun parse(uri: Uri): RoomInvite? {
            val isApp = uri.scheme == "paircast" && uri.host == "watch"
            val isWeb = uri.scheme == "https" && uri.host == "paircast.chaisz.com" &&
                uri.path.orEmpty().startsWith("/invite")
            if (!isApp && !isWeb) return null
            val roomId = uri.getQueryParameter("roomId")?.takeIf { it.isNotEmpty() } ?: return null
            return RoomInvite(roomId, uri.getQueryParameter("movieId"), uri.getQueryParameter("hostUserId"))
        }
    }
}

/** App-wide navigation + session state (Android counterpart of the iOS `AppSession`). */
class AppState(val graph: PaircastGraph) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    var route by mutableStateOf<AppRoute>(AppRoute.Splash)
    val libraryStack = mutableStateListOf<LibraryRoute>()
    var config by mutableStateOf<AppCloudConfig?>(null)
    var currentUser by mutableStateOf<User?>(null)
    var toast by mutableStateOf<String?>(null)
    var mustChangePassword by mutableStateOf(false)
    var authOptions by mutableStateOf(AuthOptions.Unavailable)
        private set

    private var pendingInvite: RoomInvite? = null
    private var bootstrapped = false

    init {
        scope.launch {
            graph.authGateway.events.collect { event ->
                when (event) {
                    SessionEvent.KickedOffline -> forcedLogout(L10n.format(AppError.KickedOffline))
                    SessionEvent.TokenExpired -> forcedLogout(L10n.format(AppError.SessionExpired))
                }
            }
        }
    }

    fun bootstrap() {
        if (bootstrapped) return
        bootstrapped = true
        scope.launch {
            val started = TimeSource.Monotonic.markNow()
            config = runCatching { graph.configGateway.load() }.getOrNull()
            var next: AppRoute = AppRoute.Login
            var stack = emptyList<LibraryRoute>()
            if (config?.isComplete == true) {
                runCatching { graph.authGateway.restoreSession() }.getOrNull()?.let {
                    currentUser = it
                    next = AppRoute.Library
                }
            }
            if (currentUser != null) {
                pendingInvite?.let {
                    pendingInvite = null
                    next = AppRoute.Library
                    stack = listOf(LibraryRoute.Watch(it.roomId, it.movieId, it.hostUserId))
                }
            }
            val remaining = MINIMUM_SPLASH - started.elapsedNow()
            if (remaining.isPositive()) delay(remaining)
            if (route != AppRoute.Splash) return@launch
            route = next
            libraryStack.clear()
            libraryStack.addAll(stack)
            if (next == AppRoute.Login && pendingInvite != null) showToast(t("Sign in to join the room"))
        }
    }

    fun showToast(message: String) {
        toast = message
    }

    suspend fun login(account: String, password: String) {
        val result = graph.login(account, password)
        currentUser = result.user
        if (result.mustChangePassword) {
            mustChangePassword = true
        } else {
            finishLogin()
        }
    }

    /** Re-reads the server's sign-up switch (login screen shows "Create Account" only when open). */
    suspend fun refreshAuthOptions() {
        authOptions = graph.authOptions()
    }

    fun openRegister() {
        route = AppRoute.Register
    }

    /** Returns the cooldown in seconds before another code can be requested. */
    suspend fun sendRegisterCode(email: String): Int = graph.sendRegisterCode(email)

    suspend fun register(email: String, code: String, password: String, confirm: String, nickname: String) {
        val result = graph.register(email, code, password, confirm, nickname)
        currentUser = result.user
        finishLogin()
    }

    /** Deletes the account on the server, then wipes local config / caches and returns to login. */
    suspend fun deleteAccount(password: String) {
        val uid = currentUser?.id
        graph.deleteAccount(password)
        uid?.let { graph.chatSafety.clear(it) }
        graph.clearLocalCaches()
        config = null
        logout()
    }

    suspend fun changePassword(old: String, new: String, confirm: String) {
        graph.changePassword(old, new, confirm)
        if (mustChangePassword) {
            mustChangePassword = false
            finishLogin()
        } else {
            showToast(t("Password updated"))
        }
    }

    fun cancelForcedPasswordChange() {
        mustChangePassword = false
        scope.launch { logout() }
    }

    suspend fun logout() {
        runCatching { graph.authGateway.logout() }
        currentUser = null
        pendingInvite = null
        resetToLogin()
    }

    private fun finishLogin() {
        route = AppRoute.Library
        libraryStack.clear()
        consumePendingInvite()
    }

    fun handleDeepLink(uri: Uri) {
        val invite = RoomInvite.parse(uri) ?: return
        if (currentUser == null) {
            pendingInvite = invite
            if (route != AppRoute.Splash) {
                resetToLogin()
                showToast(t("Sign in to join the room"))
            }
        } else {
            pendingInvite = null
            openWatch(invite.roomId, invite.movieId, invite.hostUserId)
        }
    }

    private fun consumePendingInvite() {
        val invite = pendingInvite ?: return
        if (currentUser == null) return
        pendingInvite = null
        openWatch(invite.roomId, invite.movieId, invite.hostUserId)
    }

    fun openWatch(roomId: String?, movieId: String?, hostUserId: String?) {
        route = AppRoute.Library
        libraryStack.clear()
        libraryStack.add(LibraryRoute.Watch(roomId, movieId, hostUserId))
    }

    fun openConfig(fromLogin: Boolean) {
        if (fromLogin) {
            libraryStack.clear()
            route = AppRoute.Config(fromLogin = true)
        } else {
            route = AppRoute.Library
            libraryStack.clear()
            libraryStack.add(LibraryRoute.Config)
        }
    }

    fun popLibrary() {
        if (libraryStack.isNotEmpty()) libraryStack.removeAt(libraryStack.lastIndex)
    }

    fun popLibraryToRoot() = libraryStack.clear()

    fun resetToLogin() {
        libraryStack.clear()
        route = AppRoute.Login
    }

    /** After the server address changes: keep the new config, drop the session, back to login. */
    suspend fun applyServerChange(newConfig: AppCloudConfig) {
        config = newConfig
        if (currentUser != null) {
            runCatching { graph.authGateway.logout() }
            currentUser = null
        }
        pendingInvite = null
        runCatching { graph.clearMetadataCache() }
        resetToLogin()
        showToast(t("Server changed. Please sign in again"))
    }

    private fun forcedLogout(message: String) {
        if (currentUser == null) return
        currentUser = null
        mustChangePassword = false
        pendingInvite = null
        resetToLogin()
        showToast(message)
    }

    companion object {
        private val MINIMUM_SPLASH = 1_200.milliseconds
    }
}
