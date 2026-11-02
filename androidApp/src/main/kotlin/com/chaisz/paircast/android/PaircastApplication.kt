package com.chaisz.paircast.android

import android.app.Application
import android.util.Log
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.gif.AnimatedImageDecoder
import coil3.gif.GifDecoder
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import coil3.request.crossfade
import com.chaisz.paircast.PaircastGraph
import com.chaisz.paircast.android.app.AppState
import com.chaisz.paircast.android.app.L10n
import com.chaisz.paircast.android.platform.EncryptedSecureStore
import com.chaisz.paircast.android.platform.PrefsKeyValueStore
import com.chaisz.paircast.data.support.PaircastLog
import java.io.File
import java.util.Locale

class PaircastApplication : Application(), SingletonImageLoader.Factory {
    lateinit var appState: AppState
        private set

    override fun onCreate() {
        super.onCreate()
        L10n.load(this)
        PaircastLog.sink = { level, tag, message ->
            when (level) {
                PaircastLog.Level.ERROR -> Log.e("Paircast/$tag", message)
                PaircastLog.Level.DEBUG -> Log.d("Paircast/$tag", message)
                PaircastLog.Level.INFO -> Log.i("Paircast/$tag", message)
            }
        }
        val graph = PaircastGraph(
            secureStore = EncryptedSecureStore(this),
            keyValueStore = PrefsKeyValueStore(this),
            cacheDirectory = File(cacheDir, "paircast").apply { mkdirs() }.absolutePath,
            supportDirectory = File(filesDir, "paircast").apply { mkdirs() }.absolutePath,
            preferredLanguage = Locale.getDefault().toLanguageTag(),
            appVersion = BuildConfig.VERSION_NAME,
        )
        appState = AppState(graph)
    }

    override fun newImageLoader(context: PlatformContext): ImageLoader =
        ImageLoader.Builder(context)
            .components {
                add(OkHttpNetworkFetcherFactory())
                if (android.os.Build.VERSION.SDK_INT >= 28) add(AnimatedImageDecoder.Factory()) else add(GifDecoder.Factory())
            }
            .crossfade(true)
            .build()
}
