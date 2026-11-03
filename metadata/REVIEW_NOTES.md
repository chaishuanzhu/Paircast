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
2. Service Configuration → enter the demo server address → Save
3. Sign in with the demo account and password (provided in the Demo Account fields)
4. Browse private library (sample public-domain shorts only)
5. Open a title → create/join watch room → synced playback controls
6. In-room chat → long-press a message → Block / Report (both stored on the server)
7. Me → Admin Console → User Management → Add User (top right) (admin only) → create a throwaway account by email; the initial password is shown on screen
8. Sign in with the throwaway account (forced password change) → Me → Delete Account → enter password (permanently deletes the account on the server, clears on-device data, signs out)

There is **no paid content / IAP** and **no public catalog**.

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
3. Enter the demo server address provided below in the **Server** field, tap **Save**, and return to Login.
4. Enter the demo account and password, check "I have read and agree to the Terms of Service and Privacy Policy", and sign in.
5. Library lists videos from the demo server’s media library. Sample files are public-domain / Creative Commons shorts only (e.g. Big Buck Bunny). Do **not** expect commercial films.
6. Tap a title → create or join a room → use play/pause and invite/sync.
7. Chat is invite-only. Long-press a message to **Block** (hides that user’s messages immediately; the block list is stored on the server with your account) or **Report** (sends the message to the server’s moderation queue). Server admins review reports in Me → Admin Console → **Reports** and can ignore a report or ban the reported user, which disables the account and signs it out immediately.
8. There is no sign-up in the app; accounts are created by the server admin. The demo account is an admin, so Me shows **Admin Console** → **User Management** → **Add User** (top-right button): enter any email (nickname optional) and tap **Add**. The initial password is shown on screen (tap **Copy**). Sign out, sign in with that email and password, and set a new password when asked.
9. Me → **Delete Account** asks for the current password, then permanently deletes the account on the GO-IM server (the session is revoked and the admin can add the email again) and clears the Keychain config (server address), session token and caches. Please use the account created in step 8 so the demo account stays available.

**Demo server address:**  
*(Keep the live server address and demo passwords only in App Store Connect Notes / Resolution Center — do not commit them to git.)*

**Privacy / support:**

- https://paircast.chaisz.com/en-US/terms/ (Terms of Service, linked from the consent line on Login)
- https://paircast.chaisz.com/en-US/privacy/
- https://paircast.chaisz.com/en-US/support/
- zh-Hans: `/zh-Hans/privacy/` and `/zh-Hans/support/`

---

## 4) External services used for core functionality

| Service | Role |
|---------|------|
| **GO-IM (self-hosted)** | Admin-created accounts (Me → Admin Console → User Management → Add User (top right)), account sign-in (account + password), account deletion, invite-only room messaging, avatars, and transient sync signaling; server address comes from the user-supplied config |
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

- **Account creation:** No sign-up in the app. Admins manage accounts in Me → Admin Console (User Management: add users, disable / enable or delete regular users; Reports). The admin of each self-hosted server creates accounts in Me → Admin Console → User Management → Add User (top right) (or via the server admin API); the initial password is emailed or shown to the admin to pass on, and must be changed on first sign-in. The demo account is an admin so you can create a test account yourself.
- **Account deletion (Guideline 5.1.1(v)):** Me → Delete Account → enter password. The server permanently deletes the account record and revokes its sessions; the app then clears all on-device data.
- **UGC / messaging (Guideline 1.2):** Invite-only room chat. Long-press any message to Block (server-synced, takes effect instantly) or Report. Reports go to a server-side queue; admins act on them in Me → Admin Console → Reports (ignore, or ban the user — the account is disabled and signed out at once).
- **IAP / paid features:** None.
- **Business distribution:** Consumer App Store product for private friend groups, not exclusive B2B/employee tooling.
