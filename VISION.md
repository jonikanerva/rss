# Product Vision

> This document is the single source of truth for what Feeder *is* and what it is *not*. Every agent reads it on every issue. It is human-owned: agents must not modify this file without an explicit user request.

---

## Vision *(REQUIRED)*

Feeder is a native macOS RSS reader that gives one person a calm, beautiful, high-trust reading experience. Every incoming article is classified into the user's own main categories by local or user-chosen cloud intelligence, while strict chronological order is always preserved — the reader trusts that nothing is hidden, reordered, or ranked for them.

---

## Goal *(REQUIRED)*

Help the user read their feeds calmly every day: articles arrive already sorted into their own taxonomy, in strict newest-first order, in an app that feels like Apple built it.

---

## Core Principles *(REQUIRED)*

- **Chronology is canonical.**
  Timeline order is always canonical timestamp descending, within and across categories. AI processing never changes an article's timeline position.

- **Every article gets exactly one main category.**
  Classification into the user-defined taxonomy is always on (no off-toggle in MVP), with an explicit fallback path when nothing matches. Multi-label assignment is out of scope.

- **Local intelligence, user's choice of engine.**
  Classification runs on Apple Foundation Models (zero-config, fully on-device) or OpenAI (user-supplied key; currently the higher-quality option). Both are first-class; the user chooses.

- **Keyboard-first, vanilla macOS.**
  Every core action is operable from the keyboard alone, with predictable focus and shortcuts discoverable in menus. The app uses native components, system colors, and system fonts — it looks and feels like Apple built it. Accessibility is product quality, not post-processing.

- **Reading comfort over feature count.**
  This is a reader: premium, modern, harmonious, calm. Clear information hierarchy at a glance, good contrast, comfortable font sizes. Fewer, better, polished capabilities; one opinionated way to use it. (Benchmark: Current Reader, https://www.currentreader.app/)

- **Evidence over opinion, reversibly delivered.**
  Key decisions require linked artifacts and gate outcomes (benchmarks, tests, measurements). Work ships in small, reversible milestones with safe rollback as the default.

---

## Product Shape *(REQUIRED)*

1. The user connects their Feedbin account (credentials stored in the macOS Keychain).
2. Feeder syncs subscriptions and full-content articles through the Feedbin API.
3. Each ingested article is classified into exactly one user-defined main category (or the explicit fallback) without changing its timeline position.
4. The user browses category timelines and the unified timeline — always newest first — from the sidebar, with the keyboard.
5. The user reads articles in the detail pane; read state syncs back to Feedbin.

---

## Non-Goals & Drift Guardrails *(REQUIRED)*

The product must not become:

- A cross-platform or generic feed client — Feeder is macOS-first and native; no Catalyst-style lowest common denominator.
- A recommendation or engagement product — no algorithmic ranking, popularity sorting, "for you" surfaces, or unread-anxiety mechanics. Chronology only.
- A read-later / knowledge-management system — no highlights, annotations, tagging pipelines, or archive workflows beyond read state.
- A feed-fetching engine — ingest comes from Feedbin only; no built-in crawler or parser farm.

Drift signals to flag when proposing UX, copy, or features — do not:

- reorder, group, or collapse the timeline by anything other than canonical timestamp;
- add modes, toggles, or preference matrices where one opinionated way suffices (including a categorization off-switch);
- add custom chrome, custom controls, or a design language where a standard macOS component exists;
- add a surface that requires the mouse or is not keyboard-reachable.

If a feature makes the product feel more like a news recommendation app, a social reader, or a read-it-later knowledge base, it is the wrong direction.

---

## Decision Filter *(REQUIRED)*

A proposed change should only be accepted if it clearly supports the core experience.

Ask:

1. Does every ingested article still get exactly one main category assignment (user-defined taxonomy, explicit fallback, always on)?
2. Is timeline order still canonical timestamp descending, with AI processing leaving timeline position unchanged?
3. Does the change keep the app calm, keyboard-operable, and vanilla macOS (native components, no custom chrome, no new modes)?
4. Is this the smallest polished capability that solves the problem — quality over feature count, one opinionated way, reversible to ship?

If not, it should not be added.

---

## Success Definition *(REQUIRED)*

The product succeeds when the user feels:

- "My articles are already sorted into my categories when I open the app — and I can verify the assignments are right."
- "I trust the timeline: newest first, always, nothing hidden or reordered for me."
- "I can do everything important without touching the mouse."
- "Reading here is calm and comfortable for long sessions — the app feels premium and quiet."

---

## Persistence and Privacy Posture *(REQUIRED)*

- **Persisted on-device:** synced articles with full content and denormalized display fields; feeds and subscriptions; user-defined folders and categories (`displayName`, `categoryDescription`, `keywords`, `sortOrder`); classification results (`primaryCategory`, `primaryFolder`); read state; sync state (last sync date, pending read IDs). Feedbin credentials and the optional OpenAI API key live in the macOS Keychain, never in files.
- **Transmitted off-device:** Feedbin API traffic (credentials, subscriptions, entries, read-state updates); article title and content sent to the OpenAI API for classification **only** when the user has selected OpenAI as the classification provider. Apple Foundation Models classification stays fully on-device. Nothing else leaves the machine.
- **Never persisted:** telemetry or analytics data; reading-behavior profiles beyond read state; third-party tracking identifiers; secrets in the repo or in plain-text files.
- **Telemetry / analytics:** none. No crash reporters, no third-party analytics.

---

## Audience & Voice *(OPTIONAL)*

- **Primary audience:** the developer-owner (single-user MVP) — a daily heavy RSS reader who values chronology, keyboard flow, and native macOS quality.
- **Tone:** calm — quiet microcopy, no engagement nudges, no exclamation marks.
