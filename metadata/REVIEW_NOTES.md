# App Review notes (paste into App Store Connect)

Paircast is an invite-only private cloud sync player. It does **not** host or stream a public catalog. Videos come from the tester’s own S3-compatible bucket. The app does not scrape Douban or IMDb.

## Demo setup

1. On the login screen open **Service Configuration**.
2. Paste the demo cloud config (`paircast://config?args=…` provided in App Store Connect review notes).
3. Save, then log in with User ID only (no password; IM login uses UserSig): `test1` or `test2`.
4. Open the library. Sample files in the bucket are public-domain / Creative Commons shorts only (e.g. Big Buck Bunny). Do not expect commercial films.
5. Tap a movie to create/join a room. Invite, synced playback, and in-room chat are available after login.

## Account deletion

Me → Delete Account. This clears the on-device Keychain config, session user id, IM nickname/avatar, and the uploaded avatar object.

## Chat safety

Rooms are invite-only. Long-press a message to block the sender (hidden locally) or report (opens the GitHub issue form).

## Privacy & support

- Privacy: https://blog.chaisz.com/Paircast/privacy/
- Support: https://blog.chaisz.com/Paircast/support/

## Encryption

HTTPS for all network I/O. Config share links use CryptoKit AES-GCM so credentials are not pasted in plaintext. `ITSAppUsesNonExemptEncryption` is set to false (standard HTTPS + authentication / config wrapping).
