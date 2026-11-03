package com.chaisz.paircast.android.ui

import android.text.format.DateUtils
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.chaisz.paircast.android.app.AppState
import com.chaisz.paircast.android.app.L10n
import com.chaisz.paircast.android.app.t
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.ReportAction
import com.chaisz.paircast.core.model.ReportFilter
import com.chaisz.paircast.core.model.ReportStatus
import com.chaisz.paircast.core.model.UserReport
import com.chaisz.paircast.core.usecase.LoadReportsUseCase
import kotlinx.coroutines.launch

/** Admin-only: review chat reports, ignore them or ban the reported user. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReportsScreen(app: AppState) {
    val scope = rememberCoroutineScope()
    var filter by remember { mutableStateOf(ReportFilter.PENDING) }
    val reports = remember { mutableStateListOf<UserReport>() }
    var total by remember { mutableIntStateOf(0) }
    var pending by remember { mutableIntStateOf(0) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var busyId by remember { mutableStateOf<Long?>(null) }
    var confirmBan by remember { mutableStateOf<UserReport?>(null) }
    var reloadKey by remember { mutableIntStateOf(0) }

    BackHandler { app.popLibrary() }

    suspend fun load(append: Boolean) {
        loading = true
        error = null
        try {
            val page = app.graph.loadReports(filter, if (append) reports.size else 0, LoadReportsUseCase.PAGE_SIZE)
            if (!append) reports.clear()
            reports.addAll(page.reports.filter { r -> reports.none { it.id == r.id } })
            total = page.total
            pending = page.pending
        } catch (e: Exception) {
            error = L10n.message(e, AppError.Network)
        } finally {
            loading = false
        }
    }

    LaunchedEffect(filter, reloadKey) { load(append = false) }

    fun resolve(report: UserReport, action: ReportAction) {
        scope.launch {
            busyId = report.id
            try {
                app.graph.resolveReport(report, action)
                val closed = if (action == ReportAction.BAN) {
                    reports.filter { it.targetId == report.targetId && it.isPending }
                } else {
                    listOf(report)
                }
                reports.removeAll { r -> closed.any { it.id == r.id } }
                total = (total - closed.size).coerceAtLeast(0)
                pending = (pending - closed.size).coerceAtLeast(0)
                app.showToast(
                    if (action == ReportAction.BAN) t("Banned {{name}}", "name" to report.targetName) else t("Report ignored"),
                )
            } catch (e: Exception) {
                app.showToast(L10n.message(e, AppError.Network))
            } finally {
                busyId = null
            }
        }
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(t("Reports")) },
                navigationIcon = {
                    IconButton(onClick = app::popLibrary) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = t("Back")) }
                },
                actions = {
                    IconButton(onClick = { reloadKey++ }, enabled = !loading) {
                        Icon(Icons.Filled.Refresh, contentDescription = t("Refresh"))
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                val tabs = listOf(
                    ReportFilter.PENDING to if (pending > 0) t("Pending ({{count}})", "count" to "$pending") else t("Pending"),
                    ReportFilter.HANDLED to t("Handled"),
                )
                tabs.forEachIndexed { index, (value, label) ->
                    SegmentedButton(
                        selected = filter == value,
                        onClick = { filter = value },
                        shape = SegmentedButtonDefaults.itemShape(index, tabs.size),
                    ) { Text(label) }
                }
            }

            when {
                reports.isEmpty() && loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                reports.isEmpty() -> ReportsPlaceholder(
                    error ?: t(if (filter == ReportFilter.PENDING) "No pending reports" else "No handled reports yet"),
                    retry = if (error != null) ({ reloadKey++ }) else null,
                )
                else -> LazyColumn(
                    contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 32.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    items(reports, key = { it.id }) { report ->
                        ReportCard(
                            report,
                            busy = busyId == report.id,
                            onIgnore = { resolve(report, ReportAction.IGNORE) },
                            onBan = { confirmBan = report },
                        )
                    }
                    if (reports.size < total) {
                        item {
                            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                                if (loading) {
                                    CircularProgressIndicator(Modifier.padding(8.dp))
                                } else {
                                    TextButton(onClick = { scope.launch { load(append = true) } }) { Text(t("Load more")) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    confirmBan?.let { report ->
        AlertDialog(
            onDismissRequest = { confirmBan = null },
            title = { Text(t("Ban {{name}}?", "name" to report.targetName)) },
            text = { Text(t("They are signed out right away and can no longer sign in. Their other pending reports are closed as well.")) },
            confirmButton = {
                TextButton(onClick = { confirmBan = null; resolve(report, ReportAction.BAN) }) {
                    Text(t("Ban User"), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { confirmBan = null }) { Text(t("Cancel")) } },
        )
    }
}

@Composable
private fun ReportsPlaceholder(message: String, retry: (() -> Unit)?) {
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(message, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        retry?.let { TextButton(onClick = it) { Text(t("Retry")) } }
    }
}

@Composable
private fun ReportCard(report: UserReport, busy: Boolean, onIgnore: () -> Unit, onBan: () -> Unit) {
    val context = LocalContext.current
    Surface(shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surface) {
        Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    t("Reported user: {{name}}", "name" to report.targetName),
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                StatusBadge(report)
            }
            val content = when (report.content) {
                "" -> null
                "[Sticker]" -> t("[Sticker]")
                else -> report.content
            }
            content?.let {
                Text(
                    it,
                    fontSize = 15.sp,
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(MaterialTheme.colorScheme.background, RoundedCornerShape(10.dp))
                        .padding(horizontal = 12.dp, vertical = 10.dp),
                )
            }
            val time = DateUtils.formatDateTime(
                context,
                report.createdAtMs,
                DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_SHOW_TIME or DateUtils.FORMAT_ABBREV_MONTH,
            )
            Text(
                t("Reported by {{name}} · {{time}}", "name" to report.reporterName, "time" to time),
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (report.isPending) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                    OutlinedButton(onClick = onIgnore, enabled = !busy, modifier = Modifier.weight(1f)) { Text(t("Ignore")) }
                    OutlinedButton(
                        onClick = onBan,
                        enabled = !busy && !report.targetBanned,
                        modifier = Modifier.weight(1f),
                    ) {
                        Text(t("Ban User"), color = if (busy || report.targetBanned) Color.Unspecified else MaterialTheme.colorScheme.error)
                    }
                }
            }
        }
    }
}

@Composable
private fun StatusBadge(report: UserReport) {
    val (label, color) = when {
        report.status == ReportStatus.BANNED || report.targetBanned -> t("Banned") to MaterialTheme.colorScheme.error
        report.status == ReportStatus.IGNORED -> t("Ignored") to MaterialTheme.colorScheme.outline
        else -> t("Pending") to PaircastColors.blue
    }
    Text(
        label,
        color = color,
        fontSize = 12.sp,
        fontWeight = FontWeight.Medium,
        modifier = Modifier.background(color.copy(alpha = 0.12f), CircleShape).padding(horizontal = 10.dp, vertical = 3.dp),
    )
}
