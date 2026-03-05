#!/usr/bin/env python3
"""
Generate dogfood-corrections.csv for Apple FM run-013 predictions.

This script reads the Apple FM predictions and applies manual review decisions.
Corrections are specified explicitly per item_id for precision.

Review policy:
- Accept the prediction if the assigned labels are reasonable given the article content.
- Correct if important labels are missing or wrong labels are assigned.
- For Finnish (skipped_language) items: accept "other" as correct since MVP is English-only.
- "technology" is a broad category that should accompany specific tech categories like "apple".
- "gaming_industry" for layoffs, studio closures, market analysis in gaming.
- "gaming" for game releases, reviews, gameplay content.
"""

import csv
import json
from datetime import datetime, timezone
from pathlib import Path

PREDICTIONS_PATH = Path("artifacts/feasibility/run-013-apple-fm-english-only/predictions.jsonl")
ITEMS_PATH = Path("data/review/current/items.jsonl")
OUTPUT_PATH = Path("artifacts/feasibility/run-013-apple-fm-english-only/dogfood-corrections.csv")

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

# Manual corrections: item_id -> (corrected_categories, reason)
# Only items that need correction are listed here.
# All other items are accepted as-is.
MANUAL_CORRECTIONS = {
    # Halfbrick layoffs: gaming_industry, not just "other"
    "5138524556": ("gaming_industry", "gaming studio layoffs should be gaming_industry"),
    # Apple Studio Display articles missing "apple" label
    "5138528030": ("technology|apple", "Apple product article should have apple label"),
    "5138523944": ("technology|apple", "Apple product article should have apple label"),
    # Venture investment article: primarily technology/ai, not just "world"
    "5138519596": ("technology|ai", "venture funding article about AI boom is technology+ai"),
    # Clair Obscur is a game development article, not AI
    "5138537015": ("gaming", "Clair Obscur is a game; article about game writing, not AI"),
    # Tripwire layoffs: gaming_industry
    "5138537016": ("gaming_industry", "gaming studio layoffs should be gaming_industry"),
    # SpaceX IPO: technology + world (not tesla, not ai)
    "5138518448": ("technology|world", "SpaceX IPO is technology + world news"),
    "5138486146": ("technology|world", "SpaceX IPO is technology + world news"),
    # Apple Studio Display XDR missing "apple"
    "5138486147": ("technology|apple", "Apple product article should have apple label"),
    # Apple MacBook Pro pricing missing "apple"
    "5138478564": ("technology|apple", "Apple product pricing article should have apple label"),
    # Apple M5 MacBook Air: should have technology alongside apple
    "5138471639": ("technology|apple", "Apple product should have both technology and apple"),
    # Killing Floor dev layoffs: gaming_industry
    "5138486112": ("gaming_industry", "gaming studio layoffs should be gaming_industry"),
    # Apple Studio Display XDR: should have technology alongside apple
    "5138471640": ("technology|apple", "Apple product should have both technology and apple"),
    # Apple M5 MacBook Air: should have technology alongside apple
    "5138486149": ("technology|apple", "Apple product should have both technology and apple"),
    # Apple MacBook Pro with LLM mention: technology|apple (ai is borderline but acceptable)
    "5138471644": ("technology|apple", "Apple product article; LLM mention is feature spec, not AI news"),
    # Fig Security: technology + ai (security startup using AI)
    "5138502444": ("technology|ai", "security startup is technology; AI-powered so ai label also fits"),
    # Anthropic government ban: world + ai
    "5138312742": ("world|ai", "Anthropic government action is world + ai"),
    # Nacon insolvency: gaming_industry + world
    "5138302362": ("gaming_industry", "game publisher insolvency is gaming_industry"),
    # Tesla Model 3 Canada: tesla (not ai, not world)
    "5138272988": ("tesla", "Tesla inventory clearance is tesla category"),
    # Unity Asset Store China: technology + gaming_industry
    "5138245970": ("technology|gaming_industry", "Unity Asset Store policy affects gaming industry"),
    # Google Home + Gemini: home_automation + ai
    "5138196509": ("home_automation|ai", "Google Home with Gemini is home_automation + ai"),
    # Google Home camera feeds: home_automation + ai (not just home_automation|other)
    "5138114514": ("home_automation|ai", "Google Home with Gemini camera feeds is home_automation + ai"),
    # Amazon God of War TV casting: this is entertainment/world, not gaming
    # Apple FM labeled it "world" which is reasonable for a TV show casting
    # Actually it's about a TV adaptation of a game - "world" is acceptable
    # Senator Wyden + Anthropic: world + ai
    "5138147787": ("world|ai", "Senator action about Anthropic is world + ai"),
    # Sam Altman DOD: ai + world
    "5137858268": ("ai|world", "OpenAI DOD contract is ai + world"),
    # Nvidia chips smuggling: world + technology
    "5137767219": ("world|technology", "chip smuggling is world + technology"),
    # Cursor revenue: ai + technology
    "5137581524": ("ai|technology", "Cursor is an AI coding tool; revenue news is ai + technology"),
    # Sam Altman Pentagon: ai + world
    "5137563585": ("ai|world", "OpenAI Pentagon agreement is ai + world"),
    # OpenAI DOD surveillance: ai + world
    "5137531308": ("ai|world", "OpenAI DOD deal is ai + world"),
    # Sam Altman DOD contract amendment: ai + world
    "5137722742": ("ai|world", "OpenAI DOD contract amendment is ai + world"),
    # Sam Altman rushing DOD deal: world + ai (Apple FM had just "world" which misses ai)
    "5137716908": ("world|ai", "OpenAI DOD deal is world + ai"),
    # Vento Games: gaming_industry (mobile studio funding, detected as non-English but it's English)
    # Actually this was skipped as language:id - accept as-is since language detection said Indonesian
    # Silicon Valley candidate: technology + world (not gaming_industry)
    "5138325790": ("technology|world", "Silicon Valley politics article is technology + world"),
}


def load_jsonl(path: Path):
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        rows.append(json.loads(stripped))
    return rows


def get_labels(pred):
    """Extract label names from prediction."""
    return [l["label"] for l in pred.get("labels", []) if l.get("label")]


def main():
    predictions = load_jsonl(PREDICTIONS_PATH)
    items = load_jsonl(ITEMS_PATH)

    items_by_id = {}
    for item in items:
        items_by_id[str(item.get("id", ""))] = item

    now = datetime.now(timezone.utc).isoformat()

    rows = []
    corrected_count = 0
    reviewed_count = 0

    for pred in predictions:
        item_id = str(pred.get("item_id", ""))
        labels = get_labels(pred)
        predicted_str = "|".join(labels)

        if item_id in MANUAL_CORRECTIONS:
            corrected_categories, reason = MANUAL_CORRECTIONS[item_id]
            # Verify the correction actually changes something
            if set(corrected_categories.split("|")) != set(labels):
                row = {
                    "item_id": item_id,
                    "reviewed": "true",
                    "corrected": "true",
                    "predicted_categories": predicted_str,
                    "corrected_categories": corrected_categories,
                    "reason": reason,
                    "reviewed_at": now,
                    "title": pred.get("title", ""),
                }
                corrected_count += 1
            else:
                # Correction matches prediction, mark as accepted
                row = {
                    "item_id": item_id,
                    "reviewed": "true",
                    "corrected": "false",
                    "predicted_categories": predicted_str,
                    "corrected_categories": "",
                    "reason": "",
                    "reviewed_at": now,
                    "title": pred.get("title", ""),
                }
        else:
            row = {
                "item_id": item_id,
                "reviewed": "true",
                "corrected": "false",
                "predicted_categories": predicted_str,
                "corrected_categories": "",
                "reason": "",
                "reviewed_at": now,
                "title": pred.get("title", ""),
            }

        rows.append(row)
        reviewed_count += 1

    # Write CSV
    with OUTPUT_PATH.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        writer.writeheader()
        writer.writerows(rows)

    rate = corrected_count / reviewed_count if reviewed_count else 0
    print(f"Done. reviewed={reviewed_count} corrected={corrected_count} correction_rate={rate:.4f}")
    print(f"Output: {OUTPUT_PATH}")

    # Print correction breakdown
    print(f"\nCorrection breakdown:")
    correction_types = {}
    for row in rows:
        if row["corrected"] == "true":
            reason = row["reason"]
            for r in reason.split(";"):
                r = r.strip()
                if r:
                    correction_types[r] = correction_types.get(r, 0) + 1
    for reason, count in sorted(correction_types.items(), key=lambda x: -x[1]):
        print(f"  {count}x {reason}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
