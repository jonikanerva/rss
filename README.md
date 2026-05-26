# Feeder

A chronology-first macOS RSS reader with local intelligence for categorization.

Articles synced from [Feedbin](https://feedbin.com/) appear in strict newest-first order. Local intelligence assigns each article to one of your user-defined main categories, but it never reorders the timeline.

## Features

- Feedbin sync (full article content via the Feedbin API)
- Strict chronological timeline — newest first, within and across categories
- One main category per article, from a user-defined taxonomy
- Local intelligence for categorization, with two first-class options:
  - **OpenAI API** — bring your own key. Currently the higher-quality choice.
  - **Apple Foundation Models** — zero-config, fully on-device. The
    privacy-preserving alternative.
- Full keyboard navigation
- Native macOS look and feel

## Stack

- SwiftUI + SwiftData
- Apple Foundation Models / OpenAI API
- Swift 6, strict concurrency
- macOS 26.2+

## Build

Requires Xcode 26 and a Feedbin account.

```bash
make test-all   # lint + build + unit tests
make build      # build only
```

Open `Feeder.xcodeproj` in Xcode to run.

## Status

Personal project, work in progress.
