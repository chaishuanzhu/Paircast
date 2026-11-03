package com.chaisz.paircast.data

import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.IMConfig
import com.chaisz.paircast.data.goim.GoImAccountAdminGateway
import com.chaisz.paircast.data.goim.GoImApi
import com.chaisz.paircast.data.goim.GoImAuthGateway
import com.chaisz.paircast.data.goim.GoImConnection
import com.chaisz.paircast.data.goim.GoImModerationGateway
import com.chaisz.paircast.core.model.ReportAction
import com.chaisz.paircast.core.model.ReportFilter
import com.chaisz.paircast.core.model.ReportStatus
import com.chaisz.paircast.data.net.createHttpClient
import com.chaisz.paircast.data.secure.GoImSession
import com.chaisz.paircast.core.store.InMemorySecureStore
import com.chaisz.paircast.data.secure.SecureConfigStore
import com.chaisz.paircast.data.secure.SessionStore
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.MockRequestHandleScope
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.client.request.HttpResponseData
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.headersOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class GoImAuthTest {
    private val json = headersOf(HttpHeaders.ContentType, "application/json")

    private class Harness(
        val auth: GoImAuthGateway,
        val sessions: SessionStore,
        val requests: MutableList<HttpRequestData>,
        val scope: CoroutineScope,
        val api: GoImApi,
    )

    private suspend fun harness(handler: suspend MockRequestHandleScope.(HttpRequestData) -> HttpResponseData): Harness {
        val requests = mutableListOf<HttpRequestData>()
        val client = createHttpClient(MockEngine { req -> requests += req; handler(req) })
        val store = InMemorySecureStore()
        val config = SecureConfigStore(store)
        config.save(
            AppCloudConfig(im = IMConfig("im.example.com")),
        )
        val api = GoImApi(client)
        val scope = CoroutineScope(SupervisorJob())
        val connection = GoImConnection(client, api, scope, deviceId = "dev", platform = "test")
        val sessions = SessionStore(store)
        return Harness(GoImAuthGateway(config, sessions, api, connection), sessions, requests, scope, api)
    }

    private fun formBody(req: HttpRequestData): String =
        (req.body as? OutgoingContent.ByteArrayContent)?.bytes()?.decodeToString().orEmpty()

    @Test
    fun loginMapsWrongPasswordTo401() = runTest {
        val h = harness { respond("invalid credentials", HttpStatusCode.Unauthorized) }
        assertFailsWith<AppError.InvalidCredentials> { h.auth.login("alice", "bad") }
        assertNull(h.sessions.load())
        h.scope.cancel()
    }

    @Test
    fun expiredSessionIsClearedFromStorage() = runTest {
        val h = harness { req ->
            when {
                req.url.encodedPath.endsWith("/account/login") -> respond("""{"uid":"u1","token":"pc","im":{"token":"jwt"}}""", HttpStatusCode.OK, json)
                else -> respond("invalid token", HttpStatusCode.Unauthorized)
            }
        }
        h.auth.login("alice", "pw")
        withContext(Dispatchers.Default) {
            withTimeout(5_000) { while (h.sessions.load() != null) delay(20) }
        }
        assertNull(h.auth.session)
        assertNull(h.auth.currentUser.value)
        assertNull(h.auth.restoreSession())
        h.scope.cancel()
    }

    @Test
    fun loginMapsDisabledAccount() = runTest {
        val h = harness { respond("disabled", HttpStatusCode.Forbidden) }
        assertFailsWith<AppError.AccountUnavailable> { h.auth.login("alice", "pw") }
        h.scope.cancel()
    }

    @Test
    fun mustChangePasswordPersistsSessionWithoutConnecting() = runTest {
        val h = harness {
            respond(
                """{"uid":"u1","token":"pc","nickname":"alice","avatar_url":"/avatar/3","must_change_password":true,"im":{"url":"","token":"jwt"}}""",
                HttpStatusCode.OK,
                json,
            )
        }
        val result = h.auth.login("alice", "pw")
        assertTrue(result.mustChangePassword)
        assertEquals("https://im.example.com/avatar/3", result.user.avatarUrl)
        assertEquals("alice", result.user.nickname)
        assertEquals(GoImSession("https://im.example.com", "u1", "jwt", appToken = "pc"), h.sessions.load())
        val login = h.requests.single()
        assertEquals("https://im.example.com/account/login", login.url.toString())
        assertTrue(formBody(login).contains("account=alice"))
        h.scope.cancel()
    }

    @Test
    fun adminCreateUserReturnsPasswordWhenNotMailed() = runTest {
        var mailed = false
        var createStatus = HttpStatusCode.OK
        val h = harness { req ->
            val path = req.url.encodedPath
            when {
                path.endsWith("/account/login") -> respond("""{"uid":"1","token":"t","role":"admin","im":{"token":"imt"}}""", HttpStatusCode.OK, json)
                path.endsWith("/console/users/create") -> when (createStatus) {
                    HttpStatusCode.OK -> respond(
                        """{"status":"ok","user":{"uid":"100002","nickname":"dana","email":"dana@example.com","role":"user"},""" +
                            if (mailed) """"mailed":true}""" else """"mailed":false,"initial_password":"Abc123xyz"}""",
                        HttpStatusCode.OK,
                        json,
                    )
                    else -> respond("email already registered", createStatus)
                }
                else -> respond("""{"status":"ok"}""", HttpStatusCode.OK, json)
            }
        }
        h.auth.login("root", "pw")
        val accounts = GoImAccountAdminGateway(h.auth, h.api)

        val created = accounts.createUser("dana@example.com", null)
        assertEquals("100002", created.uid)
        assertEquals("Abc123xyz", created.initialPassword)
        val body = formBody(h.requests.last { it.url.encodedPath.endsWith("/console/users/create") })
        assertTrue(body.contains("email=dana%40example.com") && !body.contains("nickname"))

        mailed = true
        assertTrue(accounts.createUser("dana@example.com", "Dana").mailed)
        assertTrue(formBody(h.requests.last { it.url.encodedPath.endsWith("/console/users/create") }).contains("nickname=Dana"))

        createStatus = HttpStatusCode.Conflict
        assertFailsWith<AppError.EmailAlreadyRegistered> { accounts.createUser("dana@example.com", null) }
        createStatus = HttpStatusCode.Forbidden
        assertFailsWith<AppError.AdminRequired> { accounts.createUser("x@example.com", null) }
        h.auth.logout()
        h.scope.cancel()
    }

    @Test
    fun adminListsDisablesAndDeletesUsers() = runTest {
        val h = harness { req ->
            val path = req.url.encodedPath
            when {
                path.endsWith("/account/login") -> respond("""{"uid":"1","token":"t","role":"admin","im":{"token":"imt"}}""", HttpStatusCode.OK, json)
                path.endsWith("/console/users") -> respond(
                    """{"users":[{"uid":"2","nickname":"","email":"bob@example.com","signature":"","role":"user",""" +
                        """"is_disabled":true,"created_at":1700000000000,"updated_at":0,"avatar_url":""},""" +
                        """{"uid":"1","nickname":"root","role":"admin","is_disabled":false,"created_at":1,"avatar_url":"https://x/avatar/3"}],""" +
                        """"total":5,"offset":0,"limit":50}""",
                    HttpStatusCode.OK,
                    json,
                )
                path.endsWith("/console/users/disable") && formBody(req).contains("target_uid=1") ->
                    respond("cannot disable yourself", HttpStatusCode.BadRequest)
                path.endsWith("/console/users/delete") && formBody(req).contains("target_uid=9") ->
                    respond("delete failed: user 9 not found", HttpStatusCode.InternalServerError)
                else -> respond("""{"status":"ok"}""", HttpStatusCode.OK, json)
            }
        }
        h.auth.login("root", "pw")
        val accounts = GoImAccountAdminGateway(h.auth, h.api)

        val page = accounts.users(0, 50)
        assertEquals(5, page.total)
        assertTrue(page.hasMore)
        val bob = page.users.first()
        assertEquals("2", bob.displayName)
        assertEquals("bob@example.com", bob.email)
        assertNull(bob.avatarUrl)
        assertTrue(bob.isDisabled && !bob.isAdmin)
        assertTrue(page.users.last().isAdmin)
        assertTrue(h.requests.last { it.url.encodedPath.endsWith("/console/users") }.url.encodedQuery.contains("offset=0"))

        accounts.setDisabled("2", false)
        assertTrue(formBody(h.requests.last { it.url.encodedPath.endsWith("/console/users/disable") }).contains("disabled=false"))
        assertFailsWith<AppError.CannotManageAccount> { accounts.setDisabled("1", true) }
        accounts.deleteUser("2")
        assertTrue(h.requests.any { it.url.encodedPath.endsWith("/console/users/delete") })
        assertFailsWith<AppError.UserNotFound> { accounts.deleteUser("9") }
        h.auth.logout()
        h.scope.cancel()
    }

    @Test
    fun deleteAccountCallsServerThenClearsEverything() = runTest {
        var deleteStatus = HttpStatusCode.Unauthorized
        val h = harness { req ->
            when {
                req.url.encodedPath.endsWith("/account/login") -> respond("""{"uid":"me","token":"t","im":{"token":"imt"}}""", HttpStatusCode.OK, json)
                req.url.encodedPath.endsWith("/account/delete") -> respond(if (deleteStatus.value == 200) """{"status":"ok"}""" else "invalid password", deleteStatus, json)
                else -> respond("", HttpStatusCode.OK)
            }
        }
        h.auth.login("me", "pw")
        assertIs<AppError.Validation>(assertFailsWith<AppError> { h.auth.deleteAccount("bad") })
        assertEquals("me", h.sessions.load()?.uid)
        deleteStatus = HttpStatusCode.Forbidden
        assertFailsWith<AppError.AdminAccountDeletion> { h.auth.deleteAccount("pw") }
        deleteStatus = HttpStatusCode.OK
        h.auth.deleteAccount("pw")
        assertTrue(formBody(h.requests.last { it.url.encodedPath.endsWith("/account/delete") }).contains("password=pw"))
        assertNull(h.sessions.load())
        assertNull(h.auth.currentUser.value)
        h.scope.cancel()
    }

    @Test
    fun restoreDropsRejectedToken() = runTest {
        val h = harness { req ->
            if (req.url.encodedPath.endsWith("/account/session")) respond("token revoked", HttpStatusCode.Unauthorized) else respond("", HttpStatusCode.NotFound)
        }
        h.sessions.save(GoImSession("https://im.example.com", "u1", "old", appToken = "pc"))
        assertNull(h.auth.restoreSession())
        assertNull(h.sessions.load())
        h.scope.cancel()
    }

    @Test
    fun restoreDropsTokenFromAnotherServer() = runTest {
        val h = harness { respond("{}", HttpStatusCode.OK, json) }
        h.sessions.save(GoImSession("https://other.example.com", "u1", "t", appToken = "pc"))
        assertNull(h.auth.restoreSession())
        assertTrue(h.requests.isEmpty())
        h.scope.cancel()
    }

    @Test
    fun fetchUsersCachesAndPreservesOrder() = runTest {
        var calls = 0
        val h = harness { req ->
            when {
                req.url.encodedPath.endsWith("/account/login") ->
                    respond("""{"uid":"me","token":"t","nickname":"Me","im":{"token":"imt"}}""", HttpStatusCode.OK, json)
                req.url.encodedPath.endsWith("/user/profiles") -> {
                    calls++
                    respond("""{"users":[{"uid":"b","nickname":"Bee"},{"uid":"a","nickname":""}]}""", HttpStatusCode.OK, json)
                }
                else -> respond("", HttpStatusCode.OK)
            }
        }
        h.auth.login("me", "pw")
        val users = h.auth.fetchUsers(listOf("a", "b", "a"))
        assertEquals(listOf("a", "b"), users.map { it.id })
        assertEquals(listOf("a", "Bee"), users.map { it.nickname })
        h.auth.fetchUsers(listOf("b"))
        assertEquals(1, calls)
        h.auth.logout()
        h.scope.cancel()
    }

    @Test
    fun adminRoleAndModerationCalls() = runTest {
        var resolveStatus = HttpStatusCode.Forbidden
        val h = harness { req ->
            val path = req.url.encodedPath
            when {
                path.endsWith("/account/login") -> respond("""{"uid":"root","token":"t","role":"admin","im":{"token":"imt"}}""", HttpStatusCode.OK, json)
                path.endsWith("/user/blocks") -> respond("""{"blocked":["b1"]}""", HttpStatusCode.OK, json)
                path.endsWith("/console/reports") -> respond(
                    """{"reports":[{"id":3,"reporter_uid":"a","reporter_nickname":"A","target_uid":"b","target_nickname":"",""" +
                        """"target_disabled":true,"context":"room1","content":"rude","status":"banned","created_at":5,"handled_at":0}],""" +
                        """"total":1,"pending":0}""",
                    HttpStatusCode.OK,
                    json,
                )
                path.endsWith("/console/reports/resolve") ->
                    respond(if (resolveStatus == HttpStatusCode.OK) """{"status":"ok"}""" else "cannot ban an admin", resolveStatus, json)
                path.endsWith("/user/report") -> respond("moderation not available", HttpStatusCode.ServiceUnavailable)
                else -> respond("""{"status":"ok"}""", HttpStatusCode.OK, json)
            }
        }
        val user = h.auth.login("root", "pw").user
        assertTrue(user.isAdmin)
        val moderation = GoImModerationGateway(h.auth, h.api)

        assertEquals(listOf("b1"), moderation.blockedUserIds())
        moderation.block("b2")
        assertTrue(formBody(h.requests.last { it.url.encodedPath.endsWith("/user/block") }).contains("target_uid=b2"))

        val page = moderation.reports(ReportFilter.HANDLED, 0, 30)
        assertTrue(h.requests.last { it.url.encodedPath.endsWith("/console/reports") }.url.encodedQuery.contains("status=handled"))
        val report = page.reports.single()
        assertEquals("b", report.targetName)
        assertEquals(ReportStatus.BANNED, report.status)
        assertTrue(report.targetBanned)
        assertNull(report.handledAtMs)
        assertEquals("room1", report.roomId)

        assertIs<AppError.CannotBanAdmin>(assertFailsWith<AppError> { moderation.resolveReport(3, ReportAction.BAN) })
        resolveStatus = HttpStatusCode.OK
        moderation.resolveReport(3, ReportAction.IGNORE)
        assertTrue(formBody(h.requests.last { it.url.encodedPath.endsWith("/resolve") }).contains("action=ignore"))

        assertIs<AppError.ModerationUnavailable>(assertFailsWith<AppError> { moderation.report("b", "x", "1", null) })
        h.scope.cancel()
    }

    @Test
    fun restoreRefreshesImTokenAndUsesSeparateImHost() = runTest {
        val h = harness { req ->
            when (req.url.encodedPath) {
                "/account/session" -> respond(
                    """{"uid":"u1","token":"pc","nickname":"Al","avatar_url":"/avatar/7","im":{"url":"https://chat.example.com","token":"fresh"}}""",
                    HttpStatusCode.OK,
                    json,
                )
                "/user/blocks" -> respond("""{"blocked":[]}""", HttpStatusCode.OK, json)
                else -> respond("", HttpStatusCode.NotFound)
            }
        }
        h.sessions.save(GoImSession("https://im.example.com", "u1", "stale", appToken = "pc"))
        val user = h.auth.restoreSession()
        assertEquals("Al", user?.nickname)
        assertEquals("https://chat.example.com/avatar/7", user?.avatarUrl)
        val stored = h.sessions.load()
        assertEquals("fresh", stored?.token)
        assertEquals("https://chat.example.com", stored?.imBase)
        val sessionCall = h.requests.first()
        assertEquals("https://im.example.com/account/session", sessionCall.url.toString().substringBefore('?'))
        assertEquals("pc", sessionCall.url.parameters["token"])

        GoImModerationGateway(h.auth, h.api).blockedUserIds()
        val blocks = h.requests.last { it.url.encodedPath == "/user/blocks" }
        assertEquals("chat.example.com", blocks.url.host)
        assertEquals("fresh", blocks.url.parameters["token"])
        h.auth.logout()
        h.scope.cancel()
    }

    @Test
    fun restoreKeepsStoredLoginWhenOffline() = runTest {
        val h = harness { throw IllegalStateException("offline") }
        val stored = GoImSession("https://im.example.com", "u1", "imt", appToken = "pc")
        h.sessions.save(stored)
        assertEquals("u1", h.auth.restoreSession()?.id)
        assertEquals(stored, h.auth.session)
        h.auth.logout()
        h.scope.cancel()
    }

    @Test
    fun changePasswordStoresNewSessionToken() = runTest {
        val h = harness { req ->
            when (req.url.encodedPath) {
                "/account/login" -> respond("""{"uid":"u1","token":"old","must_change_password":true,"im":{"token":"imt"}}""", HttpStatusCode.OK, json)
                "/account/password" -> if (formBody(req).contains("old_password=bad")) {
                    respond("invalid current password", HttpStatusCode.Unauthorized)
                } else {
                    respond("""{"status":"ok","token":"new"}""", HttpStatusCode.OK, json)
                }
                else -> respond("", HttpStatusCode.NotFound)
            }
        }
        h.auth.login("alice@example.com", "init")
        assertIs<AppError.Validation>(assertFailsWith<AppError> { h.auth.changePassword("bad", "secret1") })
        h.auth.changePassword("init", "secret1")
        assertEquals("new", h.sessions.load()?.appToken)
        assertEquals("new", h.auth.session?.appToken)
        assertTrue(h.requests.last { it.url.encodedPath == "/account/password" }.url.host == "im.example.com")
        h.auth.logout()
        h.scope.cancel()
    }

    @Test
    fun expiredImTokenIsRefreshedThroughPaircast() = runTest {
        var sessionCalls = 0
        val h = harness { req ->
            when (req.url.encodedPath) {
                "/account/login" -> respond("""{"uid":"u1","token":"pc","im":{"token":"expired"}}""", HttpStatusCode.OK, json)
                "/account/session" -> {
                    sessionCalls++
                    respond("""{"uid":"u1","token":"pc","im":{"token":"renewed"}}""", HttpStatusCode.OK, json)
                }
                "/unread" -> respond("", if (req.url.parameters["token"] == "expired") HttpStatusCode.Unauthorized else HttpStatusCode.OK)
                else -> respond("", HttpStatusCode.NotFound)
            }
        }
        h.auth.login("alice@example.com", "pw")
        withContext(Dispatchers.Default) {
            withTimeout(5_000) { while (h.sessions.load()?.token != "renewed") delay(20) }
        }
        assertEquals("renewed", h.auth.session?.token)
        assertTrue(sessionCalls >= 1)
        h.auth.logout()
        h.scope.cancel()
    }
}
