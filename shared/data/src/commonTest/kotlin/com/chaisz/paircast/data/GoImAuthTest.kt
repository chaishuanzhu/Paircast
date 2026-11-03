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
    fun loginMapsDisabledAccount() = runTest {
        val h = harness { respond("disabled", HttpStatusCode.Forbidden) }
        assertFailsWith<AppError.AccountUnavailable> { h.auth.login("alice", "pw") }
        h.scope.cancel()
    }

    @Test
    fun mustChangePasswordPersistsSessionWithoutConnecting() = runTest {
        val h = harness {
            respond(
                """{"uid":"u1","token":"jwt","username":"alice","avatar_url":"/avatar/3","must_change_password":true}""",
                HttpStatusCode.OK,
                json,
            )
        }
        val result = h.auth.login("alice", "pw")
        assertTrue(result.mustChangePassword)
        assertEquals("https://im.example.com/avatar/3", result.user.avatarUrl)
        assertEquals("alice", result.user.nickname)
        assertEquals(GoImSession("https://im.example.com", "u1", "jwt"), h.sessions.load())
        val login = h.requests.single()
        assertEquals("https://im.example.com/login", login.url.toString())
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
                path.endsWith("/login") -> respond("""{"uid":"1","token":"t","role":"admin"}""", HttpStatusCode.OK, json)
                path.endsWith("/admin/users/create") -> when (createStatus) {
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
        val body = formBody(h.requests.last { it.url.encodedPath.endsWith("/admin/users/create") })
        assertTrue(body.contains("email=dana%40example.com") && !body.contains("nickname"))

        mailed = true
        assertTrue(accounts.createUser("dana@example.com", "Dana").mailed)
        assertTrue(formBody(h.requests.last { it.url.encodedPath.endsWith("/admin/users/create") }).contains("nickname=Dana"))

        createStatus = HttpStatusCode.Conflict
        assertFailsWith<AppError.EmailAlreadyRegistered> { accounts.createUser("dana@example.com", null) }
        createStatus = HttpStatusCode.Forbidden
        assertFailsWith<AppError.AdminRequired> { accounts.createUser("x@example.com", null) }
        h.auth.logout()
        h.scope.cancel()
    }

    @Test
    fun deleteAccountCallsServerThenClearsEverything() = runTest {
        var deleteStatus = HttpStatusCode.Unauthorized
        val h = harness { req ->
            when {
                req.url.encodedPath.endsWith("/login") -> respond("""{"uid":"me","token":"t"}""", HttpStatusCode.OK, json)
                req.url.encodedPath.endsWith("/user/delete") -> respond(if (deleteStatus.value == 200) """{"status":"ok"}""" else "invalid password", deleteStatus, json)
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
        assertTrue(formBody(h.requests.last { it.url.encodedPath.endsWith("/user/delete") }).contains("password=pw"))
        assertNull(h.sessions.load())
        assertNull(h.auth.currentUser.value)
        h.scope.cancel()
    }

    @Test
    fun restoreDropsRejectedToken() = runTest {
        val h = harness { req ->
            if (req.url.encodedPath.endsWith("/unread")) respond("", HttpStatusCode.Unauthorized) else respond("", HttpStatusCode.NotFound)
        }
        h.sessions.save(GoImSession("https://im.example.com", "u1", "old"))
        assertNull(h.auth.restoreSession())
        assertNull(h.sessions.load())
        h.scope.cancel()
    }

    @Test
    fun restoreDropsTokenFromAnotherServer() = runTest {
        val h = harness { respond("{}", HttpStatusCode.OK, json) }
        h.sessions.save(GoImSession("https://other.example.com", "u1", "t"))
        assertNull(h.auth.restoreSession())
        assertTrue(h.requests.isEmpty())
        h.scope.cancel()
    }

    @Test
    fun fetchUsersCachesAndPreservesOrder() = runTest {
        var calls = 0
        val h = harness { req ->
            when {
                req.url.encodedPath.endsWith("/login") ->
                    respond("""{"uid":"me","token":"t","nickname":"Me"}""", HttpStatusCode.OK, json)
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
                path.endsWith("/login") -> respond("""{"uid":"root","token":"t","role":"admin"}""", HttpStatusCode.OK, json)
                path.endsWith("/user/blocks") -> respond("""{"blocked":["b1"]}""", HttpStatusCode.OK, json)
                path.endsWith("/admin/reports") -> respond(
                    """{"reports":[{"id":3,"reporter_uid":"a","reporter_nickname":"A","target_uid":"b","target_nickname":"",""" +
                        """"target_disabled":true,"context":"room1","content":"rude","status":"banned","created_at":5,"handled_at":0}],""" +
                        """"total":1,"pending":0}""",
                    HttpStatusCode.OK,
                    json,
                )
                path.endsWith("/admin/reports/resolve") ->
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
        assertTrue(h.requests.last { it.url.encodedPath.endsWith("/admin/reports") }.url.encodedQuery.contains("status=handled"))
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
}
