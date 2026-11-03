package com.chaisz.paircast.data.goim

import com.chaisz.paircast.core.gateway.ModerationGateway
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.ReportAction
import com.chaisz.paircast.core.model.ReportFilter
import com.chaisz.paircast.core.model.ReportPage
import com.chaisz.paircast.core.model.ReportStatus
import com.chaisz.paircast.core.model.UserReport
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
internal data class BlockListDto(val blocked: List<String>? = null)

@Serializable
internal data class ReportDto(
    val id: Long,
    @SerialName("reporter_uid") val reporterUid: String = "",
    @SerialName("reporter_nickname") val reporterNickname: String = "",
    @SerialName("target_uid") val targetUid: String = "",
    @SerialName("target_nickname") val targetNickname: String = "",
    @SerialName("target_disabled") val targetDisabled: Boolean = false,
    val context: String? = null,
    val content: String = "",
    val status: String = "pending",
    @SerialName("created_at") val createdAt: Long = 0,
    @SerialName("handled_at") val handledAt: Long? = null,
)

@Serializable
internal data class ReportListDto(
    val reports: List<ReportDto>? = null,
    val total: Int = 0,
    val pending: Int = 0,
)

/** GO-IM `/user/block*`, `/user/report`, `/admin/reports*`. */
class GoImModerationGateway(
    private val auth: GoImAuthGateway,
    private val api: GoImApi,
) : ModerationGateway {
    override suspend fun blockedUserIds(): List<String> = call {
        api.decode(api.get(auth.requireSession(), "user/blocks"), BlockListDto.serializer()).blocked.orEmpty()
    }

    override suspend fun block(userId: String) {
        call { api.post(auth.requireSession(), "user/block", "target_uid" to userId) }
    }

    override suspend fun unblock(userId: String) {
        call { api.post(auth.requireSession(), "user/unblock", "target_uid" to userId) }
    }

    override suspend fun report(targetUserId: String, content: String, messageId: String?, roomId: String?) {
        call {
            api.post(
                auth.requireSession(),
                "user/report",
                "target_uid" to targetUserId,
                "content" to content,
                "message_id" to messageId,
                "context" to roomId,
            )
        }
    }

    override suspend fun reports(filter: ReportFilter, offset: Int, limit: Int): ReportPage = call {
        val status = when (filter) {
            ReportFilter.PENDING -> "pending"
            ReportFilter.HANDLED -> "handled"
        }
        val dto = api.decode(
            api.get(auth.requireSession(), "admin/reports", "status" to status, "offset" to "$offset", "limit" to "$limit"),
            ReportListDto.serializer(),
        )
        ReportPage(dto.reports.orEmpty().map(::toModel), dto.total, dto.pending)
    }

    override suspend fun resolveReport(reportId: Long, action: ReportAction) {
        val value = when (action) {
            ReportAction.IGNORE -> "ignore"
            ReportAction.BAN -> "ban"
        }
        call { api.post(auth.requireSession(), "admin/reports/resolve", "id" to "$reportId", "action" to value) }
    }

    private fun toModel(dto: ReportDto) = UserReport(
        id = dto.id,
        reporterId = dto.reporterUid,
        reporterName = dto.reporterNickname.ifEmpty { dto.reporterUid },
        targetId = dto.targetUid,
        targetName = dto.targetNickname.ifEmpty { dto.targetUid },
        targetBanned = dto.targetDisabled,
        content = dto.content,
        roomId = dto.context?.takeIf { it.isNotEmpty() },
        status = when (dto.status) {
            "ignored" -> ReportStatus.IGNORED
            "banned" -> ReportStatus.BANNED
            else -> ReportStatus.PENDING
        },
        createdAtMs = dto.createdAt,
        handledAtMs = dto.handledAt?.takeIf { it > 0 },
    )

    private suspend fun <T> call(block: suspend () -> T): T = try {
        block()
    } catch (e: GoImHttpException) {
        throw when (e.status) {
            401 -> AppError.SessionExpired
            403 -> if (e.body.contains("cannot ban an admin")) AppError.CannotBanAdmin else AppError.AdminRequired
            404 -> when {
                e.body.contains("report not found") -> AppError.ReportNotFound
                e.body.contains("user not found") -> AppError.AccountUnavailable
                else -> AppError.ModerationUnavailable
            }
            405, 503 -> AppError.ModerationUnavailable
            else -> AppError.Unknown("Server error {{code}}", mapOf("code" to e.status.toString()))
        }
    }
}
