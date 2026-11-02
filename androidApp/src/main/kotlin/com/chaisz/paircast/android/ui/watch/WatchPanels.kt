package com.chaisz.paircast.android.ui.watch

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.History
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.chaisz.paircast.android.app.AppState
import com.chaisz.paircast.android.app.L10n
import com.chaisz.paircast.android.app.t
import com.chaisz.paircast.core.model.Movie
import com.chaisz.paircast.core.model.StickerPack
import com.chaisz.paircast.core.model.StickerPackSummary
import com.chaisz.paircast.core.model.StickerRef
import com.chaisz.paircast.core.model.SubtitleSource
import com.chaisz.paircast.core.model.SubtitleTrack
import com.chaisz.paircast.core.rules.ChatStickerCodec
import com.chaisz.paircast.core.session.WatchSession
import com.chaisz.paircast.core.session.WatchUiState
import com.chaisz.paircast.core.support.Twemoji

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SubtitlePanel(session: WatchSession, state: WatchUiState, onDismiss: () -> Unit) {
    var query by remember { mutableStateOf(state.suggestedOnlineQuery) }
    val selectedId = state.subtitleState.trackId ?: "off"
    val groups = listOf(
        t("Embedded") to state.subtitleTracks.filter { it.source == SubtitleSource.EMBEDDED },
        t("Library sidecars") to state.subtitleTracks.filter { it.source == SubtitleSource.OSS },
        t("Online Search") to state.subtitleTracks.filter { it.source == SubtitleSource.ONLINE },
    ).filter { it.second.isNotEmpty() }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        LazyColumn(Modifier.fillMaxWidth().heightIn(max = 640.dp), contentPadding = PaddingValues(16.dp)) {
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(t("Subtitles"), style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                    if (state.isApplyingSubtitle) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                }
                Spacer(Modifier.height(8.dp))
                TrackRow(SubtitleTrack.OFF.copy(label = t("Off")), selected = selectedId == "off") {
                    session.selectTrack(SubtitleTrack.OFF)
                }
            }
            groups.forEach { (title, tracks) ->
                item { SectionLabel(title) }
                items(tracks, key = { "${title}-${it.id}" }) { track ->
                    TrackRow(track, selected = track.id == selectedId) { session.selectTrack(track) }
                }
            }
            item {
                SectionLabel(t("Online Search"))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = query,
                        onValueChange = { query = it },
                        placeholder = { Text(t("Title year")) },
                        singleLine = true,
                        modifier = Modifier.weight(1f),
                    )
                    Spacer(Modifier.width(8.dp))
                    FilledTonalButton(
                        enabled = query.isNotBlank() && !state.isSearchingOnline,
                        onClick = { session.searchOnline(query.trim()) },
                    ) { Text(t(if (state.didSearchOnline) "Search Again" else "Search")) }
                }
                when {
                    state.isSearchingOnline -> Text(t("Searching…"), Modifier.padding(vertical = 12.dp))
                    state.onlineSearchError != null -> Text(
                        "${t("Search failed")} · ${L10n.format(state.onlineSearchError!!)}",
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.padding(vertical = 12.dp),
                    )
                    state.didSearchOnline && state.onlineResults.isEmpty() -> Text(
                        "${t("No subtitles found")} · ${t("Try different keywords, or try again later")}",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(vertical = 12.dp),
                    )
                }
            }
            if (state.onlineResults.isNotEmpty()) {
                item { SectionLabel(t("Results")) }
                items(state.onlineResults, key = { "online-${it.id}" }) { track ->
                    TrackRow(track, selected = track.id == selectedId) { session.selectTrack(track) }
                }
            }
            item { Spacer(Modifier.height(24.dp)) }
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text.uppercase(),
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(top = 16.dp, bottom = 4.dp),
    )
}

@Composable
private fun TrackRow(track: SubtitleTrack, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                track.languageBadge?.takeIf { it.isNotEmpty() }?.let {
                    Text(
                        it, fontSize = 10.sp, fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier
                            .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.12f), RoundedCornerShape(4.dp))
                            .padding(horizontal = 4.dp, vertical = 1.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                }
                Text(track.label, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            track.detail?.let { Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1) }
        }
        if (selected) Icon(Icons.Filled.Check, null, tint = MaterialTheme.colorScheme.primary)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SubtitleSyncSheet(session: WatchSession, state: WatchUiState, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            Modifier.fillMaxWidth().padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(t("Subtitle Sync"), style = MaterialTheme.typography.titleLarge)
            Text(state.subtitleState.offsetLabel, style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.SemiBold)
            Text(t("Earlier · Later"), color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                FilledTonalButton(onClick = { session.adjustSubtitle(-500) }) { Text("−0.5s") }
                FilledTonalButton(onClick = { session.adjustSubtitle(-100) }) { Text("−0.1s") }
                FilledTonalButton(onClick = { session.adjustSubtitle(100) }) { Text("+0.1s") }
                FilledTonalButton(onClick = { session.adjustSubtitle(500) }) { Text("+0.5s") }
            }
            Row {
                TextButton(onClick = session::resetSubtitleOffset) { Text(t("Reset")) }
                TextButton(onClick = onDismiss) { Text(t("Done")) }
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SwitchMovieSheet(state: WatchUiState, onPick: (Movie) -> Unit, onDismiss: () -> Unit) {
    var query by remember { mutableStateOf("") }
    val movies = state.libraryMovies.filter { query.isBlank() || it.title.contains(query.trim(), ignoreCase = true) }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().heightIn(max = 640.dp).padding(horizontal = 16.dp)) {
            Text(t("Switch Movie"), style = MaterialTheme.typography.titleLarge)
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = query, onValueChange = { query = it },
                placeholder = { Text(t("Search titles")) }, singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            when {
                state.isLoadingLibraryForSwitch && state.libraryMovies.isEmpty() ->
                    Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
                        Text(t("Loading library…"))
                    }
                state.libraryMovies.isEmpty() -> Text(
                    t("Make sure your object storage bucket contains mp4/m4v/mkv files"),
                    color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(vertical = 24.dp),
                )
                movies.isEmpty() -> Text(
                    "${t("No matching movies")} · ${t("Try different keywords")}",
                    color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(vertical = 24.dp),
                )
                else -> LazyColumn(Modifier.fillMaxWidth()) {
                    items(movies, key = { it.id }) { movie ->
                        val playing = movie.id == state.movie?.id
                        Row(
                            Modifier.fillMaxWidth().clickable { onPick(movie) }.padding(vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Box(
                                Modifier.width(44.dp).aspectRatio(2f / 3f).clip(RoundedCornerShape(6.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant),
                            ) {
                                movie.posterUrl?.let { AsyncImage(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
                            }
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text(movie.title, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                val sub = listOfNotNull(movie.year, if (playing) t("Playing") else null).joinToString(" · ")
                                if (sub.isNotEmpty()) Text(sub, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            if (playing) Icon(Icons.Filled.Check, null, tint = MaterialTheme.colorScheme.primary)
                        }
                    }
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InviteSheet(session: WatchSession, state: WatchUiState, app: AppState, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val url = remember(state.room, state.movie) { session.inviteUrl() }
    val inviter = app.currentUser?.displayName.orEmpty()
    val message = t(
        "{{inviter}} invites you to watch {{title}}. Come join!",
        "inviter" to inviter, "title" to state.movie?.title.orEmpty(),
    )
    var copied by remember { mutableStateOf(false) }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(t("Invite Friends"), style = MaterialTheme.typography.titleLarge)
            Text(t("Link preview"), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(url, fontSize = 12.sp, maxLines = 3, overflow = TextOverflow.Ellipsis)
            Text(
                t("After friends open the link and sign in, they join this watch room and sync playback."),
                fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            HorizontalDivider()
            TextButton(onClick = {
                val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "$message\n$url")
                context.startActivity(Intent.createChooser(send, null))
            }) { Text(t("Share")) }
            TextButton(onClick = {
                val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.setPrimaryClip(ClipData.newPlainText("Paircast", url))
                copied = true
            }) { Text(t(if (copied) "Link copied" else "Copy Invite Link")) }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
fun StickerImage(app: AppState, ref: StickerRef, modifier: Modifier) {
    val url by produceState<String?>(null, ref.bindKey, app.config) {
        val config = app.config ?: return@produceState
        value = runCatching { app.graph.stickerCatalog.imageUrl(ref, config) }.getOrNull() ?: ref.url
    }
    Box(modifier, contentAlignment = Alignment.Center) {
        if (url != null) {
            AsyncImage(url, ChatStickerCodec.FALLBACK_TEXT, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
        } else {
            Text(t(ChatStickerCodec.FALLBACK_TEXT), color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

private const val RECENT_KEY = "paircast.stickers.recent.v2"
private const val RECENT_PAGE = "__recent__"

private fun loadRecent(context: Context): List<StickerRef> {
    val raw = context.getSharedPreferences("paircast.prefs", Context.MODE_PRIVATE).getString(RECENT_KEY, null) ?: return emptyList()
    return raw.split('\n').mapNotNull { ChatStickerCodec.decode(it) }
}

private fun saveRecent(context: Context, refs: List<StickerRef>) {
    context.getSharedPreferences("paircast.prefs", Context.MODE_PRIVATE).edit()
        .putString(RECENT_KEY, refs.joinToString("\n") { ChatStickerCodec.encodeJson(it) })
        .apply()
}

/** Emoji grid + object-storage sticker packs (`stickers/`). */
@Composable
fun EmojiStickerPanel(app: AppState, onEmoji: (String) -> Unit, onSticker: (StickerRef) -> Unit, modifier: Modifier) {
    val context = LocalContext.current
    var tab by remember { mutableStateOf(0) }
    var summaries by remember { mutableStateOf<List<StickerPackSummary>>(emptyList()) }
    var loading by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    var selectedPack by remember { mutableStateOf(RECENT_PAGE) }
    val packs = remember { mutableStateMapOf<String, StickerPack>() }
    var recent by remember { mutableStateOf(loadRecent(context)) }
    val config = app.config

    LaunchedEffect(tab, config) {
        if (tab != 1 || config == null || summaries.isNotEmpty()) return@LaunchedEffect
        loading = true
        failed = false
        summaries = runCatching { app.graph.stickerCatalog.loadCatalog(config) }.getOrElse { failed = true; emptyList() }
        loading = false
    }
    LaunchedEffect(selectedPack, config) {
        if (selectedPack == RECENT_PAGE || config == null || packs.containsKey(selectedPack)) return@LaunchedEffect
        runCatching { app.graph.stickerCatalog.loadPack(selectedPack, config) }.getOrNull()?.let { packs[selectedPack] = it }
    }

    fun send(ref: StickerRef) {
        onSticker(ref)
        recent = (listOf(ref) + recent.filter { it.bindKey != ref.bindKey }).take(24)
        saveRecent(context, recent)
    }

    Column(modifier.fillMaxWidth().height(280.dp).background(MaterialTheme.colorScheme.surface)) {
        TabRow(selectedTabIndex = tab) {
            Tab(selected = tab == 0, onClick = { tab = 0 }, text = { Text(t("Emoji")) })
            Tab(selected = tab == 1, onClick = { tab = 1 }, text = { Text(t("Stickers")) })
        }
        if (tab == 0) {
            LazyVerticalGrid(GridCells.Adaptive(44.dp), contentPadding = PaddingValues(8.dp)) {
                items(Twemoji.pickerEmojis) { emoji ->
                    Box(Modifier.size(44.dp).clickable { onEmoji(emoji) }, contentAlignment = Alignment.Center) {
                        Text(emoji, fontSize = 26.sp)
                    }
                }
            }
        } else {
            when {
                config == null -> PanelMessage(t("Finish service configuration to load stickers"))
                loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                else -> {
                    val items = if (selectedPack == RECENT_PAGE) recent else packs[selectedPack]?.stickers?.map { it.asRef() }.orEmpty()
                    Box(Modifier.weight(1f)) {
                        when {
                            summaries.isEmpty() && selectedPack != RECENT_PAGE || failed && recent.isEmpty() ->
                                PanelMessage(t("Upload sticker packs to your bucket under stickers/"))
                            items.isEmpty() -> PanelMessage(
                                t(if (selectedPack == RECENT_PAGE) "No recent stickers" else "No stickers in this pack"),
                            )
                            else -> LazyVerticalGrid(GridCells.Adaptive(72.dp), contentPadding = PaddingValues(4.dp)) {
                                items(items, key = { it.bindKey }) { ref ->
                                    StickerImage(app, ref, Modifier.size(72.dp).padding(4.dp).clickable { send(ref) })
                                }
                            }
                        }
                    }
                    LazyRow(Modifier.fillMaxWidth().padding(4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        item {
                            PackTab(selectedPack == RECENT_PAGE, { selectedPack = RECENT_PAGE }) {
                                Icon(Icons.Filled.History, t("Recent"))
                            }
                        }
                        items(summaries, key = { it.packId }) { summary ->
                            PackTab(selectedPack == summary.packId, { selectedPack = summary.packId }) {
                                val cover = summary.coverFileName
                                if (cover != null) {
                                    StickerImage(
                                        app,
                                        StickerRef(packId = summary.packId, stickerId = cover.substringBeforeLast('.'), file = cover),
                                        Modifier.size(28.dp),
                                    )
                                } else {
                                    Text(summary.name.take(2), fontSize = 12.sp)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun PackTab(selected: Boolean, onClick: () -> Unit, content: @Composable () -> Unit) {
    Box(
        Modifier
            .size(40.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(if (selected) MaterialTheme.colorScheme.surfaceVariant else MaterialTheme.colorScheme.surface)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { content() }
}

@Composable
private fun PanelMessage(text: String) {
    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
