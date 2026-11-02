import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.androidApplication)
    alias(libs.plugins.kotlinAndroid)
    alias(libs.plugins.composeMultiplatform)
    alias(libs.plugins.composeCompiler)
}

android {
    namespace = "com.chaisz.paircast.android"
    compileSdk = libs.versions.android.compileSdk.get().toInt()

    defaultConfig {
        applicationId = "com.chaisz.paircast"
        minSdk = libs.versions.android.minSdk.get().toInt()
        targetSdk = libs.versions.android.targetSdk.get().toInt()
        versionCode = providers.gradleProperty("paircast.versionCode").getOrElse("1").toInt()
        versionName = providers.gradleProperty("paircast.versionName").getOrElse("1.0.0")
        // libvlc-all ships four ABIs (~120 MB); x86 32-bit devices are not a target.
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64") }
    }

    // CI injects release signing via env; fall back to debug signing so artifacts stay installable.
    val keystore = providers.environmentVariable("PAIRCAST_KEYSTORE_FILE").orNull
    signingConfigs {
        if (keystore != null) {
            create("release") {
                storeFile = file(keystore)
                storePassword = providers.environmentVariable("PAIRCAST_KEYSTORE_PASSWORD").get()
                keyAlias = providers.environmentVariable("PAIRCAST_KEY_ALIAS").get()
                keyPassword = providers.environmentVariable("PAIRCAST_KEY_PASSWORD").get()
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets.getByName("main").assets.srcDir(layout.buildDirectory.dir("generated/l10n"))

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
        jniLibs.useLegacyPackaging = true
    }
}

/** Both apps share one string catalog (keys = English templates, also used by shared `UiText`). */
val copyStringCatalog by tasks.registering(Copy::class) {
    from(rootProject.file("Projects/App/Resources/Localizable.xcstrings"))
    into(layout.buildDirectory.dir("generated/l10n"))
}
tasks.named("preBuild") { dependsOn(copyStringCatalog) }

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
        optIn.addAll("kotlin.time.ExperimentalTime", "kotlin.uuid.ExperimentalUuidApi")
    }
}

dependencies {
    implementation(projects.shared.umbrella)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.security.crypto)
    implementation(libs.kotlinx.coroutines.android)
    implementation(compose.runtime)
    implementation(compose.foundation)
    implementation(compose.material3)
    implementation(compose.ui)
    implementation(libs.compose.material.icons.extended)
    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)
    implementation(libs.coil.gif)
    implementation(libs.libvlc.android)
    implementation(libs.camerax.camera2)
    implementation(libs.camerax.lifecycle)
    implementation(libs.camerax.view)
    implementation(libs.mlkit.barcode)
    implementation(libs.zxing.core)
}
