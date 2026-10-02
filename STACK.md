# STACK.md — Feeder (Swift 6 / SwiftUI / macOS)

> Strict Swift 6 + SwiftUI macOS app. SwiftData persistence behind a background actor, Feedbin sync, on-device or user-chosen cloud classification. Apple frameworks only.

---

## 0. Project shape

- **Shape:** UI app (macOS / SwiftUI). Native Xcode project: `Feeder.xcodeproj`.
- **Critical execution path:** the main actor / UI thread (one display frame).
- **Applicable states:** every user-visible surface handles awaiting-first-data (loading), success, empty, degraded, offline, error, and permission-blocked (when applicable), plus product-specific states from `VISION.md`.

### Repository layout & layer convention

Feeder maps the doctrine's interface / domain / infrastructure layers onto a two-layer runtime shape:

- **Interface** (MainActor, read-only) — SwiftUI views in `Feeder/Views/` read via `@Query` with SQLite-level predicates (never filter results in Swift). `SyncEngine` and `ClassificationEngine` are `@Observable` for progress and account display only: zero `ModelContext`, all writes delegated to `DataWriter`.
- **Domain** (pure, `nonisolated`) — stateless helpers in `Feeder/Helpers/` (`stripHTMLToPlainText`, `formatEntryDate`, `EntryFormatting`, `HTMLToBlocks`) and `detectLanguage` in `Feeder/Classification/ClassificationEngine.swift`. Zero side effects; same input, same output; reusable from migration closures and tests.
- **Infrastructure** (background actors) — `DataWriter` (`@ModelActor`; owns a read-write `ModelContext`; ALL persistence writes; pre-computes display fields at write time), `DataReader` (`@ModelActor`; a SECOND **read-only** `ModelContext` on the SAME app container; `autosaveEnabled = false`, zero writes; owns the article-list + sidebar-count reads so they run on their own actor and are never queued behind the writer's backlog — §5, §14), and `FeedbinClient` (`actor`; all HTTP requests). Never on MainActor.

**Actor boundaries:**

- DTOs crossing actors are `nonisolated struct` + `Sendable`.
- `@Model` objects never cross actor boundaries — pass `PersistentIdentifier` or DTOs.
- `DataWriter` init happens on a background thread.

**Why this matters:**

| Rule                                       | Reason                                                       |
| ------------------------------------------ | ------------------------------------------------------------ |
| No `ModelContext` on MainActor for writes  | `save()` triggers `@Query` re-evaluation and list re-render  |
| No computed filters on `@Query` results    | O(n) filter on every update defeats lazy rendering           |
| No expensive computation during rendering  | Calendar, regex, loops block MainActor = visible lag         |
| A `@ModelActor` is NOT automatically off-main | `DefaultSerialModelExecutor` only *serialises* context access; `await`ed from a MainActor caller the fetch runs on **main**. Bind a dedicated background executor (§5, §14) + assert `dispatchPrecondition(.notOnQueue(.main))` |

---

## 1. Language & Runtime

- **Primary language:** Swift 6.1
- **Strictness mode:** `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`. No new warnings; no `@preconcurrency` ratchet-loosening.
- **Target runtime:** macOS 26.2+
- **Minimum runtime version:** macOS 26.2 (no back-deployment, no `#available` for older OSes)
- **Package manager:** Swift Package Manager (`Package.resolved`)
- **Lockfile:** `Feeder.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- **Dev-environment provisioning:** Xcode 26+; everything else is driven through `make` (§3). No additional toolchain files.

---

## 2. Frameworks

| Concern             | Framework / library                                                            | Notes                                                                                          |
| ------------------- | ------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| UI / view layer     | SwiftUI                                                                        | AppKit only as a wrapped adapter                                                               |
| Design language     | macOS system components, system colors / fonts / materials                     | No custom chrome; see §11                                                                      |
| State / observation | Observation (`@Observable`, `@State`, `@Bindable`, `@Environment`)             | No `ObservableObject` / `@StateObject` / `@ObservedObject` / `@EnvironmentObject` for new code |
| Concurrency         | async / await, `AsyncSequence`, actors, structured concurrency                 | Full prohibition list in §7                                                                    |
| Navigation          | `NavigationSplitView`, `NavigationStack`                                       | No `NavigationView`                                                                            |
| Networking          | `URLSession` async / await                                                     |                                                                                                |
| Persistence         | SwiftData (`@Model`, `ModelContainer`, `@Query`) via `DataWriter` (`@ModelActor`) | See §5                                                                                      |
| Feedbin sync        | Custom `FeedbinClient` (`actor`)                                               | The only ingest source (`VISION.md → Non-Goals`)                                               |
| Classification      | Apple Foundation Models (on-device); OpenAI API and Vercel AI Gateway / JEV (user-supplied keys)  | Both first-class; the user chooses (`VISION.md → Core Principles`)                             |
| Localization        | None — English-only UI in MVP                                                  |                                                                                                |
| Logging             | `os.Logger` per subsystem / category; `OSSignposter` for hot paths             | No `print()` in shipped code                                                                   |
| Telemetry           | None                                                                           | No third-party analytics, no crash reporter                                                    |
| Testing             | Swift Testing (`@Test`, `@Suite`, `#expect`); XCTest / XCUITest for end-to-end UI |                                                                                             |
| Formatting          | `swift-format` with repo `.swift-format`                                       | No SwiftLint                                                                                   |
| Build               | Xcode 26+, Swift 6 language mode, complete strict concurrency                  |                                                                                                |

---

### Cloud classification

Categorization runs without interruption when Feeder can heal a failure by itself. One article that keeps failing does not stop categorization of the other articles. The user sees a status banner only when categorization stops after the request retries, when a short retry cannot heal the failure, or when the user must act. Examples of a failure that a short retry cannot heal: an offline Mac, an invalid response, or a long `Retry-After` wait. Examples of a failure where the user must act: a problem with the key, the model, the categories, or the budget. The rules below serve this outcome. The code and the tests set the retry counts and the delay values.

- Only the article title, the article content, and the category definitions go to the provider that the user selected. The request also carries the API key of that service. Vercel AI Gateway uses `typesafe-ai/jev` at `POST /v1/evaluate`. One Choice question contains the category descriptions and keywords. The state contains only the article title and content. OpenAI also excludes the article URL. Each service has its own API key. Feeder stores API keys only in the Keychain. Classification settings access the Keychain through a background actor. The key sheet owns its save task and reports completed writes to the engine.
- JEV returns a validated category choice directly. Only generative Apple and OpenAI results use the confidence and keyword gates. The request contains at most 255 distinct categories, including one `uncategorized` fallback.
- The final JEV JSON body is at most 24,000 UTF-8 bytes. Keep all category metadata. Bound the title to 512 characters and truncate article text at character boundaries. This is a conservative byte policy, not token counting or a guarantee of the model context size.
- Validate the key and taxonomy locally before any reclassification reset. A classification failure never makes Feeder select another provider. A missing API key, an empty API key, or a failed Keychain read for the selected cloud provider never makes Feeder select another provider. Provider, model, and key changes cancel the owned task, wait for termination, and restart with current settings.
- `KeychainHelper.read(key:)` holds the one Keychain status rule. The status `errSecItemNotFound` means that no key is saved. Every other failed status, and stored data that is not valid UTF-8, is a failed read. The banner and the Settings screen never show a failed read as a missing key. A missing key has the `.needsKey` abort reason, and a failed read has the `.keyUnreadable` abort reason. Both reasons have the blocked disposition: the drain waits for explicit Retry, a settings change, or the hourly recheck. An in-app key save, a key removal, a provider change, or a model change restarts the drain at once, except while a Keychain access dialog waits for an answer. While that dialog waits, the drain and the in-app fixes wait too. This wait is not bounded and not cancellable. This is a known gap, not an accepted divergence. Issue #225 tracks the cause. The Settings screen shows whether a key is saved with a query that returns attributes only. That query never reads the secret, so it never shows the Keychain access dialog. A key save deletes the old item first and then adds the new item, so the new item gets a new access list. Each failed read writes one log line with the account name and the status as public values, and with no key material.
- Every cloud request uses an ephemeral session with no cache and no cookies. The rule applies to the Vercel and OpenAI classification requests and to the OpenAI model-list request. The resource timeout is 60 seconds. The Vercel request timeout is 30 seconds. OpenAI answers only after the model finishes, so the OpenAI classification request timeout is 60 seconds. The user waits for the model list in Settings, so the model-list request timeout is 15 seconds. One session serves all classification requests in a drain, so the requests can share an open connection. The session ends when the drain ends. Each model-list request uses a new session. `URLSession` chooses the HTTP version.
- A transient cloud failure does not assign a category. The article stays pending. Only the strike rule below can give that article the uncategorized fallback. A per-entry failure takes the uncategorized fallback at once, and the drain continues. OpenAI reports a context-length or content-policy rejection with HTTP 400 and an error code. The provider maps these codes to a per-entry failure.
- HTTP 408, HTTP 429, HTTP 500 to 599, a transport timeout, and a lost connection get a request retry when the failure takes the loop backoff. A request retry sends the same request to the same service after a short wait. The wait grows with each retry. A short valid `Retry-After` extends the retry wait. A longer valid `Retry-After` stops the drain at once without a request retry, and the loop honours the value. Other failures get no request retry. The model-list request gets no request retry.
- A failure that is not a per-entry failure stops the drain when it remains after the request retries. One exception applies: the drain skips the article when the failure has the transient disposition, no valid `Retry-After` value, and an abort reason other than `.rateLimited`. A failure that meets these three conditions is a skippable failure. The skipped article stays pending, and the drain sends the next article. A rate limit is a service limit, not a problem of one article, so it stops the drain. A billing failure has the blocked disposition, so it also stops the drain.
- A success is an article for which the provider returns a category. A local fallback and a per-entry failure are not a success. A second skippable failure before the next success stops the drain. A drain that skips an article and has no success stops after its last article. The banner and the loop backoff then apply, as for any drain that stops.
- A drain with at least one success gives one strike to each article that it skipped, also when the drain stops later. A drain with no success gives no strike. A failure that is not skippable never gives a strike. At three strikes, the next drain assigns the uncategorized fallback to the article and sends no request for it. The drain fetches pending articles in chunks. In each chunk, the drain sends the articles that an earlier drain skipped after the other articles. Timeline order does not change.
- `ClassificationEngine` keeps the strikes in memory only. The strikes reset when the app starts, when the provider, the model, or the key changes, and when the user reclassifies all articles. Every reset also replaces the classification task. Manual Sync and Retry keep the strikes. A cancelled drain records no skip and no strike.
- Apple Foundation Models follows the same drain rule. The provider maps each Foundation Models error to a classification failure. After each error, the provider reads the model availability again. When the model is not available, the drain stops at once with the provider-unavailable reason and the poll disposition. The article stays pending and gets no strike. The next drain reads the availability before it sends a request. A rate limit stops the drain with the `.rateLimited` reason and takes the loop backoff. A known reset date extends the wait, as a valid `Retry-After` value does. Four errors are per-entry failures: the context size is exceeded, a guardrail rejects the content, the model refuses, or the model does not support the language. Every other error, also an unknown error, is a skippable failure with the provider-unavailable reason. Apple Foundation Models gets no request retry. Apple documents that an app recovers from a macOS 27 rate limit when it sends requests less frequently. A short retry could therefore heal the failure, but the banner shows at once. This difference is a known gap, not an accepted divergence. Issue #219 decides the policy.
- After the drain stops, the continuous loop waits before the next batch. The wait grows after each failed batch and resets when progress is persisted. A valid `Retry-After` extends the wait, up to one hour. Local configuration failures can be rechecked without HTTP. Every retry and every wait is bounded and cancellable. Cancelled work cannot change classification fields.
- The providers share one retry policy when a failure has the same meaning. When the drain stops, a transport failure, HTTP 408, HTTP 429 other than an OpenAI billing failure, and HTTP 500 to 599 take the loop backoff. Other HTTP failures wait for explicit Retry, a settings change, or an hourly recheck. A provider differs only when its service gives a failure a different meaning, and this section states the reason. OpenAI also sends HTTP 429 for a billing failure: the account has no prepaid credits, or the account reached a spend limit or a usage limit. The error type `insufficient_quota`, or a billing error code that OpenAI documents, identifies a billing failure. OpenAI states that a retry does not restore access after a billing failure. An OpenAI billing failure therefore gets no request retry and waits for explicit Retry, a settings change, or an hourly recheck. Every other OpenAI HTTP 429 is a rate limit. An OpenAI HTTP 402 keeps the hourly recheck. Vercel sends HTTP 402 for a billing failure: the team has no credit balance, or a budget reached its limit. A Vercel HTTP 402 gets the same policy as an OpenAI billing failure. A billing failure gets no request retry and waits for explicit Retry, a settings change, or an hourly recheck. A valid `Retry-After` value does not shorten this wait. A Vercel budget can refresh at a fixed time. After the refresh, the hourly recheck restarts the drain within one hour. Explicit Retry restarts the drain at once. The banner for a billing failure names the provider that reported the failure.
- A blocked disposition must use an abort reason that the Settings screen can fix. A transient disposition must use a self-healing abort reason. A poll disposition is for a local re-check or a per-entry defect and carries no pairing obligation.
- Live JEV classification quality requires owner evaluation. Offline wire and state tests do not establish model accuracy.

---

## 3. Build & verify commands

| Variable         | Command                                                                              |
| ---------------- | ------------------------------------------------------------------------------------ |
| `$FORMAT_CMD`    | `make lint-fix`                                                                      |
| `$LINT_CMD`      | `make lint`                                                                          |
| `$BUILD_CMD`     | `make build`                                                                         |
| `$TEST_CMD`      | `make test` (unit tests); `make test UNIT_TEST=FeederTests/<Suite>` runs one suite   |
| `$VERIFY_CMD`    | `make test-all` (lint → build → unit tests → `verify:` line)                         |

The `Makefile` at the repository root is the single source of truth for these commands. Never invoke `swift-format`, `xcodebuild`, or `xcrun` directly from commits, CI, or agent scripts — always go through `make`.

One narrow exception: when an issue or the owner names an owner trace (§ 4 → Owner trace), an agent may read that trace with `xcrun xctrace export`, also with `--toc`. The raw export stays on the Mac. Only counts and durations go into an issue or a PR. An agent never runs `xctrace record` or `xctrace import`, and never uses `--launch` or `--attach`.

### Testing strategy

A test must protect a `VISION.md` invariant or a doctrine risk that an edit can break without notice. Delete a test that protects neither.

| Layer | What to test | How |
| ----- | ------------ | --- |
| Domain (`Feeder/Helpers/`, pure types) | Each rule and each edge case: chronology, the single category and its fallback, UTC at the boundary (§ 10), parsing, formatting. | Unit tests with fixed input and a fixed `Date`. |
| State owners (`SyncEngine`, `ClassificationEngine`, `ClassificationSettingsModel`) | The phase timeline: success, degraded, blocked, retry, cancellation. | Fakes, an injected clock, and an in-memory container. |
| Persistence (`DataWriter`, `DataReader`, `FeederMigrationPlan`) | One test per contract: each write, each read predicate, the off-main guard, each migration stage. | The real actors on an in-memory container. A migration test uses an on-disk store in a unique temporary folder. |
| Services (`FeedbinClient`, classification providers, key stores) | The request shape, the private fields, the map from status to disposition. | A stub transport or a memory store. No network. |
| Interface (`Feeder/Views/`) | Each applicable state (§ 0). | One `#Preview` per state. Logic moves to a tested owner. A layout test only pins a documented platform defect (§ 7, § 14) or the selection-text rule (§ 11). The pending first fetch of the article list has no preview. `EntryListDisplayStateTests` pins its display rule. |
| AppKit focus and first responder (the focus check) | Focus after a click, keys while the web view has focus, and the VoiceOver label of the detail pane. | One XCUITest method in one launch, owner-run. |
| Settings keyboard path (the settings check) | The keyboard path of the API key sheet and of the Reclassify prompt in the running app. | One XCUITest method, owner-run. |

Add no other XCUITest.

Do not test Apple framework behaviour, styling, a private helper whose owner has tests, or a timing budget (§ 4 owns performance evidence). Keep key storage, privacy, retry, and state-transition coverage in unit tests.

Hygiene for a new or changed test:

- Do not use a real Keychain item, `UserDefaults.standard`, `URLCache.shared` or another shared URL-loading store, the general pasteboard, or the app's on-disk store. The unit-test host runs in the owner's app container.
- Do not use a fixed sleep over 100 ms. Wait for a state, or inject a clock.
- An on-demand test uses `.enabled(if:)`.

### Gates

| When | Who | Check |
| ---- | --- | ----- |
| Each commit | dev | `$FORMAT_CMD`, `$LINT_CMD`, `$BUILD_CMD` |
| Each push | dev | `$VERIFY_CMD` once, on the committed tree to push. The hand-off quotes the `verify:` line and the pushed head. |
| Review | qa | `$VERIFY_CMD` once per PR, last, on the head that qa passes. No run in a FAIL round. |
| Mutation check | dev | `make test UNIT_TEST=FeederTests/<Suite>`, one suite per run, in a detached worktree. |
| A change to the `DataReader` or `DataWriter` container or executor (§ 14) | dev | `make test-stress-tsan` |
| Focus trigger | owner | `make test-focus` |
| Settings trigger | owner | `make test-ui UI_TEST=FeederUITests/FeederUITests/testVercelSettingsKeyboardSmoke` |
| Hot-path trigger (§ 4) | dev | The § 4 evidence, or "no new hot-path work" and the reason |
| After-trace trigger | owner | An owner trace of the slow action after the fix (§ 4 → Owner trace) |

`make test-all` ends with one stamp line: `verify: head=<sha> tree=clean|dirty result=<result> tests=<n>`. `tree=clean` means that HEAD did not move, and that `git status` showed no change and no untracked file at the start and at the end of the run. `tests` counts the passed tests. Only a `tree=clean` line with `result=Passed` whose head is the PR head is gate evidence. The PM compares the line with the pushed head before qa starts. `make test-all` refuses a `UNIT_TEST` selection.

A run with `UNIT_TEST` or `UI_TEST` fails when fewer tests pass than there are selectors. The guard counts passed tests. The guard proves that a selector matched a test only when the run has one selector, or when each selector names one test method. A mutation check therefore selects one suite per run. A Swift Testing single-test selector can match no test, so select the suite. Use the suite type name, not the file name.

Owner-run checks take over the screen or need the owner's real data, so the owner runs them. Quit the installed Feeder before an owner-run UI check. An agent runs one only when the owner asks in that task, in the foreground, and never detached. When a trigger matches the diff, the PR and the qa review list the check as `ran on <SHA>: PASS` or `triggered, pending owner run`. A pending owner-run check does not block a PASS. A PASS stays valid until a later commit matches the trigger again. After a failure, fix the cause, then rerun only the failed method.

- **Focus trigger:** the diff changes `ContentView.swift`, `ArticleWebView.swift`, `FeederCommands.swift`, `SidebarView.swift`, `EntryListView.swift`, `EntryDetailView.swift`, `Support/KeyHandling.swift`, or `Support/SidebarSelection.swift` under `Feeder/Views/`, `FeederUITests/FeederUITests.swift`, `Feeder/Data/UITestDataSeeder.swift`, the `test-ui` recipe or the `test-focus` target in the `Makefile` (with the helpers that the recipe calls), or a file under `Tools/UITestRunner/`. The trigger also matches when the diff adds or changes `@FocusState`, `.focused(`, `.focusable(`, `defaultFocus`, `FocusedValue`, `focusedSceneValue`, `onKeyPress`, `keyDown`, or `makeFirstResponder` in another file under `Feeder/Views/` that the settings trigger does not name.
- **Settings trigger:** the diff changes `SettingsView.swift`, `SettingsPane.swift`, or `ClassificationSettingsView.swift` under `Feeder/Views/`, `Feeder/Classification/ClassificationSettingsModel.swift`, `testVercelSettingsKeyboardSmoke` or a helper that it calls, `Feeder/Data/UITestDataSeeder.swift`, the `test-ui` recipe in the `Makefile` (with the helpers that the recipe calls), or a file under `Tools/UITestRunner/`.
- **After-trace trigger:** the PR closes an issue that names an owner trace.

### Build folders

A full clone uses `/tmp/FeederDerivedData`. A linked `git worktree`, or a copy without `.git`, uses its own `.build/DerivedData`. A second full clone therefore shares the folder of the main checkout. Review and mutation checks use a linked worktree under `$TMPDIR`. The agent removes each worktree after use (`git worktree remove` deletes the folder). Do not pass `DERIVED_DATA` to a gate run.

---

## 4. Performance budgets

- **UI frame budget:** 16 ms baseline; 8.3 ms on ProMotion displays.
- **Cold start:** < 2 s on supported Macs.
- **Memory ceiling:** < 500 MB resident during normal browsing.
- **Article list scroll:** 120 fps achievable on ProMotion.
- **Sync / classification:** background work must not block the UI; long-running classification batches are cancellable and yield cooperatively.

Profile before optimizing. Stay inside these budgets unless a measurement-backed Intentional Divergence (§14) is recorded. No automated check measures these budgets. An owner trace (§ 4 → Owner trace) measures the frame, cold-start, scroll, and sync budgets. No check measures the memory ceiling.

### Hot-path gate

- **Trigger:** the diff changes `ContentView.swift`, `SidebarView.swift`, `EntryListView.swift`, `EntryRowView.swift`, or `EntryDetailView.swift` under `Feeder/Views/`, `DataReader.swift` or `DataWriter.swift` under `Feeder/Data/`, or the `UnreadCountsSnapshot` declaration in `Feeder/Data/DataWriterDTOs.swift`.
- **New hot-path work:** new main-actor work that runs for each frame, row, keystroke, or selection change, or a new `DataReader` or `DataWriter` read or write.
- **Answer:** the PR answers the gate in one line: `not triggered`; or `no new hot-path work` and the reason; or the evidence for each unit of new hot-path work.
- **Evidence:** a test and a `PerformanceSignpostName` interval around the work. For work that runs off the main actor, the test is a `@MainActor` off-main test (§ 5). For work that stays on the main actor, the test bounds the input size of the work through the existing API, for example the page limit or the visible rows. The test adds no production hook. No test bounds a duration.
- The gate needs no owner run.

### Owner trace

When one of these feels slow more than once, the owner records a trace: a sidebar move, an article open, a scroll, the UI during a sync, or a launch. The owner records every trace.

- Record in the daily app with the real data, and do not relaunch the app first. For a slow launch, let Instruments launch Feeder.
- Use the Time Profiler template, which includes Hangs, and add the os_signpost instrument. For a scroll hitch, use the Animation Hitches template. Record for 30 to 60 seconds, and repeat the slow action three to five times.
- Save the trace as `~/Desktop/feeder-<topic>.trace`. The trace stays on the Mac, because the repository is public.
- Add one sentence to the issue: what felt slow, the trace file name, and the build identity. The build identity is the branch and the `git log -1 --oneline` of the installed build.
- Find `read-fetch-sections` in the os_signpost instrument. The interval runs on a background thread, and the instrument shows the start thread and the end thread of each interval. A failed executor binding (§ 5) stops the app at a `dispatchPrecondition` guard before the interval begins. The end message holds the paging mode and the row count: `mode=first|above|after rows=<n>`.

### Signposts

`PerformanceSignpostName` holds every name. A PR that adds or removes a name updates this list. `row-body-build` is an event. Each other name is an interval.

| Name | The felt symptom that it attributes |
| ---- | ----------------------------------- |
| `sidebar-click` | A sidebar move is slow. The interval is the SwiftUI commit after the selection changes. |
| `article-click` | An article open is slow. The interval is the SwiftUI commit after the row selection changes. |
| `detail-render` | The article body appears late. The interval covers the HTML render in a detached task. |
| `read-fetch-sections` | The article list appears late. The interval is the fetch, the projection, and the grouping on the `DataReader` actor. |
| `structural-reload` | The article list stays blank after a sidebar move. The interval runs from the start of the reload, after the debounce, to the new rows. |
| `reload-diff` | A list reload is slow on the main actor. The interval is the row comparison. |
| `reload-set-build` | A list reload is slow on the main actor. The interval is the build of the identifier set. |
| `reload-state-assign` | A list reload is slow on the main actor. The interval is the state assignment. |
| `contentview-reeval` | A list reload makes the whole window stutter. The interval runs from the new visible rows to the next `ContentView` render. |
| `row-body-build` | A list reload is slow for a large category. More events inside one `structural-reload` interval than visible rows show that the `List` builds rows that are not visible. |
| `net-fetch-page` | A sync is slow. The interval is the network request for one page. |
| `write-persist-page` | The UI is slow during a sync. The interval is the persist of one page. Back-to-back intervals with no `net-fetch-page` gap show that the writes saturate the shared SwiftData coordinator. |

### Rollback

Commit `c27208c3b1f588b9a6332110196a2458f8c4d139`, the base of the removal, holds the full automated performance harness. Restore a part of the harness only when an owner trace shows a regression that a repeatable measurement must guard.

---

## 5. Persistence shape

- **Storage primitive:** SwiftData (`@Model`, `ModelContainer`, `@Query`).
- **Writes:** ALL writes go through `DataWriter` (`@ModelActor`). No `ModelContext` on MainActor (§0).
- **Reads (article list + sidebar counts):** go through `DataReader` (`@ModelActor`) — a SECOND **read-only** `ModelContext` on the SAME app container as `DataWriter` and the SwiftUI main context (`autosaveEnabled = false`; zero `insert`/`save`). The separate actor keeps these reads off the writer actor's mailbox; the shared container keeps `PersistentIdentifier`s interoperable so the render/selection path (`modelContext.model(for:)`) is unchanged (§0, §14).
- **Off-main is the EXECUTOR, not the actor.** `@ModelActor` + `DefaultSerialModelExecutor` guarantee only *serialised, thread-safe* context access — NOT background execution. Awaited from a MainActor caller (every SwiftUI read site is one), a bare model actor's fetch runs **on the main thread**, silently (measurement in §14). So every SwiftData actor (`DataReader`, `DataWriter`) MUST bind its executor to a dedicated **background** queue (a custom `SerialModelExecutor`, §14) and assert `dispatchPrecondition(condition: .notOnQueue(.main))` at the top of each fetch/write. Never assume off-main execution from the actor keyword. A `@MainActor` test proves the executor binding: the actor's isolated methods do not run on the main thread (`DataReaderOffMainExecutorTests`, `DataWriterOffMainExecutorTests`). An owner trace (§ 4) shows main-thread time on real data.
- **Persisted entities:** declared by `VISION.md → Persistence and Privacy Posture`.
- **Schema versioning:** SwiftData first-party migration. Every shipped schema shape is a `VersionedSchema` (e.g. `FeederSchemaV1`). `FeederMigrationPlan: SchemaMigrationPlan` lists the versions in order plus the stages between them. The `ModelContainer` is opened with the plan so SwiftData runs the right stage at launch. **Prefer lightweight stages** (`.lightweight(fromVersion:toVersion:)`) for additive / removal-only changes — no data movement needed. **Use custom stages** (`.custom(fromVersion:toVersion:willMigrate:didMigrate:)`) when a denormalized display field needs recomputing or when data has to be transformed. **No auto-wipe on schema change.** A failed migration still takes the reset fallback in `FeederApp.init`. This is a known gap, not an accepted divergence. Issue #262 decides the policy. User folders, categories (with `displayName`, `categoryDescription`, `keywords`, `sortOrder`), classified entries (`primaryCategory`, `primaryFolder`), and feeds must survive every schema bump.
- **Pre-computed display fields:** `DataWriter` pre-computes `plainText`, `formattedDate`, `formattedPublishedTime`, `primaryCategory`, `primaryFolder`, `displayDomain`, `summaryPlainText`, `articleBlocksData` at write time. **Any future schema change that touches the inputs to these fields requires a custom migration stage that recomputes them** so older rows render consistently with newly synced rows. The pure helpers in `Helpers/EntryFormatting.swift` and `Helpers/HTMLToBlocks.swift` are `nonisolated` and reusable from inside `willMigrate` / `didMigrate` closures.
- **Migration stages run inside the container open**, not through `DataWriter`. They receive a raw `ModelContext`, which is the documented Apple pattern and an intentional, bounded exception to "all writes through `DataWriter`" (§0) — migration stages only.
- **Forbidden persistence:** anything declared forbidden in `VISION.md → Persistence and Privacy Posture`.

---

## 6. Approved dependencies

Default answer to "should we add a library?" is **no** — especially for what Apple frameworks already solve. A new third-party SPM dependency requires an entry in this table **before** it lands in `Package.resolved`.

| Dependency                       | Version | Why it earns its place | Approver | Date |
| -------------------------------- | ------- | ---------------------- | -------- | ---- |
| _(none — Apple frameworks only)_ | —       | —                      | —        | —    |

---

## 7. Stack-specific reject-list additions

Hard rules for this stack; `/codereview` enforces every entry on every PR.

**Concurrency — prohibited pattern → replacement:**

| Prohibited                     | Replacement                           |
| ------------------------------ | ------------------------------------- |
| `DispatchQueue` / GCD          | `Task {}`, `async let`, `TaskGroup`   |
| `OperationQueue`               | `TaskGroup`                           |
| `NSLock` / semaphores          | `actor` isolation                     |
| `Timer.scheduledTimer`         | `Task.sleep(for:)` loop               |
| Completion handlers            | `async` functions                     |
| `Combine` for async            | `async` / `await`, `AsyncSequence`    |
| `withCheckedContinuation`      | Native async API or redesign          |
| `[weak self]` in Task closures | Structured concurrency                |

**Further reject-list entries:**

- `ObservableObject`, `@StateObject`, `@ObservedObject`, `@EnvironmentObject`, `@Published` in new code — Observation framework only.
- `NavigationView` — `NavigationSplitView` / `NavigationStack` only.
- `ModelContext` on MainActor for writes — all writes through `DataWriter` (§0, §5).
- A SwiftData actor (`@ModelActor` / `DefaultSerialModelExecutor`) whose fetches/writes are NOT bound to a dedicated **background** executor and NOT guarded by `dispatchPrecondition(condition: .notOnQueue(.main))` — the bare `ModelActor` pattern only *serialises* access; awaited from a MainActor caller it executes on the **main** thread, silently. Off-main means a custom `SerialModelExecutor` on a background queue (§5, §14), asserted, and proved by a `@MainActor` off-main test for each SwiftData actor (§ 5) — never assumed.
- Filtering `@Query` results in Swift — push predicates to SQLite via the `@Query` predicate.
- `@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency`, `MainActor.assumeIsolated` without an inline-justified, audited comment explaining why no safe alternative exists.
- Expensive work in `body` — no regex, loops, or Calendar math during view rendering (§0, §4).
- `print()` in shipped code; `os.Logger` lines that interpolate user-derived values without `.private` (§8).
- `AnyView`, broad type erasure, reflection tricks unless there is a measured benefit.
- Force-unwraps (`!`) and `try!` outside tests and `#Preview`.
- `var` where `let` suffices.
- `TODO`, `FIXME`, `HACK`, or commented-out code in a shipped diff.
- A comment that narrates history — "previously", "used to", "the old …", "before the fix", "replaces", "retired", "now supports" — or that describes a design the diff removes (`CLAUDE.md → Code conventions → Comments`).
- A comment whose meaning depends on an issue number, a PR number, or a commit reference. Delete the reference: the comment must still read correctly. A named `STACK.md` section is a valid reference; a bare `#170` is not.
- A comment citing a line number, a file offset, or a count of things elsewhere in the tree — a later edit invalidates it silently.
- A comment over 5 lines. This one is a smell, not an automatic FAIL: the reviewer clears it by naming the constraint each line carries. A block that cannot be defended line by line is rationale and moves to the issue, the PR, or §14. Never cut a contract to reach the number.

  These four entries govern comments in **source files**. §14, the issue, and the PR are where the banned content belongs — measured numbers, rejected alternatives, and the history of a rule are the *purpose* of §14, never a violation in it.
- Persisting or computing with local-time / calendar-component values instead of a `Date` instant; manual UTC-offset arithmetic; a `DateFormatter` / `Calendar` without an explicit `timeZone` in logic (§10; the pre-computed display-string fields are a documented divergence, §14).
- Custom controls where a standard macOS component exists; private API calls; third-party UI frameworks (§11).
- New SwiftPM packages without a §6 entry approved in advance.
- A modifier placed outside `navigationSplitViewColumnWidth` on a column's content (measured 2026-09-17: an outer `onGeometryChange` hides the width preference from the split view, and the column lays out at the platform default); use `persistedColumnWidth(column:ideal:)`, whose regression test (`PersistedColumnWidthTests`) pins the order.
- An article-list row whose height is not the row floor, `AppFontSettings.entryRowHeight` (measured 2026-09-16: on macOS 27 the `NSTableView`-backed `List` can draw rows at the table's fallback row height, `defaultMinListRowHeight`, until a scroll re-tiles the table). Every row renders at the floor, and the article list sets `defaultMinListRowHeight` to the floor, so a row at the fallback height is whole. The fixed height forces two rules: the title, domain, and summary lines fit the fixed text column, and the summary shows only the whole lines that the title leaves free. `EntryRowGeometryTests` pins the floor, the fit, and the line counts.

---

## 8. Logging & privacy

- **Logger:** `os.Logger` per subsystem / category; `OSSignposter` for hot-path measurement. Log significant state changes only.

```swift
// In @MainActor files (default isolation):
private let logger = Logger(subsystem: "com.feeder.app", category: "ModuleName")

// In non-MainActor actors:
actor FeedbinClient {
  private static let logger = Logger(subsystem: "com.feeder.app", category: "FeedbinClient")
}
```

- **PII redaction:** use `os.Logger` `.private` interpolation for any value derived from user data (article URLs, feed URLs, API keys, classification prompts).
- **Crash reporter:** none. No Sentry / Crashlytics / equivalent.
- **Privacy declaration:** keep `PrivacyInfo.xcprivacy` accurate. Every required-reason API call is declared.
- **Secrets:** never in the repo. Configuration via the macOS Keychain or `.env` (gitignored). Agents never read `.env` files (enforced by a settings hook). A request that carries a credential uses an ephemeral session, never `URLSession.shared` or a `.default` configuration.
- **Feedbin account:** One Keychain item holds the Feedbin username and password: a generic password with the service `com.feeder.app` and the account `feedbin_account`. Its data is a JSON object with both values, so no Keychain attribute holds the username. One read returns both values, so the read shows at most one Keychain access dialog for the account. The one-time migration deletes the old `feedbin_password` item after it writes the `feedbin_account` item. That unverified delete can show one more dialog or fail with `errSecInvalidOwnerEdit` (-25244). `SyncEngine` reads the `feedbin_account` item once per launch through `FeedbinCredentialStore`, off the main actor. Settings and onboarding never read it. `errSecItemNotFound` means that no `feedbin_account` item exists. Every other failed status, and data that does not decode, is a failed read: Feeder shows the unreadable state and never onboarding. Feeder reads again only on Retry, on a sync request in that state, and at the next launch. While a Keychain access dialog waits, the read waits too. This wait is not bounded and not cancellable (#225). A save verifies with Feedbin, deletes the stored `feedbin_account` item, and then adds a `feedbin_account` item with the new values. If that delete fails, for example with `errSecInvalidOwnerEdit` (-25244) for an item that another build wrote, the current account stays in use and the save reports the error. If the add fails after the delete, no `feedbin_account` item is saved: Feeder stops the sync and shows onboarding. The one-time migration moves the `feedbin_username` value from `UserDefaults` and the `feedbin_password` item into the `feedbin_account` item. It runs only when no `feedbin_account` item exists, never contacts Feedbin, and removes the old values only after the write. A successful save also removes the old values. A failed delete of the old `feedbin_password` item never fails a save. A save with a failed add does not remove the old values, so the next launch can still move them into a `feedbin_account` item. Launches with an in-memory store never reach the Keychain.

---

## 9. Background & lifecycle

- **Allowed background work:** in-process background actors (`DataWriter`, `FeedbinClient`); periodic Feedbin sync via a cancellable `Task.sleep(for:)` loop; classification batches that are cancellable and yield cooperatively. All background work stops when the app quits.
- **Forbidden background work:** launch agents, daemons, login items, or any execution outside the app's lifetime; polling loops that cannot be cancelled; background work that blocks or contends with the MainActor (§4).

---

## 10. Time & timezones

UTC everywhere internally, converted only at the boundary (`CLAUDE.md → Time`). Concrete mechanics:

- **Internal representation:** all timestamps in logic, SwiftData persistence, caches, and logs are `Date` instants. Canonical timeline ordering (`VISION.md → Core Principles`) sorts on `Date`, never on formatted strings.
- **Boundary conversion:** inbound Feedbin timestamps parse to `Date` immediately (`ISO8601DateFormatter`, GMT by default); user-facing values convert at the last moment via `Text(date, format:)` / `.formatted(...)` or a `DateFormatter` / `Calendar` with an explicit `timeZone`.
- **Banned:** storing or computing with calendar components or local-time strings in logic; manual UTC-offset arithmetic; `DateFormatter` / `Calendar` without an explicit `timeZone` outside the display boundary. *Documented exception:* the pre-computed display-string fields `formattedDate` / `formattedPublishedTime` (§5) are an Intentional Divergence (§14) — they are display artifacts, never inputs to logic or ordering.
- **Tests:** inject a fixed `Date` rather than reading `Date.now`; no timezone-dependent assertions. A test reads the clock only for code that reads the clock itself and takes no `now` input, such as `articleCutoffDate()` and `DataWriter.purgeEntriesOlderThan(_:)`. No assertion then depends on the local day. An instant that must stay newer than a cutoff that the code computes from the clock is at least five seconds newer than the test's cutoff.

---

## 11. Design guidelines & UX thresholds

- **Design authority:** Apple Human Interface Guidelines (macOS). The app must look and feel like Apple built it — no custom design language.
  - Standard SwiftUI components (`List`, `NavigationSplitView`, `Table`, `Form`, `Toggle`, …); no custom controls when Apple provides an equivalent.
  - System colors (`Color.primary`, `Color.secondary`, `.background`) and system fonts (`.body`, `.headline`, `.caption`); dark mode honoured.
  - Text in a selectable `List` row uses a hierarchical style (`.primary`, `.secondary`, `.tertiary`). A fixed color such as `Color(nsColor: .secondaryLabelColor)` does not adapt to the emphasized selection.
  - Target the newest macOS APIs. No private API calls. No third-party UI frameworks.
- **Keyboard (first-class, `VISION.md → Core Principles`):** every core action has a shortcut, discoverable in menus; focus behavior predictable and consistent; sidebar ↔ article list ↔ detail pane fully keyboard-navigable; the app is operable without a mouse.
- **Readability:** good contrast at all times; comfortable body-text sizes for long sessions; clear information hierarchy at a glance; premium / calm / harmonious — reduce noise, not information.
- **Accessibility:** VoiceOver labels/hints, Dynamic Type, Reduced Motion respected on every surface.
- **Documented thresholds to exercise at the threshold** (HIG-documented limits are exactly where bugs sit; testing below them is a false pass — the preview matrix must include the threshold case):
  - Alert / `confirmationDialog` button count — truncation past ~10 buttons; use a sheet + picker beyond that.
  - `Picker` style — `.menu` above ~7 options, `.inline` below.
  - Sheet minimum / maximum widths per HIG → Sheets.
  - `NavigationSplitView` sidebar nesting depth per HIG recommendation.
  - Reference shape: the `Recategorize Sheet — Large N` preview in `CategoryEditSheet.swift` (22 targets).

---

## 12. Best practices source

`architect` and `ux-guardian` fetch Apple's current best practices and Human Interface Guidelines via the `ctx7` tool (see `~/.claude/rules/context7.md`) before every design and review pass, and cite the doc / HIG section in their reports. Topics include: Swift Concurrency, SwiftData `@ModelActor` and schema migration, Observation framework, `NavigationSplitView`, keyboard navigation patterns, accessibility, focus management, Dynamic Type.

Training-data memory is not an acceptable source for API syntax or HIG specifics.

---

## 13. Code conventions (Swift specifics)

Universal conventions (value types, immutability, composition, comments, dead code) live in `CLAUDE.md → Code conventions`. Feeder pins these Swift specifics on top:

### Change discipline

- **DRY:** if logic is similar to existing code, refactor to reuse — never copy-paste.
- **Single-purpose functions:** split when a function grows past one responsibility.
- **Minimal-scoped changes:** change only what the task needs; no unrelated refactors mixed into a fix.
- **Migrate on contact:** when touching code that uses a §7-prohibited pattern, migrate it as part of the change. Do not introduce files with legacy patterns "to be fixed later". Build stays clean after every commit.

### File organization

- **Models (`@Model`):** properties → relationships → classification fields → `init()`.
- **Actors / classes:** static properties (logger) → instance properties → init → methods by purpose.
- **Views:** `@Environment` / `@Binding` → `@State` → `@Query` → `var body` → helper views → `#Preview`.
- **DTOs:** properties only, marked `nonisolated` + `Sendable`.
- Use `// MARK: - Section Name` to separate logical concerns.

### Naming

- All identifiers in English; descriptive, intention-revealing names.
- Booleans in predicate form — `isRead`, `isClassified`, `isTopLevel`.
- Functions with a descriptive verb prefix — `persist`, `fetch`, `apply`, `detect`, `strip`.

### Formatting

Mechanical formatting is enforced by `swift-format` (§2). Beyond it: blank line between methods and between MARK sections; no blank lines between grouped property declarations.

Comment rules live in `CLAUDE.md → Code conventions → Comments`. Swift specifics on top: doc comments use `///` (`swift-format` `UseTripleSlashForDocumentationComments`); `// MARK:` lines are navigation, not prose, and sit outside the 5-line comment budget. Keep `.swift-format` `AllPublicDeclarationsHaveDocumentation` **off** — it mandates a doc comment on every public declaration, which is the mandate the comment policy removed.

### Access control

- Default: implicit `internal` (no keyword); `private` for implementation details.
- `nonisolated` on helpers and DTOs crossing actor boundaries.

### Error handling

- Shorthand unwrapping preferred: `guard let entry else { return }`.
- `if let` only when the unwrapped value is used in the immediately following block.
- `throws` for data operations that can fail; typed throws when the error domain is known: `func fetchEntries() throws(FeedbinError) -> [EntryDTO]`.

### Collections

- `Dictionary(uniqueKeysWithValues:)`, `Dictionary(grouping:by:)` over manual loops.
- `map` / `filter` / `compactMap` over `for` loops for pure transformations.
- `stride(from:to:by:)` for batching; `lazy` for chained operations to avoid intermediate allocations.

### Mandatory async patterns

```swift
// Periodic work — owned, cancellable:
private var periodicTask: Task<Void, Never>?

func startPeriodicWork(interval: TimeInterval) {
  periodicTask?.cancel()
  periodicTask = Task {
    while !Task.isCancelled {
      await doWork()
      try? await Task.sleep(for: .seconds(interval))
    }
  }
}

// UI-triggered async:
Button("Sync") {
  Task { await syncEngine.sync() }
}
```

---

## 14. Intentional Divergences

A divergence requires a measurement-backed reason, a clear benefit, and an isolated exception. Document it here when you take it.

| Date | Rule | Divergence | Reason |
| ---- | ---- | ---------- | ------ |
| 2026-05-14 | Remote CI (`CLAUDE.md → Verification`) | No GitHub Actions; `make test-all` is the contracted local gate. | Single-developer project, PR template enforces verification. Revisit if contributor count > 1 or verification is skipped in any merged PR. |
| 2026-05-14 | MainActor must not perform synchronous IO (`CLAUDE.md → Responsiveness & resource budget`) | `SyncEngine.lastSyncDate` and `pendingReadIDsToSync` accessors keep synchronous `UserDefaults` reads/writes on MainActor. This includes the queue write in `FeederAppDelegate.applicationWillTerminate(_:)` and the queue read in `SyncEngine.applyQueuedReads()` at launch. | Reads and writes occur at human-event frequency (sync completion, mark-read, app quit, app launch), are `CFPreferences`-cached in-process, and benchmark below 100 µs — well inside the 16 ms / 8.3 ms frame budget. Wrapping in an actor adds Task-hop latency on the very path it would protect and forces `ContentView` mark-read handlers to become async. The quit write must be synchronous: the process exits when `applicationWillTerminate(_:)` returns, so a Task or an actor hop that the method starts can be lost. Revisit if Instruments shows MainActor hang attributable to these accessors, or if call frequency rises (e.g., per-scroll persistence). |
| 2026-05-15 | Evidence over opinion (`VISION.md → Core Principles`) | `ClassificationEngine` heuristics — `applyConfidenceGate` (threshold 0.3), `keywordMatchConfidence` weights (title 0.8 / body 0.4), `keywordOverrideThreshold` (0.8), and language-gating — ship as calibrated values without precision/recall measurement. | MVP has one user (the developer); synthetic 30-fixture evals lack statistical power (95% CI ±10–15%) and risk confirmation bias when written by the same person tuning the gates. `VISION.md → Success Definition` frames classification correctness as human-verifiable, not benchmark-driven. Revisit when: (a) real user base produces a labeled-by-third-party corpus of ≥100 entries per major category, OR (b) production evidence shows user-facing miscategorisation > 10%. |
| 2026-05-19 | Persistence shape — "Never write migrations" (lifted) | Previous rule was: bump `currentSchemaVersion`, let the store auto-reset on mismatch. This was always destructive — folders, categories, classifications, and feeds were wiped on every schema bump even though articles re-sync from Feedbin. Lifted in favour of SwiftData `VersionedSchema` + `SchemaMigrationPlan` (`FeederSchemaV1` + `FeederMigrationPlan`). User data is now durable across schema changes per `VISION.md → Core Principles` (every ingested article keeps its category assignment). | Revisit only if the migration framework itself becomes a maintenance burden disproportionate to the value of preserved user data. |
| 2026-07-07 | Time (`CLAUDE.md → Time`, §10) | `DataWriter` persists `formattedDate` and `formattedPublishedTime` — display-formatted local-time strings pre-computed at write time. | Render-time date formatting is banned on the hot path (§0, §4: no Calendar work in `body`); these fields exist precisely to keep that work off the frame. They are display artifacts only — ordering and logic always use the `Date` instant. Staleness after a timezone change is bounded: fields recompute on the next write and in every custom migration stage (§5). Revisit if timezone-change staleness becomes user-visible, or if profiling shows render-time formatting fits the frame budget. |
| 2026-07-08 | §0/§5 single writer-context (multiple `ModelContext` per container) | `DataReader` runs a SECOND **read-only** `ModelContext` on the SAME app container as `DataWriter` + the SwiftUI main context — the supported SwiftData multi-context pattern (one coordinator serialises store access; a concurrent op briefly blocks, never throws). Reads decouple onto their own actor to end the panel-2 spinner starvation. | A SEPARATE reader container on the same store URL was evaluated and REJECTED — its coordinator mints `PersistentIdentifier`s that do NOT resolve via `model(for:)` in the app container (hard crash on the selection path). The Core Data `NSException` seen with a shared context was a TEST-PARALLELISM artifact (dozens of concurrent containers/coordinators in the parallel test target), NOT a production hazard: an isolated 1+1 production-shape stress test (`DataReaderConcurrencyTests`, clean under Thread Sanitizer) proves it. The gate caps that test-only concurrency by running the unit target SERIALLY — `make test` passes `-parallel-testing-enabled NO`. This is the load-bearing cap: `@Suite(.serialized)` only serialises WITHIN a suite (Apple's docs: "This trait doesn't affect the execution of a test relative to its peers or to unrelated tests."), so it does NOT stop the many container-creating suites running in parallel with each other; the reader-using suites keep the trait only for intra-suite ordering and single-suite Xcode (Cmd-U) runs. Revisit if Apple ships first-party read-replica support, or if a SwiftData release makes cross-container `PersistentIdentifier` resolution reliable (a separate reader container could then further decouple store access). |
| 2026-07-13 | §7 GCD ban (`DispatchQueue` / GCD → `Task` / actors) | `BackgroundSerialModelExecutor` (a custom `SerialModelExecutor` shared by `DataReader` AND `DataWriter`, one instance — one queue — per actor) backs each actor's serial executor with a dedicated background `DispatchQueue` (SE-0392 custom actor executor; `enqueue` → `UnownedJob.runSynchronously(on:)`). | `DefaultSerialModelExecutor` guarantees only SERIALISED context access, NOT off-main execution — Instruments per-thread attribution proved `DataReader`'s reads ran on the MAIN thread (18.85 s main vs 0.99 s background; issue #135), the felt category-nav lag; `DataWriter` shared the identical code shape and defect (issue #159). SE-0392 custom actor executors REQUIRE a `SerialExecutor`; a background `DispatchQueue` (which the actor never touches directly) is the stdlib primitive for a dedicated off-main serial context, and no pure-`Task` primitive binds a serial actor executor to a fixed `ModelContext`. This is an ACTOR EXECUTOR, not app-level GCD scheduling — the §7 ban targets ad-hoc `DispatchQueue.async` concurrency, which this is not. `DispatchSerialQueue` vends no public `asUnownedSerialExecutor()` in the macOS 26 SDK, hence the wrap-a-`DispatchQueue` form. A `dispatchPrecondition(.notOnQueue(.main))` at the top of every `DataReader` fetch and every `DataWriter` fetch/write fails loudly if a regression returns them to main. The two actors NEVER share one executor instance — that would re-serialise reads behind writes and reintroduce the panel-2 starvation. Revisit if SwiftData ships a first-party off-main model-actor executor. |
| 2026-09-17 | Undocumented behaviour / public API only (`CLAUDE.md → Reject changes`, `STACK.md § 7`) | `SplitViewAutosaveReset` removes every `UserDefaults.standard` key prefixed `NSSplitView Subview Frames` in `FeederApp.init`, before any window exists; Feeder persists both leading column widths itself (`ColumnWidthSetting`, `ColumnWidthRecorder`). | On macOS 27 the `NavigationSplitView` bridge autosaves the content frame with `x = sidebar width` and restores `width − x` (five-launch log, issue #170: stored 586 → restored `ideal` 586 → settled 348 = 586 − 238; a value below the column minimum lands at the ~200-pt default), overriding the launch `ideal` ~0.5 s after creation; a late `ideal` change is ignored, `min = max` is honoured (headless spike). AppKit `autosaveName` is documented, the key NAME is not. Fails safe: a renamed key makes the removal a no-op and the recorder's launch-layout skip protects the stored widths (the settled log line then shows `skippedLaunchLayout`). FB pending (owner files). Revisit: remove when the Feedback resolves or a macOS release restores the content frame correctly (verify with a diagnostic build that logs the autosave frames). |
