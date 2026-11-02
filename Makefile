.PHONY: setup shared shared-test generate test android android-test open graph clean

DESTINATION ?= platform=iOS Simulator,name=iPhone 17,OS=26.5
GRADLE ?= ./gradlew

setup: ## Download VLCKit, build the KMP framework, resolve deps, generate workspace
	./Scripts/download-vlckit.sh
	$(MAKE) shared
	tuist install
	tuist generate --no-open

shared: ## Build PaircastShared.xcframework (Kotlin core + data) for the iOS app
	$(GRADLE) :shared:umbrella:assemblePaircastSharedReleaseXCFramework

shared-test: ## Kotlin unit tests (JVM/Android + iOS simulator)
	$(GRADLE) :shared:core:allTests :shared:data:testDebugUnitTest :shared:data:iosSimulatorArm64Test

generate:
	tuist generate --no-open

test: shared-test
	xcodebuild test -workspace Paircast.xcworkspace -scheme Presentation -destination '$(DESTINATION)' -quiet

android: ## Debug APK
	$(GRADLE) :androidApp:assembleDebug

android-test:
	$(GRADLE) :androidApp:testDebugUnitTest

open:
	tuist generate
	open Paircast.xcworkspace

graph:
	tuist graph

clean:
	tuist clean
	$(GRADLE) clean
	rm -rf DerivedData .tuist Projects/*/Derived
