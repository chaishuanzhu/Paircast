package com.chaisz.paircast.android.ui.watch

import android.app.Activity
import android.content.pm.ActivityInfo
import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.automirrored.filled.ArrowBackIos
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CloseFullscreen
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.OpenInFull
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.EmojiEmotions
import androidx.compose.material.icons.outlined.Subtitles
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
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
import com.chaisz.paircast.android.ui.PaircastColors
import com.chaisz.paircast.android.ui.formatPlaybackTime
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.ChatMessage
import com.chaisz.paircast.core.model.ChatMessageKind
import com.chaisz.paircast.core.model.Movie
import com.chaisz.paircast.core.model.SubtitleSource
import com.chaisz.paircast.core.session.WatchEvent
import com.chaisz.paircast.core.session.WatchSession
import com.chaisz.paircast.core.session.WatchUiState
import kotlinx.coroutines.delay
import org.videolan.libvlc.util.VLCVideoLayout

private val ChromeShadow = androidx.compose.ui.graphics.Shadow(Color.Black.copy(alpha = 0.5f), Offset(0f, 1f), 3f)
private val HostRingColor = Color(0xFFFF6B81)
private const val CHROME_AUTO_HIDE_MS = 5_000L

@Composable
fun WatchScreen(app: AppState, roomId: String?, movieId: String?, hostUserId: String?) {
    val context = LocalContext.current
    val activity = context as? Activity
    val player = remember { VlcPlayer(context) }
    val session = remember { app.graph.watchSession(player, roomId, movieId, hostUserId) }
    val state by session.state.collectAsState()

    var fullscreen by remember { mutableStateOf(false) }
    var composing by remember { mutableStateOf(false) }
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

    val onSwitch = {
        if (state.isHost) {
            showSwitch = true
            session.loadLibraryForSwitch()
        } else {
            app.showToast(L10n.format(AppError.OnlyHostCanSwitchMovie))
        }
    }

    if (fullscreen) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            PlayerStage(
                player, state, fullscreen = true, modifier = Modifier.fillMaxSize(),
                onBack = { fullscreen = false },
                onToggleFullscreen = { fullscreen = false },
                onTogglePlay = session::togglePlay,
                onRefresh = session::requestSync,
                onSeek = session::seekToProgress,
                onSwitch = onSwitch,
                onSubtitles = { showSubtitles = true; session.refreshSubtitles() },
                onSync = { showSync = true },
            )
        }
    } else {
        Column(Modifier.fillMaxSize().background(Color.Black).statusBarsPadding()) {
            PlayerStage(
                player, state, fullscreen = false,
                modifier = Modifier.fillMaxWidth().aspectRatio(16f / 9f),
                onBack = ::leave,
                onToggleFullscreen = { fullscreen = true },
                onTogglePlay = session::togglePlay,
                onRefresh = session::requestSync,
                onSeek = session::seekToProgress,
                onSwitch = onSwitch,
                onSubtitles = { showSubtitles = true; session.refreshSubtitles() },
                onSync = { showSync = true },
            )
            Column(Modifier.weight(1f).fillMaxWidth().background(MaterialTheme.colorScheme.background)) {
                AnimatedVisibility(!composing, enter = expandVertically() + fadeIn(), exit = shrinkVertically() + fadeOut()) {
                    MembersBar(state, session) { showInvite = true }
                }
                ChatArea(app, session, state, Modifier.weight(1f), onComposingChange = { composing = it })
            }
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
    if (state.isSwitchingMovie) {
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.35f)), contentAlignment = Alignment.Center) {
            Column(
                Modifier.background(MaterialTheme.colorScheme.surface, RoundedCornerShape(14.dp)).padding(20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                CircularProgressIndicator()
                Text(t("Switching movie…"))
            }
        }
    }
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

// region Player stage

@Composable
private fun PlayerStage(
    player: VlcPlayer,
    state: WatchUiState,
    fullscreen: Boolean,
    modifier: Modifier,
    onBack: () -> Unit,
    onToggleFullscreen: () -> Unit,
    onTogglePlay: () -> Unit,
    onRefresh: () -> Unit,
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
    var interaction by remember { mutableIntStateOf(0) }
    var scrub by remember { mutableStateOf<Float?>(null) }
    var menuOpen by remember { mutableStateOf(false) }
    fun touch() {
        chromeVisible = true
        interaction++
    }

    LaunchedEffect(chromeVisible, interaction, menuOpen, scrub == null) {
        if (chromeVisible && !menuOpen && scrub == null) {
            delay(CHROME_AUTO_HIDE_MS)
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
        if (!player.hasStartedPlayback) {
            (state.movie?.backdropUrl ?: state.movie?.posterUrl)?.let { art ->
                AsyncImage(art, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            }
        }

        AnimatedVisibility(chromeVisible, enter = fadeIn(), exit = fadeOut(), modifier = Modifier.fillMaxSize()) {
            Box(
                Modifier
                    .fillMaxSize()
                    .background(
                        Brush.verticalGradient(
                            0f to Color.Black.copy(alpha = 0.55f),
                            0.45f to Color.Transparent,
                            1f to Color.Black.copy(alpha = 0.72f),
                        ),
                    )
                    .padding(horizontal = 12.dp)
                    .padding(top = if (fullscreen) 12.dp else 6.dp, bottom = if (fullscreen) 18.dp else 8.dp),
            ) {
                Row(
                    Modifier.fillMaxWidth().align(Alignment.TopStart),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    ChromeIcon(Icons.AutoMirrored.Filled.ArrowBackIos, t(if (fullscreen) "Exit fullscreen" else "Back"), iconSize = 18.dp) {
                        touch()
                        onBack()
                    }
                    Text(
                        state.movie?.title?.takeIf { it.isNotBlank() } ?: t("Movie"),
                        style = TextStyle(color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, shadow = ChromeShadow),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    SwitchCapsule(enabled = state.isHost) {
                        touch()
                        onSwitch()
                    }
                    Box {
                        ChromeIcon(Icons.Filled.MoreHoriz, t("More")) {
                            touch()
                            menuOpen = true
                        }
                        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                            DropdownMenuItem(text = { Text(t("Subtitles")) }, onClick = { menuOpen = false; onSubtitles() })
                            DropdownMenuItem(text = { Text(t("Subtitle Sync")) }, onClick = { menuOpen = false; onSync() })
                        }
                    }
                }

                Column(
                    Modifier.fillMaxWidth().align(Alignment.BottomStart),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    if (state.subtitleState.source != SubtitleSource.OFF && state.subtitleState.offsetMs != 0) {
                        Text(
                            t("Subtitles {{offset}}", "offset" to state.subtitleState.offsetLabel),
                            style = TextStyle(color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Medium, shadow = ChromeShadow),
                            modifier = Modifier.padding(horizontal = 8.dp),
                        )
                    }
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        if (state.isHost) {
                            ChromeIcon(if (paused) Icons.Filled.PlayArrow else Icons.Filled.Pause, null) {
                                touch()
                                onTogglePlay()
                            }
                        } else if (state.isRequestingSync) {
                            Box(Modifier.size(36.dp), contentAlignment = Alignment.Center) {
                                CircularProgressIndicator(Modifier.size(18.dp), color = Color.White, strokeWidth = 2.dp)
                            }
                        } else {
                            ChromeIcon(Icons.Filled.Refresh, t("Sync with host")) {
                                touch()
                                onRefresh()
                            }
                        }
                        ChromeIcon(Icons.Outlined.Subtitles, t("Subtitles")) {
                            touch()
                            onSubtitles()
                        }
                        val progress = if (duration > 0) (position.toFloat() / duration).coerceIn(0f, 1f) else 0f
                        ThinProgressBar(
                            progress = scrub ?: progress,
                            scrubbing = scrub != null,
                            enabled = state.isHost && duration > 0,
                            onScrub = { scrub = it; chromeVisible = true },
                            onSeek = {
                                scrub = null
                                onSeek(it.toDouble())
                                interaction++
                            },
                            modifier = Modifier.weight(1f).height(32.dp),
                        )
                        val shown = scrub?.let { (it * duration).toLong() } ?: position
                        Text(
                            "${formatPlaybackTime(shown)}/${formatPlaybackTime(duration)}",
                            color = Color.White.copy(alpha = 0.88f),
                            fontSize = 11.sp,
                            fontFamily = FontFamily.Monospace,
                            maxLines = 1,
                        )
                        ChromeIcon(
                            if (fullscreen) Icons.Filled.CloseFullscreen else Icons.Filled.OpenInFull,
                            t(if (fullscreen) "Exit fullscreen" else "Fullscreen"),
                            iconSize = 16.dp,
                        ) {
                            touch()
                            onToggleFullscreen()
                        }
                    }
                }
            }
        }

        if (buffering && !paused) {
            Column(
                Modifier.align(Alignment.Center),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                CircularProgressIndicator(color = Color.White, strokeWidth = 2.5.dp, modifier = Modifier.size(28.dp))
                Text(t("Buffering…"), color = Color.White, fontSize = 12.sp)
            }
        }
        state.error?.let {
            Text(
                L10n.format(it),
                color = Color.White,
                fontSize = 13.sp,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(top = if (fullscreen) 56.dp else 48.dp, start = 16.dp, end = 16.dp)
                    .background(PaircastColors.danger.copy(alpha = 0.9f), CircleShape)
                    .padding(horizontal = 12.dp, vertical = 6.dp),
            )
        }
    }
}

@Composable
private fun ChromeIcon(
    icon: ImageVector,
    description: String?,
    enabled: Boolean = true,
    iconSize: Dp = 20.dp,
    onClick: () -> Unit,
) {
    Box(
        Modifier.size(36.dp).clip(CircleShape).clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon,
            contentDescription = description,
            tint = Color.White.copy(alpha = if (enabled) 0.95f else 0.45f),
            modifier = Modifier.size(iconSize),
        )
    }
}

/** Outlined "Switch" pill; dimmed for members (tapping explains only the host can switch). */
@Composable
private fun SwitchCapsule(enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier
            .height(28.dp)
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = if (enabled) 0.18f else 0.08f))
            .border(1.dp, Color.White.copy(alpha = if (enabled) 0.85f else 0.4f), CircleShape)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(t("Switch"), color = Color.White.copy(alpha = if (enabled) 1f else 0.55f), fontSize = 13.sp, fontWeight = FontWeight.Medium)
    }
}

/** 3dp track with a dot thumb (host only); press-and-drag anywhere on the bar to scrub. */
@Composable
private fun ThinProgressBar(
    progress: Float,
    scrubbing: Boolean,
    enabled: Boolean,
    onScrub: (Float) -> Unit,
    onSeek: (Float) -> Unit,
    modifier: Modifier,
) {
    val thumb by animateDpAsState(if (scrubbing) 12.dp else 8.dp, label = "thumb")
    BoxWithConstraints(
        modifier.pointerInput(enabled) {
            if (!enabled) return@pointerInput
            awaitEachGesture {
                val width = size.width.toFloat().coerceAtLeast(1f)
                val down = awaitFirstDown()
                var fraction = (down.position.x / width).coerceIn(0f, 1f)
                onScrub(fraction)
                while (true) {
                    val change = awaitPointerEvent().changes.firstOrNull() ?: break
                    if (!change.pressed) break
                    fraction = (change.position.x / width).coerceIn(0f, 1f)
                    onScrub(fraction)
                    change.consume()
                }
                onSeek(fraction)
            }
        },
        contentAlignment = Alignment.CenterStart,
    ) {
        val width = maxWidth
        Box(Modifier.fillMaxWidth().height(3.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.28f)))
        Box(Modifier.width((width * progress).coerceAtLeast(3.dp)).height(3.dp).clip(CircleShape).background(Color.White))
        if (enabled) {
            Box(
                Modifier
                    .offset(x = (width * progress - thumb / 2).coerceIn(0.dp, (width - thumb).coerceAtLeast(0.dp)))
                    .size(thumb)
                    .background(Color.White, CircleShape),
            )
        }
    }
}

// endregion

// region Members

@Composable
private fun MembersBar(state: WatchUiState, session: WatchSession, onInvite: () -> Unit) {
    val members = state.room?.memberIds.orEmpty()
    var tick by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(500)
            tick++
        }
    }
    Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface)) {
        Column(
            Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 10.dp, bottom = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    t("{{count}} watching", "count" to members.size.toString()),
                    fontSize = 13.sp, fontWeight = FontWeight.Medium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.weight(1f))
                Text(
                    t(if (state.isHost) "You are the host — you control playback" else "Following the host"),
                    fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
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
                item { InviteCircle(onInvite) }
            }
        }
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f))
    }
}

/** Avatar inside a playback-progress ring; the host's ring is pink. */
@Composable
private fun MemberAvatar(name: String, url: String?, isHost: Boolean, progress: Float) {
    val track = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.3f)
    val fill = if (isHost) HostRingColor else MaterialTheme.colorScheme.primary
    Box(Modifier.size(50.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(46.dp)) {
            val stroke = 2.5.dp.toPx()
            drawCircle(track, style = Stroke(stroke))
            drawArc(fill, -90f, 360f * progress.coerceIn(0f, 1f), useCenter = false, style = Stroke(stroke, cap = StrokeCap.Round))
        }
        Avatar(name, url, 40.dp)
    }
}

@Composable
private fun InviteCircle(onClick: () -> Unit) {
    val dash = MaterialTheme.colorScheme.outline
    Box(
        Modifier.size(48.dp).clip(CircleShape).background(MaterialTheme.colorScheme.background).clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val stroke = 1.5.dp.toPx()
            drawCircle(
                dash,
                radius = size.minDimension / 2 - stroke / 2,
                style = Stroke(stroke, pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx()))),
            )
        }
        Icon(Icons.Filled.Add, t("Invite"), tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(22.dp))
    }
}

// endregion

// region Chat

@Composable
private fun ChatArea(
    app: AppState,
    session: WatchSession,
    state: WatchUiState,
    modifier: Modifier,
    onComposingChange: (Boolean) -> Unit,
) {
    val listState = rememberLazyListState()
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val focusRequester = remember { FocusRequester() }
    var draft by remember { mutableStateOf("") }
    var panel by remember { mutableStateOf(false) }
    var focused by remember { mutableStateOf(false) }
    var moderating by remember { mutableStateOf<ChatMessage?>(null) }
    val myId = app.currentUser?.id

    LaunchedEffect(state.messages.size) {
        if (state.messages.isNotEmpty()) listState.animateScrollToItem(state.messages.size)
    }
    LaunchedEffect(panel, focused) { onComposingChange(panel || focused) }

    fun dismissComposer() {
        focusManager.clearFocus()
        panel = false
    }

    fun togglePanel() {
        if (panel) {
            panel = false
            focusRequester.requestFocus()
            keyboard?.show()
        } else {
            keyboard?.hide()
            focusManager.clearFocus()
            panel = true
        }
    }

    Column(modifier.fillMaxWidth().imePadding()) {
        LazyColumn(
            state = listState,
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = ::dismissComposer),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(state.messages, key = { it.id }) { message ->
                ChatRow(
                    app, state, message,
                    isMe = message.senderId != null && message.senderId == myId,
                    onLongPress = { if (state.canModerate(message)) moderating = message },
                )
            }
            item {
                Text(
                    t("Invite-only room · Long-press a message to block or report"),
                    fontSize = 11.sp, color = MaterialTheme.colorScheme.outline,
                    modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                    textAlign = TextAlign.Center,
                )
            }
        }

        Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface)) {
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f))
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Box(
                    Modifier.size(36.dp).clip(CircleShape).clickable(onClick = ::togglePanel),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        if (panel) Icons.Filled.Keyboard else Icons.Outlined.EmojiEmotions,
                        t("Emoji"),
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(24.dp),
                    )
                }
                val textColor = MaterialTheme.colorScheme.onSurface
                BasicTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    maxLines = 4,
                    textStyle = TextStyle(color = textColor, fontSize = 15.sp),
                    cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                    modifier = Modifier
                        .weight(1f)
                        .focusRequester(focusRequester)
                        .onFocusChanged {
                            focused = it.isFocused
                            if (it.isFocused) panel = false
                        },
                    decorationBox = { inner ->
                        Box(
                            Modifier
                                .heightIn(min = 40.dp)
                                .background(MaterialTheme.colorScheme.background, RoundedCornerShape(20.dp))
                                .padding(horizontal = 14.dp, vertical = 9.dp),
                            contentAlignment = Alignment.CenterStart,
                        ) {
                            if (draft.isEmpty()) {
                                Text(t("Say something…"), color = MaterialTheme.colorScheme.outline, fontSize = 15.sp)
                            }
                            inner()
                        }
                    },
                )
                val canSend = draft.isNotBlank()
                Box(
                    Modifier
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.primary)
                        .clickable(enabled = canSend) {
                            session.sendChat(draft)
                            draft = ""
                        }
                        .alpha(if (canSend) 1f else 0.5f)
                        .padding(horizontal = 14.dp, vertical = 8.dp),
                ) {
                    Text(t("Send"), color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                }
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

/** iMessage-style row: own messages on the right in blue, others on the left with name above. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ChatRow(app: AppState, state: WatchUiState, message: ChatMessage, isMe: Boolean, onLongPress: () -> Unit) {
    if (message.kind == ChatMessageKind.SYSTEM) {
        Text(
            localizedSystemMessage(state, message.text),
            fontSize = 12.sp, color = MaterialTheme.colorScheme.outline,
            modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
            textAlign = TextAlign.Center,
        )
        return
    }
    val avatarUrl = message.senderId?.let { state.memberAvatarUrl(it) } ?: if (isMe) app.currentUser?.avatarUrl else null
    val avatarName = message.senderNickname.ifEmpty { message.senderId ?: "?" }
    Row(
        Modifier.fillMaxWidth().padding(start = if (isMe) 40.dp else 0.dp, end = if (isMe) 0.dp else 40.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp, if (isMe) Alignment.End else Alignment.Start),
        verticalAlignment = Alignment.Top,
    ) {
        if (!isMe) Avatar(avatarName, avatarUrl, 32.dp)
        Column(
            Modifier.weight(1f, fill = false),
            horizontalAlignment = if (isMe) Alignment.End else Alignment.Start,
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            if (!isMe) {
                Text(message.senderNickname, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            val sticker = message.sticker
            val longPress = Modifier.combinedClickable(onClick = {}, onLongClick = onLongPress)
            if (message.kind == ChatMessageKind.STICKER && sticker != null) {
                StickerImage(app, sticker, longPress.size(120.dp))
            } else {
                val shape = RoundedCornerShape(
                    topStart = 16.dp,
                    topEnd = 16.dp,
                    bottomEnd = if (isMe) 6.dp else 16.dp,
                    bottomStart = if (isMe) 16.dp else 6.dp,
                )
                Text(
                    message.text,
                    color = if (isMe) Color.White else MaterialTheme.colorScheme.onSurface,
                    fontSize = 15.sp,
                    modifier = Modifier
                        .widthIn(min = 16.dp)
                        .clip(shape)
                        .background(if (isMe) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surface)
                        .then(longPress)
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                )
            }
        }
        if (isMe) Avatar(avatarName, avatarUrl, 32.dp)
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

// endregion
