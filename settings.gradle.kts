rootProject.name = "paircast"

enableFeaturePreview("TYPESAFE_PROJECT_ACCESSORS")

pluginManagement {
    includeBuild("build-logic")
    repositories {
        google {
            mavenContent {
                includeGroupAndSubgroups("androidx")
                includeGroupAndSubgroups("com.android")
                includeGroupAndSubgroups("com.google")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google {
            mavenContent {
                includeGroupAndSubgroups("androidx")
                includeGroupAndSubgroups("com.android")
                includeGroupAndSubgroups("com.google")
            }
        }
        mavenCentral()
        mavenLocal()
        maven {
            url = uri("https://maven.pkg.github.com/chaishuanzhu/GO-IM")
            credentials {
                username = providers.environmentVariable("GITHUB_ACTOR").orElse("").get()
                password = providers.environmentVariable("GITHUB_TOKEN")
                    .orElse(providers.environmentVariable("GH_TOKEN"))
                    .orElse("")
                    .get()
            }
        }
    }
}

include(":shared:core")
include(":shared:data")
include(":shared:umbrella")
include(":androidApp")

// Sibling GO-IM KMP: full targets (incl. iOS) + Signal; substitutes Maven com.goim:sdk-lite.
includeBuild("../GitHub/GO-IM/kmp") {
    dependencySubstitution {
        substitute(module("com.goim:sdk-lite")).using(project(":sdk:lite"))
    }
}