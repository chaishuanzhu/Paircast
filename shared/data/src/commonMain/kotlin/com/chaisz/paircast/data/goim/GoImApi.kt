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

/** Non-2xx gateway response. [body] is the plain-text `http.Error` message. */
class GoImHttpException(val status: Int, val body: String) : Exception("HTTP $status: $body")

@Serializable
internal data class LoginResponseDto(
    val uid: String,
    val token: String,
    val nickname: String? = null,
    val username: String? = null,
    val email: String? = null,
    @SerialName("avatar_url") val avatarUrl: String? = null,
    @SerialName("must_change_password") val mustChangePassword: Boolean = false,
)

@Serializable
internal data class ProfileDto(
    val uid: String,
    val nickname: String = "",
    @SerialName("avatar_url") val avatarUrl: String? = null,
    val email: String? = null,
)

@Serializable
internal data class ProfileListDto(val users: List<ProfileDto>? = null)

@Serializable
internal data class GroupCreateDto(
    val id: String? = null,
    @SerialName("group_id") val groupId: String? = null,
)

@Serializable
internal data class UploadResponseDto(@SerialName("file_id") val fileId: JsonElement? = null)

/**
 * GO-IM gateway REST API (`docs/07-api-reference.md`). Anonymous calls take [serverUrl];
 * authenticated calls carry `uid` + `token` from [GoImSession].
 */
class GoImApi(private val client: HttpClient) {
    internal suspend fun login(serverUrl: String, account: String, password: String): LoginResponseDto =
        decode(
            send { client.submitForm(url(serverUrl, "login"), Parameters.build { append("account", account); append("password", password) }) { short() } },
            LoginResponseDto.serializer(),
        )

    suspend fun changePassword(session: GoImSession, oldPassword: String, newPassword: String) {
        post(session, "change-password", "old_password" to oldPassword, "new_password" to newPassword)
    }

    /** `GET /unread`: true valid, false rejected (401), null unknown (network). */
    suspend fun validateToken(session: GoImSession): Boolean? = try {
        val response = client.get(url(session.serverUrl, "unread")) {
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
        decode(get(session, "user/profile"), ProfileDto.serializer())

    internal suspend fun profiles(session: GoImSession, uids: List<String>): List<ProfileDto> =
        decode(get(session, "user/profiles", "uids" to uids.joinToString(",")), ProfileListDto.serializer()).users.orEmpty()

    /** null = unchanged; [avatarFileId] `"0"` clears the avatar. */
    internal suspend fun updateProfile(session: GoImSession, nickname: String?, avatarFileId: String?): ProfileDto =
        decode(post(session, "user/profile", "nickname" to nickname, "avatar_file_id" to avatarFileId), ProfileDto.serializer())

    /** Multipart `/upload`; returns `file_id`. */
    suspend fun upload(session: GoImSession, bytes: ByteArray, fileName: String, mime: String): String {
        val response = send {
            client.submitFormWithBinaryData(
                url = url(session.serverUrl, "upload"),
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

    suspend fun createGroup(session: GoImSession, name: String): String {
        val dto = decode(post(session, "group/create", "name" to name), GroupCreateDto.serializer())
        return dto.groupId?.takeIf { it.isNotEmpty() } ?: dto.id?.takeIf { it.isNotEmpty() }
            ?: throw GoImHttpException(200, "missing group id")
    }

    suspend fun joinGroup(session: GoImSession, groupId: String) {
        post(session, "group/join", "group_id" to groupId)
    }

    suspend fun leaveGroup(session: GoImSession, groupId: String) {
        post(session, "group/leave", "group_id" to groupId)
    }

    private suspend fun get(session: GoImSession, path: String, vararg params: Pair<String, String>): HttpResponse = send {
        client.get(url(session.serverUrl, path)) {
            parameter("uid", session.uid)
            parameter("token", session.token)
            params.forEach { (k, v) -> parameter(k, v) }
            short()
        }
    }

    private suspend fun post(session: GoImSession, path: String, vararg params: Pair<String, String?>): HttpResponse = send {
        client.submitForm(
            url = url(session.serverUrl, path),
            formParameters = Parameters.build {
                append("uid", session.uid)
                append("token", session.token)
                params.forEach { (k, v) -> if (v != null) append(k, v) }
            },
        ) { short() }
    }

    private suspend fun send(block: suspend () -> HttpResponse): HttpResponse {
        val response = try {
            block()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            throw AppError.ServerUnreachable
        }
        if (!response.status.isSuccess()) throw GoImHttpException(response.status.value, response.bodyAsText().trim())
        return response
    }

    private suspend fun <T> decode(response: HttpResponse, serializer: KSerializer<T>): T = try {
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

        /** Gateway-relative avatar paths (`/avatar/1`) → absolute URL; blank → null. */
        fun absoluteUrl(serverUrl: String, path: String?): String? = when {
            path.isNullOrBlank() -> null
            path.startsWith("http://") || path.startsWith("https://") -> path
            else -> serverUrl.trimEnd('/') + "/" + path.trimStart('/')
        }
    }
}
