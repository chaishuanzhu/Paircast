package com.chaisz.paircast.data.goim

import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.data.net.apiJson
import com.chaisz.paircast.data.secure.GoImSession
import io.ktor.client.HttpClient
import io.ktor.client.plugins.timeout
import io.ktor.client.request.forms.formData
import io.ktor.client.request.forms.submitForm
import io.ktor.client.request.forms.submitFormWithBinaryData
import io.ktor.client.request.get
import io.ktor.client.request.parameter
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.Headers
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.Parameters
import io.ktor.http.isSuccess
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive

/** Non-2xx GO-IM / Paircast response. [body] is the plain-text `http.Error` message. */
class GoImHttpException(
    val status: Int,
    val body: String,
    /** `Retry-After` seconds on 429 responses. */
    val retryAfterSeconds: Int? = null,
) : Exception("HTTP $status: $body")

/** GO-IM connection details issued with a Paircast session; empty [url] = same origin as Paircast. */
@Serializable
internal data class ImInfoDto(
    val url: String = "",
    val uid: String = "",
    val token: String = "",
    @SerialName("expires_at") val expiresAt: Long = 0,
)

/** Paircast `/account/login` and `/account/session`. [uid] is the GO-IM uid, [token] the Paircast session. */
@Serializable
internal data class SessionDto(
    val uid: String,
    val token: String,
    val nickname: String? = null,
    val email: String? = null,
    @SerialName("avatar_url") val avatarUrl: String? = null,
    @SerialName("must_change_password") val mustChangePassword: Boolean = false,
    val role: String? = null,
    val im: ImInfoDto = ImInfoDto(),
)

@Serializable
internal data class PasswordChangedDto(val token: String = "")

@Serializable
internal data class ProfileDto(
    val uid: String,
    val nickname: String = "",
    @SerialName("avatar_url") val avatarUrl: String? = null,
    val email: String? = null,
    /** Present on the caller's own profile only. */
    val role: String? = null,
)

@Serializable
internal data class ProfileListDto(val users: List<ProfileDto>? = null)

@Serializable
internal data class UploadResponseDto(@SerialName("file_id") val fileId: JsonElement? = null)

/**
 * HTTP calls for both backends. Accounts and the admin console live on the Paircast server
 * ([GoImSession.serverUrl] + `appToken`, via [appGet] / [appPost]); chat REST and uploads go to
 * GO-IM ([GoImSession.imBase] + the IM token, via [get] / [post]).
 */
class GoImApi(private val client: HttpClient) {
    internal suspend fun login(serverUrl: String, account: String, password: String): SessionDto =
        decode(
            send { client.submitForm(url(serverUrl, "account/login"), Parameters.build { append("account", account); append("password", password) }) { short() } },
            SessionDto.serializer(),
        )

    /** Validates the Paircast session and returns fresh profile + IM token. */
    internal suspend fun session(session: GoImSession): SessionDto =
        decode(appGet(session, "account/session"), SessionDto.serializer())

    suspend fun deleteAccount(session: GoImSession, password: String) {
        appPost(session, "account/delete", "password" to password)
    }

    /** Returns the new Paircast session token (every older one is revoked). */
    suspend fun changePassword(session: GoImSession, oldPassword: String, newPassword: String): String =
        decode(appPost(session, "account/password", "old_password" to oldPassword, "new_password" to newPassword), PasswordChangedDto.serializer())
            .token.ifEmpty { throw GoImHttpException(200, "missing token") }

    /** GO-IM `GET /unread`: true valid, false rejected (401), null unknown (network). */
    suspend fun validateToken(session: GoImSession): Boolean? = try {
        val response = client.get(url(session.imBase, "unread")) {
            parameter("uid", session.uid)
            parameter("token", session.token)
            short()
        }
        when {
            response.status == HttpStatusCode.Unauthorized -> false
            response.status.isSuccess() -> true
            else -> null
        }
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }

    internal suspend fun myProfile(session: GoImSession): ProfileDto =
        decode(appGet(session, "account/profile"), ProfileDto.serializer())

    internal suspend fun profiles(session: GoImSession, uids: List<String>): List<ProfileDto> =
        decode(get(session, "user/profiles", "uids" to uids.joinToString(",")), ProfileListDto.serializer()).users.orEmpty()

    /** null = unchanged; [avatarFileId] `"0"` clears the avatar. */
    internal suspend fun updateProfile(session: GoImSession, nickname: String?, avatarFileId: String?): ProfileDto =
        decode(appPost(session, "account/profile", "nickname" to nickname, "avatar_file_id" to avatarFileId), ProfileDto.serializer())

    /** GO-IM multipart `/upload`; returns `file_id`. */
    suspend fun upload(session: GoImSession, bytes: ByteArray, fileName: String, mime: String): String {
        val response = send {
            client.submitFormWithBinaryData(
                url = url(session.imBase, "upload"),
                formData = formData {
                    append("uid", session.uid)
                    append("token", session.token)
                    append(
                        "file",
                        bytes,
                        Headers.build {
                            append(HttpHeaders.ContentType, mime)
                            append(HttpHeaders.ContentDisposition, "filename=\"${fileName.replace("\"", "")}\"")
                        },
                    )
                },
            ) { timeout { requestTimeoutMillis = 60_000 } }
        }
        val dto = decode(response, UploadResponseDto.serializer())
        return (dto.fileId as? JsonPrimitive)?.content?.takeIf { it.isNotEmpty() && it != "null" }
            ?: throw GoImHttpException(response.status.value, "missing file_id")
    }

    /** GO-IM GET with the IM token. */
    internal suspend fun get(session: GoImSession, path: String, vararg params: Pair<String, String>): HttpResponse =
        getAt(session.imBase, session.uid, session.token, path, params)

    /** GO-IM form POST with the IM token. */
    internal suspend fun post(session: GoImSession, path: String, vararg params: Pair<String, String?>): HttpResponse =
        postAt(session.imBase, session.uid, session.token, path, params)

    /** Paircast GET with the session token. */
    internal suspend fun appGet(session: GoImSession, path: String, vararg params: Pair<String, String>): HttpResponse =
        getAt(session.serverUrl, session.uid, session.appToken, path, params)

    /** Paircast form POST with the session token. */
    internal suspend fun appPost(session: GoImSession, path: String, vararg params: Pair<String, String?>): HttpResponse =
        postAt(session.serverUrl, session.uid, session.appToken, path, params)

    private suspend fun getAt(base: String, uid: String, token: String, path: String, params: Array<out Pair<String, String>>) = send {
        client.get(url(base, path)) {
            parameter("uid", uid)
            parameter("token", token)
            params.forEach { (k, v) -> parameter(k, v) }
            short()
        }
    }

    private suspend fun postAt(base: String, uid: String, token: String, path: String, params: Array<out Pair<String, String?>>) = send {
        client.submitForm(
            url = url(base, path),
            formParameters = Parameters.build {
                append("uid", uid)
                append("token", token)
                params.forEach { (k, v) -> if (v != null) append(k, v) }
            },
        ) { short() }
    }

    internal suspend fun send(block: suspend () -> HttpResponse): HttpResponse {
        val response = try {
            block()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            throw AppError.ServerUnreachable
        }
        if (!response.status.isSuccess()) {
            throw GoImHttpException(
                response.status.value,
                response.bodyAsText().trim(),
                response.headers[HttpHeaders.RetryAfter]?.trim()?.toIntOrNull(),
            )
        }
        return response
    }

    internal suspend fun <T> decode(response: HttpResponse, serializer: KSerializer<T>): T = try {
        apiJson.decodeFromString(serializer, response.bodyAsText())
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        throw GoImHttpException(response.status.value, "invalid response: ${e.message}")
    }

    private fun io.ktor.client.request.HttpRequestBuilder.short() {
        timeout { requestTimeoutMillis = 15_000 }
    }

    companion object {
        fun url(serverUrl: String, path: String) = serverUrl.trimEnd('/') + "/" + path

        /** GO-IM-relative avatar paths (`/avatar/1`) → absolute URL against [serverUrl]; blank → null. */
        fun absoluteUrl(serverUrl: String, path: String?): String? = when {
            path.isNullOrBlank() -> null
            path.startsWith("http://") || path.startsWith("https://") -> path
            else -> serverUrl.trimEnd('/') + "/" + path.trimStart('/')
        }
    }
}
