# App Review notes

Paste into App Store Connect → App Review Information → Notes, and reply in Resolution Center with the same content. Attach the physical-device screen recording in Resolution Center (and optionally as a review attachment).

---

## 0) Guideline 2.3 — UIRequiredDeviceCapabilities / Device Compatibility

Reply to App Review regarding UIRequiredDeviceCapabilities and installability:

1. Info.plist `UIRequiredDeviceCapabilities` contains only `arm64`. There are no additional capability keys (telephony, gps, camera, metal, etc.) that would block installation on standard App Review devices.
2. `MinimumOSVersion` is **26.0**. The submitted binary is **arm64-only**, matching the declared `arm64` requirement.
3. The app does not declare device capabilities that would prevent install on iPhone hardware used by App Review.
4. Please **retry installation of build 5** (the build currently attached to this version). If install still fails, please share the exact device model / OS and any console or install error so we can investigate further.

---

## 1) Screen recording (physical device)

A screen recording captured on a physical iPhone running the latest iOS is attached in Resolution Center. It starts at cold launch and shows:

1. Launch → Login
2. Service Configuration → paste demo `paircast://config` link → confirm import → re-login
3. Sign in with demo User ID `test1` (no password; IM UserSig is derived from the imported config)
4. Browse private library (sample public-domain shorts only)
5. Open a title → create/join watch room → synced playback controls
6. In-room chat → long-press a message → Block / Report
7. Me → Delete Account (clears on-device account data and signs out)

There is **no in-app registration**, **no paid content / IAP**, and **no public catalog**.

---

## 2) Purpose and target audience

**Purpose:** Paircast is an invite-only private cloud sync player. Friends who already lawfully store personal media in their own object storage can watch the same file together remotely with synchronized play/pause/seek and light in-room chat.

**Problem it solves:** Consumer streaming apps do not sync playback of *your own* private files. Paircast does not host or distribute a public film/TV catalog; it only plays objects from the user’s configured bucket and coordinates sync via IM.

**Target audience:** Small groups of friends / households who self-host S3-compatible media and want remote “movie night” sync. Not intended as a business / employee-only tool distribution.

---

## 3) Setup and how to access main features

**Demo credentials (also in Demo Account fields):**

| Field | Value |
|-------|--------|
| Demo User ID A | `test1` |
| Demo User ID B | `test2` |
| Password | *(none — leave blank; login is User ID only)* |

**Steps for App Review:**

1. Cold-launch Paircast.
2. On Login, open **Service Configuration**.
3. Paste the demo cloud config link provided below (`paircast://config?args=…`), confirm import, then return to Login when prompted.
4. Enter User ID `test1` (or `test2`) and sign in. No password field.
5. Library lists objects from the demo bucket. Sample files are public-domain / Creative Commons shorts only (e.g. Big Buck Bunny). Do **not** expect commercial films.
6. Tap a title → create or join a room → use play/pause and invite/sync.
7. Chat is invite-only. Long-press a message to **Block** (local hide) or **Report** (opens the public issue form).
8. Me → **Delete Account** clears Keychain cloud config, session user id, nickname/avatar cache, and uploaded avatar object, then signs out. Provisioned IM users in the Tencent console are admin-managed (no public self-serve registration).

**Demo config link:**  
*(Keep the live `paircast://config?args=…` string only in App Store Connect Notes / Resolution Center — do not commit secrets to git.)*

**Privacy / support:**

- https://blog.chaisz.com/Paircast/en-US/privacy/
- https://blog.chaisz.com/Paircast/en-US/support/
- zh-Hans: `/zh-Hans/privacy/` and `/zh-Hans/support/`

---

## 4) External services used for core functionality

| Service | Role |
|---------|------|
| **Tencent Cloud IM** | Invite-only room messaging, presence, and sync signaling (SDKAppID + UserSig from user-supplied config) |
| **S3-compatible object storage** (e.g. Qiniu S3 / Tencent COS / other SigV4 hosts) | Private media library listing + presigned playback; avatar/room metadata objects |
| **VLCKit (MobileVLCKit)** | Local playback of common containers/codecs |
| **OpenSubtitles API** *(optional, user key)* | Online subtitle search when the user configures their own key |
| **OMDb** *(optional, user key)* | Optional poster enrichment when the user configures their own key |

No payment processors. No AI services. The app does not scrape Douban or IMDb.

---

## 5) Regional differences

The app functions consistently across all App Store regions. There is no region-locked catalog, geo-priced content, or locale-specific feature gating beyond standard UI localization (en / zh-Hans).

---

## 6) Regulated industries / protected third-party material

Paircast is **not** in a highly regulated industry (not banking, health, gambling, etc.).

It does **not** license or redistribute commercial film/TV catalogs. Reviewer demo media are public-domain / Creative Commons sample shorts only. End users must supply their own lawfully held private media and their own cloud credentials.

---

## Additional clarifications (common Guideline 2.1 / 1.2 items)

- **Account creation:** Not offered in-app. Accounts are provisioned by the cloud/IM administrator who shares a config invite. Login is User ID + UserSig only.
- **Account deletion:** Me → Delete Account removes on-device account-related data as described above (Guideline 5.1.1(v) local deletion path for this invite-only model).
- **UGC / messaging:** Invite-only room chat; Block + Report available via long-press.
- **IAP / paid features:** None.
- **Business distribution:** Consumer App Store product for private friend groups, not exclusive B2B/employee tooling.
