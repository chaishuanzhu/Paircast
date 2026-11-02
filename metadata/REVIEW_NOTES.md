# App Review notes

Paste into App Store Connect → App Review Information → Notes, and reply in Resolution Center with the same content. Attach the physical-device screen recording in Resolution Center (and optionally as a review attachment).

---

## 0) Guideline 2.3 — UIRequiredDeviceCapabilities / Device Compatibility

Reply to App Review regarding UIRequiredDeviceCapabilities and installability:

1. Info.plist `UIRequiredDeviceCapabilities` contains only `arm64`. There are no additional capability keys (telephony, gps, camera, metal, etc.) that would block installation on standard App Review devices.
2. `MinimumOSVersion` is **26.0**. The submitted binary is **arm64-only**, matching the declared `arm64` requirement.
3. The app does not declare device capabilities that would prevent install on iPhone hardware used by App Review.
4. If installation of the attached build fails, please share the exact device model / OS and any console or install error so we can investigate further.

---

## 1) Screen recording (physical device)

A screen recording captured on a physical iPhone running the latest iOS is attached in Resolution Center. It starts at cold launch and shows:

1. Launch → Login
2. Service Configuration → paste demo `paircast://config` link → confirm import → re-login
3. Sign in with the demo account and password (provided in the Demo Account fields)
4. Browse private library (sample public-domain shorts only)
5. Open a title → create/join watch room → synced playback controls
6. In-room chat → long-press a message → Block / Report
7. Me → Delete Account (clears avatar and on-device account data, then signs out)

There is **no in-app registration**, **no paid content / IAP**, and **no public catalog**.

---

## 2) Purpose and target audience

**Purpose:** Paircast is an invite-only private cloud sync player. Friends who already lawfully store personal media in their own storage (connected to their self-hosted GO-IM server) can watch the same file together remotely with synchronized play/pause/seek and light in-room chat.

**Problem it solves:** Consumer streaming apps do not sync playback of *your own* private files. Paircast does not host or distribute a public film/TV catalog; it only plays the media library that the operator of a self-hosted GO-IM server connects to their own storage, and coordinates sync through that server.

**Target audience:** Small groups of friends / households who self-host S3-compatible media and want remote “movie night” sync. Not intended as a business / employee-only tool distribution.

---

## 3) Setup and how to access main features

**Demo credentials (also in Demo Account fields):**

| Field | Value |
|-------|--------|
| Demo account A / B | *(App Store Connect Demo Account fields only — not committed)* |
| Password | *(App Store Connect only; demo accounts are not flagged for forced password change)* |

**Steps for App Review:**

1. Cold-launch Paircast.
2. On Login, open **Service Configuration**.
3. Paste the demo cloud config link provided below (`paircast://config?args=…`), confirm import, then return to Login when prompted.
4. Enter the demo account and password and sign in.
5. Library lists videos from the demo server’s media library. Sample files are public-domain / Creative Commons shorts only (e.g. Big Buck Bunny). Do **not** expect commercial films.
6. Tap a title → create or join a room → use play/pause and invite/sync.
7. Chat is invite-only. Long-press a message to **Block** (local hide) or **Report** (opens the public issue form).
8. Me → **Delete Account** clears the uploaded avatar, Keychain config (server address), and session token, then signs out. Accounts on the GO-IM server are admin-managed (no public self-serve registration).

**Demo config link:**  
*(Keep the live `paircast://config?args=…` string and demo passwords only in App Store Connect Notes / Resolution Center — do not commit secrets to git.)*

**Privacy / support:**

- https://paircast.chaisz.com/en-US/privacy/
- https://paircast.chaisz.com/en-US/support/
- zh-Hans: `/zh-Hans/privacy/` and `/zh-Hans/support/`

---

## 4) External services used for core functionality

| Service | Role |
|---------|------|
| **GO-IM (self-hosted)** | Account sign-in (account + password), invite-only room messaging, avatars, and transient sync signaling; server address comes from the user-supplied config |
| **S3-compatible object storage** (configured on the GO-IM server) | Private media library; the server lists videos and issues short-lived presigned playback URLs. The app stores no storage keys |
| **VLCKit (MobileVLCKit)** | Local playback of common containers/codecs |
| **OpenSubtitles API** *(optional, server-side key)* | Online subtitle search, proxied by the GO-IM server when its operator enables it |
| **TMDB API** *(optional, server-side token)* | Movie titles, overviews, posters, and backdrops, fetched by the GO-IM server when its operator enables it |

No payment processors. No AI services. This product uses the TMDB API but is not endorsed or certified by TMDB.

---

## 5) Regional differences

The app functions consistently across all App Store regions. There is no region-locked catalog, geo-priced content, or locale-specific feature gating beyond standard UI localization (en / zh-Hans).

---

## 6) Regulated industries / protected third-party material

Paircast is **not** in a highly regulated industry (not banking, health, gambling, etc.).

It does **not** license or redistribute commercial film/TV catalogs. Reviewer demo media are public-domain / Creative Commons sample shorts only. End users must supply their own lawfully held private media and their own cloud credentials.

---

## Additional clarifications (common Guideline 2.1 / 1.2 items)

- **Account creation:** Not offered in-app. Accounts are created by the GO-IM server administrator who shares a config invite. Login is account + password.
- **Account deletion:** Me → Delete Account removes on-device account-related data as described above (Guideline 5.1.1(v) local deletion path for this invite-only model).
- **UGC / messaging:** Invite-only room chat; Block + Report available via long-press.
- **IAP / paid features:** None.
- **Business distribution:** Consumer App Store product for private friend groups, not exclusive B2B/employee tooling.
