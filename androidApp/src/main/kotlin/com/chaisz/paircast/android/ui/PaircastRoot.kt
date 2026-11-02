package com.chaisz.paircast.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.chaisz.paircast.android.R
import com.chaisz.paircast.android.app.AppRoute
import com.chaisz.paircast.android.app.AppState
import com.chaisz.paircast.android.app.LibraryRoute
import com.chaisz.paircast.android.app.t
import com.chaisz.paircast.android.ui.watch.WatchScreen
import kotlinx.coroutines.delay

@Composable
fun PaircastRoot(app: AppState) {
    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        Crossfade(targetState = app.route, label = "route") { route ->
            when (route) {
                AppRoute.Splash -> SplashScreen()
                AppRoute.Login -> LoginScreen(app)
                AppRoute.Register -> RegisterScreen(app)
                is AppRoute.Config -> ConfigScreen(app, fromLogin = true)
                AppRoute.Library -> LibraryHost(app)
            }
        }
        ToastHost(app)
    }
}

@Composable
private fun LibraryHost(app: AppState) {
    val top = app.libraryStack.lastOrNull()
    BackHandler(enabled = top is LibraryRoute.Config) { app.popLibrary() }
    when (top) {
        null -> LibraryScreen(app)
        LibraryRoute.Config -> ConfigScreen(app, fromLogin = false)
        is LibraryRoute.Watch -> WatchScreen(app, top.roomId, top.movieId, top.hostUserId)
    }
}

@Composable
private fun SplashScreen() {
    Column(
        Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = androidx.compose.foundation.layout.Arrangement.Center,
    ) {
        Image(
            painterResource(R.drawable.brand_mark),
            contentDescription = null,
            modifier = Modifier.size(96.dp).clip(RoundedCornerShape(24.dp)),
        )
        Spacer(Modifier.height(16.dp))
        Text("Paircast", fontSize = 34.sp, fontWeight = FontWeight.Bold)
        Text(t("Watch together"), color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun ToastHost(app: AppState) {
    val message = app.toast
    LaunchedEffect(message) {
        if (message != null) {
            delay(2_000)
            if (app.toast == message) app.toast = null
        }
    }
    Box(Modifier.fillMaxSize().navigationBarsPadding().padding(bottom = 24.dp), contentAlignment = Alignment.BottomCenter) {
        AnimatedVisibility(
            visible = message != null,
            enter = fadeIn() + slideInVertically { it },
            exit = fadeOut() + slideOutVertically { it },
        ) {
            Surface(
                shape = RoundedCornerShape(50),
                color = MaterialTheme.colorScheme.inverseSurface.copy(alpha = 0.92f),
                contentColor = MaterialTheme.colorScheme.inverseOnSurface,
            ) {
                Text(message.orEmpty(), Modifier.padding(horizontal = 16.dp, vertical = 10.dp))
            }
        }
    }
}
