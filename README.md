# VideoSave – GitHub Actions iPhone Build

VideoSave ist eine native SwiftUI-App für iPhone. Sie verarbeitet direkte Video-URLs, unverschlüsselte HLS-Master-Playlists und unterstützte öffentliche XxX-Video-Seiten.

## Enthalten

- Direkte HTTP/HTTPS-Video-Downloads
- HLS-Master-Playlist-Erkennung
- Auflösung öffentlicher Pornhub-Video-Seiten in vom Server bereitgestellte MP4-/HLS-Quellen
- Qualitätsauswahl auch bei von der Seite gelieferten Videoquellen
- Qualitätsauswahl: Original, 1080p, 720p, 480p, 360p, 240p, sofern im Master vorhanden
- MP4 oder MOV
- Download-Fortschritt
- Real-ESRGAN-CoreML-Upscaling für Quellen bis 1080p: 2× AI, danach bei Bedarf Skalierung auf 4K-Abmessungen (16:9: 3840×2160; Hochformat: 2160×3840; andere Formate proportional)
- Speichern in Dateien
- Speichern in Fotos
- Kein Umgehen von DRM, CAPTCHA, Paywall oder technisch deaktivierten Downloads; bei einer normalen öffentlich erreichbaren Seite werden nur vom Server bereitgestellte Quellen verwendet

Das Real-ESRGAN-Projekt dokumentiert x2plus als 2×-Modell und beschreibt die 522×522-CoreML-Modelle mit 512-Pixel-Tiling plus 10 Pixel Pre-Padding.

## GitHub Actions

Der Workflow läuft auf `macos-15` mit Xcode 16.4, installiert XcodeGen, lädt das `RealESRGAN_x2plus_522_fp16.mlpackage`, erzeugt das Xcode-Projekt und baut eine **unsignierte** IPA.

1. Neues GitHub-Repository erstellen.
2. Alle Dateien dieses Ordners in das Repository hochladen.
3. GitHub → **Actions** → **Build VideoSave IPA**.
4. **Run workflow**.
5. Nach dem grünen Lauf unter **Artifacts** → `VideoSave-IPA` herunterladen.
6. ZIP entpacken und die `VideoSave-unsigned.ipa` mit einem iOS-Sideloading-Tool signieren/installieren.

## Wichtig

Die erzeugte IPA ist absichtlich unsigniert. GitHub baut die App; die Signierung für dein iPhone erfolgt anschließend mit deinem eigenen Apple-Account über dein Sideloading-Tool.

## Garage-Design und direkte Auflösung

- Dunkles Motorsport-Cockpit mit roten Akzenten, segmentierter Instrumentenanzeige und separaten Karten für Quelle, Ausgabe und Export.
- `view_video.php?viewkey=...` wird sowohl beim Prüfen als auch beim Speichern direkt über `PornhubResolver` verarbeitet. Kein WebView und kein Browser-Fallback.
- Beim Ändern des Links werden Qualitätsdaten zurückgesetzt. Während Prüfung und Verarbeitung sind widersprüchliche Eingaben gesperrt.
- Nur angebotene Auflösungen erscheinen in der Auswahl. MP4/MOV, AI-Upscaling sowie Dateien-/Fotos-Export bleiben verfügbar.
- Erkannte CAPTCHA-, Login-, Regions- und Zugriffssperren führen zum Abbruch. Verschlüsselte HLS-Playlists werden auch in Master-Unterplaylists abgelehnt. Es werden keine Schutzmechanismen umgangen.

## Verifikation

Pushes auf `main` und Pull Requests starten jetzt automatisch den Workflow. Vor dem IPA-Build laufen XCTest-Tests im iPhone-Simulator für URL-Erkennung, direkte MP4-Auflösung, Qualitätsreihenfolge, Unicode im HTML und Zugriffs-/HLS-Schutzprüfungen. Die Fixtures sind synthetisch und benötigen keine Live-Verbindung zu Pornhub. `VideoSave-TestResults` enthält die Testergebnisse.

Ein grüner Build bestätigt keine dauerhafte Kompatibilität mit Änderungen einer externen Website. Live-Auflösung, Geräte-Performance, AI-Bildqualität und Audio-Synchronität und die Darstellung bei allen Schriftgrößen benötigen zusätzlich einen Test auf dem iPhone.

## 4K und Sideloadly

Der Upscaler übernimmt die originale Audiospur in die finale Komposition und korrigiert die Videoorientierung. RGB-Modellausgabe und BGRA-Videopuffer werden explizit konvertiert; Modell-Strides werden berücksichtigt. Quellen unter 1080p erhalten zusätzlich zur 2×-AI-Inferenz eine proportionale Skalierung auf den 4K-Rahmen. Das ist keine native 4×-AI-Inferenz.

Nach einem erfolgreichen Actions-Lauf `VideoSave-IPA` herunterladen und entpacken. Die enthaltene `VideoSave-unsigned.ipa` in Sideloadly öffnen, das iPhone auswählen und mit dem eigenen Apple-Account signieren/installieren. Die App benötigt iOS 18 oder neuer. Die Signierung erfolgt nicht im GitHub-Build.
