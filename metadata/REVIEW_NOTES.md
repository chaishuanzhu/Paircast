# App Review notes (paste into App Store Connect)

Tandem is a private, invite-only player. It does **not** host or stream a public catalog. Videos come from the tester’s own S3-compatible bucket (Qiniu). The app does not scrape Douban or IMDb.

## Demo setup

1. On the login screen open **服务配置**.
2. Paste the demo cloud config (or import `tandem://config?args=…` provided separately).
3. Log in with the IM user ids below (no password; IM login uses UserSig).
4. Open the library. Sample files in the bucket are public-domain / Creative Commons shorts only (e.g. Big Buck Bunny). Do not expect commercial films.

Demo IM accounts (provisioned in the Tencent IM console):

- User A (host): `REVIEW_USER_A`
- User B (guest): `REVIEW_USER_B`

## Account deletion

Me → 删除账号。This clears the on-device Keychain config, session user id, IM nickname/avatar, and the uploaded avatar object.

## Chat safety

Rooms are invite-only. Long-press a message to block the sender (hidden locally) or report (opens the support issue form).

## Encryption

HTTPS for all network I/O. Config share links use CryptoKit AES-GCM so credentials are not pasted in plaintext. `ITSAppUsesNonExemptEncryption` is set to false (standard HTTPS + authentication / config wrapping).
