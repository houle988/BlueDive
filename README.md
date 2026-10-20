# BlueDive

**A feature-rich dive log for iOS, iPadOS, and macOS.**

[Website](https://www.bluedive.app) · [App Store](https://apps.apple.com/us/app/bluedive/id6760430619) · [Discussions](https://github.com/houle988/BlueDive/discussions) · [Report a Bug](https://github.com/houle988/BlueDive/issues/new/choose)

---

## Overview

BlueDive is a modern, actively maintained dive log app designed as a full-featured alternative to other legacy dive log applications. Built natively with SwiftUI, it syncs seamlessly across all your Apple devices via iCloud and supports direct import from your dive computer over Bluetooth. Version 2.0 brings a native Mac app that shares the iPhone and iPad interface and uses the extra width of the Mac window.

## Features

- **Dive log** — Record and browse your full dive history with depth profiles, gas mixes, conditions, photos, marine life, a decompression overlay with deco-stop markers, and an optional raw samples table
- **Dive computer sync** — Import dives directly from your computer over Bluetooth via libdivecomputer, with an import cutoff date, fingerprint export/import, an optional weather lookup after download, and diagnostic logging with saveable trace files
- **Native Mac app** — The same interface as on iPhone and iPad, with column-aligned lists and headers that stay visible, two-column detail layouts, and menu bar commands
- **Multiple divers** — Keep several divers' logbooks in one database, filter every tab by diver, and move a dive to another diver
- **iCloud sync** — Your logbook stays in sync across iPhone, iPad, and Mac automatically, including live updates of dives edited on another device
- **Import** — MacDive XML, UDDF, Subsurface XML, Garmin FIT, BlueDive XML, and MacDive gear CSV; `Scripts/macdive_to_bluedive.py` migrates a MacDive SQLite database (dives, gear, certifications, and critters)
- **Export** — UDDF, BlueDive XML, and a printable PDF logbook
- **Dive photos** — Import photos with their EXIF/IPTC metadata, automatic dive matching, camera clock correction, and re-import without duplicates
- **Marine life & species catalogue** — Record sightings from a species catalogue linked to iNaturalist (taxonomy, names, Creative Commons photos), detect species from photo keywords, and export or import the catalogue
- **Online weather** — Fetch weather and wind conditions from Open-Meteo for one dive or for all dives
- **Gear management** — Track your equipment, gear groups, tank templates, and service history
- **Dive sequence** — Automatic dive renumbering, surface interval recalculation, and merging of dives
- **Trips, map & statistics** — Group dives by trip, browse your dive sites on a map, and visualize your diving history with charts and a calendar heatmap
- **Certifications & insurance** — Store, import, and export certification records and diving insurance details
- **Reminders** — Notifications for upcoming gear service and for certification and insurance expiry
- **Database backup** — Back up your full logbook as a zip archive
- **Units, appearance & language** — Each dive keeps the units it was imported in and is shown in your preferred units; light/dark mode override; in-app language independent of the system
- **Localized** — Available in English (Canada), French (Canada), German, and Dutch
- **Widget** — Small and medium widgets showing recent dive stats, on the Home Screen and on the Mac desktop

## Requirements

| Platform | Minimum Version     |
| -------- | ------------------- |
| iPhone   | iOS 18.6            |
| iPad     | iPadOS 18.6         |
| Mac      | macOS 15.6 (native) |

## Contributing

BlueDive welcomes contributions from developers and divers alike. See [CONTRIBUTING.md](https://github.com/houle988/BlueDive/blob/main/CONTRIBUTING.md) for how to get involved.

**Ways to contribute:**

- Add or improve dive computer support
- Translate the app into additional languages
- Report bugs or unexpected behaviour
- Suggest or implement new features
- Help with testing on specific devices or dive computers

## Built on

- [libdivecomputer](https://github.com/houle988/libdivecomputer) — LGPL-2.1-or-later (BlueDive fork)
- [libdc-swift](https://github.com/houle988/libdc-swift) — LGPL-2.1 (BlueDive fork)
- [Garmin FIT Swift SDK](https://github.com/garmin/fit-swift-sdk) — Garmin FIT file decoding
- [Open-Meteo](https://open-meteo.com) — Weather data
- [iNaturalist](https://www.inaturalist.org) — Species taxonomy and photos

## Support the Project

If BlueDive has been useful for logging your dives, consider buying me a coffee to help support ongoing development.

<a href="https://www.buymeacoffee.com/houle988"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" width="150"></a>

## License

Source available under the [BlueDive Source Available License (BDSAL) v1.0](https://github.com/houle988/BlueDive/blob/main/LICENSE). Not a traditional open-source license — see the license file for terms.
