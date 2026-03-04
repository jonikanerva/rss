# Plan: Hard MVP Execution

Date: 2026-03-04
Owner: Repository Owner + Agent
Status: Draft — pending owner review
Derived from: `docs/vision/VISION.md`, `docs/quality-gates/2026-03-02-local-llm-classification-reset-gate-check.md`

## Context

R4 gate passed (2026-03-04). Apple Foundation Models can classify RSS articles into user-defined categories at 18.9% correction rate using only generic prompt + category descriptions. This plan defines the scope, milestones, and acceptance criteria for building the macOS MVP app.

## Product scope (from VISION.md)

The MVP is a native macOS 26 RSS reader that:

1. Ingests articles from Feedbin (full content via API).
2. Classifies each article into user-defined categories using Apple Foundation Models.
3. Groups same-story articles across sources under generated story headings.
4. Displays a chronological timeline (newest first) with category-based navigation.
5. Feels calm, beautiful, and premium.

## Architecture decisions (locked by feasibility evidence)

| Decision | Choice | Evidence |
|----------|--------|----------|
| Platform | macOS 26, Swift 6, SwiftUI | VISION.md |
| LLM | Apple Foundation Models (built-in, `@Generable`) | run-017, research dossier |
| Feed source | Feedbin API only (includes full content extraction) | VISION.md, feasibility queue |
| Language scope | English-only MVP (non-English skipped via NaturalLanguage) | run-017 decision-log |
| Classification output | Multi-label categories via `@Generable` enum | Swift test harness |
| Determinism | Greedy sampling | run-017 metrics |
| Category quality lever | User-editable category name + description | run-017 key finding |

## Milestones

### M1: Project scaffold and Feedbin sync
**Goal**: Xcode project with SwiftUI app shell, Feedbin API client, and local persistence.

- [ ] Create Xcode project (macOS 26, Swift 6, SwiftUI app lifecycle)
- [ ] Feedbin API client: auth, fetch subscriptions, fetch entries (paginated), fetch extracted content
- [ ] Local data model: Feed, Entry (with full body), Category, StoryGroup
- [ ] Persistence layer (SwiftData or lightweight local store)
- [ ] Background sync: periodic Feedbin poll with incremental fetch
- [ ] Entry deduplication and canonical timestamp assignment

**Acceptance**: App launches, authenticates with Feedbin, syncs entries with full content, persists locally. Entries survive app restart.

### M2: Classification engine
**Goal**: Apple FM classifies every synced article into user-defined categories.

- [ ] Port `@Generable` classification from test harness (`tools/apple-fm-categorizer/`) into app
- [ ] User-defined categories: data model with name + description (seeded from `categories-v1.yaml` for dogfood)
- [ ] Category management UI (add/edit/delete categories with name + description)
- [ ] Classification pipeline: on new entry → detect language → skip non-English → classify → store labels
- [ ] Body truncation (8K chars) for context window safety
- [ ] Greedy sampling for deterministic output
- [ ] `other` fallback when no category matches or language unsupported
- [ ] Background classification queue (non-blocking UI)

**Acceptance**: Every synced English article gets at least one category label. Classification runs automatically on sync. User can create/edit categories and re-classify.

### M3: Same-story grouping
**Goal**: Articles about the same story from different sources are grouped under one generated heading.

- [ ] Story grouping model: `storyKey` (kebab-case topic key from `@Generable` output)
- [ ] Grouping logic: cluster entries by `storyKey` similarity within a time window
- [ ] Group header generation: short summary title for each story group
- [ ] Group timestamp: earliest article date in the group (per VISION.md)
- [ ] Ungrouped articles remain as standalone items in the timeline

**Acceptance**: Multi-source stories (e.g., same news from theverge + techmeme) appear grouped. Group header is human-readable. Timeline order uses earliest article date.

### M4: Timeline and category views
**Goal**: Main UI with chronological timeline, category sidebar, and reading experience.

- [ ] Main timeline view: all articles in newest-first order, grouped stories inline
- [ ] Category sidebar: list of user categories, click to filter timeline
- [ ] Story group card: collapsed view showing headline + source count, expandable to show all articles
- [ ] Article detail view: title, source, date, full body, category badges
- [ ] Keyboard navigation: up/down to move between items, enter to open, escape to go back
- [ ] Visual design: calm, premium, clear hierarchy (reference: Current Reader)

**Acceptance**: User can browse all articles chronologically, filter by category, expand story groups, read full articles. All core actions are keyboard-operable.

### M5: Polish and dogfood
**Goal**: Dogfood-ready quality for daily use.

- [ ] Visual polish pass (typography, spacing, color, animations)
- [ ] Empty states and loading states
- [ ] Error handling (Feedbin auth failure, FM unavailable, network offline)
- [ ] Settings: Feedbin credentials, sync interval, category management
- [ ] Performance: smooth scrolling with 500+ articles
- [ ] Accessibility audit: VoiceOver, focus management, contrast

**Acceptance**: Owner uses the app daily for 1 week with real Feedbin account. Subjective quality feedback: "clear, beautiful, and calm."

## Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Apple FM unavailable on dev machine | Low | High | Already validated in feasibility. Requires macOS 26 + Apple Intelligence enabled. |
| Context window exceeded on long articles | Medium | Low | Body truncation at 8K chars (proven in run-017). |
| Story grouping quality too low | Medium | Medium | Start with simple `storyKey` matching. Iterate on grouping prompt. |
| Feedbin API rate limits | Low | Medium | Incremental sync with `since` parameter. Respect API etiquette. |
| SwiftData maturity issues | Medium | Medium | Fall back to lightweight JSON/SQLite if needed. |
| Classification latency blocks UI | Low | Low | Background queue, non-blocking. 1-3s/item is fine for background. |

## Out of scope (explicit)

- Non-English article classification or translation
- Feed sources other than Feedbin
- iOS/iPadOS/visionOS
- Social features, sharing, read-later
- Offline mode (beyond cached articles)
- Custom LLM models or Ollama support
- OPML import/export
- Notification system
- Post-processing rules (e.g., strip "other" when other labels present) — candidate for post-MVP

## Implementation references

- **UI/feel benchmark**: [Current Reader](https://www.currentreader.app/) — target for visual quality, calm aesthetic, premium feel.
- **Open-source reference**: [NetNewsWire](https://github.com/Ranchero-Software/NetNewsWire) — high-quality native macOS RSS reader by Brent Simmons. Reference for SwiftUI patterns, Feedbin sync implementation, data model design, and macOS platform conventions.

## Dependencies

- macOS 26 SDK (Xcode 26)
- Apple Foundation Models framework (FoundationModels)
- NaturalLanguage framework (language detection)
- Feedbin API (authentication, entries, extracted content)
- SwiftUI + SwiftData (or alternative persistence)

## Quality gate for MVP

- App builds and runs on macOS 26.
- Feedbin sync works with real account.
- Classification runs on all synced English articles with ≤20% correction rate (matching feasibility evidence).
- Same-story grouping produces meaningful clusters for multi-source stories.
- Keyboard navigation covers all core actions.
- Owner dogfoods for 1 week and rates experience as "clear and calm."

## Execution approach

- One milestone at a time, sequential.
- Each milestone produces a working increment (app launches and does something useful).
- Commit at logical milestones, PR per milestone.
- No milestone starts until the previous one's acceptance criteria are met.
- M1-M2 are the critical path. M3 can be simplified if grouping proves hard. M4-M5 are polish.
