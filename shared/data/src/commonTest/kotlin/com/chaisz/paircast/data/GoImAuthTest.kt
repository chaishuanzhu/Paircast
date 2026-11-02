package com.chaisz.paircast.data

import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.IMConfig
import com.chaisz.paircast.core.model.ObjectStorageConfig
import com.chaisz.paircast.data.goim.GoImApi
import com.chaisz.paircast.data.goim.GoImAuthGateway
import com.chaisz.paircast.data.goim.GoImConnection
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
import kotlin.test.assertNull
import kotlin.test.assertTrue

class GoImAuthTest {
    private val json = headersOf(HttpHeaders.ContentType, "application/json")

    private class Harness(
        val auth: GoImAuthGateway,
        val sessions: SessionStore,
        val requests: MutableList<HttpRequestData>,
        val scope: CoroutineScope,
    )

    private suspend fun harness(handler: suspend MockRequestHandleScope.(HttpRequestData) -> HttpResponseData): Harness {
        val requests = mutableListOf<HttpRequestData>()
        val client = createHttpClient(MockEngine { req -> requests += req; handler(req) })
        val store = InMemorySecureStore()
        val config = SecureConfigStore(store)
        config.save(
            AppCloudConfig(
                im = IMConfig("im.example.com"),
                storage = ObjectStorageConfig(accessKey = "a", secretKey = "s", bucket = "b", endpoint = "e.com"),
            ),
        )
        val api = GoImApi(client)
        val scope = CoroutineScope(SupervisorJob())
        val connection = GoImConnection(client, api, scope, deviceId = "dev", platform = "test")
        val sessions = SessionStore(store)
        return Harness(GoImAuthGateway(config, sessions, api, connection), sessions, requests, scope)
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
}
