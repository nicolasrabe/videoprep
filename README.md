# videoprep

*[English version](README.en.md)*

**videoprep** es un programa gratuito para Windows que prepara videos para editar: los baja con [yt-dlp](https://github.com/yt-dlp/yt-dlp), recorta clips con timecode exacto y los deja en **MP4 con H.264 + AAC**, listos para **Adobe Premiere Pro**.

> Estado: versión temprana (0.0.x). Puede tener errores; si encontrás alguno, abrí un [issue](https://github.com/nicolasrabe/videoprep/issues/new/choose).

## Qué hace

- Pegás un enlace (completo, corto `youtu.be`, Shorts o solo el ID del video): se reconoce solo, sin apretar Enter, y aparece la vista previa con miniatura, título, canal, duración y la calidad que se va a descargar.
- También acepta enlaces de **Twitch (clips y videos), Kick, X/Twitter, Facebook, Instagram, TikTok, Vimeo** y otros sitios que yt-dlp soporte. Algunos contenidos (privados o que piden iniciar sesión) necesitan que tengas la sesión abierta en tu navegador.
- Elegís **video o solo audio** y el formato: **MP4**, **MOV** (H.264 o **ProRes 422 HQ**), **WebM**, **MKV**, y audio en **M4A, MP3, WAV, FLAC u Opus**.
- **Varios fragmentos del mismo video** con **código de tiempo de Premiere `HH:MM:SS:FF`**, exactos al fotograma (por ejemplo, los últimos 15 fotogramas de un video). El video se baja una sola vez.
- Nombres de archivo: **título original**, **título personalizado** o **serie** (nombre + número).
- **Cola** con reordenar, editar, quitar y reintentar los fallidos. Si pegás otro enlace, el anterior pasa solo a la cola.
- Ventana de **Opciones** (subtítulos, miniaturas, límite de velocidad, calidad de los fragmentos, omitir videos ya descargados).
- Interfaz en **español e inglés** y temas **claro, oscuro, beige, gris, azul grisáceo o un color a elección**.

## Instalación

1. Bajá `videoprep-vX.Y.Z.zip` desde [Releases](https://github.com/nicolasrabe/videoprep/releases) y descomprimilo en una carpeta donde puedas escribir (Escritorio o Documentos, no "Archivos de programa").
2. Hacé doble clic en **videoprep.bat**. Si Windows muestra "Windows protegió su PC", elegí *Más información* > *Ejecutar de todas formas*.
3. La primera vez, apretá **Download**: el programa baja yt-dlp, FFmpeg y Deno (unos 200 MB, una sola vez) a la carpeta `tools`.

Requisitos: Windows 10 u 11 e internet. No hace falta instalar nada más.

## Verificá tu descarga (recomendado)

Cada release publica su huella **SHA-256**. Para comprobarla, en PowerShell:

```powershell
Get-FileHash .\videoprep-vX.Y.Z.zip -Algorithm SHA256
```

El resultado debe ser igual al de la página del release. Si no coincide, no lo uses.

## Privacidad

- La opción de login usa las cookies de **tu propio navegador, en tu PC**, para que YouTube no bloquee la descarga como bot. No se sube nada a ningún lado.
- El programa no tiene telemetría. Solo se conecta a YouTube, a GitHub (para bajar las herramientas y actualizarlas) y a nada más.

## Problemas frecuentes

Abrí la pestaña **Log**, apretá **Test setup** y después **Copy log**. Si abrís un [issue](https://github.com/nicolasrabe/videoprep/issues/new/choose), pegá ese texto (revisá antes que no tenga datos personales).

## Apoyar el proyecto

videoprep es y va a seguir siendo gratis. Si te sirve y querés ayudar a mantenerlo, podés hacer una donación:

- *(completar con tus links: GitHub Sponsors, Ko-fi, Cafecito, etc.)*

## Aviso legal

Esta herramienta es para descargar contenido **propio, con licencia o con permiso de su autor**. Cumplir los términos de cada sitio y las leyes de derechos de autor es responsabilidad de cada persona. Este proyecto **no está afiliado ni respaldado por YouTube, Google, Twitch, Kick, X, Meta (Facebook e Instagram), TikTok ni ninguna otra plataforma mencionada**.

## Licencia y créditos

[MIT](LICENSE). Usa, sin incluirlos en este repositorio: [yt-dlp](https://github.com/yt-dlp/yt-dlp), [FFmpeg](https://ffmpeg.org/) (builds de [yt-dlp/FFmpeg-Builds](https://github.com/yt-dlp/FFmpeg-Builds)) y [Deno](https://deno.com/), cada uno con su propia licencia.
