#!/usr/bin/env python3
"""Export redacted Swift / Kotlin sources for China software-copyright identification pages.

Produces front (30 pages) + back (30 pages) text under docs/soft-copyright/generated/.
Each page targets >= 50 lines. Secrets-like string literals are scrubbed.

Usage:
  python3 Scripts/export-soft-copyright-sources.py
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs" / "soft-copyright" / "generated"
LINES_PER_PAGE = 50
PAGES = 30

FRONT_FILES = [
    "iosApp/App/Sources/PaircastApp.swift",
    "iosApp/App/Sources/AppDelegate.swift",
    "shared/core/src/commonMain/kotlin/com/chaisz/paircast/core/model/AppCloudConfig.kt",
    "shared/core/src/commonMain/kotlin/com/chaisz/paircast/core/rules/ConfigQRCodec.kt",
    "shared/data/src/commonMain/kotlin/com/chaisz/paircast/data/config/ConfigShareLink.kt",
    "shared/core/src/commonMain/kotlin/com/chaisz/paircast/core/rules/ConfigValidation.kt",
    "shared/core/src/commonMain/kotlin/com/chaisz/paircast/core/rules/Rules.kt",
    "shared/core/src/commonMain/kotlin/com/chaisz/paircast/core/gateway/Gateways.kt",
    "shared/core/src/commonMain/kotlin/com/chaisz/paircast/core/usecase/UseCases.kt",
    "iosApp/Presentation/Sources/Navigation/AppSession.swift",
    "iosApp/Presentation/Sources/Scenes/Login/LoginView.swift",
    "iosApp/Presentation/Sources/Scenes/Config/ServiceConfigView.swift",
]

BACK_FILES = [
    "iosApp/Presentation/Sources/Player/VLCPlayerController.swift",
    "iosApp/Presentation/Sources/Scenes/Watch/WatchView.swift",
    "shared/core/src/commonMain/kotlin/com/chaisz/paircast/core/session/WatchSession.kt",
    "shared/data/src/commonMain/kotlin/com/chaisz/paircast/data/goim/GoImConnection.kt",
    "shared/data/src/commonMain/kotlin/com/chaisz/paircast/data/goim/GoImRoomMessaging.kt",
    "shared/data/src/commonMain/kotlin/com/chaisz/paircast/data/rooms/OssRoomStore.kt",
    "shared/data/src/commonMain/kotlin/com/chaisz/paircast/data/s3/SigV4.kt",
    "shared/data/src/commonMain/kotlin/com/chaisz/paircast/data/metadata/Metadata.kt",
]

SECRETISH = re.compile(
    r'(?P<prefix>(secret|Secret|accessKey|AccessKey|token|Token|password|Password|apiKey|ApiKey)\s*[:=]\s*)'
    r'(?P<q>"[^"]*"|\'[^\']*\')'
)


def redact(line: str) -> str:
    line = SECRETISH.sub(r'\g<prefix>"/*** redacted ***/"', line)
    # long base64-ish literals
    line = re.sub(r'"[A-Za-z0-9_\-+/=]{48,}"', '"/*** redacted ***/"', line)
    return line


def load_files(rel_paths: list[str]) -> list[str]:
    lines: list[str] = []
    for rel in rel_paths:
        path = ROOT / rel
        if not path.is_file():
            raise SystemExit(f"missing source: {rel}")
        lines.append(f"// ===== FILE: {rel} =====")
        for raw in path.read_text(encoding="utf-8").splitlines():
            lines.append(redact(raw.rstrip("\n")))
        lines.append("")
    return lines


def paginate(lines: list[str], pages: int, per_page: int) -> list[str]:
    need = pages * per_page
    if len(lines) < need:
        raise SystemExit(f"need {need} lines, only have {len(lines)}; add more files")
    return lines[:need]


def write_pages(lines: list[str], out_path: Path, title: str) -> None:
    pages = []
    for i in range(PAGES):
        chunk = lines[i * LINES_PER_PAGE : (i + 1) * LINES_PER_PAGE]
        header = [
            f"{title}",
            f"页码：{i + 1}/{PAGES}",
            "-" * 72,
        ]
        # pad to LINES_PER_PAGE body lines already exact
        pages.append("\n".join(header + chunk))
    out_path.write_text("\n\n" + ("\n\n" + "=" * 72 + "\n\n").join(pages) + "\n", encoding="utf-8")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    front = paginate(load_files(FRONT_FILES), PAGES, LINES_PER_PAGE)
    back_all = load_files(BACK_FILES)
    # take last N lines for "后 30 页"
    need = PAGES * LINES_PER_PAGE
    if len(back_all) < need:
        raise SystemExit(f"back sources need {need} lines, have {len(back_all)}")
    back = back_all[-need:]

    write_pages(front, OUT / "源程序-前30页.txt", "Paircast V2.0.0 源程序鉴别材料（前 30 页）")
    write_pages(back, OUT / "源程序-后30页.txt", "Paircast V2.0.0 源程序鉴别材料（后 30 页）")

    # also emit continuous plain dumps for Word/Pages import
    (OUT / "源程序-前30页-连续.txt").write_text("\n".join(front) + "\n", encoding="utf-8")
    (OUT / "源程序-后30页-连续.txt").write_text("\n".join(back) + "\n", encoding="utf-8")

    print(f"wrote {OUT}")
    print(f"front lines: {len(front)}, back lines: {len(back)}")


if __name__ == "__main__":
    main()
