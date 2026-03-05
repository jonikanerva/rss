#!/usr/bin/env python3

import argparse
import json
import re
import subprocess
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run local LLM categorization pass on a review queue")
    parser.add_argument("--dataset", required=True, help="Path to review queue JSONL")
    parser.add_argument("--categories", required=True, help="Path to categories YAML")
    parser.add_argument("--llm-command", required=True, help="Shell command that reads one JSON payload from stdin")
    parser.add_argument("--output-dir", required=True, help="Output artifact directory")
    parser.add_argument("--taxonomy-version", default="v1-reset", help="Taxonomy version label")
    parser.add_argument("--max-labels", type=int, default=3, help="Maximum labels per item")
    return parser.parse_args()


def parse_categories_yaml(path: Path) -> tuple[List[str], str, Dict[str, str]]:
    labels: List[str] = []
    fallback_label = ""
    descriptions: Dict[str, str] = {}
    name_pattern = re.compile(r"^\s*-\s*name:\s*([A-Za-z0-9_\-]+)\s*$")
    fallback_pattern = re.compile(r"^\s*fallback_label:\s*([A-Za-z0-9_\-]+)\s*$")
    description_pattern = re.compile(r"^\s*description:\s*\"?(.*?)\"?\s*$")
    current_label = ""

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.rstrip()
        name_match = name_pattern.match(line)
        if name_match:
            current_label = name_match.group(1).strip()
            labels.append(current_label)
            continue

        description_match = description_pattern.match(line)
        if description_match and current_label:
            descriptions[current_label] = description_match.group(1).strip()
            continue

        fallback_match = fallback_pattern.match(line)
        if fallback_match:
            fallback_label = fallback_match.group(1).strip()

    if not labels:
        labels = ["other"]

    if fallback_label not in labels:
        if "other" in labels:
            fallback_label = "other"
        elif "unsorted" in labels:
            fallback_label = "unsorted"
        else:
            fallback_label = labels[0]

    return labels, fallback_label, descriptions


def load_items(path: Path) -> List[Dict[str, Any]]:
    items: List[Dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        try:
            row = json.loads(stripped)
        except json.JSONDecodeError:
            continue
        if isinstance(row, dict):
            items.append(row)
    return items


def run_llm(command: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    proc = subprocess.run(
        ["/bin/sh", "-lc", command],
        input=json.dumps(payload, ensure_ascii=True).encode("utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    if proc.returncode != 0:
        return {"labels": [], "story_key": ""}

    out = proc.stdout.decode("utf-8", errors="replace").strip()
    if not out:
        return {"labels": [], "story_key": ""}

    try:
        parsed = json.loads(out)
    except json.JSONDecodeError:
        return {"labels": [], "story_key": ""}

    if not isinstance(parsed, dict):
        return {"labels": [], "story_key": ""}

    return parsed


def load_existing_predictions(path: Path) -> Dict[str, Dict[str, Any]]:
    """Load already-completed predictions for resume support."""
    existing: Dict[str, Dict[str, Any]] = {}
    if not path.exists():
        return existing
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        try:
            row = json.loads(stripped)
        except json.JSONDecodeError:
            continue
        if isinstance(row, dict):
            item_id = str(row.get("item_id", "")).strip()
            if item_id:
                existing[item_id] = row
    return existing


def main() -> int:
    args = parse_args()
    dataset_path = Path(args.dataset)
    categories_path = Path(args.categories)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    labels, fallback_label, descriptions = parse_categories_yaml(categories_path)
    items = load_items(dataset_path)

    predictions_path = output_dir / "predictions.jsonl"
    label_counts: Counter[str] = Counter()
    fallback_count = 0

    # Resume support: load existing predictions and skip already-processed items
    existing_predictions = load_existing_predictions(predictions_path)
    if existing_predictions:
        print(f"Resuming: {len(existing_predictions)} items already processed", file=sys.stderr)

    # Recount stats from existing predictions
    for pred in existing_predictions.values():
        pred_labels = pred.get("labels", [])
        if isinstance(pred_labels, list):
            for row in pred_labels:
                if isinstance(row, dict):
                    lbl = str(row.get("label", "")).strip()
                    if lbl:
                        label_counts[lbl] += 1
            if len(pred_labels) == 1 and isinstance(pred_labels[0], dict) and str(pred_labels[0].get("label", "")).strip() == fallback_label:
                fallback_count += 1

    newly_processed = 0
    with predictions_path.open("a" if existing_predictions else "w", encoding="utf-8") as f:
        for idx, item in enumerate(items, start=1):
            item_id = str(item.get("id", "")).strip()

            # Skip already-processed items
            if item_id in existing_predictions:
                continue

            payload = {
                "item_id": item_id,
                "title": str(item.get("title", "") or ""),
                "summary": str(item.get("summary", "") or ""),
                "body": str(item.get("body", "") or ""),
                "taxonomy_version": args.taxonomy_version,
                "candidate_categories": labels,
                "category_definitions": [
                    {"name": label, "description": descriptions.get(label, "")}
                    for label in labels
                ],
                "max_labels": max(1, args.max_labels),
            }
            raw_pred = run_llm(args.llm_command, payload)

            raw_labels = raw_pred.get("labels") if isinstance(raw_pred, dict) else []
            parsed_labels: List[Dict[str, Any]] = []
            if isinstance(raw_labels, list):
                for row in raw_labels:
                    if not isinstance(row, dict):
                        continue
                    label = str(row.get("label", "")).strip()
                    if not label or label not in labels:
                        continue
                    confidence = row.get("confidence", 0.0)
                    try:
                        confidence_value = float(confidence)
                    except (TypeError, ValueError):
                        confidence_value = 0.0
                    if confidence_value < 0:
                        confidence_value = 0.0
                    if confidence_value > 1:
                        confidence_value = 1.0
                    parsed_labels.append({"label": label, "confidence": confidence_value})

            if not parsed_labels:
                parsed_labels = [{"label": fallback_label, "confidence": 0.0}]

            for row in parsed_labels:
                label_counts[row["label"]] += 1

            if len(parsed_labels) == 1 and parsed_labels[0]["label"] == fallback_label:
                fallback_count += 1

            prediction_row = {
                "item_id": item_id,
                "source_id": str(item.get("source_id", "")),
                "title": str(item.get("title", "")),
                "labels": parsed_labels,
                "story_key": str(raw_pred.get("story_key", "") if isinstance(raw_pred, dict) else ""),
            }
            f.write(json.dumps(prediction_row, ensure_ascii=True) + "\n")
            f.flush()
            newly_processed += 1
            done = len(existing_predictions) + newly_processed
            print(f"[{done}/{len(items)}] {item_id}: {[l['label'] for l in parsed_labels]}", file=sys.stderr)

    now = datetime.now(timezone.utc).isoformat()
    metrics = {
        "run_started_at": now,
        "dataset_path": str(dataset_path),
        "categories_path": str(categories_path),
        "taxonomy_version": args.taxonomy_version,
        "total_items": len(items),
        "categorized_items": len(items),
        "fallback_label": fallback_label,
        "fallback_count": fallback_count,
        "fallback_rate": (fallback_count / len(items)) if items else 0.0,
        "label_counts": dict(sorted(label_counts.items())),
    }
    (output_dir / "metrics.json").write_text(json.dumps(metrics, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")

    runtime_manifest = {
        "llm_command": args.llm_command,
        "max_labels": args.max_labels,
        "taxonomy_version": args.taxonomy_version,
        "candidate_categories": labels,
    }
    (output_dir / "runtime-manifest.json").write_text(
        json.dumps(runtime_manifest, indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )

    print(json.dumps({"items_processed": len(items), "output_dir": str(output_dir)}, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
