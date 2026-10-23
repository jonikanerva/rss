# Feeder

A chronology-first macOS RSS reader with local or user-selected cloud classification.

Articles synced from [Feedbin](https://feedbin.com/) appear in strict newest-first order. The selected classification engine assigns each article to one of your user-defined main categories, but it never reorders the timeline.

## Features

- Feedbin sync (full article content via the Feedbin API)
- Strict chronological timeline — newest first, within and across categories
- One main category per article, from a user-defined taxonomy
- Two classification providers:
  - **Apple Foundation Models** — zero-config and fully on-device.
  - **Vercel AI Gateway** — use Typesafe JEV, Microsoft Decision-1, or OpenAI GPT-6 Luna Decisions with your AI Gateway key.
    Article titles, text, and category definitions go through Vercel to the provider of the selected model.
- Full keyboard navigation
- Native macOS look and feel

## Stack

- SwiftUI + SwiftData
- Apple Foundation Models / Vercel AI Gateway (JEV, Decision-1, GPT-6 Luna Decisions)
- Swift 6, strict concurrency
- macOS 26.2+

## Build

Requires Xcode 26 and a Feedbin account.

```bash
make test-all   # lint + build + unit tests
make build      # build only
make test-focus # owner-run focus check
make test-ui UI_TEST=FeederUITests/FeederUITests/testVercelSettingsKeyboardSmoke  # owner-run settings check
```

Open `Feeder.xcodeproj` in Xcode to run.

### Keychain prompts during local development

`make install` signs the app with the team's Apple Development identity. The
designated requirement of the app then stays the same for each build, and the
Keychain access list of each stored item trusts that requirement.

The first read of each stored item in a build with a new requirement shows one
macOS Keychain access dialog. The stored items are the Feedbin account and each
saved API key.
Click **Always Allow** on each dialog. A later `make install` with the same
certificate keeps the access, so the dialog does not show again.

`make install` stops before the build when the Mac has no Apple Development
identity for the team. See `STACK.md` § 16 for the signing rule and § 8 for
how Feeder stores secrets.

## Status

Personal project, work in progress.
