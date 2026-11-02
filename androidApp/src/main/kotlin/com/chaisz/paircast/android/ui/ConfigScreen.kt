package com.chaisz.paircast.android.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.MenuBook
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.chaisz.paircast.android.app.AppState
import com.chaisz.paircast.android.app.L10n
import com.chaisz.paircast.android.app.t
import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.IMConfig
import kotlinx.coroutines.launch

private class ConfigForm(config: AppCloudConfig?) {
    var serverUrl by mutableStateOf("")

    init {
        config?.im?.serverUrl?.takeIf { it.isNotEmpty() }?.let { serverUrl = it }
    }

    fun draft() = AppCloudConfig(im = IMConfig(serverUrl))
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConfigScreen(app: AppState, fromLogin: Boolean) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val form = remember { ConfigForm(app.config) }
    var status by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }

    fun close() = if (fromLogin) app.resetToLogin() else app.popLibrary()
    BackHandler(enabled = fromLogin) { close() }

    fun save() = scope.launch {
        saving = true
        try {
            val previousServer = app.config?.im?.serverUrl
            val stored = app.graph.saveConfig(form.draft())
            if (app.currentUser != null && previousServer != stored.im.serverUrl) {
                app.applyServerChange(stored)
            } else {
                app.config = stored
                runCatching { app.graph.clearMetadataCache() }
                app.showToast(t("Saved"))
                close()
            }
        } catch (e: Exception) {
            status = L10n.message(e, AppError.Unknown("Unable to save configuration"))
        } finally {
            saving = false
        }
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(t("Service Configuration")) },
                navigationIcon = {
                    IconButton(onClick = ::close) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = t("Back")) }
                },
                actions = {
                    TextButton(onClick = { save() }, enabled = !saving) { Text(t("Save"), fontWeight = FontWeight.SemiBold) }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            SectionCard(title = t("Server"), footer = t("The address of the server you or a friend deployed. HTTPS is assumed unless you enter http:// (LAN only).")) {
                PaircastField(t("Address"), form.serverUrl, { form.serverUrl = it }, keyboardType = KeyboardType.Uri, placeholder = "im.example.com")
            }

            SectionCard(footer = t("Fill in the server address, save, then sign in with the account the server admin created for you")) {
                ActionRow(Icons.Filled.MenuBook, t("Configuration Guide"), null) { openDoc(context, "guide") }
                HorizontalDivider()
                ActionRow(Icons.Filled.Dns, t("Server Deployment Guide"), t("Deploy your own server with Docker")) { openDoc(context, "deploy") }
            }

            SectionCard(footer = t("Videos, subtitles, posters and stickers come from the media library the server admin configures.")) {
                Text(t("Media Library"), fontWeight = FontWeight.SemiBold)
                Text(t("Managed by the server"), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }

            status?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            Spacer(Modifier.height(24.dp))
        }
    }
}

private fun openDoc(context: Context, page: String) {
    val lang = if (L10n.useChinese) "zh-Hans" else "en-US"
    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://paircast.chaisz.com/$lang/$page/")))
}

@Composable
private fun ActionRow(icon: ImageVector, title: String, subtitle: String?, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(24.dp))
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(title, fontWeight = FontWeight.SemiBold)
            subtitle?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
    }
}
