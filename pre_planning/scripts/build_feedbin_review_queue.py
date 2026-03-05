#!/usr/bin/env python3

import argparse
import base64
import json
import re
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional


API_BASE = "https://api.feedbin.com/v2"


FULL_CONTENT_MIN_BODY_CHARS = 300


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build review queue from Feedbin entries")
    parser.add_argument("--output", required=True, help="Output JSONL path")
    parser.add_argument("--max-items", type=int, default=500, help="Max item count")
    parser.add_argument("--per-page", type=int, default=100, help="Feedbin entries per page")
    parser.add_argument("--env-file", default=".env", help="Path to env file containing Feedbin credentials")
    parser.add_argument("--include-read", action="store_true", help="Include read entries if API supports unread filter")
    parser.add_argument("--profile", help="Optional JSON profile file for include/exclude source filters and defaults")
    parser.add_argument("--include-source", action="append", dest="include_sources", default=[], help="Keep only source_id containing this text (repeatable)")
    parser.add_argument("--exclude-source", action="append", dest="exclude_sources", default=[], help="Exclude source_id containing this text (repeatable)")
    parser.add_argument("--no-extract", action="store_true", help="Skip full content extraction via extracted_content_url")
    return parser.parse_args()


def load_profile(path: Optional[str]) -> Dict[str, Any]:
    if not path:
        return {}

    profile_path = Path(path)
    if not profile_path.exists():
        return {}

    try:
        payload = json.loads(profile_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}

    if isinstance(payload, dict):
        return payload

    return {}


def parse_env_file(path: Path) -> Dict[str, str]:
    data: Dict[str, str] = {}
    if not path.exists():
        return data

    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        data[key.strip()] = value.strip()
    return data


def get_credentials(env_file: Path) -> Optional[tuple[str, str]]:
    import os

    username = os.environ.get("FEEDBIN_USERNAME", "").strip()
    password = os.environ.get("FEEDBIN_PASSWORD", "").strip()
    if username and password:
        return username, password

    parsed = parse_env_file(env_file)
    username = parsed.get("FEEDBIN_USERNAME", "").strip()
    password = parsed.get("FEEDBIN_PASSWORD", "").strip()
    if username and password:
        return username, password

    return None


def auth_header(username: str, password: str) -> str:
    token = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
    return f"Basic {token}"


def request_json(url: str, authorization: str) -> Any:
    request = urllib.request.Request(
        url=url,
        headers={
            "Authorization": authorization,
            "Accept": "application/json",
            "User-Agent": "rss-feedbin-review-queue/1.0",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = response.read().decode("utf-8")
    return json.loads(payload)


def parse_iso_to_epoch(value: str, fallback: int) -> int:
    raw = value.strip()
    if not raw:
        return fallback

    normalized = raw.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(normalized)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return int(dt.timestamp())
    except ValueError:
        return fallback


def strip_html(value: str) -> str:
    text = re.sub(r"<script\b[^>]*>.*?</script>", " ", value, flags=re.IGNORECASE | re.DOTALL)
    text = re.sub(r"<style\b[^>]*>.*?</style>", " ", text, flags=re.IGNORECASE | re.DOTALL)
    text = re.sub(r"<[^>]+>", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def source_id_from_feed(feed: Dict[str, Any]) -> str:
    site_url = str(feed.get("site_url", "")).strip().lower()
    if site_url:
        parsed = urllib.parse.urlparse(site_url)
        host = parsed.netloc or parsed.path
        host = host.strip().lower()
        if host:
            return host
    return f"feedbin-{feed.get('id', 'unknown')}"


def load_subscription_feed_map(authorization: str) -> Dict[int, Dict[str, Any]]:
    subscriptions_raw = request_json(f"{API_BASE}/subscriptions.json", authorization)
    if not isinstance(subscriptions_raw, list):
        return {}
    mapped: Dict[int, Dict[str, Any]] = {}
    for subscription in subscriptions_raw:
        if not isinstance(subscription, dict):
            continue
        feed_id = subscription.get("feed_id")
        if isinstance(feed_id, int):
            mapped[feed_id] = subscription
    return mapped


def fetch_extracted_content(extracted_content_url: str) -> Optional[str]:
    """Fetch full article content from Feedbin's extracted_content_url (Mercury Parser)."""
    if not extracted_content_url:
        return None

    try:
        request = urllib.request.Request(
            url=extracted_content_url,
            headers={
                "Accept": "application/json",
                "User-Agent": "rss-feedbin-review-queue/1.0",
            },
        )
        with urllib.request.urlopen(request, timeout=15) as response:
            payload = response.read().decode("utf-8")
        parsed = json.loads(payload)
        if not isinstance(parsed, dict):
            return None
        content_html = parsed.get("content")
        if not content_html or not isinstance(content_html, str):
            return None
        return strip_html(content_html)
    except (urllib.error.URLError, json.JSONDecodeError, TimeoutError, OSError):
        return None


def body_looks_like_excerpt(summary: str, body: str) -> bool:
    """Return True if body appears to be just an excerpt (short or same as summary)."""
    if not body.strip():
        return True
    if summary.strip() and body.strip() == summary.strip():
        return True
    if len(body.strip()) < FULL_CONTENT_MIN_BODY_CHARS:
        return True
    return False


def entry_to_row(entry: Dict[str, Any], feed_map: Dict[int, Dict[str, Any]], fetched_at: int, extract_full_content: bool = True) -> Dict[str, Any]:
    entry_id = str(entry.get("id", "")).strip()
    title = str(entry.get("title", "") or "").strip()
    summary_raw = str(entry.get("summary", "") or "")
    content_raw = str(entry.get("content", "") or "")
    url = str(entry.get("url", "") or "").strip()
    extracted_content_url = str(entry.get("extracted_content_url", "") or "").strip()

    feed_id_value = entry.get("feed_id")
    feed_id = feed_id_value if isinstance(feed_id_value, int) else -1
    feed = feed_map.get(feed_id, {})
    source_id = source_id_from_feed(feed)

    summary = strip_html(summary_raw)
    body = strip_html(content_raw)
    if not body:
        body = summary

    content_source = "feed"

    if extract_full_content and body_looks_like_excerpt(summary, body) and extracted_content_url:
        extracted = fetch_extracted_content(extracted_content_url)
        if extracted and len(extracted) > len(body):
            body = extracted
            content_source = "feedbin_extract"

    published_at = parse_iso_to_epoch(str(entry.get("published", "")), fetched_at)
    updated_at = parse_iso_to_epoch(str(entry.get("created_at", "")), published_at)

    return {
        "id": entry_id or f"feedbin-entry-{feed_id}-{published_at}",
        "source_id": source_id,
        "title": title,
        "summary": summary,
        "body": body,
        "published_at": published_at,
        "updated_at": updated_at,
        "fetched_at": fetched_at,
        "link": url,
        "content_source": content_source,
    }


def fetch_entries(authorization: str, max_items: int, per_page: int, include_read: bool) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    page = 1
    while len(rows) < max_items:
        params: Dict[str, Any] = {"page": page, "per_page": per_page}
        if not include_read:
            params["read"] = "false"
        query = urllib.parse.urlencode(params)
        url = f"{API_BASE}/entries.json?{query}"
        payload = request_json(url, authorization)
        if not isinstance(payload, list) or not payload:
            break
        if not isinstance(payload[0], dict):
            break
        rows.extend(payload)
        if len(payload) < per_page:
            break
        page += 1
    return rows[:max_items]


def main() -> int:
    args = parse_args()
    profile = load_profile(args.profile)

    max_items = int(profile.get("max_items", args.max_items))
    per_page = int(profile.get("per_page", args.per_page))
    include_read = bool(profile.get("include_read", args.include_read))

    profile_include = profile.get("include_sources", [])
    profile_exclude = profile.get("exclude_sources", [])

    include_sources_cli = args.include_sources if args.include_sources else []
    exclude_sources_cli = args.exclude_sources if args.exclude_sources else []
    creds = get_credentials(Path(args.env_file))
    if creds is None:
        raise SystemExit("Missing Feedbin credentials in env or env file")

    username, password = creds
    authorization = auth_header(username, password)

    try:
        feed_map = load_subscription_feed_map(authorization)
        raw_entries = fetch_entries(
            authorization,
            max_items=max(1, max_items),
            per_page=max(20, per_page),
            include_read=include_read,
        )
    except urllib.error.HTTPError as error:
        if error.code == 401:
            raise SystemExit("Feedbin authentication failed (401)")
        raise

    extract_full_content = not args.no_extract

    fetched_at = int(datetime.now(tz=timezone.utc).timestamp())
    rows: List[Dict[str, Any]] = []
    seen_ids: set[str] = set()
    extract_count = 0
    for entry in raw_entries:
        if not isinstance(entry, dict):
            continue
        row = entry_to_row(entry, feed_map, fetched_at, extract_full_content=extract_full_content)
        item_id = row["id"]
        if item_id in seen_ids:
            continue
        seen_ids.add(item_id)
        if not row["title"]:
            continue
        if row.get("content_source") == "feedbin_extract":
            extract_count += 1
        rows.append(row)

    rows.sort(key=lambda row: row.get("published_at", 0), reverse=True)

    include_sources = [token.lower().strip() for token in [*profile_include, *include_sources_cli] if str(token).strip()]
    exclude_sources = [token.lower().strip() for token in [*profile_exclude, *exclude_sources_cli] if str(token).strip()]
    if include_sources:
        rows = [
            row
            for row in rows
            if any(token in str(row.get("source_id", "")).lower() for token in include_sources)
        ]
    if exclude_sources:
        rows = [
            row
            for row in rows
            if all(token not in str(row.get("source_id", "")).lower() for token in exclude_sources)
        ]

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=True) + "\n")

    print(json.dumps({
        "items_written": len(rows),
        "items_extracted": extract_count,
        "output": str(output_path),
    }, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
