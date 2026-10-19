# videoprep Video Downloader

*[English version](README.en.md)*

Programa gratuito para Windows con ventanas simples para descargar videos con [yt-dlp](https://github.com/yt-dlp/yt-dlp), pensado para editores: los archivos salen en **MP4 con H.264 + AAC**, listos para **Adobe Premiere Pro**.

## Qué hace

- Pegás links (completos, cortos `youtu.be`, Shorts o solo el código del video) y cada uno se reconoce solo, sin apretar Enter.
- Vista previa con miniatura, título, canal, duración y la calidad que se va a descargar.
- Nombres de archivo: **prefijo + 1, 2, 3...** (por ejemplo `Clip1.mp4`) o el **título original**.
- Pestaña **Queue**: cortá un clip con **timecode de Premiere `HH:MM:SS:FF`**, exacto al frame (por ejemplo, los últimos 15 frames de un video).
- Solo audio (M4A, MP3, WAV), tope de resolución, subtítulos, miniaturas, límite de velocidad.
- Reintentar los que fallaron, reordenar y quitar links.

## Instalación

1. Bajá `VideoDownloader-vX.Y.Z.zip` desde la sección [Releases](../../releases) y descomprimilo en una carpeta donde puedas escribir (Escritorio o Documentos, no "Archivos de programa").
2. Hacé doble clic en **Video Downloader.bat**. Si Windows muestra "Windows protegió su PC", elegí *Más información* > *Ejecutar de todas formas*.
3. La primera vez, apretá **Download**: el programa baja yt-dlp, FFmpeg y Deno (unos 200 MB, una sola vez) a la carpeta `tools`.

Requisitos: Windows 10 u 11 e internet. No hace falta instalar nada más.

## Verificá tu descarga (recomendado)

Cada release publica su huella **SHA-256**. Para comprobarla, en PowerShell:

```powershell
Get-FileHash .\VideoDownloader-vX.Y.Z.zip -Algorithm SHA256
```

El resultado debe ser igual al de la página del release. Si no coincide, no lo uses.

## Privacidad

- La opción de login usa las cookies de **tu propio navegador, en tu PC**, para que YouTube no bloquee la descarga como bot. No se sube nada a ningún lado.
- El programa no tiene telemetría. Solo se conecta a YouTube, a GitHub (para bajar las herramientas y actualizarlas) y a nada más.

## Problemas frecuentes

Abrí la pestaña **Log**, apretá **Test setup** y después **Copy log**. Si abrís un [issue](../../issues/new/choose), pegá ese texto (revisá antes que no tenga datos personales).

## Apoyar el proyecto

El programa es y va a seguir siendo gratis. Si te sirve y querés ayudar a mantenerlo, podés hacer una donación:

- *(completar con tus links: GitHub Sponsors, Ko-fi, Cafecito, etc.)*

## Aviso legal

Esta herramienta es para descargar contenido **propio, con licencia o con permiso de su autor**. Cumplir los términos de cada sitio y las leyes de derechos de autor es responsabilidad de cada persona. Este proyecto **no está afiliado ni respaldado por YouTube ni Google**.

## Licencia y créditos

[MIT](LICENSE). Usa, sin incluirlos en este repositorio: [yt-dlp](https://github.com/yt-dlp/yt-dlp), [FFmpeg](https://ffmpeg.org/) (builds de [yt-dlp/FFmpeg-Builds](https://github.com/yt-dlp/FFmpeg-Builds)) y [Deno](https://deno.com/), cada uno con su propia licencia.
