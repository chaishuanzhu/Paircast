#!/usr/bin/env bash
# Rebuild docs/source.json (AltStore / LiveContainer source) from GitHub Releases.
# Usage: ./Scripts/update-livecontainer-source.sh [output-path]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/docs/source.json}"
REPO="${GITHUB_REPOSITORY:-chaishuanzhu/Paircast}"
SOURCE_URL="${SOURCE_URL:-https://blog.chaisz.com/Paircast/source.json}"
ICON_URL="${ICON_URL:-https://blog.chaisz.com/Paircast/icon.png}"

mkdir -p "$(dirname "$OUT")"

python3 - "$OUT" "$REPO" "$SOURCE_URL" "$ICON_URL" <<'PY'
import json, os, re, subprocess, sys
from datetime import datetime, timezone

out, repo, source_url, icon_url = sys.argv[1:5]

raw = subprocess.check_output(
    [
        "gh", "api", f"repos/{repo}/releases",
        "--paginate",
        "--jq", ".",
    ],
    text=True,
)
# --paginate with --jq "." can concatenate JSON arrays; normalize
releases = []
decoder = json.JSONDecoder()
idx = 0
raw_s = raw.strip()
while idx < len(raw_s):
    while idx < len(raw_s) and raw_s[idx].isspace():
        idx += 1
    if idx >= len(raw_s):
        break
    obj, end = decoder.raw_decode(raw_s, idx)
    if isinstance(obj, list):
        releases.extend(obj)
    else:
        releases.append(obj)
    idx = end

ipa_re = re.compile(r"^Paircast-(v[\w.\-+]+)-build(\d+)\.ipa$", re.I)
versions = []

for rel in releases:
    if rel.get("draft") or rel.get("prerelease"):
        continue
    tag = rel.get("tag_name") or ""
    published = rel.get("published_at") or rel.get("created_at") or ""
    body = (rel.get("body") or "").strip()
    notes = body.split("\n\n")[0][:500] if body else f"Paircast {tag}"
    date = published[:10] if published else datetime.now(timezone.utc).strftime("%Y-%m-%d")

    for asset in rel.get("assets") or []:
        name = asset.get("name") or ""
        if not name.lower().endswith(".ipa"):
            continue
        m = ipa_re.match(name)
        if m:
            ver_tag, build = m.group(1), m.group(2)
            marketing = ver_tag.lstrip("vV")
        else:
            marketing = tag.lstrip("vV") or "0.0.0"
            build = ""
        download = asset.get("browser_download_url")
        size = int(asset.get("size") or 0)
        if not download or size <= 0:
            continue
        entry = {
            "version": marketing,
            "date": date,
            "localizedDescription": notes,
            "downloadURL": download,
            "size": size,
        }
        if build:
            entry["buildVersion"] = build
        versions.append(entry)

# Newest first (API usually is, but sort by date+version defensively)
versions.sort(key=lambda v: (v.get("date", ""), v.get("version", ""), v.get("buildVersion", "")), reverse=True)

if not versions:
    raise SystemExit("No IPA assets found on GitHub Releases — source not updated")

latest = versions[0]
source = {
    "name": "Paircast",
    "identifier": "com.chaisz.tandem.source",
    "sourceURL": source_url,
    "subtitle": "Invite-only private cloud sync player",
    "description": "Paircast sideload source. Install or update from GitHub Releases IPAs.",
    "iconURL": icon_url,
    "website": "https://blog.chaisz.com/Paircast/",
    "tintColor": "#1A73E8",
    "apps": [
        {
            "name": "Paircast",
            "bundleIdentifier": "com.chaisz.tandem",
            "developerName": "ShuanZhu Chai",
            "localizedDescription": "Invite-only private cloud sync player for watching together with friends. Videos come from your own S3-compatible bucket.",
            "iconURL": icon_url,
            "tintColor": "#1A73E8",
            "version": latest["version"],
            "versionDate": latest["date"],
            "versionDescription": latest.get("localizedDescription", ""),
            "downloadURL": latest["downloadURL"],
            "size": latest["size"],
            "versions": versions,
        }
    ],
}
if latest.get("buildVersion"):
    source["apps"][0]["buildVersion"] = latest["buildVersion"]

with open(out, "w", encoding="utf-8") as f:
    json.dump(source, f, ensure_ascii=False, indent=2)
    f.write("\n")

print(f"Wrote {out} with {len(versions)} version(s); latest={latest['version']} build={latest.get('buildVersion', '-')}")
PY
