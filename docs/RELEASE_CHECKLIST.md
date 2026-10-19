# Checklist para cada release

1. Probar en una PC limpia (o máquina virtual de Windows): primera ejecución, bajada de herramientas, una descarga común, un clip con timecode.
2. Subir el numero de version en `$AppVersion` (videoprep.ps1) y en CHANGELOG.md.
3. Armar `videoprep-vX.Y.Z.zip` con: `videoprep.ps1`, `videoprep.bat` y un `README.txt` corto.
4. Calcular la huella: `(Get-FileHash .\videoprep-vX.Y.Z.zip -Algorithm SHA256).Hash | Set-Clipboard`
5. GitHub > Releases > Draft a new release: tag `vX.Y.Z`, titulo `videoprep X.Y.Z`, notas desde CHANGELOG, adjuntar el zip y pegar el SHA-256 en las notas. Tildar "pre-release" mientras la version sea 0.x.
6. Descargar el zip desde la pagina del release y verificar que la huella coincide.
7. Responder issues y actualizar el CHANGELOG.
