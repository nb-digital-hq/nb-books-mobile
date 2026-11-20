# Privacy Statement

This statement describes what NB Books Mobile does with your data. It is enforced by the code and by automated
checks that run on every change. The detailed Spanish reference is [docs/audit/privacy.md](docs/audit/privacy.md).

## 1. No account, no cloud, no telemetry

* No feature requires registration, an email address or a sign-in.
* Your books travel from your own PC to your phone over your local network. NB Digital operates no server that
  receives them.
* The app contains **no** analytics, usage tracking, crash reporting or advertising identifiers, and it writes
  **no** logs (`tool/guardianes/registro.dart`).

## 2. Network access

Every connection is built in one place, `lib/core/network/`; any client elsewhere, and any network crate in the
reading engine, fails the checks (`tool/guardianes/red.dart`). Every destination is requested by you:

| Destination | What is sent | When |
|---|---|---|
| The PC you paired | Phone name and platform when pairing; your selection; annotations, reading positions, sessions, reviews and notes on PC books; requests for the catalogue, files, covers, search and Read on PC commands | When you pair, sync, download, search or use the remote |
| GitHub (`api.github.com`, `github.com`) | An anonymous request for the latest release | Only when you tap "Check for updates" or "Install" (Android) |
| Wikidata and Wikimedia Commons | The name of each author in your library, once, and the download of their photo | Only with "Author photos" turned on in Settings (off by default) |

The PC certificate is pinned by its fingerprint when you pair. The reader page blocks every external load and
navigation, so a book cannot reach the network. Books added from your phone, and anything you do in them, are never
sent to the PC.

## 3. What stays on the phone

Book records and covers of your selection, author photos if you asked for them, downloaded files, annotations, positions, notes, study data and
preferences. The pairing token and the PC fingerprint are kept in the system keychain. Uninstalling the app removes
everything.

## 4. Permissions

Network and Wi-Fi multicast (finding and talking to your PC), camera (only while scanning the QR code) and package
installation (updates you request, Android).
