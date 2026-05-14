# Feeder

A native macOS RSS reader focused on a calm, fast, keyboard-first reading experience.

Articles synced from [Feedbin](https://feedbin.com/) are categorized into user-defined categories. Classification runs either on-device via [Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels) or via the OpenAI API using your own API key.

## Features

- Feedbin sync
- Article classification into user-defined categories
  - On-device via Apple Foundation Models, or
  - OpenAI API (bring your own key)
- Strict chronological timeline
- Full keyboard navigation

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
