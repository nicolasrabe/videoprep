# Checklist para cada release

1. Probar en una PC limpia (o máquina virtual de Windows): primera ejecución, bajada de herramientas, una descarga común, un clip con timecode.
2. Subir el numero de version en `AppVersion` (VideoDownloader.ps1) y en CHANGELOG.md.
3. Armar `VideoDownloader-vX.Y.Z.zip` con: `VideoDownloader.ps1`, `Video Downloader.bat` y un `README.txt` corto.
4. Calcular la huella: `Get-FileHash .\VideoDownloader-vX.Y.Z.zip -Algorithm SHA256`
5. GitHub > Releases > Draft a new release: tag `vX.Y.Z`, titulo, notas desde CHANGELOG, adjuntar el zip y pegar el SHA-256 en las notas.
6. Descargar el zip desde la pagina del release y verificar que la huella coincide.
7. Responder issues y actualizar el CHANGELOG.
