#!/usr/bin/env python3
"""
Generate dogfood-corrections.csv for Apple FM run-014 predictions.
Manual review with explicit corrections per item.
"""

import csv
import json
from datetime import datetime, timezone
from pathlib import Path

PREDICTIONS_PATH = Path("artifacts/feasibility/run-014-apple-fm-multi-label/predictions.jsonl")
OUTPUT_PATH = Path("artifacts/feasibility/run-014-apple-fm-multi-label/dogfood-corrections.csv")

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

# Manual corrections for run-014
# Only items that need correction are listed here.
MANUAL_CORRECTIONS = {
    # Pokemon Pokopia: gaming only, "other" violates "never combine other with another category"
    "5138544461": ("gaming", "other should not be combined with gaming per prompt rules"),
    # Halfbrick layoffs: gaming_industry, not technology|gaming
    "5138524556": ("gaming_industry", "studio layoffs are gaming_industry, not technology|gaming"),
    # Resident Evil: gaming only, "other" violates rule
    "5138526784": ("gaming", "other should not be combined with gaming"),
    # Xbox Game Pass: gaming only, not gaming_industry (this is game releases, not industry news)
    "5138526785": ("gaming", "Game Pass monthly lineup is gaming, not gaming_industry"),
    # Clair Obscur: gaming, not technology|ai (it's about game writing advice)
    "5138537015": ("gaming", "article about game writing advice, not technology or AI"),
    # Tripwire layoffs: gaming_industry, not technology|gaming
    "5138537016": ("gaming_industry", "studio layoffs are gaming_industry"),
    # Xiaomi phone: technology only, not ai (article explicitly says they DON'T focus on AI)
    "5138510401": ("technology", "article says Xiaomi focuses on hardware not AI"),
    # SpaceX IPO: technology|world, not ai (SpaceX is not an AI company)
    "5138518448": ("technology|world", "SpaceX is not an AI company"),
    "5138486146": ("technology|world", "SpaceX is not an AI company"),
    # Bungie Marathon: gaming only, "other" violates rule
    "5138487728": ("gaming", "other should not be combined with gaming"),
    # Killing Floor layoffs: gaming_industry, not technology|gaming
    "5138486112": ("gaming_industry", "studio layoffs are gaming_industry"),
    # Nacon insolvency: gaming_industry, not technology|world
    "5138302362": ("gaming_industry", "game publisher insolvency is gaming_industry"),
    # GoPro cameras: technology only, not ai
    "5138454171": ("technology", "GoPro cameras are technology, not AI"),
    # Elgato Stream Deck: technology only, not ai (it's a hardware product)
    "5138454170": ("technology", "Elgato Stream Deck is hardware, not AI"),
    # Elgato microphone: technology only, not ai
    "5138447690": ("technology", "Elgato microphone is hardware, not AI"),
    # Oppo phone: technology only, not ai
    "5137950073": ("technology", "Oppo phone launch is technology, not AI"),
    # 6G phones: technology only, not ai (article is about phone hardware concepts)
    "5138510400": ("technology", "article about future phone hardware, not AI"),
    # Xiaomi EV hypercar: technology|tesla (EV related), not gaming
    "5138176602": ("technology", "Xiaomi EV hypercar is technology, not gaming"),
    # Pokemon FireRed: gaming only, "other" violates rule
    "5138190847": ("gaming", "other should not be combined with gaming"),
    # Blue Prince on Switch 2: gaming only, not world
    "5138526786": ("gaming", "game release is gaming, not world"),
    "5138510466": ("gaming", "game release is gaming, not world"),
    # Capcom Spotlight: gaming only, not world
    "5138150211": ("gaming", "game showcase is gaming, not world"),
    # Iranian crypto: world only, not ai (crypto is not AI)
    "5138252241": ("world", "Iranian crypto outflows are world news, not AI"),
    # Unity Asset Store: technology|gaming_industry, not ai
    "5138245970": ("technology|gaming_industry", "Unity Asset Store policy is technology + gaming_industry, not AI"),
    # Google Home: home_automation|ai|technology (missing home_automation in run-014)
    "5138196509": ("technology|ai|home_automation", "Google Home update should include home_automation"),
    # Silicon Valley candidate: technology|world, not ai
    "5138325790": ("technology|world", "Silicon Valley politics is technology|world, not AI"),
    # Grow Therapy: technology only, not ai (it's a health tech startup)
    "5138302192": ("technology", "health tech startup is technology, not AI"),
    # Sam Altman DOD: ai|world, missing ai label
    "5137858268": ("ai|world", "OpenAI DOD article should have ai label"),
    # OpenAI DOD contract: ai|world, missing ai
    "5137722742": ("ai|world", "OpenAI DOD contract should have ai label"),
    # OpenAI DOD deal: ai|world, missing ai
    "5137531308": ("ai|world", "OpenAI DOD deal should have ai label"),
    # Sam Altman Pentagon: ai|world, missing world
    "5137563585": ("ai|world", "OpenAI Pentagon agreement should have world label"),
    # Pronto home services: technology only, not home_automation (it's a gig economy app, not smart home)
    "5137603638": ("technology", "Pronto is a home services app, not home automation/smart home"),
    # Pinterest investment: technology only, not world
    "5138331973": ("technology", "Pinterest stock buyback is technology/finance, not world"),
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
    return [l["label"] for l in pred.get("labels", []) if l.get("label")]


def main():
    predictions = load_jsonl(PREDICTIONS_PATH)
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

    with OUTPUT_PATH.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        writer.writeheader()
        writer.writerows(rows)

    rate = corrected_count / reviewed_count if reviewed_count else 0
    print(f"Done. reviewed={reviewed_count} corrected={corrected_count} correction_rate={rate:.4f}")
    print(f"Output: {OUTPUT_PATH}")

    # Correction pattern analysis
    patterns = {}
    for row in rows:
        if row["corrected"] == "true":
            pred = set(row["predicted_categories"].split("|"))
            corr = set(row["corrected_categories"].split("|"))
            missing = corr - pred
            extra = pred - corr
            for m in missing:
                patterns[f"missing:{m}"] = patterns.get(f"missing:{m}", 0) + 1
            for e in extra:
                patterns[f"extra:{e}"] = patterns.get(f"extra:{e}", 0) + 1

    print("\nLabel-level correction patterns:")
    for p, c in sorted(patterns.items(), key=lambda x: -x[1]):
        print(f"  {c}x {p}")

    # English vs Finnish breakdown
    eng = [r for r in rows if "skipped_language" not in (r.get("predicted_categories", "") + str(pred))]
    # Actually check predictions for error field
    pred_by_id = {str(p["item_id"]): p for p in predictions}
    eng_rows = [r for r in rows if not pred_by_id.get(r["item_id"], {}).get("error", "").startswith("skipped_language")]
    fin_rows = [r for r in rows if pred_by_id.get(r["item_id"], {}).get("error", "").startswith("skipped_language")]
    eng_corr = sum(1 for r in eng_rows if r["corrected"] == "true")
    print(f"\nEnglish: {len(eng_rows)} reviewed, {eng_corr} corrected, rate={eng_corr/max(1,len(eng_rows)):.4f}")
    print(f"Finnish: {len(fin_rows)} reviewed, 0 corrected")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
