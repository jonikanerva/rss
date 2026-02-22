#!/usr/bin/env python3
"""Generate a human-readable review sheet from pipeline input + keyword categorizer output.

This script replicates the Swift KeywordCategorizer logic (7 user-defined categories,
multi-label) so the review sheet matches what the Swift pipeline would produce.
"""

import json
import csv
import os
import re
from datetime import datetime, timezone


# --- Keyword categorizer (mirrors Swift KeywordCategorizer exactly) ---

KEYWORD_TO_CATEGORY = [
    (["apple", "iphone", "ipad", "mac ", "macbook", "macos", "ios ", "siri", "xcode",
      "vision pro", "airpods", "apple watch", "wwdc", "app store", "tim cook"],
     "apple"),
    (["playstation 5", "playstation5", " ps5 ", "ps5 ", "dualsense", "psn"],
     "playstation 5"),
    (["video game", "gaming", "xbox", "nintendo", "steam", "playstation", "game pass",
      "esports", "rpg", "fps", "mmorpg", "indie game", "game review", "game developer",
      "console", "switch 2", "game studio", " mod ", "dlc", "roguelike", "souls",
      "resident evil", "zelda", "pokemon", "balatro", "ubisoft", "capcom", "nioh",
      "far cry", "assassin", "saints row", "styx", "tomb raider", "god of war",
      "nier", "xenoblade", "splinter cell", "mario kart", "overwatch"],
     "video games"),
    (["artificial intelligence", " ai ", "ai-", "machine learning", "deep learning",
      "chatgpt", "openai", "anthropic", "llm", "generative ai", "neural", "gpt",
      "agentic", "codex", "claude", "gemini"],
     "ai"),
    (["science", "research", "study finds", "scientists", "physics", "biology",
      "climate", "space", "nasa", "astronomy"],
     "science"),
    (["movie", "film ", "tv show", "series", "netflix", "streaming", "disney",
      "hbo", "music", "album", "concert", "podcast", "box office", "theater",
      "karaoke", "projector", "entertainment"],
     "entertainment"),
    (["tech", "software", "hardware", "chip", "processor", "battery", "robot",
      "gadget", "device", "startup", "silicon valley", "venture", "crypto",
      "internet", "browser", "app ", "phone", "laptop", "tablet", "headphone",
      "e-reader", "kindle", "wearable", "smart home", "cybersecurity",
      "hacker", "firewall", "data center", "server"],
     "technology"),
]

CONFIDENCE_MATCH = 0.85
CONFIDENCE_FALLBACK = 0.5


def keyword_categorize(title, summary):
    """Replicate the Swift KeywordCategorizer logic (multi-label).

    Returns a list of (category, source, confidence) tuples.
    """
    text = f"{title} {summary}".lower()

    matches = []
    for keywords, category in KEYWORD_TO_CATEGORY:
        for keyword in keywords:
            if keyword in text:
                matches.append((category, "model", CONFIDENCE_MATCH))
                break

    if not matches:
        return [("unsorted", "fallback", CONFIDENCE_FALLBACK)]

    return matches


# --- Grouping (mirrors Swift GroupingPolicy) ---

def grouping_id(title):
    """Replicate the Swift GroupingPolicy logic."""
    normalized = " ".join(title.strip().lower().split())
    if not normalized:
        return "group:untitled"
    return f"group:{normalized}"


# --- Main ---

def main():
    items_path = "data/eval/dogfood-v1/items.jsonl"
    output_dir = "data/eval/dogfood-v1"

    items = []
    with open(items_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                items.append(json.loads(line))

    # Process through categorizer and grouper
    processed = []
    for item in items:
        predictions = keyword_categorize(item["title"], item["summary"])
        categories = [p[0] for p in predictions]
        cat_source = predictions[0][1]  # "model" or "fallback"
        group_id = grouping_id(item["title"])

        pub_ts = item.get("published_at")
        pub_date = ""
        if pub_ts:
            pub_date = datetime.fromtimestamp(pub_ts, tz=timezone.utc).strftime("%Y-%m-%d %H:%M")

        processed.append({
            "id": item["id"],
            "source": item["source_id"],
            "title": item["title"][:120],
            "published": pub_date,
            "pipeline_categories": "; ".join(categories),
            "category_source": cat_source,
            "group_id": group_id[:80],
        })

    # Find groups with multiple items (same-story candidates)
    group_counts = {}
    for p in processed:
        gid = p["group_id"]
        group_counts[gid] = group_counts.get(gid, 0) + 1

    multi_groups = {gid for gid, count in group_counts.items() if count > 1}

    # Write review CSV
    review_path = os.path.join(output_dir, "review-sheet.csv")
    with open(review_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow([
            "item_id",
            "source",
            "title",
            "published",
            "pipeline_categories",    # multi-label: semicolon-separated
            "category_source",
            "is_grouped",
            "group_item_count",
            "categories_correct",     # YOU FILL: true/false
            "correct_categories",     # YOU FILL: if wrong, semicolon-separated correct categories
            "grouping_correct",       # YOU FILL: true/false
            "notes",                  # YOU FILL: any observations
        ])

        for p in processed:
            gid = p["group_id"]
            is_grouped = gid in multi_groups
            group_count = group_counts.get(gid, 1)

            writer.writerow([
                p["id"],
                p["source"],
                p["title"],
                p["published"],
                p["pipeline_categories"],
                p["category_source"],
                is_grouped,
                group_count,
                "",  # categories_correct - to be filled
                "",  # correct_categories - to be filled
                "",  # grouping_correct - to be filled
                "",  # notes - to be filled
            ])

    print(f"Review sheet: {review_path}")
    print(f"Total items: {len(processed)}")

    # Category distribution (multi-label aware)
    cat_dist = {}
    fallback_count = 0
    for p in processed:
        cats = [c.strip() for c in p["pipeline_categories"].split(";")]
        for cat in cats:
            cat_dist[cat] = cat_dist.get(cat, 0) + 1
        if p["category_source"] == "fallback":
            fallback_count += 1

    print(f"\nCategory distribution (multi-label, items can appear in multiple):")
    for cat, count in sorted(cat_dist.items(), key=lambda x: -x[1]):
        print(f"  {cat}: {count} ({count/len(processed)*100:.1f}%)")

    print(f"\nFallback rate: {fallback_count}/{len(processed)} ({fallback_count/len(processed)*100:.1f}%)")

    print(f"\nGrouping:")
    print(f"  Items in multi-item groups: {sum(1 for p in processed if p['group_id'] in multi_groups)}")
    print(f"  Unique multi-item groups: {len(multi_groups)}")
    print(f"  Singleton items: {sum(1 for p in processed if p['group_id'] not in multi_groups)}")

    # Also write a corrections template
    corrections_path = os.path.join(output_dir, "dogfood-corrections.csv")
    with open(corrections_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["item_id", "reviewed", "corrected", "reason"])
        for p in processed:
            writer.writerow([p["id"], "", "", ""])

    print(f"\nCorrections template: {corrections_path}")
    print(f"\n--- INSTRUCTIONS ---")
    print(f"1. Open {review_path} in a spreadsheet")
    print(f"2. For each row, fill in:")
    print(f"   - categories_correct: true or false")
    print(f"   - correct_categories: if wrong, semicolon-separated correct categories")
    print(f"     Available: apple, playstation 5, video games, ai, science, entertainment, technology, unsorted")
    print(f"   - grouping_correct: true or false (are items in same group actually same story?)")
    print(f"   - notes: any observations")
    print(f"3. After review, the corrections CSV will be generated from your answers")


if __name__ == "__main__":
    main()
