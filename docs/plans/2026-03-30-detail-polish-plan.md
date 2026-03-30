# Implementation Plan: Detail Panel Polish & List Selection Style

Date: 2026-03-30
Reference: Feedbin macOS app UI (screenshot provided by user)

## 1. Scope

Visual polish inspired by Feedbin's macOS UI:

1. **Panel 3 padding** — increase horizontal padding from 32pt to 50pt minimum.
2. **Panel 3 title size** — increase article title font size for better visual hierarchy.
3. **Panel 2 selection highlight** — replace default List selection with a rounded-rect gray highlight (matching sidebar style), not full-width.

### Why

Current UI feels cramped in the detail panel and the list selection style is inconsistent between panels 1 and 2.

## 2. Milestones

### M1: Increase detail panel padding and title size

**Files:** `Feeder/Views/EntryDetailView.swift`, `Feeder/Views/FontTheme.swift`

1. Change `.padding(.horizontal, 32)` to `.padding(.horizontal, 50)` in EntryDetailView.
2. Increase `articleTitleSize` in FontTheme from `baseSize + 11` (26pt) to `baseSize + 15` (30pt) — matching the existing `titleSize` which is already 30pt.

**Acceptance:** Detail panel has wider margins. Title is visually larger and more dominant.

### M2: Custom list row selection highlight in panel 2

**Files:** `Feeder/Views/EntryRowView.swift`, `Feeder/Views/ContentView.swift`

The goal is a Feedbin-style rounded gray highlight instead of the default accent-colored full-width selection.

Approach: Use `.listRowBackground()` with a custom `RoundedRectangle` that matches the sidebar's selection appearance. The selection state is passed to EntryRowView via the existing `selectedEntry` binding context.

1. In `EntryListView`, add `.listRowInsets()` to create horizontal inset space for the rounded background.
2. Apply `.listRowBackground()` on each row with a conditionally styled `RoundedRectangle` — gray fill when selected, clear otherwise.
3. Pass `isSelected` state to `EntryRowView` or check via environment.

Implementation detail: Since `EntryListView` uses `List(selection:)`, we need to:
- Add `@Binding var selectedEntry: Entry?` awareness in the row or use `.listRowBackground` with a conditional check.
- Use `Color(nsColor: .unemphasizedSelectedContentBackgroundColor)` for the gray that matches macOS sidebar selection.
- Corner radius ~8pt to match macOS conventions.

**Acceptance:** Selected row in panel 2 has rounded gray background with inset margins, matching sidebar appearance.

### M3: Build verification

1. Run `bash .claude/scripts/test-all.sh` — all green.

## 3. Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| `.listRowBackground` may conflict with List selection styling | Medium | Medium | Test with `.listRowSeparator(.hidden)` and accent color overrides |
| Wider padding may feel too much on narrow windows | Low | Low | 50pt is still less than Feedbin's apparent ~60pt. Can adjust. |
| Custom selection may not track focus/unfocus states correctly | Medium | Low | Use `nsColor.unemphasizedSelectedContentBackgroundColor` for unfocused state |

## 4. Confidence

| Milestone | Confidence | Notes |
|-----------|-----------|-------|
| M1: Padding + title | High | Trivial CSS-style changes |
| M2: Selection highlight | Medium | macOS List selection customization can be tricky |
| M3: Build | High | No logic changes |

## 5. Quality gates

- [ ] `test-all.sh` — all green
- [ ] Detail panel has ≥50pt horizontal padding
- [ ] Article title is visually larger
- [ ] Panel 2 selection has rounded gray background (not full-width accent)
- [ ] Selection style matches panel 1 sidebar appearance
- [ ] Works in both light and dark mode
