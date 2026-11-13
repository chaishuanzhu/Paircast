---
name: paircast-workflow
description: Paircast iOS + Android project workflow — KMP shared layer, Tuist modules, docs/Pages on paircast.chaisz.com, metadata, release tags, and secret-handling rules. Use when changing architecture, docs, store metadata, invite/privacy pages, or release/TestFlight flows.
---

# Paircast Workflow

Read `AGENTS.md` first for module boundaries and hard rules.

## When editing code

1. Keep Clean Architecture: business logic lives in Kotlin Multiplatform (`shared/core` is pure Kotlin, `shared/data` implements gateways); iOS Presentation is SwiftUI, Android is Compose — both only render shared state.
2. Xcode recompiles `shared/` automatically (Presentation's "Compile Kotlin Framework" phase → `embedAndSignAppleFrameworkForXcode`); after adding Swift files under `iosApp/{App,Presentation}/Sources`, run `cd iosApp && tuist generate` (or `make generate`).
3. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `iosApp/Project.swift` and `paircast.versionName` / `paircast.versionCode` in `gradle.properties` together when cutting a user-facing release.

## When editing docs or store copy

1. Public site files live under `docs/` and publish from `main` via GitHub Pages + custom domain `paircast.chaisz.com`.
2. Privacy/support/guide/deploy: `docs/en-US/` and `docs/zh-Hans/`. Invite landing: `docs/invite/`.
3. App Store strings: `metadata/app-info/` and `metadata/version/<ver>/`. Push with `asc metadata push` when network/auth allow.
4. Do not reintroduce `blog.chaisz.com` or `apps.chaisz.com/Paircast/` URLs.

## Secrets

Never commit real cloud keys, provisioning profiles, or full `paircast://config?args=` payloads. Redact in soft-copyright exports (`Scripts/export-soft-copyright-sources.py`).

## Release sketch

1. Version (`iosApp/Project.swift`, `gradle.properties`; `paircast.goimVersion` = required GO-IM release) + metadata → commit on `main`; `Scripts/release.sh check vX.Y.Z` passes locally
2. Tag `vX.Y.Z` on `main`: GitHub Actions attach the IPA + APK, Jenkins `paircast-tags` → `paircast-server` publishes `870027381/paircast-server:X.Y.Z` + `latest`; the Release body (artifacts + GO-IM dependency) comes from `Scripts/release.sh notes`
3. Upload/distribute TestFlight with `asc` on a machine that has ASC API access
