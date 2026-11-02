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
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
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
import com.chaisz.paircast.core.model.ObjectStorageConfig
import com.chaisz.paircast.core.model.ObjectStorageProvider
import com.chaisz.paircast.core.rules.ConfigQRCodec
import kotlinx.coroutines.launch

private class ConfigForm(config: AppCloudConfig?) {
    var serverUrl by mutableStateOf("")
    var provider by mutableStateOf(ObjectStorageProvider.QINIU)
    var accessKey by mutableStateOf("")
    var secretKey by mutableStateOf("")
    var bucket by mutableStateOf("")
    var endpoint by mutableStateOf("")
    var region by mutableStateOf("")
    var prefix by mutableStateOf("")
    var useSSL by mutableStateOf(true)
    var forcePathStyle by mutableStateOf(true)
    var subtitleApiKey by mutableStateOf("")
    var tmdbAccessToken by mutableStateOf("")

    init {
        config?.let(::apply)
    }

    fun apply(config: AppCloudConfig) {
        if (config.im.serverUrl.isNotEmpty()) serverUrl = config.im.serverUrl
        val s = config.storage
        provider = s.provider
        accessKey = s.accessKey
        secretKey = s.secretKey
        bucket = s.bucket
        endpoint = s.endpoint
        region = s.region.orEmpty()
        prefix = s.prefix.orEmpty()
        useSSL = s.useSSL
        forcePathStyle = s.forcePathStyle
        subtitleApiKey = config.subtitleApiKey.orEmpty()
        tmdbAccessToken = config.tmdbAccessToken.orEmpty()
    }

    fun selectProvider(next: ObjectStorageProvider) {
        if (next == provider) return
        provider = next
        useSSL = next.defaultUseSSL
        forcePathStyle = next.defaultForcePathStyle
        if (region.isBlank()) next.defaultRegion?.let { region = it }
    }

    fun draft() = AppCloudConfig(
        im = IMConfig(serverUrl),
        storage = ObjectStorageConfig(
            provider = provider,
            accessKey = accessKey,
            secretKey = secretKey,
            bucket = bucket,
            endpoint = endpoint,
            region = region.ifEmpty { null },
            prefix = prefix.ifEmpty { null },
            useSSL = useSSL,
            forcePathStyle = forcePathStyle,
        ),
        subtitleApiKey = subtitleApiKey.ifEmpty { null },
        tmdbAccessToken = tmdbAccessToken.ifEmpty { null },
    )
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
    var showExportRisk by remember { mutableStateOf(false) }
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
            status = t("Configuration link generated (contains secrets — do not share publicly)")
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
                form.apply(incoming)
                formEpoch++
                status = t("Imported storage settings. Enter the IM server address, then Save")
                return@launch
            }
            incoming = incoming.copy(im = IMConfig(server))
        }
        try {
            val saved = app.graph.saveConfig(incoming)
            form.apply(saved)
            formEpoch++
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
                SectionCard(footer = t("Where to get the IM server address, storage keys, Endpoint, and how to use Paircast")) {
                    ActionRow(Icons.Filled.MenuBook, t("Configuration Guide"), null) {
                        val lang = if (L10n.useChinese) "zh-Hans" else "en-US"
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://paircast.chaisz.com/$lang/guide/")))
                    }
                }

                SectionCard(title = t("Share & Import"), footer = t("Links contain secrets — share only with trusted friends")) {
                    ActionRow(Icons.Filled.ContentPaste, t("Paste to Import"), t("Paste a paircast://config?args=… link")) { showPaste = true }
                    HorizontalDivider()
                    ActionRow(Icons.Filled.QrCodeScanner, t("Scan QR Code"), null) { showScanner = true }
                    HorizontalDivider()
                    ActionRow(Icons.Filled.Share, t("Share Configuration"), t("Generate an encrypted link to copy or share with friends")) {
                        showExportRisk = true
                    }
                }

                SectionCard(title = t("IM Server"), footer = t("Your self-hosted GO-IM address. HTTPS is assumed unless you enter http:// (LAN only).")) {
                    PaircastField(t("Address"), form.serverUrl, { form.serverUrl = it }, keyboardType = KeyboardType.Uri, placeholder = "im.example.com")
                }

                SectionCard(title = t("Object Storage"), footer = t(storageFooter(form.provider))) {
                    ProviderPicker(form.provider, form::selectProvider)
                    PaircastField("AccessKey", form.accessKey, { form.accessKey = it }, secure = true)
                    PaircastField("SecretKey", form.secretKey, { form.secretKey = it }, secure = true)
                    PaircastField("Bucket", form.bucket, { form.bucket = it })
                    PaircastField(
                        t("Endpoint ({{example}})", "example" to form.provider.endpointPlaceholder),
                        form.endpoint, { form.endpoint = it }, keyboardType = KeyboardType.Uri,
                    )
                    PaircastField(
                        t("Region (optional, {{example}})", "example" to form.provider.regionPlaceholder),
                        form.region, { form.region = it },
                    )
                    PaircastField(t("Prefix (optional)"), form.prefix, { form.prefix = it })
                    SwitchRow("HTTPS", form.useSSL) { form.useSSL = it }
                    SwitchRow("Path-Style URL", form.forcePathStyle) { form.forcePathStyle = it }
                }

                SectionCard(
                    title = t("Extensions"),
                    footer = t("With your TMDB token, Paircast uses filenames to fetch localized titles, posters, backdrops, and overviews. This product uses the TMDB API but is not endorsed or certified by TMDB."),
                ) {
                    PaircastField("OpenSubtitles API Key", form.subtitleApiKey, { form.subtitleApiKey = it }, secure = true)
                    PaircastField("TMDB API Read Access Token", form.tmdbAccessToken, { form.tmdbAccessToken = it }, secure = true)
                }

                status?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                Spacer(Modifier.height(24.dp))
            }
        }
    }

    if (showExportRisk) {
        AlertDialog(
            onDismissRequest = { showExportRisk = false },
            title = { Text(t("Sharing includes secrets — do not post publicly")) },
            text = { Text(t("The link includes the IM server address and object storage credentials. Share only with trusted friends.")) },
            confirmButton = { TextButton(onClick = { showExportRisk = false; confirmExport() }) { Text(t("Continue Sharing")) } },
            dismissButton = { TextButton(onClick = { showExportRisk = false }) { Text(t("Cancel")) } },
        )
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

private fun storageFooter(provider: ObjectStorageProvider): String = when (provider) {
    ObjectStorageProvider.QINIU -> "Use a Qiniu S3 endpoint (e.g. s3.cn-south-1.qiniucs.com). Do not use a CDN or custom domain as Endpoint."
    ObjectStorageProvider.ALIYUN_OSS -> "Use an OSS regional endpoint (e.g. oss-cn-hangzhou.aliyuncs.com). Region can be left blank and inferred from Endpoint."
    ObjectStorageProvider.TENCENT_COS -> "Use a COS regional endpoint (e.g. cos.ap-guangzhou.myqcloud.com). Region can be left blank and inferred from Endpoint."
    ObjectStorageProvider.MINIO -> "Use host:port (e.g. 192.168.1.10:9000). Self-hosted MinIO usually disables HTTPS and enables Path-Style; Region defaults to us-east-1."
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
private fun SwitchRow(title: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@Composable
private fun ProviderPicker(selected: ObjectStorageProvider, onSelect: (ObjectStorageProvider) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth().clickable { open = true }.padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(t("Provider"), Modifier.weight(1f))
        Text(t(selected.displayName), color = MaterialTheme.colorScheme.primary)
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            ObjectStorageProvider.entries.forEach { provider ->
                DropdownMenuItem(text = { Text(t(provider.displayName)) }, onClick = { open = false; onSelect(provider) })
            }
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
                Text(
                    t("Link contains secrets — do not post to public groups or social media"),
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                )
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
    val rows = buildList {
        add(t("IM Server") to if (config.im.isComplete) config.im.maskedSummary else t("Not included — enter it in the form"))
        add(t("Provider") to t(config.storage.provider.displayName))
        add("AccessKey" to ConfigQRCodec.maskedAccessKey(config.storage.accessKey))
        add("Bucket" to config.storage.bucket)
        add("Endpoint" to ConfigQRCodec.truncate(config.storage.endpoint, 22))
        add(t("Region") to (config.storage.region ?: config.storage.signingRegion))
    }
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text(t("Confirm Import")) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(t("This will overwrite your local cloud service configuration"), color = MaterialTheme.colorScheme.error)
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