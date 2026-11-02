package com.chaisz.paircast.android

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.chaisz.paircast.android.ui.PaircastRoot
import com.chaisz.paircast.android.ui.PaircastTheme

class MainActivity : ComponentActivity() {
    private val appState get() = (application as PaircastApplication).appState

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.auto(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) handle(intent)
        setContent {
            PaircastTheme {
                PaircastRoot(appState)
            }
        }
        appState.bootstrap()
    }

    override fun onStart() {
        super.onStart()
        appState.graph.onAppForeground()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent?) {
        if (intent?.action == Intent.ACTION_VIEW) intent.data?.let(appState::handleDeepLink)
    }
}
