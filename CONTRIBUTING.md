# Contributing to BlueDive

Thanks for your interest in contributing to BlueDive! This document explains how to get involved.

## About the project

BlueDive is a source-available dive log app for iOS, iPadOS, and macOS. The source code is publicly readable and contributions are welcome via pull requests. Please note that BlueDive is licensed under the [BlueDive Source Available License (BDSAL) v1.0](LICENSE) — not a traditional open-source license. By submitting a pull request, you agree that your contribution will be incorporated under these terms.

## Community — GitHub Discussions

For questions, ideas, and general conversation, use [GitHub Discussions](../../discussions) rather than issues. Issues are reserved for concrete bugs and actionable feature requests.

**Recommended Discussions categories:**

| Category | Use it for |
|---|---|
| **General** | Anything that doesn't fit elsewhere |
| **Ideas** | Early-stage feature brainstorming before opening a formal issue |
| **Dive Computer Support** | Questions and requests for specific dive computer hardware |
| **Help & Q&A** | Setup, import, sync, and usage questions |
| **Show & Tell** | Share trip photos, logbook stats, or cool dives |

## How to contribute

### Reporting bugs

Use the **Bug Report** issue template ([open one here](../../issues/new/choose)). Please include:
- A clear description of the problem
- Steps to reproduce
- Your device model, OS version, and BlueDive version
- Your dive computer model, if relevant
- For dive computer problems, a Bluetooth diagnostic log (Settings → Bluetooth Import → **Save Diagnostic Log**)

### Suggesting features

Use the **Feature Request** issue template ([open one here](../../issues/new/choose)). Check existing issues and Discussions first to avoid duplicates. For early-stage ideas, start a conversation in the **Ideas** category instead.

### Submitting a pull request

1. Fork the repository
2. Create a branch from `main` with a descriptive name (e.g. `feature/shearwater-perdix-support`)
3. Make your changes, keeping commits focused and well-described
4. Open a pull request against `main` with a clear explanation of what changed and why

### Keep your local environment out of the pull request

A pull request must contain only the code required for the change. Do not commit or push anything that reflects your own machine or Apple Developer account, including:

- Bundle identifiers, development team, and code-signing settings in `BlueDive.xcodeproj/project.pbxproj`
- Entitlements, App Group, and iCloud container identifiers
- Schemes and per-user Xcode data (`xcshareddata/xcschemes`, `xcuserdata`, `*.xcuserstate`), including scheme launch arguments such as `-initializeCloudKitSchema`
- `Package.resolved` changes, unless the pull request deliberately updates a dependency
- Local paths, debugging code or logging, and test files, sample dive logs, or databases you used locally

Review `git status` and `git diff` before each commit, and stage only the files your change needs (`git add <file>` rather than `git add -A`). If a pull request includes environment-specific changes, you will be asked to remove them before it can be merged.

### Good first issues

Look for issues tagged [`good first issue`](../../issues?q=is%3Aissue+label%3A%22good+first+issue%22) if you're looking for somewhere to start.

## Setting up for development

1. Clone the repository and open `BlueDive.xcodeproj` in Xcode 26 or later (the app uses iOS 26 / macOS 26 SDK APIs)
2. Swift Package Manager will automatically resolve the [LibDCSwift](https://github.com/houle988/libdc-swift), [Garmin FIT Swift SDK](https://github.com/garmin/fit-swift-sdk), and [swift-collections](https://github.com/apple/swift-collections) dependencies
3. Select the **BlueDive** scheme and build (⌘B) for both an iOS destination and **My Mac** — BlueDive is a native universal app, and every change must build on both platforms

**iCloud & App Group:** The app's CloudKit container and App Group are tied to the project owner's private Apple Developer account. To build and run locally, you will need to:
- Change the bundle ID to one registered under your own Apple Developer account
- Create a matching App Group and iCloud container in your account
- Update the entitlements files (`BlueDive/BlueDive.entitlements` and `BlueDiveWidgetExtension/BlueDiveWidgetExtension.entitlements`) accordingly — this applies to both the iOS and Mac builds; do not include these changes in your pull request (see [Keep your local environment out of the pull request](#keep-your-local-environment-out-of-the-pull-request))

Most features (dive log, gear, import/export, Bluetooth sync) work without iCloud configured. Only iCloud sync and the widget require a fully provisioned account.

## Areas where help is especially welcome

- **Dive computer support** — additional device support via libdivecomputer
- **Localization** — translations beyond English (Canada), French (Canada), German, and Dutch
- **UI/UX** — SwiftUI improvements, accessibility
- **Testing** — edge cases, device-specific bugs, import/export workflows

## Code conventions

See [`CLAUDE.md`](CLAUDE.md) in the repository root for the full conventions. Key points:

- **SwiftUI / async** — use `async`/`await`; no Combine
- **Localization** — in SwiftUI views, use `LocalizedStringKey` (`Text("My Key")`); for strings built in code, use `NSLocalizedString(_:bundle:value:comment:)` with `Bundle.forAppLanguage()` (not `String(localized:)`). Every new key needs `fr-CA`, `de`, and `nl` translations in the same PR. Never edit `Localizable.xcstrings` by hand — build so Xcode extracts the keys, then use `Scripts/xcstrings.py` (`missing`, `set-json`, `check`)
- **Number formatting** — use `localizedString(decimals:)` for displayed numbers and `editableString(decimals:)` to pre-fill text fields; never `String(format:)` or string interpolation for displayed numbers
- **TextFields** — edit/add views require a clear button overlay and trimmed input; Double fields must be string-backed and accept both `.` and `,` as decimal separators
- **Unit display** — always go through the `Dive` display helpers; never display raw stored values directly
- **One shared UI on macOS** — no separate macOS layouts for screens that exist on iOS; prefer the shims in `PlatformCompat.swift` over `#if os(macOS)`. Forms use `.groupedFormStyleOnMac()`, Toggles use `.fullWidthSwitch()`, and every Button gets an explicit style (`.listRowButton()`, `.borderlessButton()`, or `.buttonStyle(...)`)
- **Sheets** — every `.sheet()` presentation ends with `.standardSheetPresentation()` (page sizing on iOS and Mac, and the in-app language on macOS sheets)
- **DiveStore** — never add a `@Query` for `Dive` outside `DiveDataFeeder`; save dive edits through `store.commit(_:affects:)` with the narrowest scope
- **Date display** — use `@Environment(\.locale)` in views and apply it to all date format styles; never use `Locale.current`
- **Data integrity** — never convert, normalize, or alter dive data during import, export, or storage

## Third-party dependencies

BlueDive builds on:
- [libdivecomputer](https://github.com/houle988/libdivecomputer) — LGPL-2.1-or-later (BlueDive fork)
- [libdc-swift](https://github.com/houle988/libdc-swift) — LGPL-2.1 (BlueDive fork)
- [Garmin FIT Swift SDK](https://github.com/garmin/fit-swift-sdk) — Garmin FIT file decoding
- [Open-Meteo](https://open-meteo.com) — Weather data
- [iNaturalist](https://www.inaturalist.org) — Species taxonomy and photos

Contributions to libdivecomputer, libdc-swift, or the Garmin FIT Swift SDK should be made directly to their respective repositories.

## Code of conduct

Be respectful and constructive. This project follows the [Contributor Covenant](https://www.contributor-covenant.org/version/2/1/code_of_conduct/) code of conduct.

## Questions?

Head to [GitHub Discussions](../../discussions) — that's the best place for questions and conversation.
