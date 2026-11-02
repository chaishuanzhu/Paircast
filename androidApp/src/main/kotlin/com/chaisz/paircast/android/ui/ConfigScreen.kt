package com.chaisz.paircast.android.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.MenuBook
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.chaisz.paircast.android.app.AppState
import com.chaisz.paircast.android.app.L10n
import com.chaisz.paircast.android.app.t
import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.IMConfig
import com.chaisz.paircast.core.rules.ConfigQRCodec
import kotlinx.coroutines.launch

private class ConfigForm(config: AppCloudConfig?) {
    var serverUrl by mutableStateOf("")

    init {
        config?.let(::apply)
    }

    fun apply(config: AppCloudConfig) {
        if (config.im.serverUrl.isNotEmpty()) serverUrl = config.im.serverUrl
    }

    fun draft() = AppCloudConfig(im = IMConfig(serverUrl))
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConfigScreen(app: AppState, fromLogin: Boolean) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val form = remember { ConfigForm(app.config) }
    var formEpoch by remember { mutableIntStateOf(0) }
    var status by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    var shareUrl by remember { mutableStateOf<String?>(null) }
    var showPaste by remember { mutableStateOf(false) }
    var showScanner by remember { mutableStateOf(false) }
    var pendingImport by remember { mutableStateOf<AppCloudConfig?>(null) }

    fun close() = if (fromLogin) app.resetToLogin() else app.popLibrary()
    BackHandler(enabled = fromLogin) { close() }

    fun prepareImport(raw: String) {
        try {
            pendingImport = app.graph.configLinkCodec.decode(raw.trim())
            showPaste = false
        } catch (e: Exception) {
            status = L10n.message(e, AppError.InvalidConfigQR)
        }
    }

    LaunchedEffect(Unit) { app.consumePendingConfigImport()?.let(::prepareImport) }

    fun save() = scope.launch {
        saving = true
        try {
            val previousServer = app.config?.im?.serverUrl
            val stored = app.graph.saveConfig(form.draft())
            if (app.currentUser != null && previousServer != stored.im.serverUrl) {
                app.applyImportedConfig(stored)
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

    fun confirmExport() = scope.launch {
        try {
            val stored = app.graph.saveConfig(form.draft())
            app.config = stored
            shareUrl = app.graph.configLinkCodec.shareUrl(stored)
            status = t("Configuration link generated")
        } catch (e: Exception) {
            status = L10n.message(e, AppError.InvalidConfigQR)
        }
    }

    fun confirmImport(config: AppCloudConfig) = scope.launch {
        pendingImport = null
        var incoming = config
        if (ConfigQRCodec.needsServerUrl(incoming)) {
            val server = form.serverUrl.trim()
            if (server.isEmpty()) {
                status = t("This link has no IM server address. Enter it, then Save")
                return@launch
            }
            incoming = incoming.copy(im = IMConfig(server))
        }
        try {
            val saved = app.graph.saveConfig(incoming)
            form.apply(saved)
            formEpoch++
            if (ConfigQRCodec.isLegacy(config)) app.showToast(t("Storage settings in this link were ignored — the media library is now configured on the server"))
            app.applyImportedConfig(saved)
        } catch (e: Exception) {
            status = L10n.message(e, AppError.InvalidConfigQR)
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
        androidx.compose.runtime.key(formEpoch) {
            Column(
                Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .imePadding()
                    .verticalScroll(rememberScrollState())
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                SectionCard(footer = t("Where to get the IM server address and how to use Paircast")) {
                    ActionRow(Icons.Filled.MenuBook, t("Configuration Guide"), null) {
                        val lang = if (L10n.useChinese) "zh-Hans" else "en-US"
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://paircast.chaisz.com/$lang/guide/")))
                    }
                }

                SectionCard(title = t("Share & Import"), footer = t("Links contain only the IM server address; friends still sign in with their own account")) {
                    ActionRow(Icons.Filled.ContentPaste, t("Paste to Import"), t("Paste a paircast://config?args=… link")) { showPaste = true }
                    HorizontalDivider()
                    ActionRow(Icons.Filled.QrCodeScanner, t("Scan QR Code"), null) { showScanner = true }
                    HorizontalDivider()
                    ActionRow(Icons.Filled.Share, t("Share Configuration"), t("Generate an encrypted link to copy or share with friends")) {
                        confirmExport()
                    }
                }

                SectionCard(title = t("IM Server"), footer = t("Your self-hosted GO-IM address. HTTPS is assumed unless you enter http:// (LAN only).")) {
                    PaircastField(t("Address"), form.serverUrl, { form.serverUrl = it }, keyboardType = KeyboardType.Uri, placeholder = "im.example.com")
                }

                SectionCard(footer = t("Videos, subtitles, posters and stickers come from the media library your GO-IM admin configures on the server.")) {
                    Text(t("Media Library"), fontWeight = FontWeight.SemiBold)
                    Text(t("Managed by the server"), color = MaterialTheme.colorScheme.onSurfaceVariant)
                }

                status?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                Spacer(Modifier.height(24.dp))
            }
        }
    }

    shareUrl?.let { url -> ShareConfigDialog(url) { shareUrl = null } }
    if (showPaste) PasteImportDialog(onCancel = { showPaste = false }, onContinue = ::prepareImport)
    if (showScanner) {
        QrScannerDialog(
            onResult = { showScanner = false; prepareImport(it) },
            onDismiss = { showScanner = false },
        )
    }
    pendingImport?.let { config ->
        ImportConfirmDialog(config, onCancel = { pendingImport = null }, onConfirm = { confirmImport(config) })
    }
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

@Composable
private fun ShareConfigDialog(url: String, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val qr = remember(url) { QrCodes.bitmap(url, 640) }
    var copied by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(t("Send to a friend to import")) },
        text = {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    t("They can open the link or paste it into Service Configuration to apply the same environment"),
                    style = MaterialTheme.typography.bodySmall,
                )
                qr?.let { Image(it.asImageBitmap(), contentDescription = null, modifier = Modifier.size(200.dp)) }
                Text(url, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall, maxLines = 4)
            }
        },
        confirmButton = {
            TextButton(onClick = {
                val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.setPrimaryClip(ClipData.newPlainText("Paircast", url))
                copied = true
            }) { Text(t(if (copied) "Link copied" else "Copy Link")) }
        },
        dismissButton = {
            TextButton(onClick = {
                val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, url)
                context.startActivity(Intent.createChooser(send, null))
            }) { Text(t("System Share")) }
        },
    )
}

@Composable
private fun PasteImportDialog(onCancel: () -> Unit, onContinue: (String) -> Unit) {
    val context = LocalContext.current
    var text by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text(t("Paste configuration link")) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    t("Supports a full deep link, or a paircast://config?args=… link found in a chat message"),
                    style = MaterialTheme.typography.bodySmall,
                )
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it },
                    placeholder = { Text("paircast://config?args=…") },
                    modifier = Modifier.fillMaxWidth().heightIn(min = 120.dp),
                )
                TextButton(onClick = {
                    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    clipboard.primaryClip?.getItemAt(0)?.coerceToText(context)?.toString()?.let { text = it }
                }) { Text(t("Paste from Clipboard")) }
            }
        },
        confirmButton = { TextButton(enabled = text.isNotBlank(), onClick = { onContinue(text) }) { Text(t("Continue")) } },
        dismissButton = { TextButton(onClick = onCancel) { Text(t("Cancel")) } },
    )
}

@Composable
private fun ImportConfirmDialog(config: AppCloudConfig, onCancel: () -> Unit, onConfirm: () -> Unit) {
    val rows = listOf(t("IM Server") to if (config.im.isComplete) config.im.maskedSummary else t("Not included — enter it in the form"))
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text(t("Confirm Import")) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(t("This will overwrite your local cloud service configuration"), color = MaterialTheme.colorScheme.error)
                if (ConfigQRCodec.isLegacy(config)) {
                    Text(
                        t("This link is from an older version. Its storage settings will be ignored — the media library is now configured on the server"),
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                rows.forEach { (label, value) ->
                    Row(Modifier.fillMaxWidth()) {
                        Text(label, Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(value, fontWeight = FontWeight.Medium)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onConfirm) { Text(t("Confirm Import & Overwrite")) } },
        dismissButton = { TextButton(onClick = onCancel) { Text(t("Cancel")) } },
    )
}