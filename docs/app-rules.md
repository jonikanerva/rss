# App Rules — Feeder

Design principles that guide every UI and UX decision. All code changes must respect these principles. Any change to this file requires explicit human approval.

---

## 1. Performance

The app must always feel instant and responsive. The MainActor is sacred.

- All database writes go through `DataWriter` (background actor). Never write via `ModelContext` on MainActor.
- `@Query` predicates must be pushed to SQLite. Never filter `@Query` results in Swift.
- No expensive computation during view rendering — no regex, no loops, no calendar math in `body`.
- Pre-compute display fields (`plainText`, `formattedDate`, `primaryCategory`) at write time in `DataWriter`.

## 2. Keyboard Navigation

The app must be fully operable via keyboard alone, without a mouse.

- All core actions must have keyboard shortcuts.
- Focus behavior must be predictable and consistent across views.
- Navigation between sidebar, article list, and detail pane must work with keyboard.
- Keyboard shortcuts must be discoverable in menus.

## 3. Vanilla macOS

The app must look and feel like a native Mac app built by Apple. No custom design language.

- Use SwiftUI standard components: `List`, `NavigationSplitView`, `Table`, `Form`, `Toggle`, etc.
- No custom controls when Apple provides an equivalent.
- Follow Apple Human Interface Guidelines. Use system colors (`Color.primary`, `Color.secondary`, `.background`) and system fonts (`.body`, `.headline`, `.caption`).
- Target the newest macOS version. Prefer the latest Apple platform APIs.
- No private API calls. No third-party UI frameworks.

## 4. Readability

This is a reader app. Reading comfort is the primary UX goal.

- Good contrast at all times — never sacrifice contrast for aesthetics.
- Readable font sizes — no tiny text. Body text must be comfortable to read for extended periods.
- Clear information hierarchy at a glance — the most important content stands out.
- Visual quality: premium, modern, harmonious, calm. Reduce noise, not information.
