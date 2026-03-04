#!/usr/bin/env python3
"""
Generic RSS article categorizer using a local Ollama model.

Design constraint: the prompt must be fully generic. Categories are
user-defined (label + description) and injected at runtime. No
category-specific logic, token lists, or post-processing guardrails.
"""

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
from typing import Any, Optional


PROMPT_TEMPLATE = """Categorize the following article into the user-defined categories listed below.

For each category that matches, return a confidence score between 0.0 and 1.0.
Only assign a category when the article content provides clear evidence for it.
If the article does not clearly match any category, use the fallback category.

Return JSON only, using this exact schema:
{{
  "labels": [{{"label": "<category_name>", "confidence": <0.0-1.0>}}],
  "story_key": "<short-stable-kebab-case-topic-key>"
}}

Rules:
- Only use category names from the list below. Match them exactly.
- Assign between 1 and {max_labels} categories.
- Base your decision on the article title, summary, and body content.
- A category must be clearly supported by the article text. Do not guess.
- If nothing clearly fits, use the fallback category with low confidence.

Categories:
{categories_block}

Article:
title: {title}
summary: {summary}
body: {body}
"""


INFERENCE_SETTINGS = {
    "temperature": 0,
    "top_p": 1,
    "top_k": 1,
    "repeat_penalty": 1,
    "num_predict": 200,
    "num_ctx": 4096,
}


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Categorize one article with local Ollama model")
    parser.add_argument("--print-hashes", action="store_true", help="Print prompt/settings hashes as JSON")
    parser.add_argument("--model", default=os.environ.get("OLLAMA_MODEL", "qwen2.5:0.5b"))
    parser.add_argument("--host", default=os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434"))
    parser.add_argument("--threads", type=int, default=int(os.environ.get("OLLAMA_THREADS", "4")))
    parser.add_argument("--seed", type=int, default=int(os.environ.get("OLLAMA_SEED", "0")))
    return parser.parse_args()


def normalize_story_key(value: str) -> str:
    normalized = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return normalized or "story-unknown"


def extract_json_object(raw: str) -> Optional[dict[str, Any]]:
    try:
        value = json.loads(raw)
        if isinstance(value, dict):
            return value
    except json.JSONDecodeError:
        pass

    start = raw.find("{")
    end = raw.rfind("}")
    if start >= 0 and end > start:
        candidate = raw[start : end + 1]
        try:
            value = json.loads(candidate)
            if isinstance(value, dict):
                return value
        except json.JSONDecodeError:
            return None

    return None


def parse_confidence(value: Any) -> float:
    if isinstance(value, (int, float)):
        numeric = float(value)
    elif isinstance(value, str):
        try:
            numeric = float(value)
        except ValueError:
            return 0.0
    else:
        return 0.0

    if numeric < 0:
        return 0.0
    if numeric > 1:
        return 1.0
    return numeric


def build_prompt(request_payload: dict[str, Any], max_labels: int) -> str:
    category_definitions = request_payload.get("category_definitions") or []
    title = request_payload.get("title") or ""
    summary = request_payload.get("summary") or ""
    body = request_payload.get("body") or ""

    categories_lines: list[str] = []
    if isinstance(category_definitions, list):
        for row in category_definitions:
            if not isinstance(row, dict):
                continue
            name = str(row.get("name", "")).strip()
            description = str(row.get("description", "")).strip()
            if not name:
                continue
            if description:
                categories_lines.append(f"- {name}: {description}")
            else:
                categories_lines.append(f"- {name}")
    if not categories_lines:
        categories_lines = ["- other: Fallback category"]

    return PROMPT_TEMPLATE.format(
        max_labels=max_labels,
        categories_block="\n".join(categories_lines),
        title=title,
        summary=summary,
        body=body,
    )


def call_ollama(host: str, model: str, prompt: str, seed: int, threads: int) -> str:
    payload = {
        "model": model,
        "prompt": prompt,
        "stream": False,
        "format": "json",
        "options": {
            **INFERENCE_SETTINGS,
            "seed": seed,
            "num_thread": max(1, threads),
        },
    }

    request = urllib.request.Request(
        url=f"{host.rstrip('/')}/api/generate",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    with urllib.request.urlopen(request, timeout=180) as response:
        response_body = response.read().decode("utf-8")

    parsed = json.loads(response_body)
    return parsed.get("response", "")


def normalize_label_key(value: str) -> str:
    lowered = value.lower().strip()
    lowered = lowered.replace("&", " and ")
    lowered = re.sub(r"[^a-z0-9]+", "_", lowered)
    lowered = re.sub(r"_+", "_", lowered).strip("_")
    return lowered


def build_candidate_map(candidates: set[str]) -> dict[str, str]:
    mapping: dict[str, str] = {}
    for candidate in candidates:
        key = normalize_label_key(candidate)
        if key:
            mapping[key] = candidate
        spaced_key = normalize_label_key(candidate.replace("_", " "))
        if spaced_key:
            mapping[spaced_key] = candidate
    return mapping


def map_candidate_label(raw_label: str, candidate_map: dict[str, str]) -> str:
    key = normalize_label_key(raw_label)
    return candidate_map.get(key, "")


def infer_labels_from_partial_json(raw_text: str, candidate_map: dict[str, str]) -> list[dict[str, Any]]:
    labels: list[dict[str, Any]] = []
    seen: set[str] = set()
    for match in re.finditer(r'"label"\s*:\s*"([^"]+)"', raw_text):
        raw_label = match.group(1)
        canonical = map_candidate_label(raw_label, candidate_map)
        if not canonical or canonical in seen:
            continue
        confidence = 0.0
        tail = raw_text[match.end() : match.end() + 80]
        confidence_match = re.search(r'"confidence"\s*:\s*([0-9]*\.?[0-9]+)', tail)
        if confidence_match:
            confidence = parse_confidence(confidence_match.group(1))
        if confidence <= 0:
            continue
        labels.append({"label": canonical, "confidence": confidence})
        seen.add(canonical)
    return labels


def infer_labels_from_text(raw_text: str, candidates: set[str], max_labels: int) -> list[dict[str, Any]]:
    lowered = f" {raw_text.lower()} "
    matched: list[str] = []
    for candidate in sorted(candidates, key=len, reverse=True):
        token = candidate.lower()
        forms = {
            token,
            token.replace("_", " "),
            token.replace("_", ""),
            token.replace("-", " "),
        }
        if any(f" {form} " in lowered for form in forms if form):
            matched.append(candidate)

    labels: list[dict[str, Any]] = []
    confidence = 0.7
    for label in matched[: max(1, max_labels)]:
        labels.append({"label": label, "confidence": confidence})
        confidence = max(0.5, confidence - 0.05)
    return labels


def normalize_output(
    raw: dict[str, Any],
    raw_text: str,
    candidates: set[str],
    max_labels: int,
    fallback_story_source: str,
) -> dict[str, Any]:
    candidate_map = build_candidate_map(candidates)
    labels: list[dict[str, Any]] = []

    raw_labels = raw.get("labels")
    if isinstance(raw_labels, list):
        for item in raw_labels:
            if isinstance(item, dict):
                raw_label = str(item.get("label", "")).strip()
                canonical = map_candidate_label(raw_label, candidate_map)
                if not canonical:
                    continue
                confidence = parse_confidence(item.get("confidence"))
                if confidence <= 0:
                    continue
                labels.append({"label": canonical, "confidence": confidence})
                continue
            if isinstance(item, str):
                canonical = map_candidate_label(item, candidate_map)
                if not canonical:
                    continue
                labels.append({"label": canonical, "confidence": 0.5})

    if not labels:
        category = str(raw.get("category", "")).strip()
        canonical = map_candidate_label(category, candidate_map)
        if canonical:
            confidence = parse_confidence(raw.get("confidence"))
            if confidence <= 0:
                confidence = 0.6
            labels.append({"label": canonical, "confidence": confidence})

    if not labels and raw_text.strip():
        labels = infer_labels_from_partial_json(raw_text, candidate_map)

    if not labels and raw_text.strip():
        labels = infer_labels_from_text(raw_text, candidates, max_labels)

    dedup: dict[str, float] = {}
    for item in labels:
        label = item["label"]
        confidence = item["confidence"]
        dedup[label] = max(confidence, dedup.get(label, 0.0))

    normalized_labels = [
        {"label": label, "confidence": confidence}
        for label, confidence in dedup.items()
    ]
    normalized_labels.sort(key=lambda it: it["confidence"], reverse=True)
    normalized_labels = normalized_labels[: max(1, max_labels)]

    if not normalized_labels:
        if "other" in candidates:
            fallback_label = "other"
        elif "unsorted" in candidates:
            fallback_label = "unsorted"
        else:
            fallback_label = sorted(candidates)[0]
        normalized_labels = [{"label": fallback_label, "confidence": 0.0}]

    story_key = str(raw.get("story_key", "")).strip()
    if not story_key:
        story_key = normalize_story_key(fallback_story_source)
    else:
        story_key = normalize_story_key(story_key)

    return {
        "labels": normalized_labels,
        "story_key": story_key,
    }


def main() -> int:
    args = parse_args()
    if args.print_hashes:
        print(
            json.dumps(
                {
                    "prompt_template_hash": sha256_text(PROMPT_TEMPLATE),
                    "inference_settings_hash": sha256_text(json.dumps(INFERENCE_SETTINGS, sort_keys=True)),
                    "model": args.model,
                    "host": args.host,
                    "seed": args.seed,
                    "threads": max(1, args.threads),
                }
            )
        )
        return 0

    raw_input = sys.stdin.read()
    if not raw_input.strip():
        print(json.dumps({"labels": [{"label": "unsorted", "confidence": 0.0}], "story_key": "story-unknown"}))
        return 0

    request_payload = json.loads(raw_input)
    categories = request_payload.get("candidate_categories") or []
    categories = [str(c).strip() for c in categories if str(c).strip()]
    if not categories:
        categories = ["unsorted"]

    max_labels = int(request_payload.get("max_labels") or 1)
    max_labels = max(1, max_labels)
    fallback_story_source = str(request_payload.get("title") or request_payload.get("item_id") or "story")

    raw_response_text = ""
    try:
        prompt = build_prompt(request_payload, max_labels=max_labels)
        raw_response_text = call_ollama(
            host=args.host,
            model=args.model,
            prompt=prompt,
            seed=args.seed,
            threads=args.threads,
        )
        extracted = extract_json_object(raw_response_text) or {}
    except (urllib.error.URLError, json.JSONDecodeError, TimeoutError):
        extracted = {}

    output = normalize_output(
        raw=extracted,
        raw_text=raw_response_text,
        candidates=set(categories),
        max_labels=max_labels,
        fallback_story_source=fallback_story_source,
    )

    print(json.dumps(output, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
