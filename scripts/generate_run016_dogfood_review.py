#!/usr/bin/env python3
"""
Generate dogfood-corrections.csv for Apple FM run-016 predictions.
Manual review with explicit corrections per item.
"""

import csv
import json
from datetime import datetime, timezone
from pathlib import Path

PREDICTIONS_PATH = Path("artifacts/feasibility/run-016-apple-fm-improved-descriptions/predictions.jsonl")
OUTPUT_PATH = Path("artifacts/feasibility/run-016-apple-fm-improved-descriptions/dogfood-corrections.csv")

CSV_FIELDS = [
    "item_id", "reviewed", "corrected", "predicted_categories",
    "corrected_categories", "reason", "reviewed_at", "title",
]

# Review each English-language prediction.
# Only list items that need correction.
MANUAL_CORRECTIONS = {
    # Halfbrick layoffs: gaming_industry (not gaming|world)
    "5138524556": ("gaming_industry", "studio layoffs are gaming_industry"),
    # Resident Evil: gaming (not gaming|world — it's game content, not geopolitics)
    "5138526784": ("gaming", "game content discussion is gaming, not world"),
    # Clair Obscur: gaming (article about game writing advice, not AI)
    "5138537015": ("gaming", "article about game writing advice, not AI"),
    # Tripwire layoffs: gaming_industry (not just "world")
    "5138537016": ("gaming_industry", "studio layoffs are gaming_industry"),
    # Blue Prince on Switch 2: gaming (not gaming_industry — it's a game release)
    "5138526786": ("gaming", "game release is gaming, not gaming_industry"),
    # Blue Prince indie showcase (line 19): gaming (not gaming|other)
    "5138510466": ("gaming", "game showcase is gaming"),
    # Blue Prince indie showcase (line 20): gaming (not gaming|world)
    "5138509759": ("gaming", "game showcase is gaming, not world"),
    # SpaceX IPO: technology|world (not technology|ai — SpaceX is not an AI company)
    "5138518448": ("technology|world", "SpaceX is not an AI company"),
    "5138486146": ("technology|world", "SpaceX is not an AI company"),
    # Bungie Marathon: gaming (not "world" — it's game feedback, not geopolitics)
    "5138487728": ("gaming", "game feedback is gaming, not world"),
    # Killing Floor layoffs: gaming_industry (not just "world")
    "5138486112": ("gaming_industry", "studio layoffs are gaming_industry"),
    # We Were Here game announcement: gaming (not gaming|other)
    "5138460386": ("gaming", "game announcement is gaming"),
    # Elgato Stream Deck: technology (not technology|ai)
    "5138454170": ("technology", "Stream Deck is hardware, not AI"),
    # 6G phones: technology (not technology|ai)
    "5138510400": ("technology", "future phone hardware concepts, not AI"),
    # Anthropic government ban: world|ai (missing ai)
    "5138312742": ("world|ai", "Anthropic is an AI company"),
    # Nacon insolvency: gaming_industry (not world|other)
    "5138302362": ("gaming_industry", "game publisher insolvency is gaming_industry"),
    # Pokemon Pokopia metacritic: gaming (not technology|ai)
    "5138296817": ("gaming", "Pokemon game review is gaming, not technology or AI"),
    # Xiaomi EV hypercar: technology (not technology|ai)
    "5138176602": ("technology", "EV hypercar is technology, not AI"),
    # Pokemon FireRed: gaming (not gaming|world)
    "5138190847": ("gaming", "game port review is gaming, not world"),
    # God of War next game: gaming (not gaming|world)
    "5138190848": ("gaming", "game announcement is gaming, not world"),
    # Capcom Spotlight: gaming (not gaming|gaming_industry — it's a game showcase)
    "5138150211": ("gaming", "game showcase is gaming, not gaming_industry"),
    # Meta Ray-Ban investigation: technology|world (not technology|ai)
    "5138147775": ("technology|world", "data privacy investigation is technology + world, not AI"),
    # Senator Wyden Anthropic: world|ai (missing ai)
    "5138147787": ("world|ai", "Anthropic is an AI company"),
    # Amazon God of War TV: world (acceptable — TV casting is entertainment/world)
    # Sam Altman DOD (line 95): world|ai (missing ai)
    "5137716908": ("world|ai", "OpenAI DOD deal is world + ai"),
    # Nvidia chips smuggling: world|technology (missing technology)
    "5137767219": ("world|technology", "Nvidia chip smuggling is world + technology"),
    # Silicon Valley candidate: technology|world (not technology|ai)
    "5138325790": ("technology|world", "Silicon Valley politics is technology|world, not AI"),
    # Unity Asset Store: technology|gaming_industry (not technology|ai)
    "5138245970": ("technology|gaming_industry", "Unity Asset Store policy affects gaming industry, not AI"),
    # Meta AI shopping: ai|technology (missing technology)
    "5137992283": ("ai|technology", "Meta AI shopping tool is ai + technology"),
    # Cursor revenue: ai|technology (missing technology)
    "5137581524": ("ai|technology", "Cursor is an AI dev tool; revenue news is ai + technology"),
    # Steam Next Fest: gaming (not gaming|other)
    "5137531630": ("gaming", "Steam gaming event is gaming"),
    # Pokemon Pokopia (line 2): gaming (not gaming|other)
    "5138544461": ("gaming", "Pokemon game is gaming"),
    # Cities Skylines: gaming (not gaming|gaming_industry — it's about an expansion)
    "5138326590": ("gaming", "game expansion is gaming, not gaming_industry"),
}


def load_jsonl(path: Path):
    return [json.loads(l) for l in path.read_text().splitlines() if l.strip()]


def get_labels(pred):
    return [l["label"] for l in pred.get("labels", []) if l.get("label")]


def main():
    predictions = load_jsonl(PREDICTIONS_PATH)
    now = datetime.now(timezone.utc).isoformat()

    rows = []
    corrected_count = 0

    for pred in predictions:
        item_id = str(pred.get("item_id", ""))
        labels = get_labels(pred)
        predicted_str = "|".join(labels)

        if item_id in MANUAL_CORRECTIONS:
            corr_cats, reason = MANUAL_CORRECTIONS[item_id]
            if set(corr_cats.split("|")) != set(labels):
                rows.append({
                    "item_id": item_id, "reviewed": "true", "corrected": "true",
                    "predicted_categories": predicted_str,
                    "corrected_categories": corr_cats, "reason": reason,
                    "reviewed_at": now, "title": pred.get("title", ""),
                })
                corrected_count += 1
                continue

        rows.append({
            "item_id": item_id, "reviewed": "true", "corrected": "false",
            "predicted_categories": predicted_str,
            "corrected_categories": "", "reason": "",
            "reviewed_at": now, "title": pred.get("title", ""),
        })

    with OUTPUT_PATH.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        writer.writeheader()
        writer.writerows(rows)

    rate = corrected_count / len(rows) if rows else 0
    print(f"reviewed={len(rows)} corrected={corrected_count} correction_rate={rate:.4f}")

    # English vs Finnish
    pred_by_id = {str(p["item_id"]): p for p in predictions}
    eng = [r for r in rows if not pred_by_id.get(r["item_id"], {}).get("error", "").startswith("skipped_language")]
    eng_corr = sum(1 for r in eng if r["corrected"] == "true")
    print(f"English: {len(eng)} reviewed, {eng_corr} corrected, rate={eng_corr/max(1,len(eng)):.4f}")

    # Label-level patterns
    patterns = {}
    for r in rows:
        if r["corrected"] == "true":
            pred_s = set(r["predicted_categories"].split("|"))
            corr_s = set(r["corrected_categories"].split("|"))
            for m in corr_s - pred_s:
                patterns[f"missing:{m}"] = patterns.get(f"missing:{m}", 0) + 1
            for e in pred_s - corr_s:
                patterns[f"extra:{e}"] = patterns.get(f"extra:{e}", 0) + 1
    print("\nLabel-level correction patterns:")
    for p, c in sorted(patterns.items(), key=lambda x: -x[1]):
        print(f"  {c}x {p}")


if __name__ == "__main__":
    main()
