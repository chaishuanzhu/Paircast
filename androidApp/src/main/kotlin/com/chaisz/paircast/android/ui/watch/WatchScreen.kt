package com.chaisz.paircast.android.ui.watch

import android.app.Activity
import android.content.pm.ActivityInfo
import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
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
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ClosedCaption
import androidx.compose.material.icons.filled.EmojiEmotions
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.FullscreenExit
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import coil3.compose.AsyncImage
import com.chaisz.paircast.android.app.AppState
import com.chaisz.paircast.android.app.L10n
import com.chaisz.paircast.android.app.t
import com.chaisz.paircast.android.player.VlcPlayer
import com.chaisz.paircast.android.ui.Avatar
import com.chaisz.paircast.android.ui.formatPlaybackTime
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.ChatMessage
import com.chaisz.paircast.core.model.ChatMessageKind
import com.chaisz.paircast.core.model.Movie
import com.chaisz.paircast.core.session.WatchEvent
import com.chaisz.paircast.core.session.WatchSession
import com.chaisz.paircast.core.session.WatchUiState
import kotlinx.coroutines.delay
import org.videolan.libvlc.util.VLCVideoLayout

@Composable
fun WatchScreen(app: AppState, roomId: String?, movieId: String?, hostUserId: String?) {
    val context = LocalContext.current
    val activity = context as? Activity
    val player = remember { VlcPlayer(context) }
    val session = remember { app.graph.watchSession(player, roomId, movieId, hostUserId) }
    val state by session.state.collectAsState()

    var fullscreen by remember { mutableStateOf(false) }
    var showSubtitles by remember { mutableStateOf(false) }
    var showSync by remember { mutableStateOf(false) }
    var showSwitch by remember { mutableStateOf(false) }
    var switchTarget by remember { mutableStateOf<Movie?>(null) }
    var showInvite by remember { mutableStateOf(false) }

    DisposableEffect(Unit) {
        session.start()
        activity?.window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose {
            session.close()
            player.release()
            activity?.window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            activity?.let { setFullscreen(it, false) }
        }
    }
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) { session.onBackground() }
    LifecycleEventEffect(Lifecycle.Event.ON_START) { session.onForeground() }
    LaunchedEffect(session) {
        session.events.collect { event ->
            when (event) {
                is WatchEvent.Toast -> app.showToast(L10n.format(event.text))
                WatchEvent.Left -> app.popLibraryToRoot()
            }
        }
    }
    LaunchedEffect(fullscreen) { activity?.let { setFullscreen(it, fullscreen) } }

    fun leave() {
        if (state.room == null) {
            session.stop()
            app.popLibraryToRoot()
        } else {
            session.leave()
        }
    }

    fun requestSwitch(movie: Movie) {
        when {
            !state.isHost -> app.showToast(L10n.format(AppError.OnlyHostCanSwitchMovie))
            movie.id == state.movie?.id -> app.showToast(t("Already playing"))
            else -> {
                showSwitch = false
                switchTarget = movie
            }
        }
    }

    BackHandler {
        if (fullscreen) fullscreen = false else leave()
    }

    if (fullscreen) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            PlayerStage(
                player, state, fullscreen = true, modifier = Modifier.fillMaxSize(),
                onBack = { fullscreen = false },
                onToggleFullscreen = { fullscreen = false },
                onTogglePlay = session::togglePlay,
                onSeek = session::seekToProgress,
                onSwitch = { requestSwitchSheet(state, app) { showSwitch = true; session.loadLibraryForSwitch() } },
                onSubtitles = { showSubtitles = true; session.refreshSubtitles() },
                onSync = { showSync = true },
            )
        }
    } else {
        Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).statusBarsPadding()) {
            PlayerStage(
                player, state, fullscreen = false,
                modifier = Modifier.fillMaxWidth().aspectRatio(16f / 9f),
                onBack = ::leave,
                onToggleFullscreen = { fullscreen = true },
                onTogglePlay = session::togglePlay,
                onSeek = session::seekToProgress,
                onSwitch = { requestSwitchSheet(state, app) { showSwitch = true; session.loadLibraryForSwitch() } },
                onSubtitles = { showSubtitles = true; session.refreshSubtitles() },
                onSync = { showSync = true },
            )
            MembersBar(state, session) { showInvite = true }
            ChatArea(app, session, state, Modifier.weight(1f))
        }
    }

    if (showSubtitles) SubtitlePanel(session, state) { showSubtitles = false }
    if (showSync) SubtitleSyncSheet(session, state) { showSync = false }
    if (showSwitch) SwitchMovieSheet(state, onPick = ::requestSwitch) { showSwitch = false }
    if (showInvite) InviteSheet(session, state, app) { showInvite = false }
    switchTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { switchTarget = null },
            title = { Text(t("Switch to “{{title}}”?", "title" to target.title)) },
            text = { Text(t("Playback will restart from the beginning. Everyone syncs to the new movie.")) },
            confirmButton = {
                TextButton(onClick = { switchTarget = null; session.confirmSwitch(target) }) { Text(t("Switch")) }
            },
            dismissButton = { TextButton(onClick = { switchTarget = null }) { Text(t("Cancel")) } },
        )
    }
}

private fun requestSwitchSheet(state: WatchUiState, app: AppState, open: () -> Unit) {
    if (state.isHost) open() else app.showToast(L10n.format(AppError.OnlyHostCanSwitchMovie))
}

private fun setFullscreen(activity: Activity, on: Boolean) {
    activity.requestedOrientation = if (on) {
        ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
    } else {
        ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    }
    val controller = WindowCompat.getInsetsController(activity.window, activity.window.decorView)
    if (on) {
        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        controller.hide(WindowInsetsCompat.Type.systemBars())
    } else {
        controller.show(WindowInsetsCompat.Type.systemBars())
    }
}

@Composable
private fun PlayerStage(
    player: VlcPlayer,
    state: WatchUiState,
    fullscreen: Boolean,
    modifier: Modifier,
    onBack: () -> Unit,
    onToggleFullscreen: () -> Unit,
    onTogglePlay: () -> Unit,
    onSeek: (Double) -> Unit,
    onSwitch: () -> Unit,
    onSubtitles: () -> Unit,
    onSync: () -> Unit,
) {
    val paused by player.paused.collectAsState()
    val position by player.position.collectAsState()
    val duration by player.duration.collectAsState()
    val buffering by player.buffering.collectAsState()
    var chromeVisible by remember { mutableStateOf(true) }
    var interaction by remember { mutableStateOf(0) }
    var scrubbing by remember { mutableStateOf(false) }
    var scrubValue by remember { mutableFloatStateOf(0f) }
    var menuOpen by remember { mutableStateOf(false) }

    LaunchedEffect(chromeVisible, interaction, paused) {
        if (chromeVisible && !paused && !menuOpen) {
            delay(3_500)
            chromeVisible = false
        }
    }

    Box(
        modifier
            .background(Color.Black)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {
                chromeVisible = !chromeVisible
                interaction++
            },
    ) {
        AndroidView(
            factory = { ctx -> VLCVideoLayout(ctx).also { player.attach(it) } },
            onRelease = { player.detach(it) },
            modifier = Modifier.fillMaxSize(),
        )
        if (!player.hasStartedPlayback && paused) {
            state.movie?.let { movie ->
                val art = movie.backdropUrl ?: movie.posterUrl
                if (art != null) {
                    AsyncImage(art, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop, alpha = 0.55f)
                }
            }
        }
        if (buffering && !paused) {
            Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                CircularProgressIndicator(color = Color.White)
                Text(t("Buffering…"), color = Color.White, fontSize = 13.sp)
            }
        }
        state.error?.let {
            Text(
                L10n.format(it),
                color = Color.White,
                modifier = Modifier.align(Alignment.Center).background(Color.Black.copy(alpha = 0.6f), RoundedCornerShape(8.dp)).padding(12.dp),
            )
        }

        AnimatedVisibility(chromeVisible, enter = fadeIn(), exit = fadeOut(), modifier = Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.3f))) {
                Row(
                    Modifier.fillMaxWidth().align(Alignment.TopStart).padding(4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, t("Back"), tint = Color.White)
                    }
                    Column(Modifier.weight(1f)) {
                        Text(
                            state.movie?.title ?: t("Movie"),
                            color = Color.White, fontWeight = FontWeight.SemiBold,
                            maxLines = 1, overflow = TextOverflow.Ellipsis,
                        )
                        if (state.subtitleState.offsetMs != 0) {
                            Text(
                                t("Subtitles {{offset}}", "offset" to state.subtitleState.offsetLabel),
                                color = Color.White.copy(alpha = 0.8f), fontSize = 11.sp,
                            )
                        }
                    }
                    TextButton(onClick = onSwitch) { Text(t("Switch"), color = Color.White) }
                    Box {
                        IconButton(onClick = { menuOpen = true }) { Icon(Icons.Filled.MoreVert, t("More"), tint = Color.White) }
                        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                            DropdownMenuItem(text = { Text(t("Subtitles")) }, onClick = { menuOpen = false; onSubtitles() })
                            DropdownMenuItem(text = { Text(t("Subtitle Sync")) }, onClick = { menuOpen = false; onSync() })
                        }
                    }
                }

                Column(Modifier.fillMaxWidth().align(Alignment.BottomStart).padding(horizontal = 8.dp, vertical = 4.dp)) {
                    val progress = if (duration > 0) (position.toFloat() / duration).coerceIn(0f, 1f) else 0f
                    Slider(
                        value = if (scrubbing) scrubValue else progress,
                        onValueChange = {
                            scrubbing = true
                            scrubValue = it
                            interaction++
                        },
                        onValueChangeFinished = {
                            scrubbing = false
                            onSeek(scrubValue.toDouble())
                        },
                        enabled = state.isHost && duration > 0,
                        colors = SliderDefaults.colors(
                            thumbColor = Color.White,
                            activeTrackColor = Color.White,
                            inactiveTrackColor = Color.White.copy(alpha = 0.3f),
                            disabledThumbColor = Color.White.copy(alpha = 0.7f),
                            disabledActiveTrackColor = Color.White.copy(alpha = 0.7f),
                        ),
                        modifier = Modifier.height(24.dp),
                    )
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        IconButton(onClick = { onTogglePlay(); interaction++ }, enabled = state.isHost) {
                            Icon(
                                if (paused) Icons.Filled.PlayArrow else Icons.Filled.Pause,
                                contentDescription = null,
                                tint = if (state.isHost) Color.White else Color.White.copy(alpha = 0.5f),
                            )
                        }
                        IconButton(onClick = onSubtitles) { Icon(Icons.Filled.ClosedCaption, t("Subtitles"), tint = Color.White) }
                        val shown = if (scrubbing) (scrubValue * duration).toLong() else position
                        Text(
                            "${formatPlaybackTime(shown)} / ${formatPlaybackTime(duration)}",
                            color = Color.White, fontSize = 12.sp, modifier = Modifier.weight(1f),
                        )
                        IconButton(onClick = onToggleFullscreen) {
                            Icon(
                                if (fullscreen) Icons.Filled.FullscreenExit else Icons.Filled.Fullscreen,
                                t(if (fullscreen) "Exit fullscreen" else "Fullscreen"),
                                tint = Color.White,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MembersBar(state: WatchUiState, session: WatchSession, onInvite: () -> Unit) {
    val members = state.room?.memberIds.orEmpty()
    var tick by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(1_000)
            tick++
        }
    }
    Column(
        Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row {
            Text(
                t("{{count}} watching", "count" to members.size.toString()),
                fontSize = 13.sp, fontWeight = FontWeight.Medium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.weight(1f))
            Text(
                t(if (state.isHost) "You are the host — you control playback" else "Following the host"),
                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1,
            )
        }
        LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            items(members, key = { it }) { id ->
                val progress = remember(tick, id) { session.memberPlaybackProgress(id).toFloat() }
                MemberAvatar(
                    name = state.memberDisplayName(id),
                    url = state.memberAvatarUrl(id),
                    isHost = id == state.room?.hostUserId,
                    progress = progress,
                )
            }
            item {
                Box(
                    Modifier
                        .size(44.dp)
                        .clip(CircleShape)
                        .border(1.5.dp, MaterialTheme.colorScheme.outline, CircleShape)
                        .clickable(onClick = onInvite),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Filled.Add, t("Invite"), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

@Composable
private fun MemberAvatar(name: String, url: String?, isHost: Boolean, progress: Float) {
    Box(contentAlignment = Alignment.Center) {
        androidx.compose.material3.CircularProgressIndicator(
            progress = { progress },
            modifier = Modifier.size(48.dp),
            strokeWidth = 2.5.dp,
            color = MaterialTheme.colorScheme.primary,
            trackColor = MaterialTheme.colorScheme.outlineVariant,
        )
        Avatar(name, url, 40.dp)
        if (isHost) {
            Icon(
                Icons.Filled.Star, contentDescription = null, tint = Color(0xFFFFCC00),
                modifier = Modifier.size(16.dp).align(Alignment.BottomEnd).background(Color.White, CircleShape).padding(1.dp),
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ChatArea(app: AppState, session: WatchSession, state: WatchUiState, modifier: Modifier) {
    val listState = rememberLazyListState()
    var draft by remember { mutableStateOf("") }
    var panel by remember { mutableStateOf(false) }
    var moderating by remember { mutableStateOf<ChatMessage?>(null) }

    LaunchedEffect(state.messages.size) {
        if (state.messages.isNotEmpty()) listState.animateScrollToItem(state.messages.size)
    }

    Column(modifier.fillMaxWidth().imePadding()) {
        LazyColumn(
            state = listState,
            modifier = Modifier.weight(1f).fillMaxWidth(),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(state.messages, key = { it.id }) { message ->
                ChatRow(app, state, message, onLongPress = { if (state.canModerate(message)) moderating = message })
            }
            item {
                Text(
                    t("Invite-only room · Long-press a message to block or report"),
                    fontSize = 11.sp, color = MaterialTheme.colorScheme.outline,
                    modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
            }
        }
        Row(
            Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface).padding(horizontal = 8.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = { panel = !panel }) {
                Icon(if (panel) Icons.Filled.Keyboard else Icons.Filled.EmojiEmotions, t("Emoji"))
            }
            OutlinedTextField(
                value = draft,
                onValueChange = { draft = it },
                placeholder = { Text(t("Say something…")) },
                modifier = Modifier.weight(1f),
                maxLines = 4,
                shape = RoundedCornerShape(20.dp),
            )
            IconButton(
                enabled = draft.isNotBlank(),
                onClick = {
                    session.sendChat(draft)
                    draft = ""
                },
            ) { Icon(Icons.AutoMirrored.Filled.Send, t("Send"), tint = MaterialTheme.colorScheme.primary) }
        }
        if (panel) {
            EmojiStickerPanel(
                app = app,
                onEmoji = { draft += it },
                onSticker = { session.sendSticker(it) },
                modifier = Modifier.navigationBarsPadding(),
            )
        } else {
            Spacer(Modifier.navigationBarsPadding())
        }
    }

    moderating?.let { message ->
        AlertDialog(
            onDismissRequest = { moderating = null },
            title = { Text(message.senderNickname) },
            text = { Text(message.text.take(120)) },
            confirmButton = {
                TextButton(onClick = { session.blockSender(message); moderating = null }) {
                    Text(t("Block User"), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                Row {
                    TextButton(onClick = { session.report(message); moderating = null }) { Text(t("Report")) }
                    TextButton(onClick = { moderating = null }) { Text(t("Cancel")) }
                }
            },
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ChatRow(app: AppState, state: WatchUiState, message: ChatMessage, onLongPress: () -> Unit) {
    if (message.kind == ChatMessageKind.SYSTEM) {
        Text(
            localizedSystemMessage(state, message.text),
            fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.fillMaxWidth(),
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
        return
    }
    val senderId = message.senderId
    Row(
        Modifier.fillMaxWidth().combinedClickable(onClick = {}, onLongClick = onLongPress),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Avatar(message.senderNickname, senderId?.let { state.memberAvatarUrl(it) }, 32.dp)
        Column(Modifier.weight(1f)) {
            Text(message.senderNickname, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(2.dp))
            val sticker = message.sticker
            if (message.kind == ChatMessageKind.STICKER && sticker != null) {
                StickerImage(app, sticker, Modifier.size(120.dp))
            } else {
                Text(
                    message.text,
                    modifier = Modifier
                        .background(MaterialTheme.colorScheme.surface, RoundedCornerShape(12.dp))
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                )
            }
        }
    }
}

private fun localizedSystemMessage(state: WatchUiState, text: String): String {
    val transferPrefix = "Host transferred to "
    if (text.startsWith(transferPrefix)) {
        return t("Host is now {{name}}", "name" to state.memberDisplayName(text.removePrefix(transferPrefix)))
    }
    val switchPrefix = "Host switched the movie to “"
    if (text.startsWith(switchPrefix) && text.endsWith("”")) {
        return t("Host switched the movie to “{{title}}”", "title" to text.removePrefix(switchPrefix).removeSuffix("”"))
    }
    return L10n.string(text)
}