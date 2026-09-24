#!/usr/bin/env python3
"""Upload Paircast stickers-dist to S3-compatible storage using a config share link.

Usage:
  python3 Scripts/upload-stickers.py 'paircast://config?args=…' [--src ./stickers-dist]

Does not print secrets. Requires cryptography.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import mimetypes
import re
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote, urlsplit

from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def b64url_decode(s: str) -> bytes:
    s = s.replace("-", "+").replace("_", "/")
    pad = (-len(s)) % 4
    if pad:
        s += "=" * pad
    return base64.b64decode(s)


def decode_config(link: str) -> dict:
    if "args=" not in link:
        raise SystemExit("expected paircast://config?args=…")
    args = link.split("args=", 1)[1].split("&", 1)[0]
    raw = b64url_decode(args)
    key = hashlib.sha256(b"Tandem.iOS.ConfigShare.v1").digest()
    plaintext = AESGCM(key).decrypt(raw[:12], raw[12:], None)
    return json.loads(plaintext.decode("utf-8"))


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def hmac_sha256(key: bytes, msg: bytes) -> bytes:
    return hmac.new(key, msg, hashlib.sha256).digest()


def uri_encode(s: str) -> str:
    return quote(s, safe="-._~")


def signing_region(storage: dict) -> str:
    if storage.get("region"):
        return storage["region"]
    ep = storage.get("endpoint", "")
    m = re.search(r"(?:s3[.-])([a-z0-9-]+)\.qiniucs\.com", ep)
    return m.group(1) if m else "cn-east-1"


def stickers_prefix(storage: dict) -> str:
    prefix = (storage.get("prefix") or "").strip().strip("/")
    return f"{prefix}/stickers" if prefix else "stickers"


def object_url(storage: dict, object_key: str) -> str:
    scheme = "https" if storage.get("useSSL", True) else "http"
    endpoint = storage["endpoint"].replace("https://", "").replace("http://", "").rstrip("/")
    bucket = storage["bucket"]
    segs = [uri_encode(p) for p in object_key.split("/") if p]
    if storage.get("forcePathStyle", True):
        return f"{scheme}://{endpoint}/{uri_encode(bucket)}/{'/'.join(segs)}"
    return f"{scheme}://{bucket}.{endpoint}/{'/'.join(segs)}"


def sign_request(
    storage: dict,
    method: str,
    url: str,
    payload: bytes = b"",
    content_type: str | None = None,
) -> dict:
    parts = urlsplit(url)
    host = parts.netloc
    region = signing_region(storage)
    now = datetime.now(timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")
    payload_hash = sha256_hex(payload)
    headers = {
        "host": host,
        "x-amz-content-sha256": payload_hash,
        "x-amz-date": amz_date,
    }
    if content_type:
        headers["content-type"] = content_type
    names = sorted(headers)
    canonical_headers = "".join(f"{k}:{headers[k]}\n" for k in names)
    signed_headers = ";".join(names)
    canonical_request = "\n".join(
        [method.upper(), parts.path or "/", "", canonical_headers, signed_headers, payload_hash]
    )
    scope = f"{date_stamp}/{region}/s3/aws4_request"
    string_to_sign = "\n".join(
        ["AWS4-HMAC-SHA256", amz_date, scope, sha256_hex(canonical_request.encode())]
    )
    k_date = hmac_sha256(("AWS4" + storage["secretKey"]).encode(), date_stamp.encode())
    k_region = hmac_sha256(k_date, region.encode())
    k_service = hmac_sha256(k_region, b"s3")
    k_signing = hmac_sha256(k_service, b"aws4_request")
    signature = hmac.new(k_signing, string_to_sign.encode(), hashlib.sha256).hexdigest()
    out = {
        "Authorization": (
            f"AWS4-HMAC-SHA256 Credential={storage['accessKey']}/{scope}, "
            f"SignedHeaders={signed_headers}, Signature={signature}"
        ),
        "x-amz-content-sha256": payload_hash,
        "x-amz-date": amz_date,
        "Host": host,
    }
    if content_type:
        out["Content-Type"] = content_type
    return out


def sign_put(storage: dict, url: str, payload: bytes, content_type: str) -> dict:
    return sign_request(storage, "PUT", url, payload, content_type)


def content_type_for(path: Path) -> str:
    mapping = {
        ".json": "application/json",
        ".png": "image/png",
        ".gif": "image/gif",
        ".txt": "text/plain; charset=utf-8",
    }
    if path.suffix.lower() in mapping:
        return mapping[path.suffix.lower()]
    guess, _ = mimetypes.guess_type(str(path))
    return guess or "application/octet-stream"


def main() -> int:
    import time

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config_link", help="paircast://config?args=…")
    parser.add_argument(
        "--src",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "stickers-dist",
    )
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--retries", type=int, default=6)
    parser.add_argument(
        "--delay",
        type=float,
        default=0.2,
        help="Seconds to sleep between uploads (reduces connection drops)",
    )
    parser.add_argument(
        "--skip-existing",
        action="store_true",
        help="HEAD object first and skip when already present",
    )
    args = parser.parse_args()

    if not args.src.is_dir():
        print(f"missing stickers dir: {args.src}", file=sys.stderr)
        return 1

    cfg = decode_config(args.config_link)
    storage = cfg["storage"]
    base = stickers_prefix(storage)

    print("provider:", storage.get("provider"), flush=True)
    print("bucket:", storage.get("bucket"), flush=True)
    print("endpoint:", storage.get("endpoint"), flush=True)
    print("prefix:", repr(storage.get("prefix")), flush=True)
    print("region:", signing_region(storage), flush=True)
    print("upload root:", base + "/", flush=True)
    print(
        f"workers={args.workers} delay={args.delay}s retries={args.retries} "
        f"skip_existing={args.skip_existing}",
        flush=True,
    )

    files = sorted(p for p in args.src.rglob("*") if p.is_file())
    print("files:", len(files), flush=True)

    def object_exists(key: str) -> bool:
        url = object_url(storage, key)
        headers = sign_request(storage, "HEAD", url)
        req = urllib.request.Request(url, method="HEAD", headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return 200 <= resp.status < 300
        except Exception as exc:  # noqa: BLE001
            code = getattr(exc, "code", None)
            return code == 200

    def upload_one(path: Path):
        rel = path.relative_to(args.src).as_posix()
        key = f"{base}/{rel}"
        if args.skip_existing and object_exists(key):
            return key, 200, None, "skip"
        data = path.read_bytes()
        last_err = None
        for attempt in range(1, args.retries + 1):
            url = object_url(storage, key)
            headers = sign_put(storage, url, data, content_type_for(path))
            req = urllib.request.Request(url, data=data, method="PUT", headers=headers)
            try:
                with urllib.request.urlopen(req, timeout=120) as resp:
                    return key, resp.status, None, "put"
            except Exception as exc:  # noqa: BLE001
                body = ""
                if hasattr(exc, "read"):
                    try:
                        body = exc.read().decode("utf-8", errors="replace")[:240]
                    except Exception:
                        pass
                last_err = f"{exc} {body}".strip()
                code = getattr(exc, "code", None)
                if code in (401, 403):
                    return key, code, last_err, "put"
                # Longer backoff on connection drops (not HTTP 429, but same idea).
                time.sleep(min(20, 0.6 * attempt * attempt))
        return key, None, last_err, "put"

    ok = fail = skipped = 0
    errors: list[tuple] = []

    def handle_result(i: int, result: tuple) -> None:
        nonlocal ok, fail, skipped
        key, code, err, kind = result
        if err or (code is not None and code >= 300):
            fail += 1
            errors.append((key, code, err))
            print(f"FAIL [{i}/{len(files)}] {key} code={code} {err}", flush=True)
            return
        if kind == "skip":
            skipped += 1
        else:
            ok += 1
        if i % 25 == 0 or i == len(files):
            print(
                f"progress [{i}/{len(files)}] put_ok={ok} skip={skipped} fail={fail} last={key}",
                flush=True,
            )

    if args.workers <= 1:
        for i, path in enumerate(files, 1):
            handle_result(i, upload_one(path))
            if args.delay > 0:
                time.sleep(args.delay)
    else:
        with ThreadPoolExecutor(max_workers=args.workers) as pool:
            futures = [pool.submit(upload_one, path) for path in files]
            for i, fut in enumerate(as_completed(futures), 1):
                handle_result(i, fut.result())
                if args.delay > 0:
                    time.sleep(args.delay)

    print(f"\nDone put_ok={ok} skip={skipped} fail={fail}", flush=True)
    for item in errors[:8]:
        print(" ", item, flush=True)
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
