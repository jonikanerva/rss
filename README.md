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

### Keychain prompts during local development

After every `make install`, macOS shows one native keychain dialog per stored
credential — typically the Feedbin token and, if configured, the OpenAI API key:

> *"Feeder wants to use your confidential information stored in `<key>` in your
> keychain. Allow / Always Allow / Deny."*

This is macOS's keychain access prompt, not an in-app dialog. Click **Always
Allow** on each prompt for the current binary.

**Why it re-prompts after each rebuild.** The `install` target uses ad-hoc
signing (`CODE_SIGN_IDENTITY="-"`), which produces a fresh code-signing
identity (different CDHash) on every build. macOS keychain ACLs are bound to a
specific code-signing identity, so a freshly built binary is treated as a
*different application* even though the bundle ID is unchanged — the previous
"Always Allow" grant does not carry over.

**For end users.** This is a development-only phenomenon. A user who installs
the app once and does not rebuild sees each prompt exactly once and never
again. See `docs/stack.md` § 8 Logging & privacy for how secrets are stored.

## Status

Personal project, work in progress.
