.PHONY: setup generate test open graph clean

DESTINATION ?= platform=iOS Simulator,name=iPhone 17,OS=26.5

setup: ## Download VLCKit + ImSDK (if needed), resolve deps, generate workspace
	./Scripts/download-vlckit.sh
	./Scripts/download-imsdk.sh
	tuist install
	tuist generate --no-open

generate:
	tuist generate --no-open

test:
	xcodebuild test -workspace Tandem.xcworkspace -scheme Domain -destination '$(DESTINATION)' -quiet
	xcodebuild test -workspace Tandem.xcworkspace -scheme Data -destination '$(DESTINATION)' -quiet
	xcodebuild test -workspace Tandem.xcworkspace -scheme Presentation -destination '$(DESTINATION)' -quiet

open:
	tuist generate
	open Tandem.xcworkspace

graph:
	tuist graph

clean:
	tuist clean
	rm -rf DerivedData .tuist Projects/*/Derived
