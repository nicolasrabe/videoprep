# videoprep

*[Versión en español](README.md)*

**videoprep** is a free Windows app that prepares videos for editing: it downloads them with [yt-dlp](https://github.com/yt-dlp/yt-dlp), cuts frame-accurate clips and outputs **MP4 with H.264 + AAC**, ready for **Adobe Premiere Pro**.

> Status: early version (0.0.x). It may have bugs; if you find one, open an [issue](https://github.com/nicolasrabe/videoprep/issues/new/choose).

## Features

- Paste a link (full, short `youtu.be`, Shorts or just the video ID): it is recognized instantly, no Enter needed, and a preview shows the thumbnail, title, channel, length and the quality that will be downloaded.
- It also accepts links from **Twitch (clips and videos), Kick, X/Twitter, Facebook, Instagram, TikTok, Vimeo** and other sites supported by yt-dlp. Private content or content that asks you to log in needs you to be logged in to that site in your browser.
- Choose **video or audio only** and the format: **MP4**, **MOV** (H.264 or **ProRes 422 HQ**), **WebM**, **MKV**, and audio as **M4A, MP3, WAV, FLAC or Opus**.
- **Several clips from the same video** with **Premiere timecode `HH:MM:SS:FF`**, frame-accurate (for example, the last 15 frames of a video). The video is downloaded only once.
- File names: **original title**, **custom title** or **series** (name + number).
- **Queue** with reorder, edit, remove and retry failed. Pasting another link sends the previous one to the queue automatically.
- **Options** window (subtitles, thumbnails, speed limit, clip quality, skip already-downloaded videos).
- **Spanish and English** interface and themes: **light, dark, beige, gray, slate blue or a custom color**.

## Install

1. Download `videoprep-vX.Y.Z.zip` from [Releases](https://github.com/nicolasrabe/videoprep/releases) and unzip it somewhere you can write to (Desktop or Documents, not "Program Files").
2. Double-click **videoprep.bat**. If Windows shows "Windows protected your PC", choose *More info* > *Run anyway*.
3. First time only: press **Download**. The app fetches yt-dlp, FFmpeg and Deno (about 200 MB, once) into the `tools` folder.

Requirements: Windows 10 or 11 and an internet connection.

## Verify your download (recommended)

Every release lists its **SHA-256** hash. To check it, in PowerShell:

```powershell
Get-FileHash .\videoprep-vX.Y.Z.zip -Algorithm SHA256
```

It must match the value on the release page. If it does not, do not use the file.

## Privacy

- The login option reads cookies from **your own browser, on your PC**, so YouTube does not block the download as a bot. Nothing is uploaded anywhere.
- No telemetry. The app only talks to YouTube and to GitHub (to fetch and update the tools).

## Troubleshooting

Open the **Log** tab, press **Test setup**, then **Copy log**. If you open an [issue](https://github.com/nicolasrabe/videoprep/issues/new/choose), paste that text (check it for personal data first).

## Support the project

videoprep is free and will stay free. If it helps you and you want to support its upkeep, you can donate:

- *(add your links: GitHub Sponsors, Ko-fi, etc.)*

## Legal notice

This tool is for downloading content you **own, have a license for, or have permission to use**. Following each site's terms and copyright law is each person's responsibility. This project is **not affiliated with or endorsed by YouTube, Google, Twitch, Kick, X, Meta (Facebook and Instagram), TikTok or any other platform mentioned**.

## License and credits

[MIT](LICENSE). It uses, without bundling them in this repository: [yt-dlp](https://github.com/yt-dlp/yt-dlp), [FFmpeg](https://ffmpeg.org/) (builds from [yt-dlp/FFmpeg-Builds](https://github.com/yt-dlp/FFmpeg-Builds)) and [Deno](https://deno.com/), each under its own license.
