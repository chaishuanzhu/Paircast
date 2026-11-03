package com.chaisz.paircast.android.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.chaisz.paircast.android.app.AppState
import com.chaisz.paircast.android.app.L10n
import com.chaisz.paircast.android.app.t
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.MediaSource
import com.chaisz.paircast.core.model.Movie
import com.chaisz.paircast.core.rules.LegalRules
import com.chaisz.paircast.core.rules.ProfileRules
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryScreen(app: AppState) {
    val scope = rememberCoroutineScope()
    var movies by remember { mutableStateOf<List<Movie>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var refreshing by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var creatingFor by remember { mutableStateOf<String?>(null) }
    var showMe by remember { mutableStateOf(false) }
    var sources by remember { mutableStateOf<List<MediaSource>>(emptyList()) }
    var sourceId by remember { mutableStateOf<String?>(null) }

    suspend fun load() {
        error = null
        try {
            if (sources.isEmpty()) sources = runCatching { app.graph.listMovies.sources() }.getOrDefault(emptyList())
            val listed = app.graph.listMovies(enrichMetadata = false, sourceId = sourceId)
            movies = listed
            loading = false
            val config = app.config ?: return
            movies = app.graph.listMovies.enrich(listed, config)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = L10n.message(e, AppError.CatalogUnauthorized)
        } finally {
            loading = false
        }
    }

    LaunchedEffect(app.config, sourceId) { load() }

    fun open(movie: Movie) {
        val user = app.currentUser ?: return
        if (creatingFor != null) return
        scope.launch {
            creatingFor = movie.id
            try {
                val room = app.graph.roomGateway.createRoom(movie.id, user.id)
                app.openWatch(room.id, room.movieId, room.hostUserId)
            } catch (e: Exception) {
                app.showToast(L10n.message(e, AppError.RoomNotFound))
            } finally {
                creatingFor = null
            }
        }
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(t("Library"), fontWeight = FontWeight.Bold) },
                actions = {
                    val user = app.currentUser
                    IconButton(onClick = { showMe = true }) {
                        Avatar(user?.displayName.orEmpty(), user?.avatarUrl, 32.dp)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
        if (sources.size > 1) {
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                sources.forEach { source ->
                    FilterChip(
                        selected = (sourceId ?: sources.first().id) == source.id,
                        onClick = { if (sourceId != source.id) { loading = true; sourceId = source.id } },
                        label = { Text(source.name) },
                    )
                }
            }
        }
        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = {
                scope.launch {
                    refreshing = true
                    load()
                    refreshing = false
                }
            },
            modifier = Modifier.fillMaxSize(),
        ) {
            when {
                loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                error != null && movies.isEmpty() -> EmptyState(error!!, t("Retry")) { scope.launch { loading = true; load() } }
                movies.isEmpty() -> EmptyState(t("No videos yet. Ask your admin to add MP4/MKV files to the server media library"), null, null)
                else -> LazyVerticalGrid(
                    columns = GridCells.Adaptive(150.dp),
                    contentPadding = PaddingValues(16.dp),
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                    verticalArrangement = Arrangement.spacedBy(18.dp),
                ) {
                    items(movies, key = { it.id }) { movie ->
                        MovieCard(movie, busy = creatingFor == movie.id) { open(movie) }
                    }
                }
            }
        }
        }
    }

    if (showMe) MeSheet(app) { showMe = false }
}

@Composable
private fun EmptyState(message: String, action: String?, onAction: (() -> Unit)?) {
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Spacer(Modifier.height(120.dp))
        Icon(Icons.Filled.Movie, contentDescription = null, tint = MaterialTheme.colorScheme.outline)
        Spacer(Modifier.height(12.dp))
        Text(message, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (action != null && onAction != null) TextButton(onClick = onAction) { Text(action) }
    }
}

@Composable
private fun MovieCard(movie: Movie, busy: Boolean, onClick: () -> Unit) {
    Column(Modifier.clickable(enabled = !busy, onClick = onClick)) {
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(2f / 3f)
                .clip(RoundedCornerShape(12.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant),
            contentAlignment = Alignment.Center,
        ) {
            Text(movie.title.take(1), style = MaterialTheme.typography.headlineMedium, color = MaterialTheme.colorScheme.outline)
            if (movie.posterUrl != null) {
                AsyncImage(movie.posterUrl, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            }
            if (busy) {
                Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.4f)), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = Color.White)
                }
            }
        }
        Spacer(Modifier.height(6.dp))
        Text(movie.title, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
        movie.year?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MeSheet(app: AppState, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val uriHandler = LocalUriHandler.current
    val scope = rememberCoroutineScope()
    val user = app.currentUser
    var nickname by remember { mutableStateOf(user?.nickname.orEmpty()) }
    var avatarJpeg by remember { mutableStateOf<ByteArray?>(null) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var showChangePassword by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var showAddUser by remember { mutableStateOf(false) }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            avatarJpeg = withContext(Dispatchers.IO) { runCatching { compressAvatar(context, uri) }.getOrNull() }
            if (avatarJpeg == null) error = L10n.format(AppError.AvatarUploadFailed)
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.clickable {
                    picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                }) {
                    if (avatarJpeg != null) {
                        AsyncImage(
                            avatarJpeg, null,
                            Modifier.width(64.dp).height(64.dp).clip(RoundedCornerShape(32.dp)),
                            contentScale = ContentScale.Crop,
                        )
                    } else {
                        Avatar(nickname.ifBlank { user?.displayName.orEmpty() }, user?.avatarUrl, 64.dp)
                    }
                }
                Spacer(Modifier.width(14.dp))
                Column {
                    Text(user?.displayName.orEmpty(), fontWeight = FontWeight.SemiBold)
                    user?.username?.let {
                        Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Text(t("Tap avatar to change"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.outline)
                }
            }
            PaircastField(t("Nickname"), nickname, { nickname = it.take(ProfileRules.NICKNAME_MAX_LENGTH) })
            error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            PrimaryButton(
                t("Save"),
                onClick = {
                    scope.launch {
                        saving = true
                        error = null
                        try {
                            app.currentUser = app.graph.updateProfile(nickname, avatarJpeg)
                            avatarJpeg = null
                            app.showToast(t("Saved"))
                        } catch (e: Exception) {
                            error = L10n.message(e, AppError.AvatarUploadFailed)
                        } finally {
                            saving = false
                        }
                    }
                },
                loading = saving,
                enabled = nickname.isNotBlank() && (nickname != user?.nickname || avatarJpeg != null),
            )
            HorizontalDivider()
            SheetRow(t("Change Password")) { showChangePassword = true }
            SheetRow(t("Service Configuration")) { onDismiss(); app.openConfig(fromLogin = false) }
            if (user?.isAdmin == true) {
                SheetRow(t("Reports")) { onDismiss(); app.openReports() }
                SheetRow(t("Add User")) { showAddUser = true }
            }
            SheetRow(t("Terms of Service")) { uriHandler.openUri(LegalRules.termsUrl(L10n.useChinese)) }
            SheetRow(t("Privacy Policy")) { uriHandler.openUri(LegalRules.privacyUrl(L10n.useChinese)) }
            SheetRow(t("Sign Out")) { onDismiss(); scope.launch { app.logout() } }
            SheetRow(t("Delete Account"), destructive = true) { confirmDelete = true }
            Spacer(Modifier.height(24.dp))
        }
    }

    if (showChangePassword) ChangePasswordDialog(app, forced = false) { showChangePassword = false }
    if (confirmDelete) DeleteAccountDialog(app, onDismiss = { confirmDelete = false }, onDeleted = onDismiss)
    if (showAddUser) AddUserDialog(app) { showAddUser = false }
}

/** Permanent server-side deletion; the password is re-checked by the server. */
@Composable
private fun DeleteAccountDialog(app: AppState, onDismiss: () -> Unit, onDeleted: () -> Unit) {
    val scope = rememberCoroutineScope()
    var password by remember { mutableStateOf("") }
    var deleting by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(
        onDismissRequest = { if (!deleting) onDismiss() },
        title = { Text(t("Delete account?")) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(t("Your account and profile are permanently deleted from the server, and this device's config and caches are cleared. This can't be undone."))
                PaircastField(t("Current password"), password, { password = it }, secure = true)
                error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !deleting && password.isNotEmpty(),
                onClick = {
                    scope.launch {
                        deleting = true
                        error = null
                        try {
                            app.deleteAccount(password)
                            onDismiss()
                            onDeleted()
                        } catch (e: Exception) {
                            error = L10n.message(e, AppError.AccountDeletionFailed)
                        } finally {
                            deleting = false
                        }
                    }
                },
            ) { Text(t("Delete Account"), color = MaterialTheme.colorScheme.error) }
        },
        dismissButton = { TextButton(enabled = !deleting, onClick = onDismiss) { Text(t("Cancel")) } },
    )
}

@Composable
private fun SheetRow(title: String, destructive: Boolean = false, onClick: () -> Unit) {
    Text(
        title,
        color = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 12.dp),
    )
}

/** Square-ish JPEG ≤ [ProfileRules.AVATAR_MAX_BYTES], longest side ≤ 512 px. */
private fun compressAvatar(context: Context, uri: Uri): ByteArray {
    val resolver = context.contentResolver
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    resolver.openInputStream(uri).use { BitmapFactory.decodeStream(it, null, bounds) }
    var sample = 1
    while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= 512) sample *= 2
    val decoded = resolver.openInputStream(uri).use {
        BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
    } ?: error("decode failed")
    val longest = maxOf(decoded.width, decoded.height)
    val bitmap = if (longest > 512) {
        val scale = 512f / longest
        Bitmap.createScaledBitmap(decoded, (decoded.width * scale).toInt(), (decoded.height * scale).toInt(), true)
    } else decoded
    var quality = 90
    while (true) {
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
        if (out.size() <= ProfileRules.AVATAR_MAX_BYTES || quality <= 30) return out.toByteArray()
        quality -= 15
    }
}
