package com.chaisz.paircast.data.goim

import com.chaisz.paircast.core.gateway.AccountAdminGateway
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.CreatedAccount
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
internal data class CreateUserResponseDto(
    val user: AdminUserDto,
    val mailed: Boolean = false,
    @SerialName("initial_password") val initialPassword: String? = null,
)

/** GO-IM `/admin/users/create`. */
class GoImAccountAdminGateway(
    private val auth: GoImAuthGateway,
    private val api: GoImApi,
) : AccountAdminGateway {
    override suspend fun createUser(email: String, nickname: String?): CreatedAccount {
        val dto = try {
            api.decode(
                api.post(auth.requireSession(), "admin/users/create", "email" to email, "nickname" to nickname),
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
}
