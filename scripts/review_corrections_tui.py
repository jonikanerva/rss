#!/usr/bin/env python3

import argparse
import csv
import json
import re
import subprocess
import sys
import termios
import textwrap
import tty
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional


CSV_FIELDS = [
    "item_id",
    "reviewed",
    "corrected",
    "predicted_categories",
    "corrected_categories",
    "reason",
    "reviewed_at",
    "title",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Interactive review tool for dogfood corrections")
    parser.add_argument("--dataset", required=True, help="Path to items.jsonl")
    parser.add_argument("--taxonomy-manifest", required=True, help="Path to taxonomy-v2-manifest.json")
    parser.add_argument("--llm-command", required=True, help="Local LLM command used for category predictions")
    parser.add_argument("--output", required=True, help="Path to dogfood-corrections.csv")
    parser.add_argument("--cache", help="Optional prediction cache JSONL path")
    parser.add_argument("--target-reviewed", type=int, default=300, help="Target reviewed item count")
    parser.add_argument("--max-labels", type=int, default=3, help="Max labels requested per article")
    parser.add_argument("--body-chars", type=int, default=900, help="Body preview length")
    parser.add_argument("--allow-synthetic", action="store_true", help="Allow reviewing obviously synthetic dataset rows")
    return parser.parse_args()


def load_jsonl(path: Path) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        rows.append(json.loads(stripped))
    return rows


def load_taxonomy_manifest(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def load_existing_reviews(path: Path) -> List[Dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def load_prediction_cache(path: Path) -> Dict[str, Dict[str, Any]]:
    if not path.exists():
        return {}
    cache: Dict[str, Dict[str, Any]] = {}
    for row in load_jsonl(path):
        item_id = str(row.get("item_id", "")).strip()
        if item_id:
            cache[item_id] = row
    return cache


def append_prediction_cache(path: Path, row: Dict[str, Any]) -> None:
    line = json.dumps(row, ensure_ascii=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def ensure_csv_header(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.stat().st_size == 0:
        with path.open("w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=CSV_FIELDS)
            writer.writeheader()
        return

    with path.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        existing_fields = reader.fieldnames or []
        existing_rows = list(reader)

    if existing_fields == CSV_FIELDS:
        return

    migrated_rows: List[Dict[str, str]] = []
    for row in existing_rows:
        migrated_rows.append({key: row.get(key, "") for key in CSV_FIELDS})

    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        writer.writeheader()
        writer.writerows(migrated_rows)


def append_review_row(path: Path, row: Dict[str, str]) -> None:
    with path.open("a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        writer.writerow(row)


def run_llm_command(command: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    proc = subprocess.run(
        ["/bin/sh", "-lc", command],
        input=json.dumps(payload, ensure_ascii=True).encode("utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        stderr = proc.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"llm command failed: {stderr}")

    raw = proc.stdout.decode("utf-8", errors="replace").strip()
    if not raw:
        return {"labels": [{"label": "unsorted", "confidence": 0.0}], "story_key": "story-unknown"}

    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        parsed = {"labels": [{"label": "unsorted", "confidence": 0.0}], "story_key": "story-unknown"}

    labels = parsed.get("labels") if isinstance(parsed, dict) else None
    if not isinstance(labels, list) or not labels:
        parsed = {"labels": [{"label": "unsorted", "confidence": 0.0}], "story_key": "story-unknown"}

    return parsed


def prediction_payload(item: Dict[str, Any], taxonomy_version: str, categories: List[str], max_labels: int) -> Dict[str, Any]:
    return {
        "item_id": item.get("id", ""),
        "title": item.get("title", "") or "",
        "summary": item.get("summary", "") or "",
        "body": item.get("body", "") or "",
        "taxonomy_version": taxonomy_version,
        "candidate_categories": categories,
        "max_labels": max(1, max_labels),
    }


def labels_to_string(labels: List[Dict[str, Any]]) -> str:
    output: List[str] = []
    for item in labels:
        label = str(item.get("label", "")).strip()
        if not label:
            continue
        confidence = item.get("confidence")
        if isinstance(confidence, (float, int)):
            output.append(f"{label} ({float(confidence):.2f})")
        else:
            output.append(label)
    return ", ".join(output)


def normalized_categories_input(raw: str) -> str:
    chunks = [chunk.strip() for chunk in raw.replace(",", "|").split("|")]
    clean = [chunk for chunk in chunks if chunk]
    return "|".join(clean)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def get_single_key(prompt: str) -> str:
    if not sys.stdin.isatty():
        return input(prompt).strip()[:1].lower()

    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        sys.stdout.write(prompt)
        sys.stdout.flush()
        ch = sys.stdin.read(1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)

    sys.stdout.write(ch + "\n")
    sys.stdout.flush()
    return ch.lower()


def print_item(item: Dict[str, Any], prediction: Dict[str, Any], index: int, total: int, body_chars: int) -> None:
    title = str(item.get("title", "")).strip()
    summary = str(item.get("summary", "")).strip()
    body = str(item.get("body", "") or "").strip()
    body_preview = body[:body_chars]
    labels = prediction.get("labels") if isinstance(prediction, dict) else []
    labels = labels if isinstance(labels, list) else []
    story_key = prediction.get("story_key", "") if isinstance(prediction, dict) else ""
    source_id = str(item.get("source_id", "")).strip()
    link = str(item.get("link", "")).strip()

    print("\n" + "=" * 88)
    print(f"Item {index}/{total}  id={item.get('id', '')}")
    if source_id:
        print(f"Source: {source_id}")
    if link:
        print(f"Link: {link}")
    print(f"Predicted labels: {labels_to_string(labels)}")
    print(f"Story key: {story_key}")
    print("-" * 88)
    print("TITLE:")
    print(textwrap.fill(title, width=88))
    print("\nSUMMARY:")
    print(textwrap.fill(summary or "(empty)", width=88))
    print("\nBODY PREVIEW:")
    print(textwrap.fill(body_preview or "(empty)", width=88))
    if len(body) > body_chars:
        print("... (truncated)")


def reviewed_stats(rows: List[Dict[str, str]]) -> Dict[str, float]:
    reviewed = 0
    corrected = 0
    for row in rows:
        if row.get("reviewed", "").strip().lower() == "true":
            reviewed += 1
            if row.get("corrected", "").strip().lower() == "true":
                corrected += 1
    rate = (corrected / reviewed) if reviewed else 0.0
    return {"reviewed": reviewed, "corrected": corrected, "rate": rate}


def synthetic_ratio(items: List[Dict[str, Any]], sample_size: int = 100) -> float:
    if not items:
        return 0.0

    pattern = re.compile(r"\bstory\s+\d+\s+update\b", re.IGNORECASE)
    sample = items[: min(sample_size, len(items))]
    synthetic = 0
    for item in sample:
        title = str(item.get("title", ""))
        source_id = str(item.get("source_id", ""))
        summary = str(item.get("summary", ""))
        if pattern.search(title) or source_id.startswith("feed-") or "Coverage from feed-" in summary:
            synthetic += 1

    return synthetic / len(sample)


def main() -> int:
    args = parse_args()

    dataset_path = Path(args.dataset)
    taxonomy_path = Path(args.taxonomy_manifest)
    output_path = Path(args.output)
    cache_path = Path(args.cache) if args.cache else output_path.with_suffix(".predictions-cache.jsonl")

    items = load_jsonl(dataset_path)
    synth_ratio = synthetic_ratio(items)
    if synth_ratio >= 0.6 and not args.allow_synthetic:
        print(
            "Dataset appears synthetic (>=60% sampled rows look generated).\n"
            "Use a real review queue dataset instead, or override with --allow-synthetic."
        )
        return 2

    taxonomy = load_taxonomy_manifest(taxonomy_path)
    taxonomy_version = str(taxonomy.get("taxonomyVersion", "v2"))
    categories = [str(x).strip() for x in taxonomy.get("orderedCategories", []) if str(x).strip()]
    if not categories:
        categories = ["unsorted"]

    ensure_csv_header(output_path)
    existing = load_existing_reviews(output_path)
    existing_by_item = {row.get("item_id", ""): row for row in existing}
    cache = load_prediction_cache(cache_path)

    stats = reviewed_stats(existing)
    print(f"Starting review. reviewed={int(stats['reviewed'])} corrected={int(stats['corrected'])} rate={stats['rate']:.4f}")
    print(f"Target reviewed count: {args.target_reviewed}")

    reviewed_count = int(stats["reviewed"])
    total_items = len(items)

    for idx, item in enumerate(items, start=1):
        if reviewed_count >= args.target_reviewed:
            break

        item_id = str(item.get("id", "")).strip()
        if not item_id or item_id in existing_by_item:
            continue

        if item_id in cache:
            prediction = cache[item_id]
        else:
            payload = prediction_payload(item, taxonomy_version, categories, args.max_labels)
            prediction = run_llm_command(args.llm_command, payload)
            cache_row = {
                "item_id": item_id,
                "labels": prediction.get("labels", []),
                "story_key": prediction.get("story_key", ""),
            }
            cache[item_id] = cache_row
            append_prediction_cache(cache_path, cache_row)

        print_item(item, prediction, idx, total_items, args.body_chars)
        print("Actions: [1]=OK  [2]=Correct labels  [s]=Skip  [q]=Quit")

        while True:
            action = get_single_key("Choose action: ")
            if action == "1":
                labels = prediction.get("labels", []) if isinstance(prediction, dict) else []
                predicted = "|".join(
                    str(label.get("label", "")).strip()
                    for label in labels
                    if isinstance(label, dict) and str(label.get("label", "")).strip()
                )
                row = {
                    "item_id": item_id,
                    "reviewed": "true",
                    "corrected": "false",
                    "predicted_categories": predicted,
                    "corrected_categories": "",
                    "reason": "",
                    "reviewed_at": now_iso(),
                    "title": str(item.get("title", "")),
                }
                append_review_row(output_path, row)
                existing_by_item[item_id] = row
                reviewed_count += 1
                break

            if action == "2":
                corrected_raw = input("Enter corrected categories (comma or | separated): ").strip()
                corrected_categories = normalized_categories_input(corrected_raw)
                if not corrected_categories:
                    print("No categories provided, try again.")
                    continue
                reason = input("Optional reason: ").strip()
                labels = prediction.get("labels", []) if isinstance(prediction, dict) else []
                predicted = "|".join(
                    str(label.get("label", "")).strip()
                    for label in labels
                    if isinstance(label, dict) and str(label.get("label", "")).strip()
                )
                row = {
                    "item_id": item_id,
                    "reviewed": "true",
                    "corrected": "true",
                    "predicted_categories": predicted,
                    "corrected_categories": corrected_categories,
                    "reason": reason,
                    "reviewed_at": now_iso(),
                    "title": str(item.get("title", "")),
                }
                append_review_row(output_path, row)
                existing_by_item[item_id] = row
                reviewed_count += 1
                break

            if action == "s":
                break

            if action == "q":
                final_rows = load_existing_reviews(output_path)
                final_stats = reviewed_stats(final_rows)
                print(
                    "Stopped. "
                    f"reviewed={int(final_stats['reviewed'])} "
                    f"corrected={int(final_stats['corrected'])} "
                    f"correction_rate={final_stats['rate']:.4f}"
                )
                return 0

            print("Unknown action, choose 1, 2, s, or q.")

    final_rows = load_existing_reviews(output_path)
    final_stats = reviewed_stats(final_rows)
    print(
        "Done. "
        f"reviewed={int(final_stats['reviewed'])} "
        f"corrected={int(final_stats['corrected'])} "
        f"correction_rate={final_stats['rate']:.4f}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
