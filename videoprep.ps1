# =====================================================================
#  videoprep.ps1 - prepare videos for editing (v0.0.3, tabbed)
#  Paste links, choose a name style and folder, press Download.
#  Output is Premiere Pro friendly (H.264 video + AAC audio, MP4).
#  Queue tab: frame-accurate clips with Premiere timecode HH:MM:SS:FF.
#  Keep this file ASCII-only (Windows PowerShell 5.1 misreads UTF-8).
# =====================================================================
param(
    [switch]$SetupTools,
    [string]$ToolsDir = '',
    [string]$Need = 'yt-dlp,ffmpeg,deno'
)

# ---------------------------------------------------------------------
#  One-time tool download (this branch runs in a child process)
# ---------------------------------------------------------------------
if ($SetupTools) {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
        $tmp = Join-Path $ToolsDir '_tmp'
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null

        function Expand-Needed([string]$zipPath, [string[]]$names) {
            $z = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
            try {
                foreach ($e in $z.Entries) {
                    if ($names -contains $e.Name) {
                        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $ToolsDir $e.Name), $true)
                    }
                }
            } finally { $z.Dispose() }
        }

        $list = @($Need -split ',')

        if ($list -contains 'yt-dlp') {
            Write-Output 'Downloading yt-dlp...'
            Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' -OutFile (Join-Path $ToolsDir 'yt-dlp.exe')
        }
        if ($list -contains 'ffmpeg') {
            Write-Output 'Downloading FFmpeg (about 150 MB - this can take a few minutes)...'
            $zip = Join-Path $tmp 'ffmpeg.zip'
            Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/yt-dlp/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip' -OutFile $zip
            Write-Output 'Unpacking FFmpeg...'
            Expand-Needed $zip @('ffmpeg.exe', 'ffprobe.exe')
        }
        if ($list -contains 'deno') {
            Write-Output 'Downloading Deno...'
            $zip = Join-Path $tmp 'deno.zip'
            Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip' -OutFile $zip
            Write-Output 'Unpacking Deno...'
            Expand-Needed $zip @('deno.exe')
        }

        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Write-Output 'Setup finished.'
        exit 0
    }
    catch {
        Write-Output ('SETUP ERROR: ' + $_.Exception.Message)
        exit 1
    }
}

# ---------------------------------------------------------------------
#  GUI starts here
# ---------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class YtDpi {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
    [void][YtDpi]::SetProcessDPIAware()
} catch { }

[System.Windows.Forms.Application]::EnableVisualStyles()

# Background process runner (output is queued, the UI timer drains it)
Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Threading;

public class YtRunner
{
    public ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
    public volatile bool Done = false;
    public int ExitCode = -1;
    private Process proc;

    public void Start(string exe, string args, string workDir)
    {
        ProcessStartInfo psi = new ProcessStartInfo(exe, args);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = Encoding.UTF8;
        psi.StandardErrorEncoding = Encoding.UTF8;
        psi.EnvironmentVariables["PYTHONUTF8"] = "1";
        psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8";
        if (!String.IsNullOrEmpty(workDir)) { psi.WorkingDirectory = workDir; }

        proc = new Process();
        proc.StartInfo = psi;
        proc.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) { Lines.Enqueue(e.Data); } };
        proc.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) { Lines.Enqueue(e.Data); } };
        proc.Start();
        proc.BeginOutputReadLine();
        proc.BeginErrorReadLine();

        Thread t = new Thread(delegate()
        {
            try { proc.WaitForExit(); ExitCode = proc.ExitCode; }
            catch { ExitCode = -1; }
            Done = true;
        });
        t.IsBackground = true;
        t.Start();
    }

    public void Kill()
    {
        try
        {
            if (proc != null && !proc.HasExited)
            {
                ProcessStartInfo k = new ProcessStartInfo("taskkill", "/PID " + proc.Id + " /T /F");
                k.CreateNoWindow = true;
                k.UseShellExecute = false;
                Process.Start(k);
            }
        }
        catch { }
    }
}
'@

# Paste-aware text box + thumbnail/info fetcher
Add-Type -ReferencedAssemblies 'System.Windows.Forms' -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Net;
using System.Text;
using System.Threading;

public class PasteBox : System.Windows.Forms.TextBox
{
    public event EventHandler Pasting;
    protected override void WndProc(ref System.Windows.Forms.Message m)
    {
        if (m.Msg == 0x0302 && Pasting != null)
        {
            Pasting(this, EventArgs.Empty);
            return;
        }
        base.WndProc(ref m);
    }
}

public class PreviewItem
{
    public string Id;
    public string Json;
    public byte[] Thumb;
}

public class PreviewFetcher
{
    public ConcurrentQueue<PreviewItem> Results = new ConcurrentQueue<PreviewItem>();

    public void Fetch(string id)
    {
        ThreadPool.QueueUserWorkItem(delegate(object state)
        {
            PreviewItem it = new PreviewItem();
            it.Id = id;
            try { ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072 | ServicePointManager.SecurityProtocol; } catch { }
            try
            {
                using (WebClient wc = new WebClient())
                {
                    wc.Encoding = Encoding.UTF8;
                    wc.Headers[HttpRequestHeader.UserAgent] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)";
                    try { it.Json = wc.DownloadString("https://www.youtube.com/oembed?format=json&url=" + Uri.EscapeDataString("https://www.youtube.com/watch?v=" + id)); } catch { }
                    try { it.Thumb = wc.DownloadData("https://i.ytimg.com/vi/" + id + "/mqdefault.jpg"); } catch { }
                }
            }
            catch { }
            Results.Enqueue(it);
        });
    }
}
'@


# ---------------------------------------------------------------------
#  Constants and shared state
# ---------------------------------------------------------------------
$AppVersion = '0.0.3'
$ScriptPath = $PSCommandPath
$AppDir     = Split-Path -Parent $ScriptPath
$ToolsHome  = Join-Path $AppDir 'tools'

# H.264 (avc1) video, AAC preferred, NO fallback to format 18 (360p) or VP9/AV1.
$FmtSafe = '(bv*[vcodec^=avc1]+ba[acodec^=mp4a])/(bv*[vcodec^=avc1]+ba)/(b[vcodec^=avc1])'

# Cookie problems and bot checks -> try the next cookie source
$RetryRegex = 'Could not copy .*cookie|Failed to decrypt|could not find .*cookie|cookie database|DPAPI|Sign in to confirm|not a bot'

$BrowserDefs = @(
    @{ Key = 'firefox';  Name = 'Firefox';  Path = "$env:APPDATA\Mozilla\Firefox\Profiles" },
    @{ Key = 'chrome';   Name = 'Chrome';   Path = "$env:LOCALAPPDATA\Google\Chrome\User Data" },
    @{ Key = 'edge';     Name = 'Edge';     Path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data" },
    @{ Key = 'brave';    Name = 'Brave';    Path = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data" },
    @{ Key = 'opera';    Name = 'Opera';    Path = "$env:APPDATA\Opera Software\Opera Stable" },
    @{ Key = 'vivaldi';  Name = 'Vivaldi';  Path = "$env:LOCALAPPDATA\Vivaldi\User Data" },
    @{ Key = 'chromium'; Name = 'Chromium'; Path = "$env:LOCALAPPDATA\Chromium\User Data" },
    @{ Key = 'whale';    Name = 'Whale';    Path = "$env:LOCALAPPDATA\Naver\Naver Whale\User Data" }
)

$SettingsDir  = Join-Path $env:APPDATA 'videoprep'
$OldSettingsDir = Join-Path $env:APPDATA 'VideoDownloader'
if ((-not (Test-Path -LiteralPath $SettingsDir)) -and (Test-Path -LiteralPath $OldSettingsDir)) {
    try { Copy-Item -LiteralPath $OldSettingsDir -Destination $SettingsDir -Recurse -Force } catch { }
}
$SettingsFile = Join-Path $SettingsDir 'settings.json'
$ArchiveFile  = Join-Path $SettingsDir 'downloaded.txt'

$T = @{ YtDlp = $null; Ffmpeg = $null; Ffprobe = $null; Deno = $null }

$S = @{
    Mode = 'idle'; Step = 'dl'; Runner = $null; Jobs = @(); LastJobs = @(); Idx = -1
    BaseBrowsers = @(); Browsers = @(); AttemptIdx = 0
    Output = $null; AttemptOut = $null; JobStart = (Get-Date)
    Ok = 0; Warn = 0; Fail = 0; Failed = @()
    Cancelled = $false; Exe = ''; Folder = ''; StartAfterSetup = $false
    CutSrc = ''; CutTmp = ''; CutDir = ''; CutBase = ''; CutIsRange = $false; CutNote = ''
    LastUpdate = ''
}

$Pref = @{ Browser = $null }

$P = @{
    Id = $null; Cache = @{}; Fetcher = (New-Object PreviewFetcher)
    Runner = $null; RunnerId = $null; RunnerStart = (Get-Date)
    Browsers = @(); BIdx = 0; DetOut = $null; DetLine = $null
}

# Per-link time ranges and row status, keyed by "url|occurrence"
$Ranges    = @{}
$RowStatus = @{}
$RowFile   = @{}

$TcTip = @"
TIME RANGE  (Premiere-style timecode)

Format:   HH:MM:SS:FF   = hours : minutes : seconds : frames
Example:  00:01:23:15   = 1 minute, 23 seconds and 15 frames

The last number counts FRAMES inside that second (0 up to fps-1),
so you can cut to the exact frame. At 30 fps the frames go 00-29,
at 60 fps they go 00-59.

Start = first frame you want.
End   = last frame you want (this frame is included).
Leave End empty to go until the end of the video.
Leave both empty to download the whole video.

Typing shortcut (like Premiere): numbers fill from the right.
    1523  ->  00:00:15:23        100  ->  00:00:01:00

From the end: start with a minus sign.
    Start  -00:00:00:15   (End empty) = the LAST 15 FRAMES
    Start  -00:00:01:00   (End empty) = the last second

Use semicolons (00;01;23;15) for drop-frame timecode (29.97 / 59.94 fps).

Clips are cut AFTER the download using the video's real frame rate,
so they are frame-accurate. The clip is re-encoded (H.264 + AAC).
"@

# ---------------------------------------------------------------------
#  Helpers
# ---------------------------------------------------------------------
function ConvertTo-ArgString([string[]]$Items) {
    $parts = foreach ($a in $Items) {
        if ($a -eq '') { '""' }
        elseif ($a -notmatch '[\s"]') { $a }
        else {
            $s = $a -replace '(\\*)"', '$1$1\"'
            $s = $s -replace '(\\+)$', '$1$1'
            '"' + $s + '"'
        }
    }
    return ($parts -join ' ')
}

function Find-Exe([string]$name) {
    $c = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    return $null
}

function Resolve-Tool([string]$name) {
    foreach ($p in @((Join-Path $ToolsHome $name), (Join-Path $AppDir $name))) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return (Find-Exe $name)
}

function Update-Tools {
    $T.YtDlp   = Resolve-Tool 'yt-dlp.exe'
    $T.Ffmpeg  = Resolve-Tool 'ffmpeg.exe'
    $T.Ffprobe = Resolve-Tool 'ffprobe.exe'
    $T.Deno    = Resolve-Tool 'deno.exe'
    foreach ($p in @($T.Ffmpeg, $T.Deno)) {
        if ($p) {
            $d = Split-Path -Parent $p
            if (($env:PATH -split ';') -notcontains $d) { $env:PATH = $d + ';' + $env:PATH }
        }
    }
}

function Get-MissingTools {
    $m = @()
    if (-not $T.YtDlp) { $m += 'yt-dlp' }
    if (-not ($T.Ffmpeg -and $T.Ffprobe)) { $m += 'ffmpeg' }
    if (-not $T.Deno) { $m += 'deno' }
    return $m
}

function Show-Msg([string]$text, [string]$title = 'videoprep', [string]$buttons = 'OK', [string]$icon = 'Information') {
    return [System.Windows.Forms.MessageBox]::Show($form, $text, $title, $buttons, $icon)
}

function Write-Log([string]$msg) {
    $txtLog.AppendText($msg + [Environment]::NewLine)
    if ($txtLog.TextLength -gt 400000) {
        $txtLog.Text = $txtLog.Text.Substring(200000)
        $txtLog.SelectionStart = $txtLog.TextLength
        $txtLog.ScrollToCaret()
    }
}

function Read-GuiSettings {
    if (Test-Path -LiteralPath $SettingsFile) {
        try { return (Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json) } catch { }
    }
    return $null
}

function Save-GuiSettings {
    try {
        New-Item -ItemType Directory -Force -Path $SettingsDir | Out-Null
        $o = [ordered]@{
            folder     = $txtFolder.Text
            usePrefix  = $radPrefix.Checked
            prefix     = $txtPrefix.Text
            cookie     = $cmbCookie.SelectedIndex
            cookieFile = $txtCookieFile.Text
            mode       = $cmbMode.SelectedIndex
            cap        = $cmbCap.SelectedIndex
            fallback   = $chkFallback.Checked
            subs       = $chkSubs.Checked
            subLangs   = $txtSubLangs.Text
            thumbs     = $chkThumbs.Checked
            archive    = $chkArchive.Checked
            limit      = [int]$numLimit.Value
            sleep      = [int]$numSleep.Value
            keepFull   = $chkKeepFull.Checked
            crf        = [int]$numCrf.Value
            autoUpdate = $chkAutoUpdate.Checked
            lastUpdate = $S.LastUpdate
            sound      = $chkSound.Checked
            openDone   = $chkOpenDone.Checked
        }
        ($o | ConvertTo-Json) | Set-Content -LiteralPath $SettingsFile -Encoding UTF8
    } catch { }
}

# ---- YouTube link / ID recognition ----
function ConvertTo-YoutubeUrl([string]$text) {
    $t2 = $text.Trim()
    if ($t2 -eq '') { return $null }
    $id = $null
    if ($t2 -match '^[A-Za-z0-9_-]{11}$') { $id = $t2 }
    elseif ($t2 -match '^(?:https?://)?(?:www\.|m\.|music\.)?youtu\.be/([A-Za-z0-9_-]{11})(?![A-Za-z0-9_-])') { $id = $Matches[1] }
    elseif ($t2 -match '^(?:https?://)?(?:www\.|m\.|music\.)?youtube(?:-nocookie)?\.com/(?:shorts|live|embed|v)/([A-Za-z0-9_-]{11})(?![A-Za-z0-9_-])') { $id = $Matches[1] }
    elseif ($t2 -match '^(?:https?://)?(?:www\.|m\.|music\.)?youtube\.com/watch\?(?:[^#\s]*&)?v=([A-Za-z0-9_-]{11})(?![A-Za-z0-9_-])') { $id = $Matches[1] }
    if ($id) { return ('https://www.youtube.com/watch?v=' + $id) }
    return $null
}

function Get-VideoId([string]$url) {
    if ($url -match '[?&]v=([A-Za-z0-9_-]{11})') { return $Matches[1] }
    return $null
}

# ---- Queue entries (one per non-empty line of the links box) ----
function Get-QueueEntries {
    $out = @()
    $seen = @{}
    $lines = $txtLinks.Lines
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $t2 = $lines[$i].Trim()
        if ($t2 -eq '' -or $t2.StartsWith('#') -or $t2.StartsWith(';')) { continue }
        $u = ConvertTo-YoutubeUrl $t2
        if (-not $u) { $u = $t2 }
        if ($seen.ContainsKey($u)) { $seen[$u] = $seen[$u] + 1 } else { $seen[$u] = 1 }
        $out += [pscustomobject]@{ Line = $i; Url = $u; Key = ($u + '|' + $seen[$u]) }
    }
    return $out
}

function Update-LinkCount {
    $n = @(Get-QueueEntries).Count
    $lblCount.Text = "$n link(s) detected"
}

function Update-Example {
    if ($radPrefix.Checked) {
        $lblExample.Text = ('Example: {0}1.mp4, {0}2.mp4, {0}3.mp4' -f $txtPrefix.Text)
    } else {
        $lblExample.Text = 'Example: the video title exactly as it appears on YouTube'
    }
}

# ---- Cookie sources ----
function Get-BrowserList {
    $n = $BrowserDefs.Count
    $sel = $cmbCookie.SelectedIndex
    if ($sel -eq ($n + 2)) { return @('none') }
    if ($sel -eq ($n + 1)) {
        if ($txtCookieFile.Text -and (Test-Path -LiteralPath $txtCookieFile.Text)) { return @('file') }
        return @('none')
    }
    if ($sel -ge 1) { return @($BrowserDefs[$sel - 1].Key) }
    $found = @($BrowserDefs | Where-Object { Test-Path -LiteralPath $_.Path } | ForEach-Object { $_.Key })
    $list = @($found + 'none')
    if ($Pref.Browser -and ($list -contains $Pref.Browser)) {
        $list = @(@($Pref.Browser) + @($list | Where-Object { $_ -ne $Pref.Browser }))
    }
    return $list
}

function Get-CookieArgs([string]$browser) {
    if ($browser -eq 'none') { return @() }
    if ($browser -eq 'file') { return @('--cookies', $txtCookieFile.Text) }
    return @('--cookies-from-browser', $browser)
}

function Get-CookieLabel([string]$browser) {
    if ($browser -eq 'none') { return 'no login cookies' }
    if ($browser -eq 'file') { return 'cookies.txt file' }
    return ($browser + ' cookies')
}

# ---- Download options ----
function Get-FormatArgs {
    $res = '1080'
    switch ($cmbCap.SelectedIndex) {
        1 { $res = '720' }
        2 { $res = '480' }
    }
    $fmt = $FmtSafe
    if ($chkFallback.Checked) { $fmt = $FmtSafe + '/bv*+ba/b' }
    $a = @('-f', $fmt, '-S', ('res:{0},fps' -f $res))
    if ($chkFallback.Checked) { $a += @('--merge-output-format', 'mp4/mkv') }
    else { $a += @('--merge-output-format', 'mp4', '--remux-video', 'mp4') }
    return $a
}

function Get-AudioArgs {
    $fmt = 'm4a'
    if ($cmbMode.SelectedIndex -eq 2) { $fmt = 'mp3' }
    elseif ($cmbMode.SelectedIndex -eq 3) { $fmt = 'wav' }
    return @('-f', 'ba/b', '-x', '--audio-format', $fmt, '--audio-quality', '0')
}

function Set-Running([bool]$on) {
    foreach ($c in $LockCtls) { $c.Enabled = (-not $on) }
    $txtPrefix.Enabled = ((-not $on) -and $radPrefix.Checked)
    $grid.ReadOnly = $on
    $btnStop.Enabled = $on
    $hasFailed = (@($S.LastJobs | Where-Object { $_.Status -eq 'ERROR' }).Count -gt 0)
    $btnRetry.Enabled = ((-not $on) -and $hasFailed)
}

function Update-ToolStatus {
    Update-Tools
    $lines = @()
    foreach ($pair in @(@('yt-dlp', $T.YtDlp), @('FFmpeg', $T.Ffmpeg), @('FFprobe', $T.Ffprobe), @('Deno', $T.Deno))) {
        if ($pair[1]) { $lines += ('{0}: found  ({1})' -f $pair[0], $pair[1]) }
        else { $lines += ('{0}: MISSING' -f $pair[0]) }
    }
    $lblTools.Text = ($lines -join [Environment]::NewLine)
}

function Find-ResultFile([string]$folder, [datetime]$since) {
    $since = $since.AddSeconds(-3)
    $cand = Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LastWriteTime -ge $since -and
            $_.Extension -match '^\.(mp4|mkv|webm|mov|m4a|mp3|wav|aac|opus)$' -and
            $_.Name -notmatch '\.f\d+\.' -and
            $_.Name -notmatch '\.__tmp\.'
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    return $cand
}

function Get-UniquePath([string]$dir, [string]$base, [string]$ext) {
    $p = Join-Path $dir ($base + $ext)
    $n = 2
    while (Test-Path -LiteralPath $p) {
        $p = Join-Path $dir ('{0}_{1}{2}' -f $base, $n, $ext)
        $n = $n + 1
    }
    return $p
}

function Get-MediaInfo([string]$path) {
    $res = @{ Text = ''; Warn = $false }
    $ffprobe = $T.Ffprobe
    if (-not $ffprobe) { $res.Text = '(ffprobe not found - cannot verify the codec)'; return $res }

    try {
        $v = @(& $ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,r_frame_rate -of default=noprint_wrappers=1 $path 2>$null)
        $a = @(& $ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1 $path 2>$null)
    } catch {
        $res.Text = '(could not read file info)'
        return $res
    }

    $vi = @{}
    foreach ($l in $v) { if ($l -match '^(\w+)=(.*)$') { $vi[$Matches[1]] = $Matches[2] } }
    $ai = @{}
    foreach ($l in $a) { if ($l -match '^(\w+)=(.*)$') { $ai[$Matches[1]] = $Matches[2] } }

    $fps = ''
    if ($vi['r_frame_rate'] -match '^(\d+)/(\d+)$') {
        if ([int]$Matches[2] -ne 0) {
            $fps = ('{0:0.##} fps' -f ([double]$Matches[1] / [double]$Matches[2]))
        }
    }
    $size = ''
    if ($vi['width']) { $size = ('{0}x{1}' -f $vi['width'], $vi['height']) }
    $vc = $vi['codec_name']
    $ac = $ai['codec_name']
    $res.Text = ('video {0} {1} {2} | audio {3}' -f $vc, $size, $fps, $ac)
    if ($vc -ne 'h264' -or $ac -ne 'aac') { $res.Warn = $true }
    return $res
}

# ---------------------------------------------------------------------
#  Timecode (HH:MM:SS:FF) -> exact frame numbers
# ---------------------------------------------------------------------
function ConvertFrom-TimecodeText([string]$text) {
    $r = [pscustomobject]@{ Blank = $false; Valid = $false; Neg = $false; H = 0; M = 0; S = 0; F = 0; Drop = $false }
    $t = $text.Trim()
    if ($t -eq '') { $r.Blank = $true; return $r }
    if ($t.StartsWith('-')) { $r.Neg = $true; $t = $t.Substring(1).Trim() }
    if ($t.Contains(';')) { $r.Drop = $true; $t = $t.Replace(';', ':') }
    $parts = $null
    if ($t -match '^\d{1,8}$') {
        # Premiere-style digit entry: numbers fill from the right (1523 -> 00:00:15:23)
        $t = $t.PadLeft(8, '0')
        $parts = @($t.Substring(0, 2), $t.Substring(2, 2), $t.Substring(4, 2), $t.Substring(6, 2))
    }
    elseif ($t -match '^\d{1,2}(:\d{1,2}){1,3}$') {
        $parts = @($t -split ':')
        while ($parts.Count -lt 4) { $parts = @('0') + $parts }
    }
    if ($null -eq $parts) { return $r }
    $r.H = [int]$parts[0]
    $r.M = [int]$parts[1]
    $r.S = [int]$parts[2]
    $r.F = [int]$parts[3]
    if ($r.M -ge 60 -or $r.S -ge 60) { return $r }
    $r.Valid = $true
    return $r
}

function ConvertTo-FrameIndex($tc, [int]$base, [bool]$ntsc) {
    $total = ((($tc.H * 60 + $tc.M) * 60 + $tc.S) * $base) + $tc.F
    if ($tc.Drop -and $ntsc -and ($base -eq 30 -or $base -eq 60)) {
        $df = 2
        if ($base -eq 60) { $df = 4 }
        $mins = $tc.H * 60 + $tc.M
        $total = $total - ($df * ($mins - [math]::Floor($mins / 10)))
    }
    return [int64]$total
}

# Real frame rate, frame count and codecs of a downloaded file
function Get-SourceTiming([string]$path) {
    $r = @{ Ok = $false; Num = 0; Den = 1; Base = 0; Ntsc = $false; Total = [int64]0; VCodec = ''; ACodec = ''; Error = '' }
    $ff = $T.Ffprobe
    if (-not $ff) { $r.Error = 'ffprobe not found'; return $r }
    try {
        $v = @(& $ff -v error -select_streams v:0 -show_entries stream=codec_name,r_frame_rate,nb_frames,duration -of default=noprint_wrappers=1 $path 2>$null)
        $a = @(& $ff -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1 $path 2>$null)
        $f = @(& $ff -v error -show_entries format=duration -of default=noprint_wrappers=1 $path 2>$null)
    } catch {
        $r.Error = 'ffprobe failed'
        return $r
    }
    $vi = @{}
    foreach ($l in $v) { if ($l -match '^(\w+)=(.*)$') { $vi[$Matches[1]] = $Matches[2] } }
    $ai = @{}
    foreach ($l in $a) { if ($l -match '^(\w+)=(.*)$') { $ai[$Matches[1]] = $Matches[2] } }
    $fi = @{}
    foreach ($l in $f) { if ($l -match '^(\w+)=(.*)$') { $fi[$Matches[1]] = $Matches[2] } }

    $r.VCodec = [string]$vi['codec_name']
    $r.ACodec = [string]$ai['codec_name']

    if ($vi['r_frame_rate'] -match '^(\d+)/(\d+)$') {
        $n = [int]$Matches[1]
        $d = [int]$Matches[2]
        if ($d -gt 0 -and $n -gt 0) {
            $r.Num = $n
            $r.Den = $d
            $r.Base = [int][math]::Round($n / $d)
            $r.Ntsc = ($d -eq 1001)
        }
    }
    if ($r.Num -le 0) { $r.Error = 'could not read the frame rate'; return $r }

    if ($vi['nb_frames'] -match '^\d+$') {
        $r.Total = [int64]$vi['nb_frames']
    } else {
        $dur = $null
        if ($vi['duration'] -match '^\d+(\.\d+)?$') { $dur = [double]$vi['duration'] }
        elseif ($fi['duration'] -match '^\d+(\.\d+)?$') { $dur = [double]$fi['duration'] }
        if ($null -eq $dur) { $r.Error = 'could not read the video length'; return $r }
        $r.Total = [int64][math]::Round($dur * $r.Num / $r.Den)
    }
    if ($r.Total -lt 1) { $r.Error = 'the video has no frames'; return $r }
    $r.Ok = $true
    return $r
}

# Turn the job's Start / End timecodes into exact frame numbers and ffmpeg times
function Get-CutPlan($job, $tm) {
    $plan = @{ Ok = $false; Error = ''; S = [int64]0; E = [int64]0; T0 = 0.0; Dur = 0.0; Frames = [int64]0; Fps = 0.0; Note = '' }
    $base = $tm.Base
    $stc = ConvertFrom-TimecodeText $job.Start
    $etc = ConvertFrom-TimecodeText $job.End

    foreach ($tc in @($stc, $etc)) {
        if (-not $tc.Blank) {
            if (-not $tc.Valid) { $plan.Error = 'invalid timecode'; return $plan }
            if ($tc.F -ge $base) {
                $plan.Error = ('frames must be 0-{0} for this video ({1} fps)' -f ($base - 1), $base)
                return $plan
            }
        }
    }
    if ((-not $etc.Blank) -and $etc.Neg) { $plan.Error = 'End cannot start with a minus sign'; return $plan }

    $total = $tm.Total
    $s = [int64]0
    if (-not $stc.Blank) {
        $sf = ConvertTo-FrameIndex $stc $base $tm.Ntsc
        if ($stc.Neg) { $s = $total - $sf } else { $s = $sf }
    }
    $e = $total - 1
    if (-not $etc.Blank) { $e = ConvertTo-FrameIndex $etc $base $tm.Ntsc }

    if ($s -lt 0) { $plan.Error = 'Start is before the beginning of the video'; return $plan }
    if ($s -ge $total) { $plan.Error = ('Start is after the end of the video ({0} frames)' -f $total); return $plan }
    if ($e -ge $total) { $e = $total - 1; $plan.Note = 'End was past the last frame - used the last frame' }
    if ($e -lt $s) { $plan.Error = 'End is before Start'; return $plan }

    $fd = [double]$tm.Den / [double]$tm.Num
    $t0 = 0.0
    if ($s -gt 0) { $t0 = ([double]$s - 0.25) * $fd }
    $dur = (([double]$e + 0.75) * $fd) - $t0

    $plan.S = $s
    $plan.E = $e
    $plan.T0 = $t0
    $plan.Dur = $dur
    $plan.Frames = $e - $s + 1
    $plan.Fps = [double]$tm.Num / [double]$tm.Den
    $plan.Ok = $true
    return $plan
}

# ---------------------------------------------------------------------
#  Row status helpers (Queue tab)
# ---------------------------------------------------------------------
function Set-RowStatus($job, [string]$text, [string]$file = '') {
    $job.Status = $text
    $RowStatus[$job.Key] = $text
    if ($file) { $RowFile[$job.Key] = $file }
    if ($tabs.SelectedTab -eq $pgQueue) {
        foreach ($row in $grid.Rows) {
            if ([string]$row.Tag -eq $job.Key) {
                $row.Cells['colStatus'].Value = $text
                if ($file) { $row.Cells['colFile'].Value = $file }
                break
            }
        }
    }
}

# ---------------------------------------------------------------------
#  Engine (state machine driven by a UI timer)
# ---------------------------------------------------------------------
function Start-Setup([string[]]$need) {
    $S.Mode = 'setup'
    $S.Cancelled = $false
    $S.Output = $null
    $S.AttemptOut = $null
    Set-Running $true
    $bar.Style = 'Marquee'
    $bar.MarqueeAnimationSpeed = 30
    $lblStatus.Text = 'Downloading the required tools (first time only)...'
    Write-Log ''
    Write-Log '=== First-time setup: downloading tools ==='
    $argStr = ConvertTo-ArgString @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, '-SetupTools', '-ToolsDir', $ToolsHome, '-Need', ($need -join ','))
    $S.Runner = New-Object YtRunner
    try {
        $S.Runner.Start('powershell.exe', $argStr, $AppDir)
    } catch {
        Write-Log ('ERROR: could not start the setup: ' + $_.Exception.Message)
        $S.Runner = $null
        $S.Mode = 'idle'
        $bar.Style = 'Continuous'
        Set-Running $false
    }
}

function Start-UpdateRun {
    Update-Tools
    if (-not $T.YtDlp) { return $false }
    $S.Mode = 'update'
    $S.Exe = $T.YtDlp
    $S.Cancelled = $false
    $S.Jobs = @()
    $S.Output = New-Object System.Text.StringBuilder
    $S.AttemptOut = New-Object System.Text.StringBuilder
    Set-Running $true
    Write-Log ''
    Write-Log '=== Updating yt-dlp ==='
    $S.Runner = New-Object YtRunner
    try {
        $S.Runner.Start($T.YtDlp, '-U', (Split-Path -Parent $T.YtDlp))
        return $true
    } catch {
        Write-Log ('ERROR: ' + $_.Exception.Message)
        $S.Runner = $null
        $S.Mode = 'idle'
        Set-Running $false
        return $false
    }
}

function Start-Attempt {
    $job = $S.Jobs[$S.Idx]
    $browser = $S.Browsers[$S.AttemptIdx]
    $audio = ($cmbMode.SelectedIndex -ge 1)

    $ytArgs = @(
        '--ignore-config', '--newline', '--no-playlist', '--no-mtime',
        '--continue', '--no-overwrites',
        '--retries', '10', '--fragment-retries', '10',
        '--sleep-requests', [string][int]$numSleep.Value
    )
    if ($audio) { $ytArgs += Get-AudioArgs } else { $ytArgs += Get-FormatArgs }

    if ($chkSubs.Checked) {
        $langs = $txtSubLangs.Text.Trim()
        if (-not $langs) { $langs = 'en' }
        $ytArgs += @('--write-subs', '--write-auto-subs', '--sub-langs', $langs, '--convert-subs', 'srt')
    } else {
        $ytArgs += @('--no-write-subs', '--no-write-auto-subs')
    }
    if ($chkThumbs.Checked) { $ytArgs += @('--write-thumbnail', '--convert-thumbnails', 'jpg') }
    else { $ytArgs += '--no-write-thumbnail' }

    $lim = [int]$numLimit.Value
    if ($lim -gt 0) { $ytArgs += @('--limit-rate', ('{0}M' -f $lim)) }
    if ($chkArchive.Checked) { $ytArgs += @('--download-archive', $ArchiveFile) }

    $ytArgs += @('-P', $S.Folder)
    $hasRange = ((-not $audio) -and ($job.Start -ne '' -or $job.End -ne ''))
    if ($job.Label) { $nameT = $job.Label } else { $nameT = '%(title).140s' }
    if ($hasRange) { $nameT = $nameT + '__full' }
    $ytArgs += @('-o', ($nameT + '.%(ext)s'))

    if ($T.Ffmpeg) { $ytArgs += @('--ffmpeg-location', (Split-Path -Parent $T.Ffmpeg)) }
    $ytArgs += Get-CookieArgs $browser
    $ytArgs += $job.Url

    if ($S.AttemptIdx -eq 0) {
        $tag = ''
        if ($job.Label) { $tag = $job.Label + '  ' }
        Write-Log ''
        Write-Log ('[{0}/{1}] {2}{3}' -f ($S.Idx + 1), $S.Jobs.Count, $tag, $job.Url)
        if ($hasRange) { Write-Log ('    clip: start "{0}"  end "{1}"' -f $job.Start, $job.End) }
    }
    Write-Log ('    login: ' + (Get-CookieLabel $browser))
    $S.Step = 'dl'
    $bar.Value = 0
    $lblStatus.Text = ('Video {0}/{1}  |  starting...' -f ($S.Idx + 1), $S.Jobs.Count)

    $S.AttemptOut = New-Object System.Text.StringBuilder
    $S.Runner = New-Object YtRunner
    try {
        $S.Runner.Start($S.Exe, (ConvertTo-ArgString $ytArgs), $S.Folder)
    } catch {
        Write-Log ('ERROR: could not start yt-dlp: ' + $_.Exception.Message)
        $S.Runner = $null
        $S.Fail = $S.Fail + 1
        $S.Failed += ('{0} {1}' -f $job.Label, $job.Url)
        Set-RowStatus $job 'ERROR'
        Start-NextJob
    }
}

function Start-NextJob {
    $S.Idx = $S.Idx + 1
    if ($S.Idx -ge $S.Jobs.Count) { Complete-Batch; return }
    $S.AttemptIdx = 0
    $S.JobStart = Get-Date
    $S.Output = New-Object System.Text.StringBuilder
    Set-RowStatus $S.Jobs[$S.Idx] 'Downloading'
    Start-Attempt
}

function Complete-Batch {
    $S.Runner = $null
    $S.Mode = 'idle'
    $S.Step = 'dl'
    $S.LastJobs = @($S.Jobs)
    $bar.Style = 'Continuous'
    Write-Log ''
    if ($S.Cancelled) {
        Write-Log ('=== Stopped: {0} OK, {1} to review, {2} failed ===' -f $S.Ok, $S.Warn, $S.Fail)
        $lblStatus.Text = 'Stopped'
    } else {
        Write-Log ('=== Done: {0} OK, {1} to review, {2} failed ===' -f $S.Ok, $S.Warn, $S.Fail)
        $lblStatus.Text = ('Done: {0} OK, {1} to review, {2} failed' -f $S.Ok, $S.Warn, $S.Fail)
    }
    foreach ($f in $S.Failed) { Write-Log ('  FAILED: ' + $f) }
    $bar.Value = 0
    Set-Running $false
    if (-not $S.Cancelled) {
        if ($chkSound.Checked) { try { [System.Media.SystemSounds]::Asterisk.Play() } catch { } }
        if ($chkOpenDone.Checked -and $S.Folder -and (Test-Path -LiteralPath $S.Folder)) {
            try { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $S.Folder) } catch { }
        }
    }
}

function Handle-Line([string]$line) {
    if ($line -match '^\[download\]\s+(\d+(?:\.\d+)?)%') {
        $pct = [double]$Matches[1]
        $speed = ''
        $eta = ''
        if ($line -match '\sat\s+(\S+)') { $speed = $Matches[1] }
        if ($line -match 'ETA\s+(\S+)') { $eta = $Matches[1] }
        $bar.Value = [int][math]::Min(100, [math]::Max(0, $pct))
        $lblStatus.Text = ('Video {0}/{1}  |  {2}%  |  {3}  |  ETA {4}' -f ($S.Idx + 1), $S.Jobs.Count, $pct, $speed, $eta)
        return
    }
    if ($S.Output) { [void]$S.Output.AppendLine($line) }
    if ($S.AttemptOut) { [void]$S.AttemptOut.AppendLine($line) }
    Write-Log $line
}

# ---- ffmpeg step: frame-accurate clip and/or conversion to H.264 + AAC ----
function Start-Cut($job, $file, [bool]$isRange) {
    $S.Step = 'cut'
    $S.CutIsRange = $isRange
    $S.CutSrc = $file.FullName
    $S.CutNote = ''
    $dir = Split-Path -Parent $file.FullName
    $base = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    if ($isRange -and $base.EndsWith('__full')) { $base = $base.Substring(0, $base.Length - 6) }
    $S.CutDir = $dir
    $S.CutBase = $base
    $S.CutTmp = Join-Path $dir ($base + '.__tmp.mp4')

    $tm = Get-SourceTiming $file.FullName
    $plan = $null
    if ($isRange) {
        if (-not $tm.Ok) {
            Write-Log ('REVIEW  clip not made: ' + $tm.Error + '. The full video was kept.')
            $S.Warn = $S.Warn + 1
            Set-RowStatus $job 'REVIEW' $file.Name
            $S.Step = 'dl'
            Start-NextJob
            return
        }
        $plan = Get-CutPlan $job $tm
        if (-not $plan.Ok) {
            Write-Log ('REVIEW  clip not made: ' + $plan.Error + '. The full video was kept as ' + $file.Name)
            $S.Warn = $S.Warn + 1
            Set-RowStatus $job 'REVIEW' $file.Name
            $S.Step = 'dl'
            Start-NextJob
            return
        }
        $S.CutNote = ('clip: frames {0} to {1} = {2} frames at {3:0.###} fps' -f $plan.S, $plan.E, $plan.Frames, $plan.Fps)
        if ($plan.Note) { $S.CutNote = $S.CutNote + '  (' + $plan.Note + ')' }
    }

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $crf = [string][int]$numCrf.Value
    $a = @('-hide_banner', '-loglevel', 'error', '-nostats', '-y', '-i', $file.FullName)
    if ($isRange) { $a += @('-ss', $plan.T0.ToString('0.######', $inv), '-t', $plan.Dur.ToString('0.######', $inv)) }
    $a += @('-map', '0:v:0', '-map', '0:a:0?')
    if ($isRange -or $tm.VCodec -ne 'h264') {
        $a += @('-c:v', 'libx264', '-preset', 'medium', '-crf', $crf, '-pix_fmt', 'yuv420p')
    } else {
        $a += @('-c:v', 'copy')
    }
    if ($isRange -or $tm.ACodec -ne 'aac') {
        $a += @('-c:a', 'aac', '-b:a', '256k')
    } else {
        $a += @('-c:a', 'copy')
    }
    $a += @('-movflags', '+faststart', $S.CutTmp)

    if ($isRange) { Write-Log ('    cutting ' + $S.CutNote) }
    else { Write-Log '    converting to H.264 + AAC...' }
    Set-RowStatus $job 'Cutting...'
    $bar.Style = 'Marquee'
    $bar.MarqueeAnimationSpeed = 30
    $lblStatus.Text = ('Video {0}/{1}  |  working on the clip...' -f ($S.Idx + 1), $S.Jobs.Count)

    $S.AttemptOut = New-Object System.Text.StringBuilder
    $S.Runner = New-Object YtRunner
    try {
        $S.Runner.Start($T.Ffmpeg, (ConvertTo-ArgString $a), $dir)
    } catch {
        Write-Log ('ERROR: could not start ffmpeg: ' + $_.Exception.Message)
        $S.Runner = $null
        $S.Fail = $S.Fail + 1
        $S.Failed += ('{0} {1}' -f $job.Label, $job.Url)
        Set-RowStatus $job 'ERROR'
        $bar.Style = 'Continuous'
        $S.Step = 'dl'
        Start-NextJob
    }
}

function Finish-Cut([int]$exitCode) {
    $job = $S.Jobs[$S.Idx]
    $src = $S.CutSrc
    $tmp = $S.CutTmp
    $bar.Style = 'Continuous'
    $bar.Value = 0
    $S.Step = 'dl'

    if ($S.Cancelled) {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        Write-Log 'Stopped by user.'
        Complete-Batch
        return
    }

    if ($exitCode -eq 0 -and (Test-Path -LiteralPath $tmp)) {
        $keep = ($S.CutIsRange -and $chkKeepFull.Checked)
        if (-not $keep) { Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue }
        $final = Get-UniquePath $S.CutDir $S.CutBase '.mp4'
        Move-Item -LiteralPath $tmp -Destination $final -Force
        $name = Split-Path -Leaf $final
        $info = Get-MediaInfo $final
        if ($info.Warn) {
            $S.Warn = $S.Warn + 1
            Write-Log ('WARN  {0}  ->  {1}' -f $name, $info.Text)
            Set-RowStatus $job 'WARN' $name
        } else {
            $S.Ok = $S.Ok + 1
            Write-Log ('OK    {0}  ->  {1}' -f $name, $info.Text)
            Set-RowStatus $job 'OK' $name
        }
        if ($S.CutNote) { Write-Log ('      ' + $S.CutNote) }
        if ($keep) { Write-Log ('      the full video was kept: ' + (Split-Path -Leaf $src)) }
    } else {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        $S.Warn = $S.Warn + 1
        Write-Log ('REVIEW  ffmpeg failed (exit code {0}). The downloaded video was kept: {1}' -f $exitCode, (Split-Path -Leaf $src))
        Set-RowStatus $job 'REVIEW' (Split-Path -Leaf $src)
    }
    Start-NextJob
}

function Finish-Attempt([int]$exitCode) {
    if ($S.Mode -eq 'update') {
        Write-Log ('--- Update finished (exit code {0}) ---' -f $exitCode)
        $S.Mode = 'idle'
        $lblStatus.Text = 'Ready'
        $bar.Value = 0
        Set-Running $false
        return
    }

    if ($S.Mode -eq 'setup') {
        $bar.Style = 'Continuous'
        $bar.Value = 0
        $S.Mode = 'idle'
        Update-ToolStatus
        $missing = @(Get-MissingTools)
        $again = $S.StartAfterSetup
        $S.StartAfterSetup = $false
        if ($exitCode -eq 0 -and $missing.Count -eq 0) {
            Write-Log '=== Setup complete ==='
            $lblStatus.Text = 'Ready'
            Set-Running $false
            if ($again) { Start-Batch }
        } else {
            Write-Log ('Setup did not finish (exit code {0}). Still missing: {1}' -f $exitCode, ($missing -join ', '))
            Write-Log 'Check your internet connection and press Download to try again.'
            $lblStatus.Text = 'Setup failed'
            Set-Running $false
        }
        return
    }

    if ($S.Step -eq 'cut') { Finish-Cut $exitCode; return }

    if ($S.Cancelled) {
        Write-Log 'Stopped by user. Partial files (.part) may remain in the folder.'
        Complete-Batch
        return
    }

    $job = $S.Jobs[$S.Idx]
    $browser = $S.Browsers[$S.AttemptIdx]
    $attemptText = $S.AttemptOut.ToString()
    $audio = ($cmbMode.SelectedIndex -ge 1)

    # Cookie problem or bot check with this source -> try the next one
    if ($exitCode -ne 0 -and ($S.AttemptIdx + 1) -lt $S.Browsers.Count -and $attemptText -match $RetryRegex) {
        $S.AttemptIdx = $S.AttemptIdx + 1
        Write-Log ('    "{0}" did not work - trying "{1}"...' -f $browser, $S.Browsers[$S.AttemptIdx])
        Start-Attempt
        return
    }

    $file = Find-ResultFile $S.Folder $S.JobStart
    $name = $job.Url
    if ($job.Label) { $name = $job.Label }

    if ($exitCode -eq 0 -and $file) {
        # Remember the source that worked so the next videos try it first
        if ($S.AttemptIdx -gt 0) {
            $S.Browsers = @(@($browser) + @($S.Browsers | Where-Object { $_ -ne $browser }))
            $Pref.Browser = $browser
        }

        if ($audio) {
            $S.Ok = $S.Ok + 1
            Write-Log ('OK    {0}' -f $file.Name)
            Set-RowStatus $job 'OK' $file.Name
            Start-NextJob
            return
        }

        $needRange = ($job.Start -ne '' -or $job.End -ne '')
        $needConv = $false
        if ((-not $needRange) -and $chkFallback.Checked) {
            $tm0 = Get-SourceTiming $file.FullName
            if ($tm0.Ok -and ($tm0.VCodec -ne 'h264' -or $tm0.ACodec -ne 'aac' -or $file.Extension -ne '.mp4')) { $needConv = $true }
        }
        if ($needRange -or $needConv) {
            if ($T.Ffmpeg) { Start-Cut $job $file $needRange; return }
            Write-Log 'WARN  ffmpeg not found - cannot cut or convert. The downloaded video was kept.'
        }

        $info = Get-MediaInfo $file.FullName
        if ($info.Warn) {
            $S.Warn = $S.Warn + 1
            Write-Log ('WARN  {0}  ->  {1}' -f $file.Name, $info.Text)
            Write-Log '      Not the expected h264 + aac - Premiere may reject this file.'
            Set-RowStatus $job 'WARN' $file.Name
        } else {
            $S.Ok = $S.Ok + 1
            Write-Log ('OK    {0}  ->  {1}' -f $file.Name, $info.Text)
            Set-RowStatus $job 'OK' $file.Name
        }
    }
    elseif ($file) {
        $S.Warn = $S.Warn + 1
        Write-Log ('REVIEW  {0} exists but yt-dlp returned code {1}.' -f $file.Name, $exitCode)
        Set-RowStatus $job 'REVIEW' $file.Name
    }
    elseif ($exitCode -eq 0) {
        $S.Warn = $S.Warn + 1
        Write-Log 'SKIPPED  no new file appeared (already downloaded before, or a file with the same name exists).'
        Set-RowStatus $job 'Skipped'
    }
    else {
        $S.Fail = $S.Fail + 1
        $S.Failed += ('{0}  {1}' -f $name, $job.Url)
        Set-RowStatus $job 'ERROR'
        Write-Log ('ERROR  no file produced (exit code {0}).' -f $exitCode)
        $all = $S.Output.ToString()
        if ($all -match 'Sign in to confirm') {
            Write-Log '    Hint: log into YouTube in Firefox, keep the login source on Auto (Settings tab), then press Update tools and try again.'
        }
        elseif ($all -match 'Requested format is not available') {
            Write-Log '    Hint: YouTube did not offer H.264 for this video. Tick the H.264 fallback in the Options tab, or press Update tools.'
        }
        elseif ($all -match 'DPAPI|Could not copy') {
            Write-Log '    Hint: Chrome/Edge cookies are often unreadable on Windows. Firefox works best, or close the browser completely.'
        }
    }
    Start-NextJob
}

function Invoke-Tick {
    $r = $S.Runner
    if ($null -eq $r) { return }
    $wasDone = $r.Done
    $line = $null
    $count = 0
    while ($count -lt 300 -and $r.Lines.TryDequeue([ref]$line)) {
        $count++
        Handle-Line $line
    }
    if ($wasDone -and $r.Lines.IsEmpty) {
        $S.Runner = $null
        Finish-Attempt $r.ExitCode
    }
}

# ---------------------------------------------------------------------
#  Starting batches
# ---------------------------------------------------------------------
function Begin-Jobs($jobs, [string]$folder) {
    $S.Mode = 'download'
    $S.Step = 'dl'
    $S.Exe = $T.YtDlp
    $S.Folder = $folder
    $S.Jobs = @($jobs)
    $S.Idx = -1
    $S.Ok = 0
    $S.Warn = 0
    $S.Fail = 0
    $S.Failed = @()
    $S.Cancelled = $false
    $S.BaseBrowsers = @(Get-BrowserList)
    $S.Browsers = @($S.BaseBrowsers)

    Save-GuiSettings
    Set-Running $true
    Write-Log ''
    Write-Log ('=== Starting: {0} item(s) -> {1} ===' -f $S.Jobs.Count, $folder)
    Start-NextJob
}

function Start-Batch {
    $folder = $txtFolder.Text.Trim('" ')
    if (-not $folder) {
        [void](Show-Msg 'Choose a folder to save the videos in.' 'videoprep' 'OK' 'Warning')
        return
    }
    $audio = ($cmbMode.SelectedIndex -ge 1)

    $entries = @()
    foreach ($en in @(Get-QueueEntries)) {
        if ($en.Url -match '^https?://') { $entries += $en }
        else { Write-Log ('Skipped (not a link): ' + $en.Url) }
    }
    if ($entries.Count -eq 0) {
        [void](Show-Msg 'Paste at least one link that starts with http:// or https://' 'videoprep' 'OK' 'Warning')
        return
    }

    $usePrefix = $radPrefix.Checked
    $prefix = ''
    if ($usePrefix) {
        $prefix = ($txtPrefix.Text -replace '[\\/:*?"<>|%]', '')
        if ($prefix.Trim() -eq '') {
            [void](Show-Msg 'Type a name prefix, for example: Clip' 'videoprep' 'OK' 'Warning')
            return
        }
        if ($prefix -ne $txtPrefix.Text) { $txtPrefix.Text = $prefix }
    }

    # Check the time ranges typed in the Queue tab
    if (-not $audio) {
        $rowNo = 0
        foreach ($en in $entries) {
            $rowNo = $rowNo + 1
            if ($Ranges.ContainsKey($en.Key)) {
                foreach ($tx in @($Ranges[$en.Key].Start, $Ranges[$en.Key].End)) {
                    $tcv = ConvertFrom-TimecodeText ([string]$tx)
                    if ((-not $tcv.Blank) -and (-not $tcv.Valid)) {
                        $tabs.SelectedTab = $pgQueue
                        [void](Show-Msg ("Link {0}: '{1}' is not a valid timecode.`n`nUse HH:MM:SS:FF, for example 00:01:23:15. Hover over the Start / End headers for help." -f $rowNo, $tx) 'videoprep' 'OK' 'Warning')
                        return
                    }
                }
            }
        }
    }

    # Make sure the tools exist (first run downloads them)
    Update-Tools
    $missing = @(Get-MissingTools)
    if ($missing.Count -gt 0) {
        $ans = Show-Msg ("First-time setup: this app needs to download a few free tools ({0}).`n`nIt is about 200 MB and only happens once. Download now?" -f ($missing -join ', ')) 'First-time setup' 'YesNo' 'Question'
        if ($ans -eq 'Yes') {
            $S.StartAfterSetup = $true
            Start-Setup $missing
        }
        return
    }

    Stop-DetailRun

    try { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
    catch {
        [void](Show-Msg ("Could not create the folder:`n$folder") 'videoprep' 'OK' 'Warning')
        return
    }

    $startNum = 1
    if ($usePrefix) {
        $rx = '^' + [regex]::Escape($prefix) + '(\d+)\.'
        $nums = @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue |
            ForEach-Object { if ($_.Name -match $rx) { [int]$Matches[1] } })
        if ($nums.Count -gt 0) {
            $max = ($nums | Measure-Object -Maximum).Maximum
            $next = $max + 1
            $ans = Show-Msg ("This folder already has files like ${prefix}1, ${prefix}2... (up to ${prefix}${max}).`n`nYes = continue numbering from ${prefix}${next}`nNo = cancel (nothing is overwritten)") 'Existing files' 'YesNo' 'Question'
            if ($ans -ne 'Yes') { return }
            $startNum = $next
        }
    }

    $jobs = @()
    $n = $startNum
    $RowStatus.Clear()
    $RowFile.Clear()
    foreach ($en in $entries) {
        $label = $null
        if ($usePrefix) { $label = "$prefix$n"; $n = $n + 1 }
        $st = ''
        $ed = ''
        if ((-not $audio) -and $Ranges.ContainsKey($en.Key)) {
            $st = ([string]$Ranges[$en.Key].Start).Trim()
            $ed = ([string]$Ranges[$en.Key].End).Trim()
        }
        $RowStatus[$en.Key] = 'Queued'
        $jobs += [pscustomobject]@{ Url = $en.Url; Label = $label; Key = $en.Key; Start = $st; End = $ed; Status = 'Queued' }
    }
    if ($audio -and ($Ranges.Values | Where-Object { $_.Start -or $_.End })) {
        Write-Log 'Note: time ranges are ignored in audio-only mode.'
    }
    Begin-Jobs $jobs $folder
}

function Start-Retry {
    $failed = @($S.LastJobs | Where-Object { $_.Status -eq 'ERROR' })
    if ($failed.Count -eq 0) { return }
    Update-Tools
    if (@(Get-MissingTools).Count -gt 0) {
        [void](Show-Msg 'The tools are missing. Press Download once to install them.' 'videoprep' 'OK' 'Warning')
        return
    }
    Stop-DetailRun
    $audio = ($cmbMode.SelectedIndex -ge 1)
    foreach ($j in $failed) {
        $j.Status = 'Queued'
        $RowStatus[$j.Key] = 'Queued'
        if ($Ranges.ContainsKey($j.Key) -and (-not $audio)) {
            $j.Start = ([string]$Ranges[$j.Key].Start).Trim()
            $j.End = ([string]$Ranges[$j.Key].End).Trim()
        }
    }
    Begin-Jobs $failed $S.Folder
}

# ---------------------------------------------------------------------
#  Link preview (thumbnail, title, channel, quality)
# ---------------------------------------------------------------------
function Clear-PreviewPanel {
    $picThumb.Image = $null
    $lblTitle.Text = 'Paste a YouTube link to see a preview'
    $lblMeta.Text = ''
}

function Show-Preview([string]$id) {
    $c = $P.Cache[$id]
    if ($null -eq $c) { Clear-PreviewPanel; return }
    $picThumb.Image = $c.Img
    if (-not $c.Fetched) {
        $lblTitle.Text = 'Loading preview...'
        $lblMeta.Text = ''
        return
    }
    if (-not $c.Title) {
        $lblTitle.Text = 'No preview for this link'
        $lblMeta.Text = 'The video may be private or removed, or the ID is wrong.'
        return
    }
    $lblTitle.Text = $c.Title
    $bits = @()
    if ($c.Author) { $bits += $c.Author }
    if ($c.Duration) { $bits += $c.Duration }
    if ($c.Date) { $bits += $c.Date }
    $line2 = ''
    switch ($c.DetState) {
        'loading'  { $line2 = 'Checking available quality...' }
        'done'     { $line2 = $c.DetText }
        'noformat' { $line2 = 'No H.264 version offered (tick the fallback in Options).' }
        'fail'     { $line2 = 'Quality check unavailable.' }
    }
    $lblMeta.Text = (($bits -join '  |  ') + [Environment]::NewLine + $line2)
}

function Stop-DetailRun {
    if ($P.Runner) {
        $P.Runner.Kill()
        $c = $P.Cache[$P.RunnerId]
        if ($c -and $c.DetState -eq 'loading') { $c.DetState = '' }
        $P.Runner = $null
    }
}

function Start-DetailAttempt {
    $id = $P.RunnerId
    $browser = $P.Browsers[$P.BIdx]
    $fa = @(Get-FormatArgs)
    $a = @('--ignore-config', '--no-playlist', '--no-warnings', $fa[0], $fa[1], $fa[2], $fa[3],
        '--print', 'DET|%(duration_string)s|%(height)s|%(fps)s|%(vcodec)s|%(acodec)s|%(upload_date)s')
    $a += Get-CookieArgs $browser
    $a += ('https://www.youtube.com/watch?v=' + $id)
    $P.DetOut = New-Object System.Text.StringBuilder
    $P.DetLine = $null
    $P.RunnerStart = Get-Date
    $P.Cache[$id].DetState = 'loading'
    $P.Runner = New-Object YtRunner
    try { $P.Runner.Start($T.YtDlp, (ConvertTo-ArgString $a), $AppDir) }
    catch {
        $P.Runner = $null
        $P.Cache[$id].DetState = 'fail'
    }
}

function Start-DetailRun([string]$id) {
    Update-Tools
    if (-not $T.YtDlp) { return }
    Stop-DetailRun
    $P.Browsers = @(Get-BrowserList)
    $P.BIdx = 0
    $P.RunnerId = $id
    Start-DetailAttempt
}

function Ensure-Details([string]$id) {
    $c = $P.Cache[$id]
    if ($null -eq $c) { return }
    if (-not $c.Title) { return }
    if ($c.DetState -ne '') { return }
    if ($S.Mode -ne 'idle') { return }
    Start-DetailRun $id
}

function Finish-Detail([int]$exitCode) {
    $id = $P.RunnerId
    $c = $P.Cache[$id]
    if ($null -eq $c) { return }
    $out = $P.DetOut.ToString()
    if ($P.DetLine) {
        $f = @($P.DetLine -split '\|')
        $dur = ''
        if ($f.Count -gt 1 -and $f[1] -and $f[1] -ne 'NA') { $dur = $f[1] }
        $h = ''
        if ($f.Count -gt 2) { $h = $f[2] }
        $fps = ''
        if ($f.Count -gt 3) { $fps = $f[3] }
        $vc = ''
        if ($f.Count -gt 4) { $vc = $f[4] }
        $ac = ''
        if ($f.Count -gt 5) { $ac = $f[5] }
        $dt = ''
        if ($f.Count -gt 6) { $dt = $f[6] }
        $res = ''
        if ($h -match '^\d+$') {
            $res = $h + 'p'
            if ($fps -match '^\d+(\.\d+)?$') { $res = $res + [string][math]::Round([double]$fps) }
        }
        $vl = $vc
        $conv = ''
        if ($vc -like 'avc1*') { $vl = 'H.264' }
        elseif ($vc -like 'vp0*' -or $vc -like 'vp9*') { $vl = 'VP9'; $conv = ' (will be converted)' }
        elseif ($vc -like 'av01*') { $vl = 'AV1'; $conv = ' (will be converted)' }
        $al = $ac
        if ($ac -like 'mp4a*') { $al = 'AAC' }
        $c.Duration = $dur
        if ($dt -match '^(\d{4})(\d{2})(\d{2})$') { $c.Date = ('{0}-{1}-{2}' -f $Matches[1], $Matches[2], $Matches[3]) }
        $c.DetText = (('Will download: {0} {1} + {2}{3}' -f $res, $vl, $al, $conv)).Trim()
        $c.DetState = 'done'
        if ($P.BIdx -gt 0) { $Pref.Browser = $P.Browsers[$P.BIdx] }
    }
    elseif ($exitCode -ne 0 -and ($P.BIdx + 1) -lt $P.Browsers.Count -and $out -match $RetryRegex) {
        $P.BIdx = $P.BIdx + 1
        Start-DetailAttempt
        return
    }
    elseif ($out -match 'Requested format is not available') { $c.DetState = 'noformat' }
    else { $c.DetState = 'fail' }
    if ($P.Id -eq $id) { Show-Preview $id }
}

function Ensure-Meta([string]$id) {
    if (-not $P.Cache.ContainsKey($id)) {
        $P.Cache[$id] = @{ Fetched = $false; Title = ''; Author = ''; Img = $null; Stream = $null; Duration = ''; Date = ''; DetState = ''; DetText = '' }
        $P.Fetcher.Fetch($id)
    }
}

function Update-GridTitles {
    foreach ($row in $grid.Rows) {
        $key = [string]$row.Tag
        $cut = $key.LastIndexOf('|')
        if ($cut -lt 0) { continue }
        $id = Get-VideoId $key.Substring(0, $cut)
        if (-not $id) { continue }
        $c = $P.Cache[$id]
        if ($c -and $c.Title) { $row.Cells['colTitle'].Value = $c.Title }
    }
}

function Apply-FetchResult($item) {
    $c = $P.Cache[$item.Id]
    if ($null -eq $c) { return }
    $c.Fetched = $true
    if ($item.Json) {
        try {
            $o = $item.Json | ConvertFrom-Json
            $c.Title = [string]$o.title
            $c.Author = [string]$o.author_name
        } catch { }
    }
    if ($null -ne $item.Thumb -and $item.Thumb.Length -gt 0) {
        try {
            $bytes = [byte[]]$item.Thumb
            $ms = New-Object System.IO.MemoryStream(, $bytes)
            $c.Stream = $ms
            $c.Img = [System.Drawing.Image]::FromStream($ms)
        } catch { }
    }
    if ($P.Id -eq $item.Id) {
        Show-Preview $item.Id
        Ensure-Details $item.Id
    }
    if ($tabs.SelectedTab -eq $pgQueue) { Update-GridTitles }
}

function Invoke-PreviewTick {
    $item = $null
    while ($P.Fetcher.Results.TryDequeue([ref]$item)) { Apply-FetchResult $item }

    $r = $P.Runner
    if ($null -eq $r) { return }
    $wasDone = $r.Done
    $line = $null
    while ($r.Lines.TryDequeue([ref]$line)) {
        [void]$P.DetOut.AppendLine($line)
        if ($line.StartsWith('DET|')) { $P.DetLine = $line }
    }
    if ($wasDone -and $r.Lines.IsEmpty) {
        $P.Runner = $null
        Finish-Detail $r.ExitCode
    }
    elseif (((Get-Date) - $P.RunnerStart).TotalSeconds -gt 45) {
        $r.Kill()
        $P.Runner = $null
        $c = $P.Cache[$P.RunnerId]
        if ($c) { $c.DetState = 'fail' }
        if ($P.Id -eq $P.RunnerId) { Show-Preview $P.RunnerId }
    }
}

function Request-Preview([string]$url) {
    $id = Get-VideoId $url
    if (-not $id) { return }
    $P.Id = $id
    Ensure-Meta $id
    Show-Preview $id
    Ensure-Details $id
}

function Show-PreviewForCaret {
    $i = $txtLinks.GetLineFromCharIndex($txtLinks.SelectionStart)
    $ls = $txtLinks.Lines
    if ($i -lt 0 -or $i -ge $ls.Count) { return }
    $u = ConvertTo-YoutubeUrl $ls[$i]
    if ($u) { Request-Preview $u }
}

# ---------------------------------------------------------------------
#  Adding links: paste, drag and drop, load .txt
# ---------------------------------------------------------------------
# Recognises links / short links / bare video IDs and puts each on its own line.
# Returns $true if at least one link was found.
function Add-LinksFromText([string]$text) {
    if (-not $text) { return $false }
    $parts = @()
    foreach ($tok in @($text -split '\s+' | Where-Object { $_ -ne '' })) {
        $u = ConvertTo-YoutubeUrl $tok
        if ($u) { $parts += $u }
        elseif ($tok -match '^https?://') { $parts += $tok }
    }
    if ($parts.Count -eq 0) { return $false }
    $nl = [Environment]::NewLine
    $insert = ($parts -join $nl) + $nl
    $pos = $txtLinks.SelectionStart
    if ($pos -gt 0 -and $txtLinks.Text[$pos - 1] -ne "`n") { $insert = $nl + $insert }
    $txtLinks.SelectedText = $insert
    $txtLinks.ScrollToCaret()
    $last = $null
    foreach ($q in $parts) { if (ConvertTo-YoutubeUrl $q) { $last = $q } }
    if ($last) { Request-Preview $last }
    return $true
}

function Invoke-SmartPaste {
    $clip = ''
    try { $clip = [System.Windows.Forms.Clipboard]::GetText() } catch { }
    if (-not $clip) { return }
    if (-not (Add-LinksFromText $clip)) { $txtLinks.SelectedText = $clip }
}

# ---------------------------------------------------------------------
#  Queue tab
# ---------------------------------------------------------------------
function Test-RangeCells($row) {
    foreach ($cn in @('colStart', 'colEnd')) {
        $cell = $row.Cells[$cn]
        $tcv = ConvertFrom-TimecodeText ([string]$cell.Value)
        if ($tcv.Blank -or $tcv.Valid) {
            $cell.Style.ForeColor = [System.Drawing.SystemColors]::ControlText
            $cell.ToolTipText = ''
        } else {
            $cell.Style.ForeColor = [System.Drawing.Color]::Red
            $cell.ToolTipText = 'Not a valid timecode. Use HH:MM:SS:FF, for example 00:01:23:15'
        }
    }
}

function Update-QueueGrid {
    $entries = @(Get-QueueEntries)
    $grid.Rows.Clear()
    $n = 0
    foreach ($en in $entries) {
        $n = $n + 1
        if (-not $Ranges.ContainsKey($en.Key)) { $Ranges[$en.Key] = @{ Start = ''; End = '' } }
        $rg = $Ranges[$en.Key]
        $id = Get-VideoId $en.Url
        $title = $en.Url
        if ($id) {
            Ensure-Meta $id
            $c = $P.Cache[$id]
            if ($c -and $c.Title) { $title = $c.Title }
        }
        $status = ''
        if ($RowStatus.ContainsKey($en.Key)) { $status = $RowStatus[$en.Key] }
        $file = ''
        if ($RowFile.ContainsKey($en.Key)) { $file = $RowFile[$en.Key] }
        $ri = $grid.Rows.Add([object[]]@($n, $title, $rg.Start, $rg.End, $status, $file))
        $grid.Rows[$ri].Tag = $en.Key
        Test-RangeCells $grid.Rows[$ri]
    }
}

function Get-SelectedEntryIndexes {
    $idx = @()
    foreach ($r in $grid.SelectedRows) { $idx += $r.Index }
    return @($idx | Sort-Object)
}

function Remove-SelectedQueueRows {
    $entries = @(Get-QueueEntries)
    $sel = @(Get-SelectedEntryIndexes)
    if ($sel.Count -eq 0) { return }
    $drop = @{}
    foreach ($i in $sel) { if ($i -lt $entries.Count) { $drop[$entries[$i].Line] = $true } }
    $lines = @($txtLinks.Lines)
    $keep = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (-not $drop.ContainsKey($i)) { $keep += $lines[$i] }
    }
    $txtLinks.Lines = [string[]]$keep
    Update-QueueGrid
}

function Move-QueueRow([int]$dir) {
    $entries = @(Get-QueueEntries)
    $sel = @(Get-SelectedEntryIndexes)
    if ($sel.Count -ne 1) { return }
    $i = $sel[0]
    $j = $i + $dir
    if ($j -lt 0 -or $j -ge $entries.Count) { return }
    $lines = @($txtLinks.Lines)
    $a = $entries[$i].Line
    $b = $entries[$j].Line
    $tmp = $lines[$a]
    $lines[$a] = $lines[$b]
    $lines[$b] = $tmp
    $txtLinks.Lines = [string[]]$lines
    Update-QueueGrid
    $grid.ClearSelection()
    $grid.Rows[$j].Selected = $true
}

# ---------------------------------------------------------------------
#  Log tab tools
# ---------------------------------------------------------------------
function Invoke-TestSetup {
    $tabs.SelectedTab = $pgLog
    Write-Log ''
    Write-Log ('=== Test setup (videoprep ' + $AppVersion + ') ===')
    Update-ToolStatus
    foreach ($ln in ($lblTools.Text -split "`r?`n")) { Write-Log ('  ' + $ln) }
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        if ($T.YtDlp) {
            try { $v = (& $T.YtDlp --version 2>&1 | Select-Object -First 1) } catch { $v = '(could not run)' }
            Write-Log ('  yt-dlp version: ' + $v)
        }
        if ($T.Ffmpeg) {
            try { $v = (& $T.Ffmpeg -version 2>&1 | Select-Object -First 1) } catch { $v = '(could not run)' }
            Write-Log ('  ffmpeg: ' + $v)
        }
        if ($T.Deno) {
            try { $v = (& $T.Deno --version 2>&1 | Select-Object -First 1) } catch { $v = '(could not run)' }
            Write-Log ('  deno: ' + $v)
        }
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
    $found = @($BrowserDefs | Where-Object { Test-Path -LiteralPath $_.Path } | ForEach-Object { $_.Name })
    if ($found.Count -gt 0) { Write-Log ('  browsers with a profile: ' + ($found -join ', ')) }
    else { Write-Log '  browsers with a profile: none found' }
    Write-Log ('  cookie source order: ' + ((@(Get-BrowserList) | ForEach-Object { Get-CookieLabel $_ }) -join ' > '))
    $folder = $txtFolder.Text.Trim('" ')
    if ($folder) {
        try {
            New-Item -ItemType Directory -Force -Path $folder | Out-Null
            $probe = Join-Path $folder '.__write_test'
            Set-Content -LiteralPath $probe -Value 'x'
            Remove-Item -LiteralPath $probe -Force
            Write-Log ('  save folder is writable: ' + $folder)
        } catch {
            Write-Log ('  PROBLEM: cannot write to ' + $folder)
        }
    }
    Write-Log '=== End of test ==='
}

# ---------------------------------------------------------------------
#  Build the window
# ---------------------------------------------------------------------
function New-Ctl([string]$type, [int]$x, [int]$y, [int]$w, [int]$h, $text, $parent = $null) {
    $c = New-Object $type
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.Size = New-Object System.Drawing.Size($w, $h)
    if ($null -ne $text) { $c.Text = $text }
    if ($null -eq $parent) { $parent = $form }
    $parent.Controls.Add($c)
    return $c
}

function New-Page([string]$title) {
    $pg = New-Object System.Windows.Forms.TabPage
    $pg.Text = $title
    $pg.UseVisualStyleBackColor = $true
    $tabs.TabPages.Add($pg)
    return $pg
}

function Set-Num($ctl, $value, [int]$min, [int]$max) {
    try {
        $v = [int]$value
        if ($v -lt $min) { $v = $min }
        if ($v -gt $max) { $v = $max }
        $ctl.Value = $v
    } catch { }
}

try {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'videoprep'
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    $form.AutoScaleMode = 'Dpi'
    $form.ClientSize = New-Object System.Drawing.Size(760, 640)
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false

    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.AutoPopDelay = 30000
    $tip.InitialDelay = 250
    $tip.ReshowDelay = 100

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(8, 8)
    $tabs.Size = New-Object System.Drawing.Size(744, 624)
    $form.Controls.Add($tabs)

    $pgDownload = New-Page 'Download'
    $pgQueue    = New-Page 'Queue'
    $pgOptions  = New-Page 'Options'
    $pgSettings = New-Page 'Settings'
    $pgLog      = New-Page 'Log'

    # ================= DOWNLOAD TAB =================
    $lblLinks = New-Ctl 'System.Windows.Forms.Label' 8 8 250 20 'Paste your links (one per line):' $pgDownload
    $lblCount = New-Ctl 'System.Windows.Forms.Label' 258 8 214 20 '0 link(s) detected' $pgDownload
    $lblCount.TextAlign = 'MiddleRight'

    $txtLinks = New-Ctl 'PasteBox' 8 32 464 200 $null $pgDownload
    $txtLinks.Multiline = $true
    $txtLinks.AcceptsReturn = $true
    $txtLinks.WordWrap = $false
    $txtLinks.ScrollBars = 'Both'
    $txtLinks.AllowDrop = $true

    $picThumb = New-Ctl 'System.Windows.Forms.PictureBox' 480 32 248 140 $null $pgDownload
    $picThumb.SizeMode = 'Zoom'
    $picThumb.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $lblTitle = New-Ctl 'System.Windows.Forms.Label' 480 176 248 34 '' $pgDownload
    $lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $lblTitle.AutoEllipsis = $true
    $lblMeta = New-Ctl 'System.Windows.Forms.Label' 480 210 248 36 '' $pgDownload
    $lblMeta.AutoEllipsis = $true

    $btnLoad = New-Ctl 'System.Windows.Forms.Button' 8 238 110 26 'Load .txt...' $pgDownload
    $btnClear = New-Ctl 'System.Windows.Forms.Button' 124 238 70 26 'Clear' $pgDownload
    $lblDrop = New-Ctl 'System.Windows.Forms.Label' 202 242 270 20 'or drag a .txt file or links onto the box' $pgDownload
    $lblDrop.ForeColor = [System.Drawing.Color]::Gray

    $grp = New-Ctl 'System.Windows.Forms.GroupBox' 8 274 720 88 'File names' $pgDownload
    $radPrefix = New-Ctl 'System.Windows.Forms.RadioButton' 14 24 150 22 'Name + number:' $grp
    $txtPrefix = New-Ctl 'System.Windows.Forms.TextBox' 170 22 200 24 $null $grp
    $lblExample = New-Ctl 'System.Windows.Forms.Label' 380 25 330 20 '' $grp
    $radOriginal = New-Ctl 'System.Windows.Forms.RadioButton' 14 56 400 22 'Original YouTube title' $grp

    $lblFolder = New-Ctl 'System.Windows.Forms.Label' 8 378 70 20 'Save to:' $pgDownload
    $txtFolder = New-Ctl 'System.Windows.Forms.TextBox' 80 376 520 24 $null $pgDownload
    $btnFolder = New-Ctl 'System.Windows.Forms.Button' 608 375 120 26 'Browse...' $pgDownload

    $btnStart = New-Ctl 'System.Windows.Forms.Button' 8 414 150 38 'Download' $pgDownload
    $btnStart.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $btnStop = New-Ctl 'System.Windows.Forms.Button' 166 414 90 38 'Stop' $pgDownload
    $btnStop.Enabled = $false
    $btnOpen = New-Ctl 'System.Windows.Forms.Button' 264 414 120 38 'Open folder' $pgDownload

    $bar = New-Ctl 'System.Windows.Forms.ProgressBar' 8 464 720 18 $null $pgDownload
    $bar.Minimum = 0
    $bar.Maximum = 100
    $lblStatus = New-Ctl 'System.Windows.Forms.Label' 8 486 720 20 'Ready' $pgDownload

    $lblTip = New-Ctl 'System.Windows.Forms.Label' 8 520 720 40 'Tip: open the Queue tab to cut a clip from a video (Premiere-style timecode, down to the frame), reorder links or retry failed ones.' $pgDownload
    $lblTip.ForeColor = [System.Drawing.Color]::Gray

    # ================= QUEUE TAB =================
    $grid = New-Ctl 'System.Windows.Forms.DataGridView' 8 8 720 480 $null $pgQueue
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $true
    $grid.BackgroundColor = [System.Drawing.Color]::White
    $grid.AutoSizeColumnsMode = 'None'
    [void]$grid.Columns.Add('colNum', '#')
    [void]$grid.Columns.Add('colTitle', 'Title')
    [void]$grid.Columns.Add('colStart', 'Start  HH:MM:SS:FF')
    [void]$grid.Columns.Add('colEnd', 'End  HH:MM:SS:FF')
    [void]$grid.Columns.Add('colStatus', 'Status')
    [void]$grid.Columns.Add('colFile', 'File')
    $grid.Columns['colNum'].Width = 34
    $grid.Columns['colTitle'].Width = 240
    $grid.Columns['colStart'].Width = 112
    $grid.Columns['colEnd'].Width = 112
    $grid.Columns['colStatus'].Width = 80
    $grid.Columns['colFile'].Width = 120
    foreach ($col in $grid.Columns) { $col.SortMode = 'NotSortable'; $col.ReadOnly = $true }
    $grid.Columns['colStart'].ReadOnly = $false
    $grid.Columns['colEnd'].ReadOnly = $false
    $grid.Columns['colStart'].ToolTipText = $TcTip
    $grid.Columns['colEnd'].ToolTipText = $TcTip

    $btnRemove = New-Ctl 'System.Windows.Forms.Button' 8 496 130 28 'Remove selected' $pgQueue
    $btnUp = New-Ctl 'System.Windows.Forms.Button' 146 496 80 28 'Move up' $pgQueue
    $btnDown = New-Ctl 'System.Windows.Forms.Button' 232 496 90 28 'Move down' $pgQueue
    $btnRetry = New-Ctl 'System.Windows.Forms.Button' 330 496 150 28 'Retry failed' $pgQueue
    $btnRetry.Enabled = $false

    $lblTcHelp = New-Ctl 'System.Windows.Forms.Label' 8 534 720 40 '(?) Clip part of a video: type Premiere timecode HH:MM:SS:FF in Start / End. Hover here or over the column headers for help. Leave both empty to get the whole video.' $pgQueue
    $lblTcHelp.ForeColor = [System.Drawing.Color]::FromArgb(0, 70, 160)
    $tip.SetToolTip($lblTcHelp, $TcTip)

    # ================= OPTIONS TAB =================
    $lblMode = New-Ctl 'System.Windows.Forms.Label' 12 16 110 20 'Download as:' $pgOptions
    $cmbMode = New-Ctl 'System.Windows.Forms.ComboBox' 130 13 360 24 $null $pgOptions
    $cmbMode.DropDownStyle = 'DropDownList'
    [void]$cmbMode.Items.Add('Video - MP4 (H.264 + AAC, Premiere ready)')
    [void]$cmbMode.Items.Add('Audio only - M4A (AAC)')
    [void]$cmbMode.Items.Add('Audio only - MP3')
    [void]$cmbMode.Items.Add('Audio only - WAV')

    $lblCap = New-Ctl 'System.Windows.Forms.Label' 12 50 110 20 'Max resolution:' $pgOptions
    $cmbCap = New-Ctl 'System.Windows.Forms.ComboBox' 130 47 360 24 $null $pgOptions
    $cmbCap.DropDownStyle = 'DropDownList'
    [void]$cmbCap.Items.Add('1080p (the best H.264 YouTube offers)')
    [void]$cmbCap.Items.Add('720p')
    [void]$cmbCap.Items.Add('480p')

    $chkFallback = New-Ctl 'System.Windows.Forms.CheckBox' 12 86 710 22 'If a video has no H.264 version: download the best one and convert it to H.264 + AAC (slower)' $pgOptions
    $chkSubs = New-Ctl 'System.Windows.Forms.CheckBox' 12 118 220 22 'Download subtitles (SRT)' $pgOptions
    $lblLangs = New-Ctl 'System.Windows.Forms.Label' 250 120 80 20 'Languages:' $pgOptions
    $txtSubLangs = New-Ctl 'System.Windows.Forms.TextBox' 332 117 160 24 $null $pgOptions
    $chkThumbs = New-Ctl 'System.Windows.Forms.CheckBox' 12 150 400 22 'Also save the thumbnail (JPG)' $pgOptions
    $chkArchive = New-Ctl 'System.Windows.Forms.CheckBox' 12 182 710 22 'Skip videos I already downloaded before (remembers video IDs)' $pgOptions

    $lblLimit = New-Ctl 'System.Windows.Forms.Label' 12 216 240 20 'Speed limit in MB/s (0 = no limit):' $pgOptions
    $numLimit = New-Ctl 'System.Windows.Forms.NumericUpDown' 256 213 70 24 $null $pgOptions
    $numLimit.Minimum = 0
    $numLimit.Maximum = 500
    $lblSleep = New-Ctl 'System.Windows.Forms.Label' 12 250 240 20 'Pause between requests (seconds):' $pgOptions
    $numSleep = New-Ctl 'System.Windows.Forms.NumericUpDown' 256 247 70 24 $null $pgOptions
    $numSleep.Minimum = 0
    $numSleep.Maximum = 30

    $grpClips = New-Ctl 'System.Windows.Forms.GroupBox' 12 288 710 100 'Clips (time ranges from the Queue tab)' $pgOptions
    $chkKeepFull = New-Ctl 'System.Windows.Forms.CheckBox' 14 24 680 22 'Keep the full video too (saved with __full in its name)' $grpClips
    $lblCrf = New-Ctl 'System.Windows.Forms.Label' 14 60 380 20 'Clip quality (CRF - lower is better, 14 is near lossless):' $grpClips
    $numCrf = New-Ctl 'System.Windows.Forms.NumericUpDown' 400 57 70 24 $null $grpClips
    $numCrf.Minimum = 10
    $numCrf.Maximum = 28

    $lblOptNote = New-Ctl 'System.Windows.Forms.Label' 12 404 710 40 'Time ranges only work in video mode. Cutting re-encodes the clip so it is frame-accurate.' $pgOptions
    $lblOptNote.ForeColor = [System.Drawing.Color]::Gray

    # ================= SETTINGS TAB =================
    $lblCookie = New-Ctl 'System.Windows.Forms.Label' 12 16 170 20 'YouTube login (cookies):' $pgSettings
    $cmbCookie = New-Ctl 'System.Windows.Forms.ComboBox' 190 13 400 24 $null $pgSettings
    $cmbCookie.DropDownStyle = 'DropDownList'
    [void]$cmbCookie.Items.Add('Auto: try every installed browser (Firefox first)')
    foreach ($b in $BrowserDefs) { [void]$cmbCookie.Items.Add($b.Name) }
    [void]$cmbCookie.Items.Add('cookies.txt file')
    [void]$cmbCookie.Items.Add('None (no login)')

    $lblCookieFile = New-Ctl 'System.Windows.Forms.Label' 12 50 170 20 'cookies.txt file:' $pgSettings
    $txtCookieFile = New-Ctl 'System.Windows.Forms.TextBox' 190 47 400 24 $null $pgSettings
    $btnCookieFile = New-Ctl 'System.Windows.Forms.Button' 598 46 120 26 'Browse...' $pgSettings

    $lblPrivacy = New-Ctl 'System.Windows.Forms.Label' 12 80 710 48 'The login option lets yt-dlp read YouTube cookies from a browser on THIS PC, so YouTube does not block downloads as a bot. Nothing is uploaded anywhere; the cookies stay on this computer.' $pgSettings
    $lblPrivacy.ForeColor = [System.Drawing.Color]::Gray

    $grpTools = New-Ctl 'System.Windows.Forms.GroupBox' 12 134 710 140 'Tools' $pgSettings
    $lblTools = New-Ctl 'System.Windows.Forms.Label' 14 22 680 74 '' $grpTools
    $btnRecheck = New-Ctl 'System.Windows.Forms.Button' 14 100 110 28 'Re-check' $grpTools
    $btnUpdate = New-Ctl 'System.Windows.Forms.Button' 132 100 130 28 'Update tools' $grpTools

    $chkAutoUpdate = New-Ctl 'System.Windows.Forms.CheckBox' 12 290 710 22 'Check for yt-dlp updates automatically (about once a week)' $pgSettings
    $chkSound = New-Ctl 'System.Windows.Forms.CheckBox' 12 320 710 22 'Play a sound when a batch finishes' $pgSettings
    $chkOpenDone = New-Ctl 'System.Windows.Forms.CheckBox' 12 350 710 22 'Open the save folder when a batch finishes' $pgSettings
    $btnClearArchive = New-Ctl 'System.Windows.Forms.Button' 12 388 300 28 'Clear the "already downloaded" history' $pgSettings
    $lblAbout = New-Ctl 'System.Windows.Forms.Label' 12 440 710 40 ('videoprep ' + $AppVersion + ' - uses yt-dlp, FFmpeg and Deno (downloaded on first run).') $pgSettings
    $lblAbout.ForeColor = [System.Drawing.Color]::Gray

    # ================= LOG TAB =================
    $txtLog = New-Ctl 'System.Windows.Forms.TextBox' 8 8 720 534 $null $pgLog
    $txtLog.Multiline = $true
    $txtLog.ReadOnly = $true
    $txtLog.WordWrap = $false
    $txtLog.ScrollBars = 'Both'
    $txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
    $txtLog.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $txtLog.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
    $btnCopyLog = New-Ctl 'System.Windows.Forms.Button' 8 550 110 30 'Copy log' $pgLog
    $btnSaveLog = New-Ctl 'System.Windows.Forms.Button' 124 550 110 30 'Save log...' $pgLog
    $btnClearLog = New-Ctl 'System.Windows.Forms.Button' 240 550 90 30 'Clear' $pgLog
    $btnTest = New-Ctl 'System.Windows.Forms.Button' 338 550 140 30 'Test setup' $pgLog

    # Controls that are locked while something is running
    $LockCtls = @(
        $txtLinks, $btnLoad, $btnClear, $txtFolder, $btnFolder, $radPrefix, $radOriginal, $btnStart,
        $btnRemove, $btnUp, $btnDown,
        $cmbMode, $cmbCap, $chkFallback, $chkSubs, $txtSubLangs, $chkThumbs, $chkArchive,
        $numLimit, $numSleep, $chkKeepFull, $numCrf,
        $cmbCookie, $txtCookieFile, $btnCookieFile, $btnRecheck, $btnUpdate,
        $chkAutoUpdate, $chkSound, $chkOpenDone, $btnClearArchive
    )

    # ---- defaults + saved settings ----
    $defaultFolder = [Environment]::GetFolderPath('MyVideos')
    if (-not $defaultFolder) { $defaultFolder = [Environment]::GetFolderPath('Desktop') }
    $txtFolder.Text = $defaultFolder
    $txtPrefix.Text = 'Video'
    $radPrefix.Checked = $true
    $cmbMode.SelectedIndex = 0
    $cmbCap.SelectedIndex = 0
    $cmbCookie.SelectedIndex = 0
    $chkFallback.Checked = $true
    $txtSubLangs.Text = 'en,es'
    $numLimit.Value = 0
    $numSleep.Value = 1
    $numCrf.Value = 14
    $chkSound.Checked = $true

    $cfg = Read-GuiSettings
    if ($cfg) {
        if ($cfg.folder) { $txtFolder.Text = [string]$cfg.folder }
        if ($cfg.prefix) { $txtPrefix.Text = [string]$cfg.prefix }
        if ($null -ne $cfg.usePrefix) {
            if ([bool]$cfg.usePrefix) { $radPrefix.Checked = $true } else { $radOriginal.Checked = $true }
        }
        if ($null -ne $cfg.cookie) {
            $ci = [int]$cfg.cookie
            if ($ci -ge 0 -and $ci -lt $cmbCookie.Items.Count) { $cmbCookie.SelectedIndex = $ci }
        }
        if ($cfg.cookieFile) { $txtCookieFile.Text = [string]$cfg.cookieFile }
        if ($null -ne $cfg.mode) {
            $mi = [int]$cfg.mode
            if ($mi -ge 0 -and $mi -lt $cmbMode.Items.Count) { $cmbMode.SelectedIndex = $mi }
        }
        if ($null -ne $cfg.cap) {
            $pi = [int]$cfg.cap
            if ($pi -ge 0 -and $pi -lt $cmbCap.Items.Count) { $cmbCap.SelectedIndex = $pi }
        }
        if ($null -ne $cfg.fallback) { $chkFallback.Checked = [bool]$cfg.fallback }
        if ($null -ne $cfg.subs) { $chkSubs.Checked = [bool]$cfg.subs }
        if ($cfg.subLangs) { $txtSubLangs.Text = [string]$cfg.subLangs }
        if ($null -ne $cfg.thumbs) { $chkThumbs.Checked = [bool]$cfg.thumbs }
        if ($null -ne $cfg.archive) { $chkArchive.Checked = [bool]$cfg.archive }
        if ($null -ne $cfg.limit) { Set-Num $numLimit $cfg.limit 0 500 }
        if ($null -ne $cfg.sleep) { Set-Num $numSleep $cfg.sleep 0 30 }
        if ($null -ne $cfg.keepFull) { $chkKeepFull.Checked = [bool]$cfg.keepFull }
        if ($null -ne $cfg.crf) { Set-Num $numCrf $cfg.crf 10 28 }
        if ($null -ne $cfg.autoUpdate) { $chkAutoUpdate.Checked = [bool]$cfg.autoUpdate }
        if ($cfg.lastUpdate) { $S.LastUpdate = [string]$cfg.lastUpdate }
        if ($null -ne $cfg.sound) { $chkSound.Checked = [bool]$cfg.sound }
        if ($null -ne $cfg.openDone) { $chkOpenDone.Checked = [bool]$cfg.openDone }
    }
    $txtPrefix.Enabled = $radPrefix.Checked
    Update-Example

    # ---- events: links box ----
    $selectAll = {
        param($sender, $e)
        if ($e.Control -and $e.KeyCode -eq 'A') {
            $sender.SelectAll()
            $e.SuppressKeyPress = $true
        }
    }
    $txtLinks.Add_KeyDown($selectAll)
    $txtLog.Add_KeyDown($selectAll)
    $txtLinks.Add_TextChanged({ Update-LinkCount })
    $txtLinks.Add_Pasting({ try { Invoke-SmartPaste } catch { } })
    $txtLinks.Add_KeyUp({ try { Show-PreviewForCaret } catch { } })
    $txtLinks.Add_MouseUp({ try { Show-PreviewForCaret } catch { } })
    $txtLinks.Add_DragEnter({
        param($sender, $e)
        $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    })
    $txtLinks.Add_DragDrop({
        param($sender, $e)
        try {
            $txtLinks.SelectionStart = $txtLinks.TextLength
            if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
                foreach ($f in @($e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))) {
                    if ($f -and (Test-Path -LiteralPath $f)) {
                        $txtLinks.SelectionStart = $txtLinks.TextLength
                        [void](Add-LinksFromText (Get-Content -LiteralPath $f -Raw))
                    }
                }
            } elseif ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::Text)) {
                [void](Add-LinksFromText ([string]$e.Data.GetData([System.Windows.Forms.DataFormats]::Text)))
            }
        } catch { }
    })

    $txtPrefix.Add_TextChanged({ Update-Example })
    $radPrefix.Add_CheckedChanged({
        $txtPrefix.Enabled = $radPrefix.Checked
        Update-Example
    })

    $btnClear.Add_Click({ $txtLinks.Clear() })

    $btnLoad.Add_Click({
        $d = New-Object System.Windows.Forms.OpenFileDialog
        $d.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
        if ($d.ShowDialog() -eq 'OK') {
            $content = Get-Content -LiteralPath $d.FileName -Raw
            $txtLinks.SelectionStart = $txtLinks.TextLength
            if (-not (Add-LinksFromText $content)) {
                [void](Show-Msg 'No links were found in that file.' 'videoprep' 'OK' 'Information')
            }
        }
    })

    $btnFolder.Add_Click({
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Choose where to save the videos'
        $d.ShowNewFolderButton = $true
        if ($txtFolder.Text -and (Test-Path -LiteralPath $txtFolder.Text)) { $d.SelectedPath = $txtFolder.Text }
        if ($d.ShowDialog() -eq 'OK') { $txtFolder.Text = $d.SelectedPath }
    })

    $btnOpen.Add_Click({
        $f = $txtFolder.Text.Trim('" ')
        if ($f -and (Test-Path -LiteralPath $f)) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $f) }
        else { [void](Show-Msg 'That folder does not exist yet.' 'videoprep' 'OK' 'Information') }
    })

    $btnStart.Add_Click({ Start-Batch })

    $btnStop.Add_Click({
        if ($S.Runner) {
            $S.Cancelled = $true
            $S.Runner.Kill()
            $lblStatus.Text = 'Stopping...'
        }
    })

    # ---- events: queue tab ----
    $tabs.Add_SelectedIndexChanged({
        if ($tabs.SelectedTab -eq $pgQueue) { try { Update-QueueGrid } catch { } }
    })

    $grid.Add_DataError({
        param($sender, $e)
        $e.ThrowException = $false
    })

    $grid.Add_CellEndEdit({
        param($sender, $e)
        try {
            $row = $grid.Rows[$e.RowIndex]
            $key = [string]$row.Tag
            if (-not $Ranges.ContainsKey($key)) { $Ranges[$key] = @{ Start = ''; End = '' } }
            $Ranges[$key].Start = [string]$row.Cells['colStart'].Value
            $Ranges[$key].End = [string]$row.Cells['colEnd'].Value
            Test-RangeCells $row
        } catch { }
    })

    $btnRemove.Add_Click({ try { Remove-SelectedQueueRows } catch { } })
    $btnUp.Add_Click({ try { Move-QueueRow -1 } catch { } })
    $btnDown.Add_Click({ try { Move-QueueRow 1 } catch { } })
    $btnRetry.Add_Click({ Start-Retry })

    # ---- events: settings tab ----
    $btnCookieFile.Add_Click({
        $d = New-Object System.Windows.Forms.OpenFileDialog
        $d.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
        if ($d.ShowDialog() -eq 'OK') {
            $txtCookieFile.Text = $d.FileName
            $cmbCookie.SelectedIndex = $BrowserDefs.Count + 1
        }
    })

    $btnRecheck.Add_Click({ Update-ToolStatus })

    $btnUpdate.Add_Click({
        Update-Tools
        if (-not $T.YtDlp) {
            [void](Show-Msg 'The tools are not installed yet. Press Download once and the app will install them.' 'videoprep' 'OK' 'Information')
            return
        }
        $S.LastUpdate = (Get-Date).ToString('o')
        $tabs.SelectedTab = $pgLog
        [void](Start-UpdateRun)
    })

    $btnClearArchive.Add_Click({
        $ans = Show-Msg 'Forget which videos were downloaded before? Videos you already have can then be downloaded again.' 'videoprep' 'YesNo' 'Question'
        if ($ans -eq 'Yes') {
            if (Test-Path -LiteralPath $ArchiveFile) { Remove-Item -LiteralPath $ArchiveFile -Force -ErrorAction SilentlyContinue }
            Write-Log 'History of downloaded videos cleared.'
        }
    })

    # ---- events: log tab ----
    $btnCopyLog.Add_Click({
        if ($txtLog.Text) { try { [System.Windows.Forms.Clipboard]::SetText($txtLog.Text) } catch { } }
    })
    $btnSaveLog.Add_Click({
        $d = New-Object System.Windows.Forms.SaveFileDialog
        $d.Filter = 'Text files (*.txt)|*.txt'
        $d.FileName = 'videoprep-log.txt'
        if ($d.ShowDialog() -eq 'OK') {
            try { Set-Content -LiteralPath $d.FileName -Value $txtLog.Text -Encoding UTF8 } catch { }
        }
    })
    $btnClearLog.Add_Click({ $txtLog.Clear() })
    $btnTest.Add_Click({ try { Invoke-TestSetup } catch { Write-Log ('Test failed: ' + $_.Exception.Message) } })

    # ---- timer, closing, startup ----
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 150
    $timer.Add_Tick({
        try { Invoke-Tick }
        catch { Write-Log ('Internal error: ' + $_.Exception.Message) }
        try { Invoke-PreviewTick } catch { }
    })
    $timer.Start()

    $form.Add_FormClosing({
        param($sender, $e)
        if ($S.Runner -and -not $S.Runner.Done) {
            $ans = Show-Msg 'Something is still running. Stop it and exit?' 'videoprep' 'YesNo' 'Question'
            if ($ans -ne 'Yes') { $e.Cancel = $true; return }
            $S.Cancelled = $true
            $S.Runner.Kill()
        }
        Stop-DetailRun
        Save-GuiSettings
    })

    $form.Add_Shown({
        Clear-PreviewPanel
        Update-LinkCount
        Update-ToolStatus
        $missing = @(Get-MissingTools)
        if ($missing.Count -gt 0) {
            Write-Log ('First run: press Download and the app will fetch what it needs (' + ($missing -join ', ') + ', about 200 MB, once).')
        } else {
            Write-Log 'Ready. Paste links, choose a name style and folder, press Download.'
        }
        $found = @($BrowserDefs | Where-Object { Test-Path -LiteralPath $_.Path } | ForEach-Object { $_.Name })
        if ($found.Count -gt 0) { Write-Log ('Browsers found on this PC: ' + ($found -join ', ')) }

        if ($chkAutoUpdate.Checked -and $missing.Count -eq 0) {
            $due = $true
            if ($S.LastUpdate) {
                try {
                    $last = [datetime]::Parse($S.LastUpdate, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                    if (((Get-Date) - $last).TotalDays -lt 7) { $due = $false }
                } catch { }
            }
            if ($due) {
                $S.LastUpdate = (Get-Date).ToString('o')
                [void](Start-UpdateRun)
                Save-GuiSettings
            }
        }
    })

    [void]$form.ShowDialog()
}
catch {
    [System.Windows.Forms.MessageBox]::Show(("The program hit an error:`n`n" + $_.Exception.Message + "`n`n" + $_.ScriptStackTrace), 'videoprep', 'OK', 'Error') | Out-Null
}
