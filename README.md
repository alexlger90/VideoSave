# VideoSave

Native SwiftUI-App für iPhone zum Speichern öffentlich erreichbarer Videoquellen.

## Fertige IPA herunterladen

**[⬇️ VideoSave.ipa direkt von GitHub herunterladen](https://github.com/alexlger90/VideoSave/releases/download/videosave-latest/VideoSave.ipa)**

Die IPA ist bereits fertig gebaut. Du musst **nichts mit Xcode bauen, nichts entpacken und keinen GitHub-Artifact herunterladen**. Für die Installation brauchst du nur **Sideloadly**:

1. `VideoSave.ipa` über den Link oben herunterladen.
2. Sideloadly öffnen und das iPhone verbinden (https://sideloadly.io/)
3. `VideoSave.ipa` in Sideloadly auswählen bzw. hineinziehen.
4. Den eigenen Apple-Account für die Signierung verwenden.
5. **Remove Extensions deaktiviert lassen**, damit die VideoSave-Share-Extension mit installiert wird.
6. **Start** drücken und die App auf dem iPhone installieren lassen.

Die IPA ist absichtlich nicht mit einem fremden Zertifikat vorsigniert. Sideloadly übernimmt die Signierung für dein Gerät und installiert die fertige App. Die App benötigt iOS 18 oder neuer.

## Funktionen

- Direkte HTTP/HTTPS-Videodateien sowie unverschlüsselte HLS-VOD-Streams
- Qualitätsauswahl mit automatischem Quellen-Fallback
- Spezialisierter Resolver plus generischer Resolver für 113 konfigurierte Video-Seiten
- MP4/MOV-Ausgabe
- Real-ESRGAN-CoreML-Upscaling für Quellen bis 1080p auf eine 4K-Ausgabe
- Speichern in Dateien und Fotos
- iOS-Share-Extension für Links aus dem Browser
- Quellen-Diagnose direkt in der App

VideoSave verwendet nur Medienquellen, die eine öffentlich erreichbare Seite selbst bereitstellt. CAPTCHA, Login, Regions-/Zugriffssperren, Paywalls und DRM bzw. verschlüsselte HLS-Streams werden nicht umgangen. Eine echte CAPTCHA-Seite kann ausschließlich zur manuellen Bestätigung geöffnet werden.

## Unterstützte Seiten

Der Resolver erkennt zusätzlich die im Projekt hinterlegten 113 Quellen und versucht dort öffentlich eingebettete MP4-/M4V-/MOV- oder HLS-Quellen zu verwenden. Da externe Seiten ihr Markup und ihre Player jederzeit ändern können, ist die Unterstützung best effort und wird durch die Quellen-Diagnose nachvollziehbar gemacht.

Die aktuelle Quellenliste liegt in `Sources/GenericTubeResolver.swift`.

## Automatischer GitHub-Build

Der GitHub-Actions-Workflow läuft auf `macos-15` mit Xcode 16.4. Er führt die Resolver-/Zugriffsschutztests aus, baut die iPhone-App und erzeugt `VideoSave.ipa`.

Nach jedem erfolgreichen Build auf `main` wird die fertige IPA automatisch unter **Releases → VideoSave – aktuelle IPA** veröffentlicht. Der feste Download-Link oben zeigt dadurch immer auf die aktuelle Version. Alte Workflow-Runs werden automatisch entfernt, damit die Actions-Seite sauber bleibt.

## Share Sheet

Nach der Installation kann VideoSave im iOS-Teilen-Menü aktiviert werden. Die Share-Extension übernimmt Weblinks bzw. Text und reicht den gefundenen HTTP-/HTTPS-Link an die Haupt-App weiter.

## Projektstruktur

- `Sources/` – Haupt-App, Resolver, Download-/HLS-Logik und Upscaler
- `ShareExtension/` – iOS-Share-Extension
- `Shared/` – gemeinsam verwendete Link-Logik
- `Tests/` – Resolver-, HLS-, Export- und Schutztests
- `project.yml` – XcodeGen-Projektdefinition
- `.github/workflows/build-ipa.yml` – CI-, IPA- und Release-Build
