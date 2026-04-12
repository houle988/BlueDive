# Contributing to BlueDive

Thanks for your interest in contributing to BlueDive! This document explains how to get involved.

## About the project

BlueDive is a source-available dive log app for iOS, iPadOS, and macOS. The source code is publicly readable and contributions are welcome via pull requests. Please note that BlueDive is licensed under the [BlueDive Source Available License (BDSAL) v1.0](LICENSE) — not a traditional open-source license. By submitting a pull request, you agree that your contribution will be incorporated under these terms.

## How to contribute

### Reporting bugs
Open a [GitHub issue](../../issues) with:
- A clear description of the problem
- Steps to reproduce
- Your device, OS version, and BlueDive version
- Your dive computer model, if relevant

### Suggesting features
Open a GitHub issue tagged `enhancement`. Please check existing issues first to avoid duplicates.

### Submitting a pull request
1. Fork the repository privately
2. Create a branch from `main` with a descriptive name (e.g. `feature/shearwater-perdix-support`)
3. Make your changes, keeping commits focused and well-described
4. Open a pull request against `main` with a clear explanation of what you changed and why

### Good first issues
Look for issues tagged [`good first issue`](../../issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22) if you're looking for a place to start.

## Areas where help is especially welcome

- **Dive computer support** — additional device support via libdivecomputer
- **Localization** — translations beyond English and French Canadian
- **UI/UX** — SwiftUI improvements, accessibility
- **Testing** — edge cases, device-specific bugs, import/export workflows

## Third-party dependencies

BlueDive builds on:
- [libdivecomputer](https://github.com/libdivecomputer/libdivecomputer) — LGPL-2.1-or-later
- [libdc-swift](https://github.com/jdevost/libdc-swift) — LGPL-2.1 (BlueDive fork)

Contributions to those libraries should be made directly to their respective repositories.

## Code conventions

Please refer to `claude.md` in the repository root for project-specific coding conventions and architecture guidelines.

## Questions?

Open an issue or reach out via the contact information in the App Store listing.
