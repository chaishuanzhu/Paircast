#!/usr/bin/env python3
"""Build Paircast-compatible sticker packs from a SigStick/LINE dump.

Input (default): /Users/chaisz/WorkSpace/Stickers
  {nnn}-{display-name}-…/
    001-file_xxxx.gif
    …

Output (upload this folder to your bucket as `stickers/`):
  stickers-dist/
    catalog.json
    {pack_id}/
      pack.json
      {image files}

Usage:
  python3 Scripts/build-stickers.py
  python3 Scripts/build-stickers.py --src ~/WorkSpace/Stickers --out ./stickers-dist
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path

IMAGE_EXTS = {".png", ".gif", ".jpg", ".jpeg", ".webp"}
# Metadata / bot / store id segments — stop collecting display name here.
STOP_TOKEN = re.compile(
    r"^(pa_|p_|kal|moe|SigStick|line\d?|_by_|bot|emoticon|animated|Happy|New|Year|CN)",
    re.IGNORECASE,
)
# Leading brand slug in English; skip but keep following Chinese title.
SKIP_LEADING = {"capoo", "bugcat", "x"}


def _is_stop_part(part: str) -> bool:
    if not part:
        return True
    if part.startswith(("pa_", "p_")):
        return True
    if "_by_" in part or part.endswith("Bot"):
        return True
    if STOP_TOKEN.search(part):
        return True
    # Trailing usernames / kal tags: jorden2895, foo_kal
    if re.fullmatch(r"[A-Za-z]+\d+", part):
        return True
    if part.lower().endswith("_kal") or "_kal" in part.lower():
        return True
    # Capoo_Stickers / Capoo_Video3 style suffixes
    if re.match(r"^Capoo[_A-Za-z0-9]", part, re.IGNORECASE):
        return True
    return False


def parse_pack_meta(folder_name: str) -> tuple[str, str]:
    """Return (pack_id, display_name) from a dump folder name."""
    m = re.match(r"^(\d+)[-_](.+)$", folder_name)
    if not m:
        slug = re.sub(r"[^a-zA-Z0-9_-]+", "_", folder_name).strip("_").lower()
        return (slug or "pack", folder_name[:32])

    num, rest = m.group(1), m.group(2)
    pack_id = f"p{num}"

    parts: list[str] = []
    skipping_lead = True
    for part in rest.split("-"):
        if not part:
            continue
        # Keep title text before tags like 驚悚表情篇_kal
        part = re.sub(r"_kal$", "", part, flags=re.IGNORECASE)
        if not part:
            continue
        if skipping_lead and part.lower() in SKIP_LEADING:
            continue
        skipping_lead = False
        if _is_stop_part(part):
            break
        parts.append(part)

    display = "-".join(parts).strip("-_") if parts else f"Pack {num}"
    if len(display) > 36:
        display = display[:36].rstrip("-_")
    return pack_id, display


def sticker_id_from_filename(name: str) -> str:
    stem = Path(name).stem
    m = re.match(r"^(\d+)", stem)
    if m:
        return m.group(1).zfill(3)
    safe = re.sub(r"[^a-zA-Z0-9_-]+", "_", stem)
    return safe[:48] or "sticker"


def image_size(path: Path) -> tuple[int, int]:
    """Best-effort width/height; default 240 without requiring Pillow."""
    try:
        from PIL import Image  # type: ignore

        with Image.open(path) as im:
            return int(im.size[0]), int(im.size[1])
    except Exception:
        return 240, 240


def link_or_copy(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        return
    try:
        os.link(src, dst)
    except OSError:
        shutil.copy2(src, dst)


def build(src: Path, out: Path, *, clean: bool) -> int:
    if not src.is_dir():
        print(f"error: source not found: {src}", file=sys.stderr)
        return 1

    if clean and out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True, exist_ok=True)

    folders = sorted(
        [p for p in src.iterdir() if p.is_dir() and not p.name.startswith(".")],
        key=lambda p: p.name,
    )
    catalog_packs: list[dict] = []
    used_ids: set[str] = set()

    for folder in folders:
        pack_id, display = parse_pack_meta(folder.name)
        if pack_id in used_ids:
            pack_id = f"{pack_id}_{len(used_ids)}"
        used_ids.add(pack_id)

        images = sorted(
            [f for f in folder.iterdir() if f.is_file() and f.suffix.lower() in IMAGE_EXTS],
            key=lambda f: f.name,
        )
        if not images:
            print(f"skip empty: {folder.name}")
            continue

        pack_dir = out / pack_id
        pack_dir.mkdir(parents=True, exist_ok=True)

        stickers: list[dict] = []
        seen_ids: set[str] = set()
        for img in images:
            sid = sticker_id_from_filename(img.name)
            if sid in seen_ids:
                sid = f"{sid}_{len(seen_ids)}"
            seen_ids.add(sid)
            dest_name = img.name  # keep original filename for GIF/png identity
            link_or_copy(img, pack_dir / dest_name)
            w, h = image_size(img)
            stickers.append({"id": sid, "file": dest_name, "w": w, "h": h})

        cover = stickers[0]["file"]
        pack_json = {
            "pack_id": pack_id,
            "name": display,
            "version": 1,
            "cover": cover,
            "stickers": stickers,
        }
        (pack_dir / "pack.json").write_text(
            json.dumps(pack_json, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

        catalog_packs.append(
            {
                "pack_id": pack_id,
                "name": display,
                "version": 1,
                "cover": cover,
                "count": len(stickers),
            }
        )
        print(f"ok {pack_id:12} {len(stickers):3}  {display}")

    catalog = {"version": 1, "packs": catalog_packs}
    (out / "catalog.json").write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print(f"\nWrote {len(catalog_packs)} packs → {out}")
    print("Upload the contents of this folder to your object storage key prefix:")
    print("  stickers/catalog.json")
    print("  stickers/{pack_id}/pack.json + images")
    return 0


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--src",
        type=Path,
        default=Path.home() / "WorkSpace" / "Stickers",
        help="Source sticker dump directory",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=root / "stickers-dist",
        help="Output directory (Paircast stickers/ layout)",
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        help="Remove output directory before building",
    )
    args = parser.parse_args()
    return build(args.src, args.out, clean=args.clean)


if __name__ == "__main__":
    raise SystemExit(main())
