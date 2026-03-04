#!/usr/bin/env python3
"""Generate dogfood-corrections.csv for run-017."""
import csv, json
from datetime import datetime, timezone
from pathlib import Path

PREDICTIONS_PATH = Path("artifacts/feasibility/run-017-apple-fm-tighter-descriptions/predictions.jsonl")
OUTPUT_PATH = Path("artifacts/feasibility/run-017-apple-fm-tighter-descriptions/dogfood-corrections.csv")
CSV_FIELDS = ["item_id","reviewed","corrected","predicted_categories","corrected_categories","reason","reviewed_at","title"]

MANUAL_CORRECTIONS = {
    # other+gaming violations (other should never pair with real label)
    "5138544461": ("gaming", "other should not combine with gaming"),
    "5138510466": ("gaming", "other should not combine with gaming"),
    "5138509759": ("gaming", "other should not combine with gaming"),
    "5137531630": ("gaming", "other should not combine with gaming"),
    # other+technology violation
    "5138147775": ("technology", "other should not combine with technology"),
    # Halfbrick layoffs: gaming_industry
    "5138524556": ("gaming_industry", "studio layoffs are gaming_industry"),
    # Tripwire layoffs: gaming_industry
    "5138537016": ("gaming_industry", "studio layoffs are gaming_industry"),
    # Killing Floor layoffs: gaming_industry (currently technology|world)
    "5138486112": ("gaming_industry", "studio layoffs are gaming_industry"),
    # Nacon insolvency: gaming_industry
    "5138302362": ("gaming_industry", "game publisher insolvency is gaming_industry"),
    # Anthropic government: world|ai (missing ai)
    "5138312742": ("world|ai", "Anthropic is an AI company"),
    # Senator Wyden Anthropic: world|ai (currently just world)
    "5138147787": ("world|ai", "Anthropic is an AI company"),
    # Sam Altman DOD rushing: world|ai (missing ai)
    "5137716908": ("world|ai", "OpenAI DOD deal should have ai"),
    # Sam Altman DOD affirmed: ai|world (missing world)
    "5137858268": ("ai|world", "OpenAI DOD is ai + world"),
    # OpenAI DOD contract amendment: ai|world (missing world)
    "5137722742": ("ai|world", "OpenAI DOD contract is ai + world"),
    # Sam Altman Pentagon sentences: ai|world (currently just ai)
    "5137563585": ("ai|world", "OpenAI Pentagon is ai + world"),
    # Resident Evil: gaming (not gaming|world)
    "5138526784": ("gaming", "game content is gaming, not world"),
    # Blue Prince: gaming (not gaming|gaming_industry)
    "5138526786": ("gaming", "game release is gaming, not gaming_industry"),
    # Clair Obscur: gaming (not technology|ai — game writing advice)
    "5138537015": ("gaming", "game writing advice is gaming"),
    # Scott Pilgrim (line 3): gaming (not technology|apple — it's a game, Apple tag is wrong)
    "5138533661": ("gaming", "Scott Pilgrim game is gaming, not Apple"),
    # SpaceX IPO: technology|world (not technology|ai)
    "5138518448": ("technology|world", "SpaceX is not an AI company"),
    "5138486146": ("technology|world", "SpaceX is not an AI company"),
    # Elgato Stream Deck: technology (not technology|apple)
    "5138454170": ("technology", "Elgato is not Apple"),
    # Bungie Marathon: gaming (not technology)
    "5138487728": ("gaming", "game feedback is gaming"),
    # Pokemon FireRed: gaming (not gaming|world)
    "5138190847": ("gaming", "game port review is gaming"),
    # God of War game: gaming (not gaming|world)
    "5138190848": ("gaming", "game announcement is gaming"),
    # Capcom Spotlight: gaming (not gaming|gaming_industry)
    "5138150211": ("gaming", "game showcase is gaming"),
    # Cities Skylines: gaming (not gaming|gaming_industry)
    "5138326590": ("gaming", "game expansion is gaming"),
    # Pokemon metacritic: gaming (not technology|gaming)
    "5138296817": ("gaming", "game review/ranking is gaming"),
    # We Were Here: gaming (not technology|gaming)
    "5138460386": ("gaming", "game announcement is gaming"),
    # Unity Asset Store: technology|gaming_industry
    "5138245970": ("technology|gaming_industry", "Unity store policy affects gaming industry"),
    # Google Home: technology|home_automation|ai (Gemini is AI)
    "5138196509": ("technology|home_automation|ai", "Google Home with Gemini is home_automation + ai"),
    # Google Home camera: add ai (Gemini is AI)
    "5138114514": ("technology|home_automation|ai", "Gemini camera is home_automation + ai"),
    # Meta AI shopping: ai|technology (currently just technology, missing ai)
    "5137623677": ("technology|ai", "Meta AI shopping is ai + technology"),
    # Cursor revenue: add technology
    "5137581524": ("technology|ai", "Cursor revenue is technology + ai"),
}

def load_jsonl(p): return [json.loads(l) for l in p.read_text().splitlines() if l.strip()]
def get_labels(p): return [l["label"] for l in p.get("labels", []) if l.get("label")]

def main():
    predictions = load_jsonl(PREDICTIONS_PATH)
    now = datetime.now(timezone.utc).isoformat()
    rows, corrected_count = [], 0

    for pred in predictions:
        item_id = str(pred.get("item_id", ""))
        labels = get_labels(pred)
        predicted_str = "|".join(labels)
        if item_id in MANUAL_CORRECTIONS:
            corr_cats, reason = MANUAL_CORRECTIONS[item_id]
            if set(corr_cats.split("|")) != set(labels):
                rows.append({"item_id": item_id, "reviewed": "true", "corrected": "true",
                    "predicted_categories": predicted_str, "corrected_categories": corr_cats,
                    "reason": reason, "reviewed_at": now, "title": pred.get("title", "")})
                corrected_count += 1
                continue
        rows.append({"item_id": item_id, "reviewed": "true", "corrected": "false",
            "predicted_categories": predicted_str, "corrected_categories": "",
            "reason": "", "reviewed_at": now, "title": pred.get("title", "")})

    with OUTPUT_PATH.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS); w.writeheader(); w.writerows(rows)

    rate = corrected_count / len(rows)
    pred_by_id = {str(p["item_id"]): p for p in predictions}
    eng = [r for r in rows if not pred_by_id.get(r["item_id"], {}).get("error", "").startswith("skipped_language")]
    eng_corr = sum(1 for r in eng if r["corrected"] == "true")
    print(f"reviewed={len(rows)} corrected={corrected_count} rate={rate:.4f}")
    print(f"English: {len(eng)} reviewed, {eng_corr} corrected, rate={eng_corr/len(eng):.4f}")

    patterns = {}
    for r in rows:
        if r["corrected"] == "true":
            ps, cs = set(r["predicted_categories"].split("|")), set(r["corrected_categories"].split("|"))
            for m in cs - ps: patterns[f"missing:{m}"] = patterns.get(f"missing:{m}", 0) + 1
            for e in ps - cs: patterns[f"extra:{e}"] = patterns.get(f"extra:{e}", 0) + 1
    print("\nLabel patterns:")
    for p, c in sorted(patterns.items(), key=lambda x: -x[1]):
        print(f"  {c}x {p}")

if __name__ == "__main__": main()
