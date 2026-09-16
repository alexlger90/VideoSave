# VideoSave

Native SwiftUI-App für iPhone zum Speichern öffentlich erreichbarer Videoquellen.

## Funktionen

- Direkte HTTP/HTTPS-Videodateien sowie unverschlüsselte HLS-VOD-Streams
- Qualitätsauswahl mit automatischem Quellen-Fallback
- Spezialisierter Pornhub-Resolver plus generischer Resolver für 113 konfigurierte Video-Seiten
- MP4/MOV-Ausgabe
- Real-ESRGAN-CoreML-Upscaling für Quellen bis 1080p auf eine 4K-Ausgabe
- Speichern in Dateien und Fotos
- iOS-Share-Extension für Links aus dem Browser
- Quellen-Diagnose direkt in der App

VideoSave verwendet nur Medienquellen, die eine öffentlich erreichbare Seite selbst bereitstellt. CAPTCHA, Login, Regions-/Zugriffssperren, Paywalls und DRM bzw. verschlüsselte HLS-Streams werden nicht umgangen. Eine echte CAPTCHA-Seite kann ausschließlich zur manuellen Bestätigung geöffnet werden.

## Unterstützte Seiten

`PornhubResolver` behandelt Pornhub gezielt. `GenericTubeResolver` erkennt zusätzlich die im Projekt hinterlegten 113 Domains und versucht dort öffentlich eingebettete MP4-/M4V-/MOV- oder HLS-Quellen zu verwenden. Da externe Seiten ihr Markup und ihre Player jederzeit ändern können, ist die Unterstützung best effort und wird durch die Quellen-Diagnose nachvollziehbar gemacht.

Die aktuelle Domainliste liegt in `Sources/GenericTubeResolver.swift`.

## Build

Der GitHub-Actions-Workflow läuft auf `macos-15` mit Xcode 16.4:

1. XcodeGen installieren
2. Real-ESRGAN-x2plus-CoreML-Modell laden
3. Xcode-Projekt aus `project.yml` erzeugen
4. Resolver-/Zugriffsschutztests im iPhone-Simulator ausführen
5. unsignierte iPhone-App bauen
6. `VideoSave-unsigned.ipa` als Artifact bereitstellen

Pushes auf `main`, Pull Requests und manuelle Workflow-Starts führen den Build aus. Test-Artefakte werden nur bei Fehlern hochgeladen und nach 7 Tagen gelöscht. Erfolgreiche Main-Builds behalten nur die Artefakte des aktuellen Laufs; ältere `VideoSave-*`-Artefakte werden automatisch entfernt. Die aktuelle IPA hat zusätzlich eine maximale Aufbewahrungszeit von 30 Tagen.

## Installation

Die erzeugte IPA ist absichtlich unsigniert. `VideoSave-unsigned.ipa` herunterladen und mit Sideloadly über den eigenen Apple-Account signieren/installieren. **Remove Extensions** in Sideloadly deaktiviert lassen, damit `VideoSaveShare.appex` erhalten bleibt.

Die App benötigt iOS 18 oder neuer.

## Share Sheet

Nach der Installation kann VideoSave im iOS-Teilen-Menü aktiviert werden. Die Share-Extension übernimmt Weblinks bzw. Text und reicht den gefundenen HTTP-/HTTPS-Link an die Haupt-App weiter.

## Projektstruktur

- `Sources/` – Haupt-App, Resolver, Download-/HLS-Logik und Upscaler
- `ShareExtension/` – iOS-Share-Extension
- `Shared/` – gemeinsam verwendete Link-Logik
- `Tests/` – Resolver-, HLS-, Export- und Schutztests
- `project.yml` – XcodeGen-Projektdefinition
- `.github/workflows/build-ipa.yml` – CI/IPA-Build
