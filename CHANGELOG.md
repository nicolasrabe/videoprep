# Changelog

Versions below 1.0.0 are early releases: things can change between them.

## 0.1.1
- Links from other sites: Twitch (clips and videos), Kick, X/Twitter, Facebook, Instagram, TikTok, Vimeo and any other site supported by yt-dlp.
- Preview for those sites (title, author, length, thumbnail and quality) read through yt-dlp.
- Other sites are downloaded as best available and converted to the chosen format when needed.
- File names fall back to the video ID when a site gives no title.
- Hints for sites that need a login; the legal notice now covers the other platforms.
- Safer link recognition: only real YouTube links are treated as YouTube (Facebook video numbers are no longer mistaken for YouTube IDs).

## 0.1.0
- New Download tab: single-line link box (clears after pasting), format block, clips, file names, Options window and Send to queue.
- Several clips per video (frame-accurate Premiere timecode); the video is downloaded once and cut as many times as needed.
- New formats: MP4, MOV (H.264 or ProRes 422 HQ), WebM, MKV; audio-only as M4A, MP3, WAV, FLAC or Opus.
- Pasting a new link sends the previous one to the queue automatically.
- Queue tab: edit, remove, reorder, retry failed, load a .txt file.
- Full Spanish and English interface; language selector in Settings.
- Themes: light, dark, beige, gray, slate blue and a custom color.
- The Options tab became a window; Download, Stop, Open folder and Browse were rearranged and colored.
- The script is now saved as UTF-8 with BOM so accents display correctly.

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
