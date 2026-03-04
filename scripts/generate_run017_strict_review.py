#!/usr/bin/env python3
"""
Strict dogfood review for run-017.
Only correct UNAMBIGUOUSLY wrong predictions.
Accept borderline/debatable labels as correct.

Borderline cases we ACCEPT:
- technology on gaming articles from tech publications (debatable)
- world on gaming articles with international scope (debatable)
- gaming_industry on game service announcements (debatable)
- technology on Pokemon/game articles (debatable — from tech sites)

Unambiguous errors we CORRECT:
- other combined with another category (violates description rule)
- gaming_industry for studio layoffs/closures (clearly business news)
- AI company (OpenAI, Anthropic) articles missing ai label
- OpenAI/DOD articles missing world label
- Clair Obscur is a game, not AI
- Scott Pilgrim labeled as Apple (wrong company)
- Elgato labeled as Apple (wrong company)
- SpaceX labeled as AI (wrong topic)
"""
import csv, json
from datetime import datetime, timezone
from pathlib import Path

PREDICTIONS_PATH = Path("artifacts/feasibility/run-017-apple-fm-tighter-descriptions/predictions.jsonl")
OUTPUT_PATH = Path("artifacts/feasibility/run-017-apple-fm-tighter-descriptions/dogfood-corrections.csv")
CSV_FIELDS = ["item_id","reviewed","corrected","predicted_categories","corrected_categories","reason","reviewed_at","title"]

MANUAL_CORRECTIONS = {
    # === other+real label violations (clear per description) ===
    "5138544461": ("gaming", "other combined with gaming"),
    "5138510466": ("gaming", "other combined with gaming"),
    "5138509759": ("gaming", "other combined with gaming"),
    "5137531630": ("gaming", "other combined with gaming"),
    "5138147775": ("technology", "other combined with technology"),

    # === gaming_industry for layoffs/closures (unambiguous) ===
    "5138524556": ("gaming_industry", "studio layoffs are gaming_industry"),
    "5138537016": ("gaming_industry", "studio layoffs are gaming_industry"),
    "5138486112": ("gaming_industry", "studio layoffs are gaming_industry"),
    "5138302362": ("gaming_industry", "game publisher insolvency is gaming_industry"),

    # === AI company articles missing ai label (unambiguous) ===
    "5138312742": ("world|ai", "Anthropic is an AI company"),
    "5138147787": ("world|ai", "Anthropic is an AI company"),
    "5137716908": ("world|ai", "OpenAI article missing ai"),

    # === OpenAI/DOD articles missing world (unambiguous) ===
    "5137858268": ("ai|world", "OpenAI DOD article missing world"),
    "5137722742": ("ai|world", "OpenAI DOD contract missing world"),
    "5137563585": ("ai|world", "OpenAI Pentagon agreement missing world"),

    # === Clearly wrong label assignment ===
    "5138537015": ("gaming", "Clair Obscur is a game, not AI"),
    "5138533661": ("gaming", "Scott Pilgrim is a game, not Apple"),
    "5138454170": ("technology", "Elgato is not Apple"),
    "5138518448": ("technology|world", "SpaceX is not an AI company"),
    "5138486146": ("technology|world", "SpaceX is not an AI company"),
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
    print(f"Overall: reviewed={len(rows)} corrected={corrected_count} rate={rate:.4f}")
    print(f"English: reviewed={len(eng)} corrected={eng_corr} rate={eng_corr/len(eng):.4f}")

    patterns = {}
    for r in rows:
        if r["corrected"] == "true":
            ps, cs = set(r["predicted_categories"].split("|")), set(r["corrected_categories"].split("|"))
            for m in cs - ps: patterns[f"missing:{m}"] = patterns.get(f"missing:{m}", 0) + 1
            for e in ps - cs: patterns[f"extra:{e}"] = patterns.get(f"extra:{e}", 0) + 1
    print("\nCorrection types:")
    for p, c in sorted(patterns.items(), key=lambda x: -x[1]):
        print(f"  {c}x {p}")

if __name__ == "__main__": main()
