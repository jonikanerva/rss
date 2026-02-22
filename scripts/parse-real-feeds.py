#!/usr/bin/env python3
"""Parse real RSS/Atom/JSON feeds into pipeline-compatible items.jsonl."""

import json
import re
import sys
import os
import time
from html import unescape
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime

# Feed data files (raw XML/JSON saved by the fetch step)
FEEDS = {
    "theverge": {
        "source_id": "theverge",
        "type": "atom",
    },
    "techmeme": {
        "source_id": "techmeme",
        "type": "rss",
    },
    "eurogamer": {
        "source_id": "eurogamer",
        "type": "rss",
    },
    "daringfireball": {
        "source_id": "daringfireball",
        "type": "atom",
    },
    "sixcolors": {
        "source_id": "sixcolors",
        "type": "json",
    },
    "arstechnica": {
        "source_id": "arstechnica",
        "type": "rss",
    },
    "macrumors": {
        "source_id": "macrumors",
        "type": "rss",
    },
    "kotaku": {
        "source_id": "kotaku",
        "type": "rss",
    },
}


def strip_html(text):
    """Remove HTML tags and decode entities."""
    if not text:
        return ""
    text = re.sub(r"<[^>]+>", " ", text)
    text = unescape(text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def parse_rfc2822(datestr):
    """Parse RFC 2822 date to unix timestamp."""
    if not datestr:
        return None
    try:
        dt = parsedate_to_datetime(datestr.strip())
        return int(dt.timestamp())
    except Exception:
        return None


def parse_iso8601(datestr):
    """Parse ISO 8601 date to unix timestamp."""
    if not datestr:
        return None
    try:
        # Handle various ISO formats
        datestr = datestr.strip()
        # Python 3.7+ fromisoformat doesn't handle all formats
        for fmt in [
            "%Y-%m-%dT%H:%M:%S%z",
            "%Y-%m-%dT%H:%M:%SZ",
            "%Y-%m-%dT%H:%M:%S.%f%z",
            "%Y-%m-%dT%H:%M:%S.%fZ",
            "%Y-%m-%dT%H:%M:%S+00:00",
        ]:
            try:
                dt = datetime.strptime(datestr, fmt)
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=timezone.utc)
                return int(dt.timestamp())
            except ValueError:
                continue
        # Try fromisoformat as fallback
        dt = datetime.fromisoformat(datestr)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return int(dt.timestamp())
    except Exception:
        return None


def parse_atom_entries(xml_text):
    """Simple regex-based Atom feed parser."""
    entries = []
    # Find all <entry>...</entry> blocks (handle tabs/whitespace around tags)
    entry_blocks = re.findall(r"<entry\b[^>]*>(.*?)</entry>", xml_text, re.DOTALL)

    for block in entry_blocks:
        # Handle CDATA in titles: <title type="html"><![CDATA[...]]></title>
        title_match = re.search(
            r"<title[^>]*>\s*(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?\s*</title>",
            block, re.DOTALL
        )
        title = strip_html(title_match.group(1)) if title_match else ""

        # Get link
        link_match = re.search(r'<link[^>]*rel="alternate"[^>]*href="([^"]*)"', block)
        if not link_match:
            link_match = re.search(r'<link[^>]*href="([^"]*)"', block)
        link = link_match.group(1) if link_match else ""

        # Get id
        id_match = re.search(r"<id>(.*?)</id>", block, re.DOTALL)
        entry_id = id_match.group(1).strip() if id_match else link

        # Get summary/content - handle CDATA
        summary_match = re.search(
            r"<summary[^>]*>\s*(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?\s*</summary>",
            block, re.DOTALL
        )
        if not summary_match:
            summary_match = re.search(
                r"<content[^>]*>\s*(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?\s*</content>",
                block, re.DOTALL
            )
        summary = strip_html(summary_match.group(1))[:500] if summary_match else ""

        # Get dates
        published_match = re.search(r"<published>(.*?)</published>", block)
        updated_match = re.search(r"<updated>(.*?)</updated>", block)

        published_at = parse_iso8601(published_match.group(1)) if published_match else None
        updated_at = parse_iso8601(updated_match.group(1)) if updated_match else None

        if title:  # Skip entries without titles
            entries.append({
                "id": entry_id,
                "title": title,
                "summary": summary,
                "published_at": published_at,
                "updated_at": updated_at,
            })

    return entries


def parse_rss_entries(xml_text):
    """Simple regex-based RSS 2.0 feed parser."""
    entries = []
    item_blocks = re.findall(r"<item>(.*?)</item>", xml_text, re.DOTALL)

    for block in item_blocks:
        # Handle CDATA in titles: <title><![CDATA[...]]></title>
        title_match = re.search(
            r"<title[^>]*>\s*(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?\s*</title>",
            block, re.DOTALL
        )
        title = strip_html(title_match.group(1)) if title_match else ""

        link_match = re.search(r"<link>(.*?)</link>", block, re.DOTALL)
        link = link_match.group(1).strip() if link_match else ""

        guid_match = re.search(r"<guid[^>]*>(.*?)</guid>", block, re.DOTALL)
        entry_id = guid_match.group(1).strip() if guid_match else link

        # Handle CDATA in descriptions
        desc_match = re.search(
            r"<description[^>]*>\s*(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?\s*</description>",
            block, re.DOTALL
        )
        summary = strip_html(desc_match.group(1))[:500] if desc_match else ""

        pubdate_match = re.search(r"<pubDate>(.*?)</pubDate>", block)
        published_at = parse_rfc2822(pubdate_match.group(1)) if pubdate_match else None

        if title:
            entries.append({
                "id": entry_id,
                "title": title,
                "summary": summary,
                "published_at": published_at,
                "updated_at": None,
            })

    return entries


def parse_json_feed(json_text):
    """Parse JSON Feed format."""
    entries = []
    try:
        feed = json.loads(json_text)
    except json.JSONDecodeError:
        return entries

    for item in feed.get("items", []):
        title = item.get("title", "")
        entry_id = item.get("id", item.get("url", ""))
        summary = strip_html(item.get("content_text", "") or item.get("content_html", ""))[:500]

        published_at = parse_iso8601(item.get("date_published"))
        updated_at = parse_iso8601(item.get("date_modified"))

        if title:
            entries.append({
                "id": entry_id,
                "title": title,
                "summary": summary,
                "published_at": published_at,
                "updated_at": updated_at,
            })

    return entries


def main():
    output_dir = os.path.join("data", "eval", "dogfood-v1")
    os.makedirs(output_dir, exist_ok=True)

    # Read raw feed files from stdin arguments or cached files
    raw_feeds_dir = os.path.join("data", "raw-feeds")

    all_items = []
    item_counter = 1

    for feed_name, config in FEEDS.items():
        feed_path = os.path.join(raw_feeds_dir, f"{feed_name}.txt")
        if not os.path.exists(feed_path):
            print(f"WARNING: {feed_path} not found, skipping", file=sys.stderr)
            continue

        with open(feed_path, "r", encoding="utf-8") as f:
            raw = f.read()

        feed_type = config["type"]
        source_id = config["source_id"]

        if feed_type == "atom":
            entries = parse_atom_entries(raw)
        elif feed_type == "rss":
            entries = parse_rss_entries(raw)
        elif feed_type == "json":
            entries = parse_json_feed(raw)
        else:
            continue

        print(f"  {feed_name}: {len(entries)} entries parsed", file=sys.stderr)

        now_ts = int(time.time())
        for entry in entries:
            # Skip sponsor/ad entries
            title_lower = entry["title"].lower()
            if title_lower.startswith("[sponsor]"):
                continue
            if "(sponsor)" in title_lower:
                continue

            item = {
                "id": str(item_counter),
                "source_id": source_id,
                "title": entry["title"],
                "summary": entry["summary"],
                "published_at": entry["published_at"],
                "updated_at": entry.get("updated_at"),
                "fetched_at": now_ts,
            }
            all_items.append(item)
            item_counter += 1

    # Write items.jsonl
    items_path = os.path.join(output_dir, "items.jsonl")
    with open(items_path, "w", encoding="utf-8") as f:
        for item in all_items:
            f.write(json.dumps(item, ensure_ascii=False) + "\n")

    print(f"\nTotal items: {len(all_items)}", file=sys.stderr)
    print(f"Written to: {items_path}", file=sys.stderr)

    # Write empty taxonomy labels (to be filled by pipeline output review)
    taxonomy_path = os.path.join(output_dir, "labels-taxonomy.csv")
    with open(taxonomy_path, "w", encoding="utf-8") as f:
        f.write("item_id,category\n")
        # We leave taxonomy labels empty - pipeline will assign categories,
        # and the human reviewer will check them

    # Write empty story labels
    story_path = os.path.join(output_dir, "labels-same-story.csv")
    with open(story_path, "w", encoding="utf-8") as f:
        f.write("item_id_a,item_id_b,label\n")

    print(f"Empty label files created at {output_dir}", file=sys.stderr)
    print("Next: run pipeline and generate review sheet", file=sys.stderr)


if __name__ == "__main__":
    main()
