import org.jetbrains.kotlin.gradle.plugin.mpp.apple.XCFramework

plugins {
    alias(libs.plugins.paircast.kmp.library)
    alias(libs.plugins.skie)
}

kotlin {
    val xcf = XCFramework("PaircastShared")
    listOf(iosArm64(), iosSimulatorArm64()).forEach { target ->
        target.binaries.framework {
            baseName = "PaircastShared"
            isStatic = true
            export(projects.shared.core)
            xcf.add(this)
        }
    }

    sourceSets {
        commonMain.dependencies {
            api(projects.shared.core)
            api(projects.shared.data)
        }
    }
}

skie {
    features {
        enableSwiftUIObservingPreview = false
    }
}
