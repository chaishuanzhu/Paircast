package com.chaisz.paircast.data.goim

import com.chaisz.paircast.core.gateway.AccountAdminGateway
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.CreatedAccount
import com.chaisz.paircast.core.model.ManagedUser
import com.chaisz.paircast.core.model.UserPage
import com.chaisz.paircast.core.rules.ProfileRules
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
internal data class AdminUserDto(
    val uid: String,
    val nickname: String = "",
    val email: String = "",
)

@Serializable
internal data class ManagedUserDto(
    val uid: String,
    val nickname: String = "",
    val email: String? = null,
    @SerialName("avatar_url") val avatarUrl: String? = null,
    val role: String = "",
    @SerialName("is_disabled") val isDisabled: Boolean = false,
    @SerialName("created_at") val createdAt: Long = 0,
)

@Serializable
internal data class UserListDto(
    val users: List<ManagedUserDto>? = null,
    val total: Int = 0,
)

@Serializable
internal data class CreateUserResponseDto(
    val user: AdminUserDto,
    val mailed: Boolean = false,
    @SerialName("initial_password") val initialPassword: String? = null,
)

/** Paircast `/console/users`, `/console/users/create`, `/console/users/disable`, `/console/users/delete`. */
class GoImAccountAdminGateway(
    private val auth: GoImAuthGateway,
    private val api: GoImApi,
) : AccountAdminGateway {
    override suspend fun createUser(email: String, nickname: String?): CreatedAccount {
        val dto = try {
            api.decode(
                api.appPost(auth.requireSession(), "console/users/create", "email" to email, "nickname" to nickname),
                CreateUserResponseDto.serializer(),
            )
        } catch (e: GoImHttpException) {
            throw when (e.status) {
                400 -> when {
                    e.body.contains("nickname") -> AppError.Validation(
                        "Nickname can be at most {{count}} characters",
                        mapOf("count" to "${ProfileRules.NICKNAME_MAX_LENGTH}"),
                    )
                    else -> AppError.Validation("Please enter a valid email address")
                }
                401 -> AppError.SessionExpired
                403 -> AppError.AdminRequired
                409 -> AppError.EmailAlreadyRegistered
                else -> AppError.Unknown("Server error {{code}}", mapOf("code" to e.status.toString()))
            }
        }
        return CreatedAccount(
            uid = dto.user.uid,
            email = dto.user.email.ifEmpty { email },
            nickname = dto.user.nickname.ifEmpty { dto.user.uid },
            initialPassword = if (dto.mailed) null else dto.initialPassword?.takeIf { it.isNotEmpty() },
        )
    }

    override suspend fun users(offset: Int, limit: Int): UserPage = call {
        val s = auth.requireSession()
        val dto = api.decode(
            api.appGet(s, "console/users", "offset" to "$offset", "limit" to "$limit"),
            UserListDto.serializer(),
        )
        UserPage(dto.users.orEmpty().map { toModel(it, s.imBase) }, dto.total)
    }

    override suspend fun setDisabled(userId: String, disabled: Boolean) {
        call { api.appPost(auth.requireSession(), "console/users/disable", "target_uid" to userId, "disabled" to "$disabled") }
    }

    override suspend fun deleteUser(userId: String) {
        call { api.appPost(auth.requireSession(), "console/users/delete", "target_uid" to userId) }
    }

    private fun toModel(dto: ManagedUserDto, imBase: String) = ManagedUser(
        id = dto.uid,
        nickname = dto.nickname,
        email = dto.email?.takeIf { it.isNotEmpty() },
        avatarUrl = GoImApi.absoluteUrl(imBase, dto.avatarUrl),
        isAdmin = dto.role == GoImAuthGateway.ADMIN_ROLE,
        isDisabled = dto.isDisabled,
        createdAtMs = dto.createdAt,
    )

    private suspend fun <T> call(block: suspend () -> T): T = try {
        block()
    } catch (e: GoImHttpException) {
        throw when {
            e.status == 401 -> AppError.SessionExpired
            e.status == 403 -> AppError.AdminRequired
            e.status == 400 && e.body.contains("yourself") -> AppError.CannotManageAccount
            e.body.contains("not found") -> AppError.UserNotFound
            else -> AppError.Unknown("Server error {{code}}", mapOf("code" to e.status.toString()))
        }
    }
}
