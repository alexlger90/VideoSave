# VideoSave – GitHub Actions iPhone Build

VideoSave ist eine native SwiftUI-App für iPhone. Sie verarbeitet direkte Video-URLs, unverschlüsselte HLS-Master-Playlists und unterstützte öffentliche Pornhub-Video-Seiten (`view_video.php?viewkey=…`).

## Enthalten

- Direkte HTTP/HTTPS-Video-Downloads
- HLS-Master-Playlist-Erkennung
- Auflösung öffentlicher Pornhub-Video-Seiten in vom Server bereitgestellte MP4-/HLS-Quellen
- Qualitätsauswahl auch bei von der Seite gelieferten Videoquellen
- Qualitätsauswahl: Original, 1080p, 720p, 480p, 360p, 240p, sofern im Master vorhanden
- MP4 oder MOV
- Download-Fortschritt
- 2× Real-ESRGAN-CoreML-Upscaling für Quellen bis 1080p; 1080p → 3840×2160
- Speichern in Dateien
- Speichern in Fotos
- Kein Umgehen von DRM, CAPTCHA, Paywall oder technisch deaktivierten Downloads; bei einer normalen öffentlich erreichbaren Seite werden nur vom Server bereitgestellte Quellen verwendet

Das Real-ESRGAN-Projekt dokumentiert x2plus als 2×-Modell und beschreibt die 522×522-CoreML-Modelle mit 512-Pixel-Tiling plus 10 Pixel Pre-Padding.

## GitHub Actions

Der Workflow läuft auf `macos-14`, installiert XcodeGen, lädt das `RealESRGAN_x2plus_522_fp16.mlpackage`, erzeugt das Xcode-Projekt und baut eine **unsignierte** IPA.

1. Neues GitHub-Repository erstellen.
2. Alle Dateien dieses Ordners in das Repository hochladen.
3. GitHub → **Actions** → **Build VideoSave IPA**.
4. **Run workflow**.
5. Nach dem grünen Lauf unter **Artifacts** → `VideoSave-IPA` herunterladen.
6. ZIP entpacken und die `VideoSave-unsigned.ipa` mit einem iOS-Sideloading-Tool signieren/installieren.

## Wichtig

Die erzeugte IPA ist absichtlich unsigniert. GitHub baut die App; die Signierung für dein iPhone erfolgt anschließend mit deinem eigenen Apple-Account über dein Sideloading-Tool.
