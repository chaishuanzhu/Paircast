import com.android.build.gradle.LibraryExtension
import org.gradle.api.JavaVersion
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.artifacts.VersionCatalogsExtension
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.getByType
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinMultiplatformExtension

/**
 * Kotlin Multiplatform library: Android + iOS (arm64 / simulator arm64).
 *
 * Android namespace derives from the module path: `:shared:core` → `com.chaisz.paircast.shared.core`.
 */
class KmpLibraryConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("org.jetbrains.kotlin.multiplatform")
        pluginManager.apply("com.android.library")

        val libs = extensions.getByType<VersionCatalogsExtension>().named("libs")
        fun version(alias: String) = libs.findVersion(alias).get().requiredVersion

        extensions.configure<KotlinMultiplatformExtension> {
            androidTarget {
                compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
            }
            iosArm64()
            iosSimulatorArm64()

            compilerOptions {
                freeCompilerArgs.addAll("-Xexpect-actual-classes")
                optIn.addAll(
                    "kotlin.uuid.ExperimentalUuidApi",
                    "kotlin.time.ExperimentalTime",
                    "kotlin.io.encoding.ExperimentalEncodingApi",
                )
            }

            sourceSets.commonTest.dependencies {
                implementation(kotlin("test"))
            }
        }

        extensions.configure<LibraryExtension> {
            namespace = "com.chaisz.paircast." + path.removePrefix(":").replace(':', '.').replace('-', '_')
            compileSdk = version("android-compileSdk").toInt()
            defaultConfig {
                minSdk = version("android-minSdk").toInt()
            }
            compileOptions {
                sourceCompatibility = JavaVersion.VERSION_17
                targetCompatibility = JavaVersion.VERSION_17
            }
        }
    }
}
