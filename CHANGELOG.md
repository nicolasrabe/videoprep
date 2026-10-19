# Changelog

Versions below 1.0.0 are early releases: things can change between them.

## 0.0.3
- The project is now called **videoprep** (it was "Video Downloader"): new file names (`videoprep.bat`, `videoprep.ps1`), window title and documentation.
- Settings and the "already downloaded" history from older versions are copied over automatically.
- No other changes.

## 0.0.2 (released as "Video Downloader")
- New tabbed window: Download, Queue, Options, Settings, Log.
- Queue tab: per-link clips with Premiere timecode `HH:MM:SS:FF` (frame-accurate, last-N-frames with a minus sign, drop-frame with semicolons).
- Instant link recognition on paste (full, `youtu.be`, Shorts, bare ID) and a preview panel.
- Audio-only modes, resolution cap, H.264 fallback conversion, subtitles, thumbnails, speed limit, skip already-downloaded videos.
- Retry failed, reorder and remove links, drag and drop.
- Log tools: Copy log, Save log, Test setup.
- First-run tool download (yt-dlp, FFmpeg, Deno).

## 0.0.1
- First prototype: one window to paste links, choose a name style and a folder.
