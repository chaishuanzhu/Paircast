.PHONY: setup shared shared-test generate test android android-test open graph clean

DESTINATION ?= platform=iOS Simulator,name=iPhone 17,OS=26.5
GRADLE ?= ./gradlew
IOS := iosApp

setup: ## Download VLCKit, resolve deps, generate workspace (Xcode compiles the KMP framework itself)
	./$(IOS)/Scripts/download-vlckit.sh
	cd $(IOS) && tuist install && tuist generate --no-open

shared: ## Optional: standalone PaircastShared.xcframework for distribution (not needed for Xcode builds)
	$(GRADLE) :shared:umbrella:assemblePaircastSharedReleaseXCFramework

shared-test: ## Kotlin unit tests (JVM/Android + iOS simulator)
	$(GRADLE) :shared:core:allTests :shared:data:testDebugUnitTest :shared:data:iosSimulatorArm64Test

generate:
	cd $(IOS) && tuist generate --no-open

test: shared-test
	xcodebuild test -workspace $(IOS)/Paircast.xcworkspace -scheme Paircast -destination '$(DESTINATION)' -quiet

android: ## Debug APK
	$(GRADLE) :androidApp:assembleDebug

android-test:
	$(GRADLE) :androidApp:testDebugUnitTest

open:
	cd $(IOS) && tuist generate

graph:
	cd $(IOS) && tuist graph

clean:
	cd $(IOS) && tuist clean
	$(GRADLE) clean
	rm -rf $(IOS)/Derived $(IOS)/DerivedData
