#!/usr/bin/env python3
"""Generate the manifest-only lua.tools Store recommendation index."""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import json
import os
import pathlib
import re
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


DEFAULT_BASE_URL = "https://lua.tools/api/denuvo"
USER_AGENT = "LuaTools-Lumen-Index/1"
MAX_LISTING_BYTES = 32 * 1024 * 1024
MAX_DETAIL_BYTES = 2 * 1024 * 1024
FIX_ID_RE = re.compile(
    r"^(?:[a-z0-9][a-z0-9_-]{0,31}:)?"
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
CATEGORY_RANK = {
    "voices38": 10,
    "bypass": 20,
    "online_fix": 30,
    "freetp": 40,
    "other": 50,
    "denuvowo": 90,
}


def _positive_appid(value: Any) -> int | None:
    text = str(value or "")
    if not text.isdecimal():
        return None
    number = int(text)
    return number if number > 0 else None


def _normalize_fix_id(value: Any) -> str | None:
    text = str(value or "")
    return text.lower() if FIX_ID_RE.fullmatch(text) else None


def _manifest_filename(appid: int, value: Any) -> str | None:
    text = str(value or "")
    if not text or "/" in text or "\\" in text or "\x00" in text:
        return None
    if not text.lower().endswith(".lua") or not text.startswith(str(appid)):
        return None
    return text


def _tag_text(entry: dict[str, Any]) -> str:
    parts = [str(entry.get("title") or "")]
    for tag in entry.get("tags") if isinstance(entry.get("tags"), list) else []:
        if isinstance(tag, dict):
            parts.extend((str(tag.get("slug") or ""), str(tag.get("name") or "")))
        else:
            parts.append(str(tag))
    return " ".join(parts).lower()


def _classify(entry: dict[str, Any]) -> str:
    text = _tag_text(entry)
    if "voices38" in text:
        return "voices38"
    if "bypass" in text:
        return "bypass"
    if "online-fix" in text or "online fix" in text or "onlinefix" in text:
        return "online_fix"
    if "freetp" in text or "free tp" in text:
        return "freetp"
    if "denuvowo" in text or "hypervisor" in text:
        return "denuvowo"
    return "other"


def _normalize_entry(appid: int, entry: Any) -> dict[str, Any] | None:
    if not isinstance(entry, dict) or entry.get("hasManifest") is not True:
        return None
    fix_id = _normalize_fix_id(entry.get("id") or entry.get("fixId"))
    filename = _manifest_filename(
        appid, entry.get("manifestFilename") or entry.get("manifest_filename")
    )
    if not fix_id or not filename:
        return None
    return {
        "fixId": fix_id,
        "title": str(entry.get("title") or "Recommended version"),
        "category": _classify(entry),
        "createdAt": str(entry.get("createdAt") or entry.get("created_at") or ""),
        "manifestFilename": filename,
        "hasFix": entry.get("hasFix") is True,
    }


def _normalize_stored_entry(appid: int, entry: Any) -> dict[str, Any] | None:
    if not isinstance(entry, dict):
        return None
    fix_id = _normalize_fix_id(entry.get("fixId"))
    filename = _manifest_filename(appid, entry.get("manifestFilename"))
    category = str(entry.get("category") or "")
    if not fix_id or not filename or category not in CATEGORY_RANK:
        return None
    return {
        "fixId": fix_id,
        "title": str(entry.get("title") or "Recommended version"),
        "category": category,
        "createdAt": str(entry.get("createdAt") or ""),
        "manifestFilename": filename,
        "hasFix": entry.get("hasFix") is True,
    }


def _load_previous(path: pathlib.Path) -> dict[str, dict[str, Any]]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(document, dict) or document.get("schema") != 1:
        return {}
    apps = document.get("apps")
    if not isinstance(apps, dict):
        return {}
    normalized: dict[str, dict[str, Any]] = {}
    for raw_appid, entry in apps.items():
        appid = _positive_appid(raw_appid)
        parsed = _normalize_stored_entry(appid, entry) if appid else None
        if parsed:
            normalized[str(appid)] = parsed
    return normalized


def _fetch_json(url: str, *, timeout: float, retries: int, max_bytes: int) -> Any:
    last_error: Exception | None = None
    for attempt in range(retries + 1):
        try:
            request = urllib.request.Request(url, headers={
                "Accept": "application/json",
                "User-Agent": USER_AGENT,
            })
            with urllib.request.urlopen(request, timeout=timeout) as response:
                if response.status != 200:
                    raise RuntimeError(f"HTTP {response.status}")
                body = response.read(max_bytes + 1)
                if len(body) > max_bytes:
                    raise RuntimeError("response too large")
                return json.loads(body.decode("utf-8"))
        except (OSError, UnicodeError, ValueError, RuntimeError,
                urllib.error.URLError) as error:
            last_error = error
            if attempt < retries:
                time.sleep(0.2 * (2**attempt))
    raise RuntimeError(str(last_error or "request failed"))


def _detail_recommendation(appid: int, base_url: str, timeout: float,
                           retries: int) -> tuple[int, dict[str, Any] | None, str | None]:
    query = urllib.parse.urlencode({"appid": str(appid)})
    try:
        payload = _fetch_json(
            f"{base_url.rstrip('/')}/fixes?{query}", timeout=timeout,
            retries=retries, max_bytes=MAX_DETAIL_BYTES,
        )
    except RuntimeError as error:
        return appid, None, str(error)
    if not isinstance(payload, dict) or _positive_appid(payload.get("appid")) != appid:
        return appid, None, "invalid detail response"
    candidates: list[tuple[int, str, int, dict[str, Any]]] = []
    raw_fixes = payload.get("fixes") if isinstance(payload.get("fixes"), list) else []
    for order, raw in enumerate(raw_fixes):
        entry = _normalize_entry(appid, raw)
        if entry:
            candidates.append((
                CATEGORY_RANK[entry["category"]],
                str(entry["createdAt"]),
                order,
                entry,
            ))
    candidates.sort(key=lambda item: (item[0], _ReverseText(item[1]), item[2]))
    return appid, candidates[0][3] if candidates else None, None


class _ReverseText(str):
    def __lt__(self, other: object) -> bool:
        return str.__gt__(self, str(other))


def _atomic_write(path: pathlib.Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(document, ensure_ascii=False, sort_keys=True,
                         separators=(",", ":")) + "\n"
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".tmp.", dir=path.parent)
    temporary_path = pathlib.Path(temporary)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary_path, 0o644)
        os.replace(temporary_path, path)
    finally:
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass


def refresh_index(output: pathlib.Path | str, *, base_url: str = DEFAULT_BASE_URL,
                  workers: int = 6, retries: int = 2,
                  timeout: float = 12.0) -> dict[str, Any]:
    output = pathlib.Path(output)
    previous = _load_previous(output)
    try:
        listing = _fetch_json(
            f"{base_url.rstrip('/')}/listings", timeout=timeout,
            retries=retries, max_bytes=MAX_LISTING_BYTES,
        )
    except RuntimeError as error:
        return {"success": False, "error": str(error), "count": len(previous)}
    if not isinstance(listing, dict) or not isinstance(listing.get("games"), list):
        return {"success": False, "error": "invalid listings response", "count": len(previous)}

    appids = sorted({
        appid for game in listing["games"] if isinstance(game, dict)
        for appid in [_positive_appid(game.get("appid"))] if appid
    })
    if not appids:
        return {"success": False, "error": "empty listings response", "count": len(previous)}

    apps: dict[str, dict[str, Any]] = {}
    failures: list[int] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, min(workers, 12))) as pool:
        futures = [
            pool.submit(_detail_recommendation, appid, base_url, timeout, retries)
            for appid in appids
        ]
        for future in concurrent.futures.as_completed(futures):
            appid, recommendation, error = future.result()
            key = str(appid)
            if error:
                failures.append(appid)
                if key in previous:
                    apps[key] = previous[key]
            elif recommendation:
                apps[key] = recommendation

    document = {
        "schema": 1,
        "generatedAt": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
        .replace("+00:00", "Z"),
        "source": base_url,
        "apps": {key: apps[key] for key in sorted(apps, key=int)},
    }
    _atomic_write(output, document)
    return {
        "success": True,
        "count": len(apps),
        "details": len(appids),
        "failed": len(failures),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--retries", type=int, default=2)
    parser.add_argument("--timeout", type=float, default=12.0)
    args = parser.parse_args()
    result = refresh_index(args.output, base_url=args.base_url,
                           workers=args.workers, retries=args.retries,
                           timeout=args.timeout)
    print(json.dumps(result, sort_keys=True))
    return 0 if result.get("success") else 1


if __name__ == "__main__":
    raise SystemExit(main())
