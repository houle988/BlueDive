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

### Suggesting features

Use the **Feature Request** issue template ([open one here](../../issues/new/choose)). Check existing issues and Discussions first to avoid duplicates. For early-stage ideas, start a conversation in the **Ideas** category instead.

### Submitting a pull request

1. Fork the repository
2. Create a branch from `main` with a descriptive name (e.g. `feature/shearwater-perdix-support`)
3. Make your changes, keeping commits focused and well-described
4. Open a pull request against `main` with a clear explanation of what changed and why

### Good first issues

Look for issues tagged [`good first issue`](../../issues?q=is%3Aissue+label%3A%22good+first+issue%22) if you're looking for somewhere to start.

## Setting up for development

1. Clone the repository and open `BlueDive.xcodeproj` in Xcode 15 or later
2. Swift Package Manager will automatically resolve the [LibDCSwift](https://github.com/houle988/libdc-swift) dependency
3. Select your target and build (⌘B)

**iCloud & App Group:** The app's CloudKit container and App Group are tied to the project owner's private Apple Developer account. To build and run locally, you will need to:
- Change the bundle ID to one registered under your own Apple Developer account
- Create a matching App Group and iCloud container in your account
- Update the entitlements files accordingly — do not include these changes in your pull request

Most features (dive log, gear, import/export, Bluetooth sync) work without iCloud configured. Only iCloud sync and the widget require a fully provisioned account.

## Areas where help is especially welcome

- **Dive computer support** — additional device support via libdivecomputer
- **Localization** — translations beyond English (Canada), French (Canada), and German
- **UI/UX** — SwiftUI improvements, accessibility
- **Testing** — edge cases, device-specific bugs, import/export workflows

## Code conventions

See `claude.md` in the repository root for the full conventions. Key points:

- **SwiftUI / async** — use `async`/`await`; no Combine
- **Localization** — all user-facing text must use `NSLocalizedString(_:bundle:comment:)` with `Bundle.forAppLanguage()` (not `String(localized:)`); every new key needs `fr-CA` and `de` entries in the same PR
- **TextFields** — edit/add views require a clear button overlay and trimmed input; Double fields must be string-backed and accept both `.` and `,` as decimal separators
- **Unit display** — always go through the `Dive` display helpers; never display raw stored values directly
- **Mac sheets** — all `.sheet()` presentations need `.presentationSizing(.page)`, `.presentationDetents([.large])`, and `.presentationDragIndicator(.visible)`
- **Date display** — use `@Environment(\.locale)` in views and apply it to all date format styles; never use `Locale.current`
- **Data integrity** — never convert, normalize, or alter dive data during import, export, or storage

## Third-party dependencies

BlueDive builds on:
- [libdivecomputer](https://github.com/houle988/libdivecomputer) — LGPL-2.1-or-later (BlueDive fork)
- [libdc-swift](https://github.com/houle988/libdc-swift) — LGPL-2.1 (BlueDive fork)

Contributions to those libraries should be made directly to their respective repositories.

## Code of conduct

Be respectful and constructive. This project follows the [Contributor Covenant](https://www.contributor-covenant.org/version/2/1/code_of_conduct/) code of conduct.

## Questions?

Head to [GitHub Discussions](../../discussions) — that's the best place for questions and conversation.
