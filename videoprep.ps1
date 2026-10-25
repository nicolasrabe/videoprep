# =====================================================================
#  videoprep.ps1 - prepare videos for editing (v0.1.1)
#  Paste a link, pick format, clips and names, send to the queue, download.
#  Output is edit-friendly: MP4/MOV (H.264 or ProRes), WebM, MKV, audio.
#  Clips use Premiere timecode HH:MM:SS:FF. Saved as UTF-8 with BOM.
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
    private string cue = "";

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);

    public string CueText
    {
        get { return cue; }
        set
        {
            cue = value == null ? "" : value;
            if (IsHandleCreated) { SendMessage(Handle, 0x1501, (IntPtr)1, cue); }
        }
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        if (cue.Length > 0) { SendMessage(Handle, 0x1501, (IntPtr)1, cue); }
    }

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

    public void FetchThumb(string id, string url)
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
                    wc.Headers[HttpRequestHeader.UserAgent] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)";
                    it.Thumb = wc.DownloadData(url);
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
$AppVersion = '0.1.1'
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
    Groups = @{}
    PostSrc = ''; PostTmp = ''; PostDir = ''; PostBase = ''; PostExt = ''; PostNote = ''
    LastUpdate = ''
}

$Pref = @{ Browser = $null }

$P = @{
    Id = $null; Cache = @{}; Fetcher = (New-Object PreviewFetcher)
    Runner = $null; RunnerId = $null; RunnerStart = (Get-Date)
    Browsers = @(); BIdx = 0; DetOut = $null; DetLine = $null
}

# User options (the Options window) and appearance
$lang0 = 'en'
try { if ([System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'es') { $lang0 = 'es' } } catch { }
$Opt = @{
    Subs = $false; SubLangs = 'en,es'; Thumbs = $false; Archive = $false
    Fallback = $true; KeepFull = $false; Crf = 14; Limit = 0; Sleep = 1
    Theme = 'light'; CustomColor = '#d9e1ea'; Lang = $lang0
    Sound = $true; OpenDone = $false; AutoUpdate = $false
}

# Queue (items), the link being prepared (draft) and clip rows
$Items = New-Object System.Collections.ArrayList
$Draft = @{ Url = ''; Id = ''; EditId = 0 }
$Counter = @{ Item = 0 }
$ClipRows = New-Object System.Collections.ArrayList
$LangMap = New-Object System.Collections.ArrayList
$UiState = @{ FmtNow = @(); Busy = $false }
$RowStatus = @{}
$RowFile   = @{}

$FormatKeys = @{ video = @('mp4', 'movh', 'movp', 'webm', 'mkv'); audio = @('m4a', 'mp3', 'wav', 'flac', 'opus') }
$FormatLabels = @{ mp4 = 'MP4 - H.264 + AAC'; movh = 'MOV - H.264 + AAC'; movp = 'MOV - ProRes 422 HQ'; webm = 'WebM - VP9 + Opus'; mkv = 'MKV'; m4a = 'M4A (AAC)'; mp3 = 'MP3'; wav = 'WAV'; flac = 'FLAC'; opus = 'Opus' }
$FormatExt = @{ mp4 = '.mp4'; movh = '.mov'; movp = '.mov'; webm = '.webm'; mkv = '.mkv'; m4a = '.m4a'; mp3 = '.mp3'; wav = '.wav'; flac = '.flac'; opus = '.opus' }
$ResMap = @{ '4K' = 2160; '1440p' = 1440; '1080p' = 1080; '720p' = 720; '480p' = 480 }
$KnownHosts = '^(?:www\.|m\.|mobile\.|clips\.|go\.)?(?:twitch\.tv|kick\.com|x\.com|twitter\.com|facebook\.com|fb\.watch|instagram\.com|tiktok\.com|vimeo\.com|reddit\.com|dailymotion\.com)/'
$ThemeNames = @('light', 'dark', 'beige', 'gray', 'slate', 'custom')

$ThemeHex = @{
    light = @{ bg = '#f1f1ee'; card = '#ffffff'; inp = '#ffffff'; tx = '#1f1f1d'; mu = '#6b6b66'; bd = '#d6d6cf'; gb = '#cdeccf'; gt = '#1f5a26'; rb = '#f6cccc'; rt = '#7a1f1f'; ob = '#fbddb8'; ot = '#7a4510' }
    dark  = @{ bg = '#1e1f22'; card = '#2a2b2f'; inp = '#1e1f22'; tx = '#e8e8e6'; mu = '#a0a09b'; bd = '#3b3c41'; gb = '#2f5a33'; gt = '#cdeccf'; rb = '#5e2f2f'; rt = '#f6cccc'; ob = '#5e4426'; ot = '#fbddb8' }
    beige = @{ bg = '#eadfca'; card = '#f6efe0'; inp = '#fbf7ee'; tx = '#3b3226'; mu = '#7a6c58'; bd = '#d3c5aa'; gb = '#cfe6c4'; gt = '#2f5a26'; rb = '#f2cfc4'; rt = '#7a2b1f'; ob = '#f7d9a8'; ot = '#7a4510' }
    gray  = @{ bg = '#dcdcdc'; card = '#eeeeee'; inp = '#fafafa'; tx = '#222222'; mu = '#666666'; bd = '#c2c2c2'; gb = '#cdeccf'; gt = '#1f5a26'; rb = '#f6cccc'; rt = '#7a1f1f'; ob = '#fbddb8'; ot = '#7a4510' }
    slate = @{ bg = '#d9e1ea'; card = '#e9eef4'; inp = '#f7f9fb'; tx = '#1f2a37'; mu = '#5b6b7d'; bd = '#bcc8d6'; gb = '#cdeccf'; gt = '#1f5a26'; rb = '#f6cccc'; rt = '#7a1f1f'; ob = '#fbddb8'; ot = '#7a4510' }
}

# ---------------------------------------------------------------------
#  Texts (Spanish / English)
# ---------------------------------------------------------------------
$I18N = @{}
$I18N['es'] = @{
    tab_dl = 'Descargar'; tab_q = 'Cola'; tab_st = 'Ajustes'; tab_log = 'Registro'
    ph_link = 'pegá acá tu enlace o ID de video'
    lbl_type = 'Tipo'; rad_video = 'Video'; rad_audio = 'Solo audio'; lbl_fmt = 'Formato'; lbl_res = 'Resolución máx.'
    lbl_clips = 'Fragmentos (vacío = video completo)'; btn_addclip = 'Agregar fragmento'; lbl_start = 'Inicio'; lbl_end = 'Fin'
    prev_hint = 'Pegá un enlace de YouTube para ver la vista previa'
    prev_loading = 'Cargando vista previa...'; prev_none = 'Sin vista previa para este enlace'
    prev_none2 = 'Puede ser privado o eliminado, pedir iniciar sesión, o no estar soportado.'
    prev_check = 'Revisando la calidad disponible...'; prev_noformat = 'No hay versión H.264 (activá la conversión en Opciones).'
    prev_fail = 'No se pudo revisar la calidad.'; prev_audio = 'Se descargará: audio {0}'; prev_will = 'Se descargará: {0}'; prev_conv = ' (se convertirá)'
    lbl_names = 'Nombre de los archivos'; rad_n1 = 'Título original del video'; rad_n2 = 'Título personalizado'; rad_n3 = 'Serie (nombre + número)'
    ex_label = 'Ejemplo: '; ex_orig_title = 'Título del video'
    btn_options = 'Opciones...'; btn_send = 'Enviar a la cola'; tip_folder = 'Abrir carpeta'; btn_browse = 'Examinar...'
    lbl_saveto = 'Guardar en'; btn_download = 'Descargar'; btn_stop = 'Detener'
    st_ready = 'Todo listo'; st_done = 'Terminado: {0} bien, {1} para revisar, {2} con error'; st_stopped = 'Detenido'; st_stopping = 'Deteniendo...'
    st_progress = 'Video {0}/{1}  |  {2} %  |  {3}  |  faltan {4}'; st_starting = 'Video {0}/{1}  |  iniciando...'
    st_cutting = 'Video {0}/{1}  |  procesando el archivo...'; st_setup = 'Descargando las herramientas necesarias (solo la primera vez)...'; st_setupfail = 'Falló la instalación'
    rs_Queued = 'En cola'; rs_Downloading = 'Descargando'; rs_Cutting = 'Procesando...'; rs_OK = 'Listo'; rs_WARN = 'Revisar'; rs_REVIEW = 'Revisar'; rs_ERROR = 'Error'; rs_Skipped = 'Omitido'
    col_num = '#'; col_name = 'Nombre'; col_fmt = 'Formato'; col_clip = 'Fragmento'; col_status = 'Estado'; col_file = 'Archivo'
    clip_whole = 'Video completo'; clip_end = 'final'; clip_start = 'inicio'
    btn_edit = 'Editar'; btn_remove = 'Quitar'; btn_up = 'Subir'; btn_down = 'Bajar'; btn_retry = 'Reintentar los fallidos'; btn_loadtxt = 'Cargar .txt...'; btn_clearq = 'Vaciar la cola'
    lbl_qhelp = 'Cada fila es un video o un fragmento. Con Editar volvés a la pestaña Descargar para cambiar los fragmentos, el formato o el nombre.'
    dlg_options = 'Opciones'; opt_subs = 'Descargar subtítulos (SRT)'; opt_langs = 'Idiomas:'; opt_thumbs = 'Guardar también la miniatura (JPG)'
    opt_skip = 'Omitir los videos que ya descargué antes'; opt_conv = 'Si no hay H.264, convertir a H.264 + AAC (más lento)'
    opt_keep = 'Conservar también el video completo (cuando hay fragmentos)'
    opt_crf = 'Calidad de los fragmentos (CRF; menor = mejor, 14 casi sin pérdida):'
    opt_limit = 'Límite de velocidad en MB/s (0 = sin límite):'; opt_sleep = 'Pausa entre pedidos (segundos):'
    btn_ok = 'Aceptar'; btn_cancel = 'Cancelar'
    lbl_cookies = 'Inicio de sesión de YouTube (cookies):'; ck_auto = 'Automático: probar todos los navegadores instalados (Firefox primero)'
    ck_file = 'Archivo cookies.txt'; ck_none = 'Ninguno (sin sesión)'; lbl_cookiefile = 'Archivo cookies.txt:'
    txt_privacy = 'La opción de sesión permite que yt-dlp lea las cookies de YouTube de un navegador de ESTA PC, para que YouTube no bloquee la descarga como si fuera un robot. No se sube nada a ningún lado: las cookies quedan en tu computadora.'
    grp_tools = 'Herramientas'; btn_recheck = 'Volver a revisar'; btn_update = 'Actualizar herramientas'
    chk_autoupdate = 'Buscar actualizaciones de yt-dlp automáticamente (una vez por semana)'
    chk_sound = 'Reproducir un sonido al terminar'; chk_opendone = 'Abrir la carpeta al terminar'; btn_cleararchive = 'Borrar el historial de videos descargados'
    lbl_theme = 'Tema:'; th_light = 'Claro'; th_dark = 'Oscuro'; th_beige = 'Beige'; th_gray = 'Gris'; th_slate = 'Azul grisáceo'; th_custom = 'Personalizado'
    btn_pickcolor = 'Elegir color...'; lbl_lang = 'Idioma:'
    txt_about = 'videoprep {0} - usa yt-dlp, FFmpeg y Deno (se descargan la primera vez).'
    btn_copylog = 'Copiar registro'; btn_savelog = 'Guardar registro...'; btn_clearlog = 'Limpiar'; btn_test = 'Probar la instalación'
    msg_nofolder_sel = 'Elegí una carpeta para guardar los videos.'
    msg_empty = 'La cola está vacía. Pegá un enlace y apretá Enviar a la cola.'
    msg_prefix = 'Escribí el nombre de la serie, por ejemplo: Fragmento'
    msg_custom = 'Escribí el título personalizado.'
    msg_badtc = 'Fragmento {0}: "{1}" no es un código de tiempo válido.{2}Usá HH:MM:SS:FF, por ejemplo 00:01:23:15. Pasá el mouse por el signo ? para ver la ayuda.'
    msg_setup = 'Configuración inicial: videoprep necesita descargar algunas herramientas gratuitas ({0}).{1}Son unos 200 MB y solo pasa una vez. ¿Descargarlas ahora?'
    msg_setup_title = 'Configuración inicial'
    msg_exists = 'Esta carpeta ya tiene archivos como {0}1, {0}2... (hasta {0}{1}).{2}Sí = seguir la numeración desde {0}{3}{2}No = cancelar (no se pisa nada)'
    msg_exists_title = 'Archivos existentes'
    msg_cantcreate = 'No se pudo crear la carpeta:{0}'
    msg_nofolder = 'Esa carpeta todavía no existe.'
    msg_tools_missing = 'Todavía no están instaladas las herramientas. Apretá Descargar una vez y se instalan solas.'
    msg_running = 'Todavía hay algo en curso. ¿Detenerlo y salir?'
    msg_cleararchive = '¿Olvidar qué videos se descargaron antes? Después se pueden volver a descargar.'
    msg_nolinks = 'No se encontraron enlaces en ese archivo.'
    msg_nolink_draft = 'Primero pegá un enlace.'
    msg_sel_one = 'Elegí una fila de la cola.'
    tip_tc = @'
FRAGMENTOS  (código de tiempo como en Premiere)

Formato:  HH:MM:SS:FF  = horas : minutos : segundos : fotogramas
Ejemplo:  00:01:23:15  = 1 minuto, 23 segundos y 15 fotogramas

El último número cuenta FOTOGRAMAS dentro de ese segundo (de 0 a fps-1),
así que podés cortar en el fotograma exacto. A 30 fps van de 00 a 29,
a 60 fps van de 00 a 59.

Inicio = primer fotograma que querés.
Fin    = último fotograma que querés (se incluye).
Dejá Fin vacío para llegar hasta el final del video.
Si no agregás fragmentos, se descarga el video completo.

Atajo de escritura (como en Premiere): los números se llenan desde la derecha.
    1523  ->  00:00:15:23        100  ->  00:00:01:00

Desde el final: empezá con un signo menos.
    Inicio  -00:00:00:15   (Fin vacío) = los ÚLTIMOS 15 FOTOGRAMAS
    Inicio  -00:00:01:00   (Fin vacío) = el último segundo

Usá punto y coma (00;01;23;15) para código de tiempo con descarte
de fotogramas (drop frame, 29,97 / 59,94 fps).

Los fragmentos se cortan DESPUÉS de la descarga, con la velocidad real
del video, así que son exactos al fotograma. Se vuelven a codificar
según el formato elegido.
'@
    h_mp4 = 'Compatible con Premiere Pro y casi todo. Hasta 1080p.'
    h_movh = 'Misma calidad que MP4 en contenedor MOV, sin recomprimir. Hasta 1080p.'
    h_movp = 'Para editar con fluidez. Archivos muy grandes (aprox. 100 GB por hora a 1080p30). Hasta 4K.'
    h_webm = 'VP9 + Opus tal como los da YouTube. Hasta 4K. Premiere puede no abrirlo.'
    h_mkv = 'Contenedor flexible. Hasta 4K. Premiere puede no abrirlo.'
    h_m4a = 'AAC sin recomprimir (calidad original de YouTube).'; h_mp3 = 'Compatible con todo. Recomprime el audio.'
    h_wav = 'Sin compresión, ideal para editar. Archivos grandes.'; h_flac = 'Sin pérdidas y más liviano que WAV.'; h_opus = 'Calidad original de YouTube y liviano.'
}
$I18N['en'] = @{
    tab_dl = 'Download'; tab_q = 'Queue'; tab_st = 'Settings'; tab_log = 'Log'
    ph_link = 'paste your link or video ID here'
    lbl_type = 'Type'; rad_video = 'Video'; rad_audio = 'Audio only'; lbl_fmt = 'Format'; lbl_res = 'Max resolution'
    lbl_clips = 'Clips (empty = whole video)'; btn_addclip = 'Add clip'; lbl_start = 'Start'; lbl_end = 'End'
    prev_hint = 'Paste a YouTube link to see a preview'
    prev_loading = 'Loading preview...'; prev_none = 'No preview for this link'
    prev_none2 = 'It may be private or removed, need a login, or not be supported.'
    prev_check = 'Checking available quality...'; prev_noformat = 'No H.264 version offered (turn on the conversion in Options).'
    prev_fail = 'Quality check unavailable.'; prev_audio = 'Will download: {0} audio'; prev_will = 'Will download: {0}'; prev_conv = ' (will be converted)'
    lbl_names = 'File names'; rad_n1 = 'Original video title'; rad_n2 = 'Custom title'; rad_n3 = 'Series (name + number)'
    ex_label = 'Example: '; ex_orig_title = 'Video title'
    btn_options = 'Options...'; btn_send = 'Send to queue'; tip_folder = 'Open folder'; btn_browse = 'Browse...'
    lbl_saveto = 'Save to'; btn_download = 'Download'; btn_stop = 'Stop'
    st_ready = 'Ready'; st_done = 'Done: {0} OK, {1} to review, {2} failed'; st_stopped = 'Stopped'; st_stopping = 'Stopping...'
    st_progress = 'Video {0}/{1}  |  {2}%  |  {3}  |  ETA {4}'; st_starting = 'Video {0}/{1}  |  starting...'
    st_cutting = 'Video {0}/{1}  |  processing the file...'; st_setup = 'Downloading the required tools (first time only)...'; st_setupfail = 'Setup failed'
    rs_Queued = 'Queued'; rs_Downloading = 'Downloading'; rs_Cutting = 'Processing...'; rs_OK = 'Done'; rs_WARN = 'Review'; rs_REVIEW = 'Review'; rs_ERROR = 'Error'; rs_Skipped = 'Skipped'
    col_num = '#'; col_name = 'Name'; col_fmt = 'Format'; col_clip = 'Clip'; col_status = 'Status'; col_file = 'File'
    clip_whole = 'Whole video'; clip_end = 'end'; clip_start = 'start'
    btn_edit = 'Edit'; btn_remove = 'Remove'; btn_up = 'Move up'; btn_down = 'Move down'; btn_retry = 'Retry failed'; btn_loadtxt = 'Load .txt...'; btn_clearq = 'Clear queue'
    lbl_qhelp = 'Each row is a video or a clip. Edit takes you back to the Download tab to change the clips, format or name.'
    dlg_options = 'Options'; opt_subs = 'Download subtitles (SRT)'; opt_langs = 'Languages:'; opt_thumbs = 'Also save the thumbnail (JPG)'
    opt_skip = 'Skip videos I already downloaded before'; opt_conv = 'If there is no H.264, convert to H.264 + AAC (slower)'
    opt_keep = 'Also keep the full video (when there are clips)'
    opt_crf = 'Clip quality (CRF; lower = better, 14 is near lossless):'
    opt_limit = 'Speed limit in MB/s (0 = no limit):'; opt_sleep = 'Pause between requests (seconds):'
    btn_ok = 'OK'; btn_cancel = 'Cancel'
    lbl_cookies = 'YouTube login (cookies):'; ck_auto = 'Automatic: try every installed browser (Firefox first)'
    ck_file = 'cookies.txt file'; ck_none = 'None (no login)'; lbl_cookiefile = 'cookies.txt file:'
    txt_privacy = 'The login option lets yt-dlp read YouTube cookies from a browser on THIS PC, so YouTube does not block downloads as if you were a bot. Nothing is uploaded anywhere; the cookies stay on this computer.'
    grp_tools = 'Tools'; btn_recheck = 'Check again'; btn_update = 'Update tools'
    chk_autoupdate = 'Check for yt-dlp updates automatically (once a week)'
    chk_sound = 'Play a sound when a batch finishes'; chk_opendone = 'Open the folder when a batch finishes'; btn_cleararchive = 'Clear the downloaded videos history'
    lbl_theme = 'Theme:'; th_light = 'Light'; th_dark = 'Dark'; th_beige = 'Beige'; th_gray = 'Gray'; th_slate = 'Slate blue'; th_custom = 'Custom'
    btn_pickcolor = 'Pick color...'; lbl_lang = 'Language:'
    txt_about = 'videoprep {0} - uses yt-dlp, FFmpeg and Deno (downloaded on first run).'
    btn_copylog = 'Copy log'; btn_savelog = 'Save log...'; btn_clearlog = 'Clear'; btn_test = 'Test setup'
    msg_nofolder_sel = 'Choose a folder to save the videos in.'
    msg_empty = 'The queue is empty. Paste a link and press Send to queue.'
    msg_prefix = 'Type the series name, for example: Clip'
    msg_custom = 'Type the custom title.'
    msg_badtc = 'Clip {0}: "{1}" is not a valid timecode.{2}Use HH:MM:SS:FF, for example 00:01:23:15. Hover over the ? sign for help.'
    msg_setup = 'First-time setup: videoprep needs to download a few free tools ({0}).{1}It is about 200 MB and only happens once. Download now?'
    msg_setup_title = 'First-time setup'
    msg_exists = 'This folder already has files like {0}1, {0}2... (up to {0}{1}).{2}Yes = continue numbering from {0}{3}{2}No = cancel (nothing is overwritten)'
    msg_exists_title = 'Existing files'
    msg_cantcreate = 'Could not create the folder:{0}'
    msg_nofolder = 'That folder does not exist yet.'
    msg_tools_missing = 'The tools are not installed yet. Press Download once and they install themselves.'
    msg_running = 'Something is still running. Stop it and exit?'
    msg_cleararchive = 'Forget which videos were downloaded before? They can then be downloaded again.'
    msg_nolinks = 'No links were found in that file.'
    msg_nolink_draft = 'Paste a link first.'
    msg_sel_one = 'Pick a row in the queue.'
    tip_tc = @'
CLIPS  (Premiere-style timecode)

Format:   HH:MM:SS:FF   = hours : minutes : seconds : frames
Example:  00:01:23:15   = 1 minute, 23 seconds and 15 frames

The last number counts FRAMES inside that second (0 up to fps-1),
so you can cut to the exact frame. At 30 fps the frames go 00-29,
at 60 fps they go 00-59.

Start = first frame you want.
End   = last frame you want (this frame is included).
Leave End empty to go until the end of the video.
If you add no clips, the whole video is downloaded.

Typing shortcut (like Premiere): numbers fill from the right.
    1523  ->  00:00:15:23        100  ->  00:00:01:00

From the end: start with a minus sign.
    Start  -00:00:00:15   (End empty) = the LAST 15 FRAMES
    Start  -00:00:01:00   (End empty) = the last second

Use semicolons (00;01;23;15) for drop-frame timecode (29.97 / 59.94 fps).

Clips are cut AFTER the download using the video's real frame rate,
so they are frame-accurate. They are re-encoded to the chosen format.
'@
    h_mp4 = 'Works in Premiere Pro and almost everything. Up to 1080p.'
    h_movh = 'Same quality as MP4 in a MOV container, no re-encoding. Up to 1080p.'
    h_movp = 'For smooth editing. Very large files (about 100 GB per hour at 1080p30). Up to 4K.'
    h_webm = 'VP9 + Opus exactly as YouTube serves them. Up to 4K. Premiere may not open it.'
    h_mkv = 'Flexible container. Up to 4K. Premiere may not open it.'
    h_m4a = 'AAC without re-encoding (original YouTube quality).'; h_mp3 = 'Plays everywhere. Re-encodes the audio.'
    h_wav = 'Uncompressed, great for editing. Large files.'; h_flac = 'Lossless and smaller than WAV.'; h_opus = 'Original YouTube quality and small.'
}

# ---------------------------------------------------------------------
#  Small helpers
# ---------------------------------------------------------------------
function Tx([string]$k) {
    $d = $I18N[$Opt.Lang]
    if ($d -and $d.ContainsKey($k)) { return $d[$k] }
    $d2 = $I18N['en']
    if ($d2.ContainsKey($k)) { return $d2[$k] }
    return $k
}

function Show-Msg([string]$text, [string]$title = 'videoprep', [string]$buttons = 'OK', [string]$icon = 'Information') {
    return [System.Windows.Forms.MessageBox]::Show($form, $text, $title, $buttons, $icon)
}

function Get-SafeName([string]$text) {
    $n = ($text -replace '[\\/:*?"<>|%]', '').Trim()
    if ($n -eq '') { return 'video' }
    return $n
}

function Get-ExtFor([string]$fmt) {
    if ($FormatExt.ContainsKey($fmt)) { return $FormatExt[$fmt] }
    return '.mp4'
}

function Get-FormatKind([string]$fmt) {
    if ($FormatKeys['audio'] -contains $fmt) { return 'audio' }
    return 'video'
}

function ConvertFrom-Hex([string]$h) {
    $h = $h.TrimStart('#')
    return [System.Drawing.Color]::FromArgb([Convert]::ToInt32($h.Substring(0, 2), 16), [Convert]::ToInt32($h.Substring(2, 2), 16), [Convert]::ToInt32($h.Substring(4, 2), 16))
}

function Mix-Color($a, $b, [double]$t) {
    return [System.Drawing.Color]::FromArgb(
        [int]($a.R + ($b.R - $a.R) * $t), [int]($a.G + ($b.G - $a.G) * $t), [int]($a.B + ($b.B - $a.B) * $t))
}

function New-CustomPalette([string]$hex) {
    $bg = ConvertFrom-Hex $hex
    $lum = (0.299 * $bg.R + 0.587 * $bg.G + 0.114 * $bg.B) / 255
    $base = $ThemeHex['light']
    if ($lum -lt 0.5) { $base = $ThemeHex['dark'] }
    $p = @{}
    foreach ($k in $base.Keys) { $p[$k] = ConvertFrom-Hex $base[$k] }
    $p['bg'] = $bg
    $white = [System.Drawing.Color]::White
    $black = [System.Drawing.Color]::Black
    if ($lum -lt 0.5) {
        $p['card'] = Mix-Color $bg $white 0.08
        $p['inp'] = Mix-Color $bg $black 0.15
        $p['bd'] = Mix-Color $bg $white 0.25
    } else {
        $p['card'] = Mix-Color $bg $white 0.6
        $p['inp'] = Mix-Color $bg $white 0.8
        $p['bd'] = Mix-Color $bg $black 0.15
    }
    return $p
}

function Get-Palette([string]$name) {
    if ($name -eq 'custom') {
        try { return (New-CustomPalette $Opt.CustomColor) } catch { $name = 'light' }
    }
    $h = $ThemeHex[$name]
    if (-not $h) { $h = $ThemeHex['light'] }
    $p = @{}
    foreach ($k in $h.Keys) { $p[$k] = ConvertFrom-Hex $h[$k] }
    return $p
}

function Get-ExpectedCodecs([string]$fmt, [string]$kind) {
    if ($kind -eq 'audio') { return $null }
    switch ($fmt) {
        'mp4'  { return @{ V = 'h264'; A = 'aac' } }
        'movh' { return @{ V = 'h264'; A = 'aac' } }
        'movp' { return @{ V = 'prores'; A = 'pcm_s24le' } }
        'webm' { return @{ V = 'vp9'; A = 'opus' } }
    }
    return $null
}

function Find-ResultFile([string]$folder, [datetime]$since) {
    $since = $since.AddSeconds(-3)
    $cand = Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LastWriteTime -ge $since -and
            $_.Extension -match '^\.(mp4|mkv|webm|mov|m4a|mp3|wav|aac|opus|flac|ogg)$' -and
            $_.Name -notmatch '\.f\d+\.' -and
            $_.Name -notmatch '\.__tmp\.'
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    return $cand
}

function Get-MediaInfo([string]$path, [string]$ev = '', [string]$ea = '') {
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
        if ([int]$Matches[2] -ne 0) { $fps = ('{0:0.##} fps' -f ([double]$Matches[1] / [double]$Matches[2])) }
    }
    $size = ''
    if ($vi['width']) { $size = ('{0}x{1}' -f $vi['width'], $vi['height']) }
    $vc = $vi['codec_name']
    $ac = $ai['codec_name']
    $res.Text = ('video {0} {1} {2} | audio {3}' -f $vc, $size, $fps, $ac)
    if ($ev -and $vc -ne $ev) { $res.Warn = $true }
    if ($ea -and $ac -ne $ea) { $res.Warn = $true }
    return $res
}

# Timing of an audio-only file, using the video's frame rate for the timecodes
function Get-AudioTiming([string]$path, $fps) {
    $r = @{ Ok = $false; Num = 30; Den = 1; Base = 30; Ntsc = $false; Total = [int64]0; VCodec = ''; ACodec = ''; Error = '' }
    $f = 30.0
    if ($fps -and [double]$fps -gt 0) { $f = [double]$fps }
    if ([math]::Abs($f - 29.97) -lt 0.02) { $r.Num = 30000; $r.Den = 1001; $r.Base = 30; $r.Ntsc = $true }
    elseif ([math]::Abs($f - 59.94) -lt 0.02) { $r.Num = 60000; $r.Den = 1001; $r.Base = 60; $r.Ntsc = $true }
    elseif ([math]::Abs($f - 23.976) -lt 0.02) { $r.Num = 24000; $r.Den = 1001; $r.Base = 24; $r.Ntsc = $true }
    else { $r.Num = [int][math]::Round($f); $r.Den = 1; $r.Base = $r.Num }
    $ff = $T.Ffprobe
    if (-not $ff) { $r.Error = 'ffprobe not found'; return $r }
    try {
        $fi = @(& $ff -v error -show_entries format=duration -of default=noprint_wrappers=1 $path 2>$null)
        $ai = @(& $ff -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1 $path 2>$null)
    } catch { $r.Error = 'ffprobe failed'; return $r }
    $dur = $null
    foreach ($l in $fi) { if ($l -match '^duration=(\d+(\.\d+)?)$') { $dur = [double]$Matches[1] } }
    foreach ($l in $ai) { if ($l -match '^codec_name=(.+)$') { $r.ACodec = $Matches[1] } }
    if ($null -eq $dur) { $r.Error = 'could not read the audio length'; return $r }
    $r.Total = [int64][math]::Floor($dur * $r.Num / $r.Den)
    if ($r.Total -lt 1) { $r.Error = 'the file has no length'; return $r }
    $r.Ok = $true
    return $r
}

# yt-dlp arguments for one job (format, quality cap, container)
function Get-DownloadArgs($job) {
    if ($job.Kind -eq 'audio') {
        return @('-f', 'ba/b', '-x', '--audio-format', $job.Fmt, '--audio-quality', '0')
    }
    $sort = ('res:{0},fps' -f $job.Cap)
    switch ($job.Fmt) {
        'movp' { return @('-f', 'bv*+ba/b', '-S', $sort, '--merge-output-format', 'mkv') }
        'webm' { return @('-f', 'bv*[ext=webm]+ba[ext=webm]/bv*+ba/b', '-S', $sort, '--merge-output-format', 'webm/mkv') }
        'mkv'  { return @('-f', 'bv*+ba/b', '-S', $sort, '--merge-output-format', 'mkv') }
    }
    # other sites: best available, converted afterwards if needed
    if ($job.Site -eq 'other') { return @('-f', 'bv*+ba/b', '-S', $sort, '--merge-output-format', 'mp4/mkv') }
    # mp4 and MOV (H.264): strict H.264 + AAC, optional fallback to the best stream
    $fmt = $FmtSafe
    if ($Opt.Fallback) { $fmt = $FmtSafe + '/bv*+ba/b' }
    $a = @('-f', $fmt, '-S', $sort)
    if ($Opt.Fallback) { $a += @('--merge-output-format', 'mp4/mkv') }
    elseif ($job.Fmt -eq 'movh') { $a += @('--merge-output-format', 'mp4', '--remux-video', 'mov') }
    else { $a += @('--merge-output-format', 'mp4', '--remux-video', 'mp4') }
    return $a
}

# ffmpeg arguments for a clip and/or conversion
function Get-EncodeArgs($job, [bool]$isRange, $plan, $tm, [string]$src, [string]$tmp) {
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $crf = [string][int]$Opt.Crf
    $a = @('-hide_banner', '-loglevel', 'error', '-nostats', '-y', '-i', $src)
    if ($isRange) { $a += @('-ss', $plan.T0.ToString('0.######', $inv), '-t', $plan.Dur.ToString('0.######', $inv)) }
    if ($job.Kind -eq 'audio') {
        $a += @('-vn', '-map', '0:a:0')
        switch ($job.Fmt) {
            'm4a'  { $a += @('-c:a', 'aac', '-b:a', '256k') }
            'mp3'  { $a += @('-c:a', 'libmp3lame', '-b:a', '320k') }
            'wav'  { $a += @('-c:a', 'pcm_s16le') }
            'flac' { $a += @('-c:a', 'flac') }
            'opus' { $a += @('-c:a', 'libopus', '-b:a', '160k') }
        }
    } else {
        $a += @('-map', '0:v:0', '-map', '0:a:0?')
        switch ($job.Fmt) {
            'movp' { $a += @('-c:v', 'prores_ks', '-profile:v', '3', '-vendor', 'apl0', '-pix_fmt', 'yuv422p10le', '-c:a', 'pcm_s24le', '-ar', '48000') }
            'webm' { $a += @('-c:v', 'libvpx-vp9', '-crf', '24', '-b:v', '0', '-row-mt', '1', '-deadline', 'good', '-cpu-used', '2', '-pix_fmt', 'yuv420p', '-c:a', 'libopus', '-b:a', '192k') }
            default {
                if ((-not $isRange) -and $tm.VCodec -eq 'h264') { $a += @('-c:v', 'copy') }
                else { $a += @('-c:v', 'libx264', '-preset', 'medium', '-crf', $crf, '-pix_fmt', 'yuv420p') }
                if ((-not $isRange) -and $tm.ACodec -eq 'aac') { $a += @('-c:a', 'copy') }
                else { $a += @('-c:a', 'aac', '-b:a', '256k') }
            }
        }
        if ($job.Fmt -eq 'mp4' -or $job.Fmt -eq 'movh' -or $job.Fmt -eq 'movp') { $a += @('-movflags', '+faststart') }
    }
    $a += $tmp
    return $a
}

# ---------------------------------------------------------------------
#  Reused functions
# ---------------------------------------------------------------------
function Start-Setup([string[]]$need) {
    $S.Mode = 'setup'
    $S.Cancelled = $false
    $S.Output = $null
    $S.AttemptOut = $null
    Set-Running $true
    $bar.Style = 'Marquee'
    $bar.MarqueeAnimationSpeed = 30
    $lblStatus.Text = (Tx 'st_setup')
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

function Handle-Line([string]$line) {
    if ($line -match '^\[download\]\s+(\d+(?:\.\d+)?)%') {
        $pct = [double]$Matches[1]
        $speed = ''
        $eta = ''
        if ($line -match '\sat\s+(\S+)') { $speed = $Matches[1] }
        if ($line -match 'ETA\s+(\S+)') { $eta = $Matches[1] }
        $bar.Value = [int][math]::Min(100, [math]::Max(0, $pct))
        $lblStatus.Text = ((Tx 'st_progress') -f ($S.Idx + 1), $S.Jobs.Count, $pct, $speed, $eta)
        return
    }
    if ($S.Output) { [void]$S.Output.AppendLine($line) }
    if ($S.AttemptOut) { [void]$S.AttemptOut.AppendLine($line) }
    Write-Log $line
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
    if ($url -notmatch '^https://www\.youtube\.com/watch\?v=') { return $null }
    if ($url -match '[?&]v=([A-Za-z0-9_-]{11})$') { return $Matches[1] }
    return $null
}

# Key used for the preview cache: the YouTube ID, or a short hash for other sites
function Get-LinkKey([string]$url) {
    $id = Get-VideoId $url
    if ($id) { return $id }
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($url))
    return ('h' + (($bytes | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12))
}

function ConvertTo-AnyUrl([string]$tok) {
    $u = ConvertTo-YoutubeUrl $tok
    if ($u) { return $u }
    if ($tok -match '^https?://') { return $tok }
    if ($tok -match $KnownHosts) { return ('https://' + $tok) }
    return $null
}

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

function Update-ToolStatus {
    Update-Tools
    $lines = @()
    foreach ($pair in @(@('yt-dlp', $T.YtDlp), @('FFmpeg', $T.Ffmpeg), @('FFprobe', $T.Ffprobe), @('Deno', $T.Deno))) {
        if ($pair[1]) { $lines += ('{0}: found  ({1})' -f $pair[0], $pair[1]) }
        else { $lines += ('{0}: MISSING' -f $pair[0]) }
    }
    $lblTools.Text = ($lines -join [Environment]::NewLine)
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

function Stop-DetailRun {
    if ($P.Runner) {
        $P.Runner.Kill()
        $c = $P.Cache[$P.RunnerId]
        if ($c -and $c.DetState -eq 'loading') { $c.DetState = '' }
        $P.Runner = $null
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

function Ensure-Meta([string]$id, [string]$url = '') {
    if (-not $P.Cache.ContainsKey($id)) {
        $other = ($id.Length -ne 11)
        $P.Cache[$id] = @{ Fetched = $false; Title = ''; Author = ''; Img = $null; Stream = $null; Duration = ''; Date = ''; DetState = ''; DetText = ''; Other = $other; Url = $url }
        if (-not $other) { $P.Fetcher.Fetch($id) }
    }
    elseif ($url -and (-not $P.Cache[$id].Url)) { $P.Cache[$id].Url = $url }
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
    $id = Get-LinkKey $url
    $P.Id = $id
    Ensure-Meta $id $url
    Show-Preview $id
    Ensure-Details $id
}

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
#  Row status (Queue tab)
# ---------------------------------------------------------------------
function Set-RowStatus($job, [string]$code, [string]$file = '') {
    $job.Status = $code
    $RowStatus[$job.Key] = $code
    if ($file) { $RowFile[$job.Key] = $file }
    if ($tabs.SelectedTab -eq $pgQueue) {
        foreach ($row in $grid.Rows) {
            if ([string]$row.Tag -eq $job.Key) {
                $row.Cells['colStatus'].Value = (Tx ('rs_' + $code))
                if ($file) { $row.Cells['colFile'].Value = $file }
                break
            }
        }
    }
}

function Add-JobFailure($job) {
    $nm = $job.Url
    if ($job.Label) { $nm = $job.Label }
    $S.Fail = $S.Fail + 1
    $S.Failed += ('{0}  {1}' -f $nm, $job.Url)
    Set-RowStatus $job 'ERROR'
}

# ---------------------------------------------------------------------
#  Engine (state machine driven by a UI timer)
# ---------------------------------------------------------------------
function Start-Attempt {
    $job = $S.Jobs[$S.Idx]
    $g = $S.Groups[$job.Gid]
    $browser = $S.Browsers[$S.AttemptIdx]

    $ytArgs = @(
        '--ignore-config', '--newline', '--no-playlist', '--no-mtime',
        '--continue', '--no-overwrites',
        '--retries', '10', '--fragment-retries', '10',
        '--sleep-requests', [string][int]$Opt.Sleep
    )
    $ytArgs += Get-DownloadArgs $job

    if ($Opt.Subs) {
        $langs = ([string]$Opt.SubLangs).Trim()
        if (-not $langs) { $langs = 'en' }
        $ytArgs += @('--write-subs', '--write-auto-subs', '--sub-langs', $langs, '--convert-subs', 'srt')
    } else {
        $ytArgs += @('--no-write-subs', '--no-write-auto-subs')
    }
    if ($Opt.Thumbs) { $ytArgs += @('--write-thumbnail', '--convert-thumbnails', 'jpg') }
    else { $ytArgs += '--no-write-thumbnail' }

    $lim = [int]$Opt.Limit
    if ($lim -gt 0) { $ytArgs += @('--limit-rate', ('{0}M' -f $lim)) }
    if ($Opt.Archive) { $ytArgs += @('--download-archive', $ArchiveFile) }

    $ytArgs += @('-P', $S.Folder)
    if ($job.Label) { $nameT = $job.Label } else { $nameT = '%(title,id).140s' }
    if ($g.HasClips) { $nameT = $nameT + '__full' }
    $ytArgs += @('-o', ($nameT + '.%(ext)s'))

    if ($T.Ffmpeg) { $ytArgs += @('--ffmpeg-location', (Split-Path -Parent $T.Ffmpeg)) }
    $ytArgs += Get-CookieArgs $browser
    $ytArgs += $job.Url

    if ($S.AttemptIdx -eq 0) {
        $tag = ''
        if ($job.Label) { $tag = $job.Label + '  ' }
        Write-Log ''
        Write-Log ('[{0}/{1}] {2}{3}' -f ($S.Idx + 1), $S.Jobs.Count, $tag, $job.Url)
        Write-Log ('    format: {0}   max {1}p' -f $FormatLabels[$job.Fmt], $job.Cap)
        if ($g.HasClips) { Write-Log ('    {0} clip(s) will be cut from this video' -f $g.Total) }
    }
    Write-Log ('    login: ' + (Get-CookieLabel $browser))
    $S.Step = 'dl'
    $bar.Value = 0
    $lblStatus.Text = ((Tx 'st_starting') -f ($S.Idx + 1), $S.Jobs.Count)

    $S.AttemptOut = New-Object System.Text.StringBuilder
    $S.Runner = New-Object YtRunner
    try {
        $S.Runner.Start($S.Exe, (ConvertTo-ArgString $ytArgs), $S.Folder)
    } catch {
        Write-Log ('ERROR: could not start yt-dlp: ' + $_.Exception.Message)
        $S.Runner = $null
        $g.Failed = $true
        Add-JobFailure $job
        Start-NextJob
    }
}

function Start-NextJob {
    $S.Idx = $S.Idx + 1
    if ($S.Idx -ge $S.Jobs.Count) { Complete-Batch; return }
    $job = $S.Jobs[$S.Idx]
    $g = $S.Groups[$job.Gid]
    $S.AttemptIdx = 0
    $S.JobStart = Get-Date
    $S.Output = New-Object System.Text.StringBuilder
    $S.Step = 'dl'

    if ($g.Failed) {
        Write-Log ''
        Write-Log ('[{0}/{1}] skipped: the download of this video failed' -f ($S.Idx + 1), $S.Jobs.Count)
        Add-JobFailure $job
        Start-NextJob
        return
    }
    if ($job.Download) {
        Set-RowStatus $job 'Downloading'
        Start-Attempt
        return
    }
    Write-Log ''
    Write-Log ('[{0}/{1}] next clip of an already downloaded video' -f ($S.Idx + 1), $S.Jobs.Count)
    $full = Get-Item -LiteralPath $g.Full -ErrorAction SilentlyContinue
    if ($null -eq $full) {
        Write-Log 'ERROR  the full video is missing, so this clip cannot be cut.'
        Add-JobFailure $job
        Start-NextJob
        return
    }
    Complete-Download $job $full
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
        $lblStatus.Text = (Tx 'st_stopped')
    } else {
        Write-Log ('=== Done: {0} OK, {1} to review, {2} failed ===' -f $S.Ok, $S.Warn, $S.Fail)
        $lblStatus.Text = ((Tx 'st_done') -f $S.Ok, $S.Warn, $S.Fail)
    }
    foreach ($f in $S.Failed) { Write-Log ('  FAILED: ' + $f) }
    $bar.Value = 0
    Set-Running $false
    if (-not $S.Cancelled) {
        if ($Opt.Sound) { try { [System.Media.SystemSounds]::Asterisk.Play() } catch { } }
        if ($Opt.OpenDone -and $S.Folder -and (Test-Path -LiteralPath $S.Folder)) {
            try { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $S.Folder) } catch { }
        }
    }
}

# Called when a video is on disk (just downloaded, or reused for the next clip)
function Complete-Download($job, $file) {
    $g = $S.Groups[$job.Gid]
    if ($job.Download) {
        $g.Full = $file.FullName
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        if ($stem.EndsWith('__full')) { $stem = $stem.Substring(0, $stem.Length - 6) }
        $g.Stem = $stem
    }
    $hasRange = ($job.Start -ne '' -or $job.End -ne '')
    $needPost = $hasRange
    $ext = Get-ExtFor $job.Fmt
    if (-not $needPost) {
        if ($job.Fmt -eq 'movp') { $needPost = $true }
        elseif ($job.Kind -eq 'video' -and ($job.Fmt -eq 'mp4' -or $job.Fmt -eq 'movh') -and ($Opt.Fallback -or $job.Site -eq 'other') -and $T.Ffprobe) {
            $tm0 = Get-SourceTiming $file.FullName
            if ($tm0.Ok -and ($tm0.VCodec -ne 'h264' -or $tm0.ACodec -ne 'aac' -or $file.Extension -ne $ext)) { $needPost = $true }
        }
    }
    if ($needPost) {
        if ($T.Ffmpeg) { Start-Post $job $file $hasRange; return }
        Write-Log 'WARN  ffmpeg not found - cannot cut or convert. The downloaded file was kept.'
    }
    $g.Done = $g.Done + 1
    Finish-Job $job $file
    Start-NextJob
}

function Finish-Job($job, $file) {
    $exp = Get-ExpectedCodecs $job.Fmt $job.Kind
    if ($exp) { $info = Get-MediaInfo $file.FullName $exp.V $exp.A }
    else { $info = @{ Text = ''; Warn = $false } }
    if ($info.Warn) {
        $S.Warn = $S.Warn + 1
        Write-Log ('WARN  {0}  ->  {1}' -f $file.Name, $info.Text)
        Write-Log ('      Not the expected codecs ({0} + {1}).' -f $exp.V, $exp.A)
        Set-RowStatus $job 'WARN' $file.Name
    } else {
        $S.Ok = $S.Ok + 1
        if ($info.Text) { Write-Log ('OK    {0}  ->  {1}' -f $file.Name, $info.Text) }
        else { Write-Log ('OK    {0}' -f $file.Name) }
        Set-RowStatus $job 'OK' $file.Name
    }
}

function Skip-Post($job, $file, [string]$why) {
    $g = $S.Groups[$job.Gid]
    $g.Keep = $true
    $g.Done = $g.Done + 1
    $S.Warn = $S.Warn + 1
    Write-Log ('REVIEW  not processed: {0}. The downloaded file was kept: {1}' -f $why, $file.Name)
    Set-RowStatus $job 'REVIEW' $file.Name
    $S.Step = 'dl'
    Start-NextJob
}

# ---- ffmpeg step: frame-accurate clip and/or conversion ----
function Start-Post($job, $file, [bool]$isRange) {
    $g = $S.Groups[$job.Gid]
    $g.PostUsed = $true
    $S.Step = 'post'
    $S.PostSrc = $file.FullName
    $S.PostNote = ''
    $dir = Split-Path -Parent $file.FullName
    $ext = Get-ExtFor $job.Fmt
    if ($job.Label) { $base = $job.Label }
    else {
        $base = $g.Stem
        if ($isRange -and $job.Count -gt 1) { $base = $base + ' - ' + ($job.Idx + 1) }
    }
    $S.PostDir = $dir
    $S.PostBase = $base
    $S.PostExt = $ext
    $S.PostTmp = Join-Path $dir ($base + '.__tmp' + $ext)

    if ($job.Kind -eq 'audio') { $tm = Get-AudioTiming $file.FullName $job.Fps }
    else { $tm = Get-SourceTiming $file.FullName }

    $plan = $null
    if ($isRange) {
        if (-not $tm.Ok) { Skip-Post $job $file $tm.Error; return }
        $plan = Get-CutPlan $job $tm
        if (-not $plan.Ok) { Skip-Post $job $file $plan.Error; return }
        $S.PostNote = ('clip: frames {0} to {1} = {2} frames at {3:0.###} fps' -f $plan.S, $plan.E, $plan.Frames, $plan.Fps)
        if ($plan.Note) { $S.PostNote = $S.PostNote + '  (' + $plan.Note + ')' }
    } elseif (-not $tm.Ok) {
        Skip-Post $job $file $tm.Error
        return
    }

    $a = Get-EncodeArgs $job $isRange $plan $tm $file.FullName $S.PostTmp
    if ($isRange) { Write-Log ('    cutting ' + $S.PostNote) }
    else { Write-Log ('    converting to ' + $FormatLabels[$job.Fmt] + '...') }
    Set-RowStatus $job 'Cutting'
    $bar.Style = 'Marquee'
    $bar.MarqueeAnimationSpeed = 30
    $lblStatus.Text = ((Tx 'st_cutting') -f ($S.Idx + 1), $S.Jobs.Count)

    $S.AttemptOut = New-Object System.Text.StringBuilder
    $S.Runner = New-Object YtRunner
    try {
        $S.Runner.Start($T.Ffmpeg, (ConvertTo-ArgString $a), $dir)
    } catch {
        Write-Log ('ERROR: could not start ffmpeg: ' + $_.Exception.Message)
        $S.Runner = $null
        $bar.Style = 'Continuous'
        $g.Keep = $true
        $g.Done = $g.Done + 1
        Add-JobFailure $job
        $S.Step = 'dl'
        Start-NextJob
    }
}

function Finish-Post([int]$exitCode) {
    $job = $S.Jobs[$S.Idx]
    $g = $S.Groups[$job.Gid]
    $tmp = $S.PostTmp
    $bar.Style = 'Continuous'
    $bar.Value = 0
    $S.Step = 'dl'

    if ($S.Cancelled) {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        Write-Log 'Stopped by user.'
        Complete-Batch
        return
    }

    $g.Done = $g.Done + 1
    if ($exitCode -eq 0 -and (Test-Path -LiteralPath $tmp)) {
        $last = ($g.Done -ge $g.Total)
        $keepFull = (($g.HasClips -and $Opt.KeepFull) -or $g.Keep)
        if ($last -and (-not $keepFull)) { Remove-Item -LiteralPath $g.Full -Force -ErrorAction SilentlyContinue }
        $final = Get-UniquePath $S.PostDir $S.PostBase $S.PostExt
        Move-Item -LiteralPath $tmp -Destination $final -Force
        $nf = Get-Item -LiteralPath $final
        Finish-Job $job $nf
        if ($S.PostNote) { Write-Log ('      ' + $S.PostNote) }
        if ($last -and $keepFull -and $g.HasClips) { Write-Log ('      the full video was kept: ' + (Split-Path -Leaf $g.Full)) }
    } else {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        $g.Keep = $true
        $S.Warn = $S.Warn + 1
        Write-Log ('REVIEW  ffmpeg failed (exit code {0}). The downloaded video was kept: {1}' -f $exitCode, (Split-Path -Leaf $S.PostSrc))
        Set-RowStatus $job 'REVIEW' (Split-Path -Leaf $S.PostSrc)
    }
    Start-NextJob
}

function Finish-Attempt([int]$exitCode) {
    if ($S.Mode -eq 'update') {
        Write-Log ('--- Update finished (exit code {0}) ---' -f $exitCode)
        $S.Mode = 'idle'
        $lblStatus.Text = (Tx 'st_ready')
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
            $lblStatus.Text = (Tx 'st_ready')
            Set-Running $false
            if ($again) { Start-Batch }
        } else {
            Write-Log ('Setup did not finish (exit code {0}). Still missing: {1}' -f $exitCode, ($missing -join ', '))
            Write-Log 'Check your internet connection and press Download to try again.'
            $lblStatus.Text = (Tx 'st_setupfail')
            Set-Running $false
        }
        return
    }

    if ($S.Step -eq 'post') { Finish-Post $exitCode; return }

    if ($S.Cancelled) {
        Write-Log 'Stopped by user. Partial files (.part) may remain in the folder.'
        Complete-Batch
        return
    }

    $job = $S.Jobs[$S.Idx]
    $g = $S.Groups[$job.Gid]
    $browser = $S.Browsers[$S.AttemptIdx]
    $attemptText = $S.AttemptOut.ToString()

    # Cookie problem or bot check with this source -> try the next one
    if ($exitCode -ne 0 -and ($S.AttemptIdx + 1) -lt $S.Browsers.Count -and $attemptText -match $RetryRegex) {
        $S.AttemptIdx = $S.AttemptIdx + 1
        Write-Log ('    "{0}" did not work - trying "{1}"...' -f $browser, $S.Browsers[$S.AttemptIdx])
        Start-Attempt
        return
    }

    $file = Find-ResultFile $S.Folder $S.JobStart

    if ($exitCode -eq 0 -and $file) {
        # Remember the source that worked so the next videos try it first
        if ($S.AttemptIdx -gt 0) {
            $S.Browsers = @(@($browser) + @($S.Browsers | Where-Object { $_ -ne $browser }))
            $Pref.Browser = $browser
        }
        Complete-Download $job $file
        return
    }

    if ($file) {
        $g.Done = $g.Done + 1
        $g.Failed = $true
        $S.Warn = $S.Warn + 1
        Write-Log ('REVIEW  {0} exists but yt-dlp returned code {1}.' -f $file.Name, $exitCode)
        Set-RowStatus $job 'REVIEW' $file.Name
    }
    elseif ($exitCode -eq 0) {
        $g.Done = $g.Done + 1
        $g.Failed = $true
        $S.Warn = $S.Warn + 1
        Write-Log 'SKIPPED  no new file appeared (already downloaded before, or a file with the same name exists).'
        Set-RowStatus $job 'Skipped'
    }
    else {
        $g.Failed = $true
        Add-JobFailure $job
        Write-Log ('ERROR  no file produced (exit code {0}).' -f $exitCode)
        $all = $S.Output.ToString()
        if ($all -match 'Sign in to confirm') {
            Write-Log '    Hint: log into YouTube in Firefox, keep the login source on Automatic (Settings tab), then press Update tools and try again.'
        }
        elseif (($job.Site -eq 'other') -and ($all -match '(?i)login|log in|cookie|private|authenticat|restricted|rate.?limit|not available')) {
            Write-Log '    Hint: this site may need you to be logged in. Log in to it in Firefox and keep the login source on Automatic (Settings tab). Public posts usually work without it. Press Update tools if the site changed.'
        }
        elseif ($all -match 'Requested format is not available') {
            Write-Log '    Hint: YouTube did not offer this format. Turn on the H.264 conversion in Options, or press Update tools.'
        }
        elseif ($all -match 'DPAPI|Could not copy') {
            Write-Log '    Hint: Chrome/Edge cookies are often unreadable on Windows. Firefox works best, or close the browser completely.'
        }
    }
    Start-NextJob
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
    Write-Log ('=== Starting: {0} file(s) -> {1} ===' -f $S.Jobs.Count, $folder)
    Start-NextJob
}

function Start-Batch {
    $folder = $txtFolder.Text.Trim('" ')
    if (-not $folder) {
        [void](Show-Msg (Tx 'msg_nofolder_sel') 'videoprep' 'OK' 'Warning')
        return
    }
    # a link that is still being prepared goes to the queue first
    if ($Draft.Url) { if (-not (Send-Draft $false)) { return } }
    if ($Items.Count -eq 0) {
        [void](Show-Msg (Tx 'msg_empty') 'videoprep' 'OK' 'Information')
        return
    }

    # Make sure the tools exist (first run downloads them)
    Update-Tools
    $missing = @(Get-MissingTools)
    if ($missing.Count -gt 0) {
        $nl = [Environment]::NewLine + [Environment]::NewLine
        $ans = Show-Msg ((Tx 'msg_setup') -f ($missing -join ', '), $nl) (Tx 'msg_setup_title') 'YesNo' 'Question'
        if ($ans -eq 'Yes') {
            $S.StartAfterSetup = $true
            Start-Setup $missing
        }
        return
    }

    Stop-DetailRun

    try { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
    catch {
        [void](Show-Msg ((Tx 'msg_cantcreate') -f ([Environment]::NewLine + $folder)) 'videoprep' 'OK' 'Warning')
        return
    }

    # Numbering for "series" names (continues after files that already exist)
    $startNums = @{}
    $prefixes = @($Items | Where-Object { $_.NameMode -eq 'series' } | ForEach-Object { $_.Prefix } | Select-Object -Unique)
    foreach ($px in $prefixes) {
        $rx = '^' + [regex]::Escape($px) + '(\d+)\.'
        $nums = @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue |
            ForEach-Object { if ($_.Name -match $rx) { [int]$Matches[1] } })
        $next = 1
        if ($nums.Count -gt 0) {
            $max = ($nums | Measure-Object -Maximum).Maximum
            $next = $max + 1
            $nl = [Environment]::NewLine
            $ans = Show-Msg ((Tx 'msg_exists') -f $px, $max, $nl, $next) (Tx 'msg_exists_title') 'YesNo' 'Question'
            if ($ans -ne 'Yes') { return }
        }
        $startNums[$px] = $next
    }

    # Build one job per output file (a video, or each clip of a video)
    $jobs = @()
    $S.Groups = @{}
    $RowStatus.Clear()
    $RowFile.Clear()
    foreach ($it in $Items) {
        $outs = @($it.Clips)
        if ($outs.Count -eq 0) { $outs = @(@{ Start = ''; End = '' }) }
        $total = $outs.Count
        $S.Groups[$it.Id] = @{ Full = ''; Stem = ''; Done = 0; Total = $total; Failed = $false; Keep = $false; PostUsed = $false; HasClips = ($it.Clips.Count -gt 0) }
        for ($i = 0; $i -lt $total; $i++) {
            $label = $null
            if ($it.NameMode -eq 'series') {
                $label = $it.Prefix + $startNums[$it.Prefix]
                $startNums[$it.Prefix] = $startNums[$it.Prefix] + 1
            }
            elseif ($it.NameMode -eq 'custom') {
                $label = Get-SafeName $it.Custom
                if ($total -gt 1) { $label = $label + ' - ' + ($i + 1) }
            }
            $key = '{0}|{1}' -f $it.Id, $i
            $RowStatus[$key] = 'Queued'
            $jobs += [pscustomobject]@{
                Key = $key; Gid = $it.Id; Idx = $i; Count = $total; Url = $it.Url
                Kind = $it.Kind; Fmt = $it.Fmt; Cap = $it.Cap; Label = $label
                Start = [string]$outs[$i].Start; End = [string]$outs[$i].End
                Download = ($i -eq 0); Status = 'Queued'; Fps = $it.Fps; Site = $it.Site
            }
        }
    }
    Begin-Jobs $jobs $folder
}

function Start-Retry {
    $failed = @($S.LastJobs | Where-Object { $_.Status -eq 'ERROR' })
    if ($failed.Count -eq 0) { return }
    Update-Tools
    if (@(Get-MissingTools).Count -gt 0) {
        [void](Show-Msg (Tx 'msg_tools_missing') 'videoprep' 'OK' 'Warning')
        return
    }
    Stop-DetailRun
    $S.Groups = @{}
    $seen = @{}
    foreach ($j in $failed) {
        if (-not $S.Groups.ContainsKey($j.Gid)) {
            $cnt = @($failed | Where-Object { $_.Gid -eq $j.Gid }).Count
            $hasClips = (@($failed | Where-Object { $_.Gid -eq $j.Gid -and ($_.Start -ne '' -or $_.End -ne '') }).Count -gt 0)
            $S.Groups[$j.Gid] = @{ Full = ''; Stem = ''; Done = 0; Total = $cnt; Failed = $false; Keep = $false; PostUsed = $false; HasClips = $hasClips }
            $j.Download = $true
        } else {
            $j.Download = $false
        }
        $j.Status = 'Queued'
        $RowStatus[$j.Key] = 'Queued'
    }
    Begin-Jobs $failed $S.Folder
}

# ---------------------------------------------------------------------
#  Current selections in the Download tab
# ---------------------------------------------------------------------
function Get-SelFmt {
    $i = $cmbFmt.SelectedIndex
    $keys = $UiState.FmtNow
    if ($i -lt 0 -or $i -ge $keys.Count) { return 'mp4' }
    return $keys[$i]
}

function Get-SelCap {
    $capTxt = [string]$cmbRes.SelectedItem
    if ($ResMap.ContainsKey($capTxt)) { return [int]$ResMap[$capTxt] }
    return 1080
}

function Update-ResList {
    $fmt = Get-SelFmt
    $kind = Get-FormatKind $fmt
    if ($fmt -eq 'mp4' -or $fmt -eq 'movh' -or $kind -eq 'audio') { $list = @('1080p', '720p', '480p') }
    else { $list = @('4K', '1440p', '1080p', '720p') }
    $keep = [string]$cmbRes.SelectedItem
    $cmbRes.Items.Clear()
    foreach ($x in $list) { [void]$cmbRes.Items.Add($x) }
    $i = [array]::IndexOf($list, $keep)
    if ($i -lt 0) { $i = [array]::IndexOf($list, '1080p') }
    $cmbRes.SelectedIndex = $i
    $cmbRes.Enabled = (($kind -eq 'video') -and ($S.Mode -eq 'idle'))
}

function Update-Hint { $lblHint.Text = (Tx ('h_' + (Get-SelFmt))) }

function Update-Example {
    $ex1 = Get-ExtFor (Get-SelFmt)
    $txt = Tx 'ex_label'
    if ($radN3.Checked) { $txt += ('{0}1{1}, {0}2{1}, {0}3{1}' -f $txtSeries.Text, $ex1) }
    else {
        $nm1 = Tx 'ex_orig_title'
        if ($radN2.Checked) { $nm1 = $txtCustom.Text }
        $txt += ('{0} - 1{1}, {0} - 2{1}' -f $nm1, $ex1)
    }
    $lblExample.Text = $txt
}

function Update-NameControls {
    $idle = ($S.Mode -eq 'idle')
    $txtCustom.Enabled = ($radN2.Checked -and $idle)
    $txtSeries.Enabled = ($radN3.Checked -and $idle)
}

function Update-FormatList {
    $UiState.Busy = $true
    $kind = 'video'
    if ($radAudio.Checked) { $kind = 'audio' }
    $keep = Get-SelFmt
    $keys = @($FormatKeys[$kind])
    $cmbFmt.Items.Clear()
    foreach ($k in $keys) { [void]$cmbFmt.Items.Add($FormatLabels[$k]) }
    $UiState.FmtNow = $keys
    $idx = [array]::IndexOf($keys, $keep)
    if ($idx -lt 0) { $idx = 0 }
    $cmbFmt.SelectedIndex = $idx
    $UiState.Busy = $false
    Update-ResList
    Update-Hint
    Update-Example
}

function Set-Running([bool]$on) {
    foreach ($c in $LockCtls) { $c.Enabled = (-not $on) }
    $btnStop.Enabled = $on
    Update-NameControls
    $hasFailed = (@($S.LastJobs | Where-Object { $_.Status -eq 'ERROR' }).Count -gt 0)
    $btnRetry.Enabled = ((-not $on) -and $hasFailed)
    if (-not $on) { Update-ResList }
}

# ---------------------------------------------------------------------
#  Preview panel
# ---------------------------------------------------------------------
function Clear-PreviewPanel {
    $picThumb.Image = $null
    $lblTitle.Text = (Tx 'prev_hint')
    $lblMeta.Text = ''
}

function Get-WillText($c) {
    $fmt = Get-SelFmt
    if ((Get-FormatKind $fmt) -eq 'audio') { return ((Tx 'prev_audio') -f $FormatLabels[$fmt]) }
    $will = ''
    if ($fmt -eq 'movp') {
        $will = 'ProRes 422 HQ'
        if ($c.DetRes) { $will = $will + ' (' + $c.DetRes + ')' }
    } else {
        $bits = @()
        foreach ($x in @($c.DetRes, $c.DetVL)) { if ($x) { $bits += $x } }
        $will = ($bits -join ' ')
        if ($c.DetAL) { $will = $will + ' + ' + $c.DetAL }
    }
    if (($fmt -eq 'mp4' -or $fmt -eq 'movh') -and $c.DetVL -ne 'H.264') { $will = $will + (Tx 'prev_conv') }
    return ((Tx 'prev_will') -f $will.Trim())
}

function Show-Preview([string]$id) {
    $c = $P.Cache[$id]
    if ($null -eq $c) { Clear-PreviewPanel; return }
    $picThumb.Image = $c.Img
    if (-not $c.Fetched) {
        $lblTitle.Text = (Tx 'prev_loading')
        $lblMeta.Text = ''
        return
    }
    if (-not $c.Title) {
        $lblTitle.Text = (Tx 'prev_none')
        $lblMeta.Text = (Tx 'prev_none2')
        return
    }
    $lblTitle.Text = $c.Title
    $bits = @()
    if ($c.Author) { $bits += $c.Author }
    if ($c.Duration) { $bits += $c.Duration }
    if ($c.Date) { $bits += $c.Date }
    $line2 = ''
    switch ($c.DetState) {
        'loading'  { $line2 = (Tx 'prev_check') }
        'done'     { $line2 = (Get-WillText $c) }
        'noformat' { $line2 = (Tx 'prev_noformat') }
        'fail'     { $line2 = (Tx 'prev_fail') }
    }
    $lblMeta.Text = (($bits -join '  |  ') + [Environment]::NewLine + $line2)
}

function Start-DetailAttempt {
    $id = $P.RunnerId
    $c = $P.Cache[$id]
    $browser = $P.Browsers[$P.BIdx]
    $fmt = Get-SelFmt
    $sort = ('res:{0},fps' -f (Get-SelCap))
    if ($c.Other) {
        $sel = 'bv*+ba/b'
        $url = $c.Url
    } else {
        $url = 'https://www.youtube.com/watch?v=' + $id
        if ($fmt -eq 'mp4' -or $fmt -eq 'movh' -or (Get-FormatKind $fmt) -eq 'audio') { $sel = $FmtSafe } else { $sel = 'bv*+ba/b' }
    }
    $a = @('--ignore-config', '--no-playlist', '--no-warnings', '-f', $sel, '-S', $sort,
        '--print', 'DET|%(duration_string)s|%(height)s|%(fps)s|%(vcodec)s|%(acodec)s|%(upload_date)s|%(uploader)s|%(thumbnail)s|%(title)s')
    $a += Get-CookieArgs $browser
    $a += $url
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

function Ensure-Details([string]$id) {
    $c = $P.Cache[$id]
    if ($null -eq $c) { return }
    if ((-not $c.Title) -and (-not $c.Other)) { return }
    if ($c.DetState -ne '') { return }
    if ($S.Mode -ne 'idle') { return }
    Start-DetailRun $id
}

# Run the quality check again (the format group or resolution changed)
function Reset-Details {
    if (-not $Draft.Id) { return }
    $c = $P.Cache[$Draft.Id]
    if ($null -eq $c) { return }
    Stop-DetailRun
    $c.DetState = ''
    Show-Preview $Draft.Id
    Ensure-Details $Draft.Id
}

function Finish-Detail([int]$exitCode) {
    $id = $P.RunnerId
    $c = $P.Cache[$id]
    if ($null -eq $c) { return }
    $out = $P.DetOut.ToString()
    if ($P.DetLine) {
        $f = @($P.DetLine -split '\|', 10)
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
        $up = ''
        if ($f.Count -gt 7) { $up = $f[7] }
        $th = ''
        if ($f.Count -gt 8) { $th = $f[8] }
        $ti = ''
        if ($f.Count -gt 9) { $ti = $f[9] }
        $res = ''
        if ($h -match '^\d+$') {
            $res = $h + 'p'
            if ($fps -match '^\d+(\.\d+)?$') {
                $res = $res + [string][math]::Round([double]$fps)
                $c.Fps = [double]$fps
            }
        }
        $vl = $vc
        if ($vc -like 'avc1*' -or $vc -eq 'h264') { $vl = 'H.264' }
        elseif ($vc -like 'vp0*' -or $vc -like 'vp9*') { $vl = 'VP9' }
        elseif ($vc -like 'av01*') { $vl = 'AV1' }
        $al = $ac
        if ($ac -like 'mp4a*' -or $ac -eq 'aac') { $al = 'AAC' }
        elseif ($ac -like 'opus*') { $al = 'Opus' }
        if ($vl -eq 'NA' -or $vl -eq 'none') { $vl = '' }
        if ($al -eq 'NA' -or $al -eq 'none') { $al = '' }
        $c.Duration = $dur
        if ($dt -match '^(\d{4})(\d{2})(\d{2})$') { $c.Date = ('{0}-{1}-{2}' -f $Matches[1], $Matches[2], $Matches[3]) }
        $c.DetRes = $res
        $c.DetVL = $vl
        $c.DetAL = $al
        $c.DetState = 'done'
        if ($c.Other) {
            $c.Fetched = $true
            if ($ti -and $ti -ne 'NA') { $c.Title = $ti }
            if ($up -and $up -ne 'NA') { $c.Author = $up }
            if ($th -match '^https?://') { $P.Fetcher.FetchThumb($id, $th) }
        }
        if ($P.BIdx -gt 0) { $Pref.Browser = $P.Browsers[$P.BIdx] }
    }
    elseif ($exitCode -ne 0 -and ($P.BIdx + 1) -lt $P.Browsers.Count -and $out -match $RetryRegex) {
        $P.BIdx = $P.BIdx + 1
        Start-DetailAttempt
        return
    }
    elseif (($out -match 'Requested format is not available') -and (-not $c.Other)) { $c.DetState = 'noformat' }
    else {
        $c.DetState = 'fail'
        if ($c.Other) { $c.Fetched = $true }
    }
    if ($P.Id -eq $id) { Show-Preview $id }
}

function Update-GridTitles {
    foreach ($row in $grid.Rows) {
        $key = [string]$row.Tag
        $cut = $key.IndexOf('|')
        if ($cut -lt 0) { continue }
        $gid = [int]$key.Substring(0, $cut)
        foreach ($it in $Items) {
            if ($it.Id -eq $gid) {
                $c = $P.Cache[$it.VideoId]
                if ($c -and $c.Title) { $row.Cells['colName'].Value = $c.Title }
                break
            }
        }
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

# ---------------------------------------------------------------------
#  Clip rows (Download tab)
# ---------------------------------------------------------------------
function Update-ClipLayout {
    $i = 0
    foreach ($r in $ClipRows) {
        $y = 4 + $i * 30
        $r.L1.Top = $y + 3
        $r.T1.Top = $y
        $r.L2.Top = $y + 3
        $r.T2.Top = $y
        $r.B.Top = $y - 1
        $i = $i + 1
    }
}

function Test-ClipText($tb) {
    $tcv = ConvertFrom-TimecodeText $tb.Text
    if ($tcv.Blank -or $tcv.Valid) { $tb.ForeColor = $Pal.tx } else { $tb.ForeColor = [System.Drawing.Color]::Red }
}

function Remove-ClipRow($row) {
    foreach ($c in @($row.L1, $row.T1, $row.L2, $row.T2, $row.B)) {
        $pnlClips.Controls.Remove($c)
        $c.Dispose()
    }
    [void]$ClipRows.Remove($row)
    Update-ClipLayout
}

function Add-ClipRow([string]$startText = '', [string]$endText = '') {
    $y = 4 + $ClipRows.Count * 30
    $l1 = New-Ctl 'System.Windows.Forms.Label' 4 ($y + 3) 50 20 (Tx 'lbl_start') $pnlClips
    $l1.Tag = 'muted'
    $t1 = New-Ctl 'System.Windows.Forms.TextBox' 56 $y 104 24 $startText $pnlClips
    $l2 = New-Ctl 'System.Windows.Forms.Label' 168 ($y + 3) 36 20 (Tx 'lbl_end') $pnlClips
    $l2.Tag = 'muted'
    $t2 = New-Ctl 'System.Windows.Forms.TextBox' 206 $y 104 24 $endText $pnlClips
    $b = New-Ctl 'System.Windows.Forms.Button' 318 ($y - 1) 28 26 'X' $pnlClips
    $row = @{ L1 = $l1; T1 = $t1; L2 = $l2; T2 = $t2; B = $b }
    $b.Tag = $row
    $b.Add_Click({ param($sender, $ev) Remove-ClipRow $sender.Tag })
    $t1.Add_TextChanged({ param($sender, $ev) Test-ClipText $sender })
    $t2.Add_TextChanged({ param($sender, $ev) Test-ClipText $sender })
    [void]$ClipRows.Add($row)
    Set-ThemeOn $pnlClips $Pal
    Test-ClipText $t1
    Test-ClipText $t2
    $pnlClips.ScrollControlIntoView($t1)
}

function Clear-ClipRows {
    foreach ($r in @($ClipRows)) { Remove-ClipRow $r }
}

# Returns the clips typed in the rows, or $null when a timecode is invalid
function Get-DraftClips {
    $out = @()
    $n = 0
    $nl = [Environment]::NewLine + [Environment]::NewLine
    foreach ($r in $ClipRows) {
        $n = $n + 1
        $s1 = $r.T1.Text.Trim()
        $e1 = $r.T2.Text.Trim()
        if ($s1 -eq '' -and $e1 -eq '') { continue }
        foreach ($tx in @($s1, $e1)) {
            $tcv = ConvertFrom-TimecodeText $tx
            if ((-not $tcv.Blank) -and (-not $tcv.Valid)) {
                [void](Show-Msg ((Tx 'msg_badtc') -f $n, $tx, $nl) 'videoprep' 'OK' 'Warning')
                return $null
            }
        }
        $out += @{ Start = $s1; End = $e1 }
    }
    return ,$out
}

# ---------------------------------------------------------------------
#  Draft (the link being prepared) and queue items
# ---------------------------------------------------------------------
function Reset-DraftFields {
    Clear-ClipRows
    $radVideo.Checked = $true
    Update-FormatList
    $cmbFmt.SelectedIndex = 0
    $cmbRes.SelectedIndex = [array]::IndexOf(@($cmbRes.Items), '1080p')
    $txtCustom.Text = ''
    if ($radN2.Checked) { $radN1.Checked = $true }
    Update-NameControls
    Update-Hint
    Update-Example
}

function Get-DefaultNaming {
    $mode = 'orig'
    if ($radN3.Checked) { $mode = 'series' }
    $px = ([string]$txtSeries.Text).Trim()
    if (-not $px) { $px = 'Video' }
    return @{ Mode = $mode; Prefix = (Get-SafeName $px) }
}

function New-Item-Object([string]$url, [string]$kind, [string]$fmt, [int]$cap, [string]$mode, [string]$custom, [string]$prefix, $clips) {
    $vid = Get-LinkKey $url
    $site = 'other'
    if ($vid.Length -eq 11) { $site = 'youtube' }
    $fps = 30.0
    if ($P.Cache.ContainsKey($vid) -and $P.Cache[$vid].Fps) { $fps = [double]$P.Cache[$vid].Fps }
    return [pscustomobject]@{
        Id = 0; Url = $url; VideoId = $vid; Site = $site; Kind = $kind; Fmt = $fmt; Cap = $cap
        NameMode = $mode; Custom = $custom; Prefix = $prefix; Clips = @($clips); Fps = $fps
    }
}

function Add-ItemToQueue($it) {
    $Counter.Item = $Counter.Item + 1
    $it.Id = $Counter.Item
    [void]$Items.Add($it)
    if ($it.VideoId) { Ensure-Meta $it.VideoId $it.Url }
}

function Add-DefaultItem([string]$url) {
    $nm = Get-DefaultNaming
    $it = New-Item-Object $url 'video' 'mp4' 1080 $nm.Mode '' $nm.Prefix @()
    Add-ItemToQueue $it
}

function Send-Draft([bool]$interactive) {
    if (-not $Draft.Url) {
        if ($interactive) { [void](Show-Msg (Tx 'msg_nolink_draft') 'videoprep' 'OK' 'Information') }
        return $false
    }
    $clips = Get-DraftClips
    if ($null -eq $clips) { return $false }
    $kind = 'video'
    if ($radAudio.Checked) { $kind = 'audio' }
    $mode = 'orig'
    if ($radN2.Checked) { $mode = 'custom' } elseif ($radN3.Checked) { $mode = 'series' }
    if ($mode -eq 'custom' -and $txtCustom.Text.Trim() -eq '') {
        if ($interactive) { [void](Show-Msg (Tx 'msg_custom') 'videoprep' 'OK' 'Warning'); return $false }
        $mode = 'orig'
    }
    $px = ([string]$txtSeries.Text).Trim()
    if ($mode -eq 'series' -and $px -eq '') {
        if ($interactive) { [void](Show-Msg (Tx 'msg_prefix') 'videoprep' 'OK' 'Warning'); return $false }
        $px = 'Video'
    }
    $it = New-Item-Object $Draft.Url $kind (Get-SelFmt) (Get-SelCap) $mode ($txtCustom.Text.Trim()) (Get-SafeName $px) $clips

    if ($Draft.EditId -gt 0) {
        $replaced = $false
        for ($i = 0; $i -lt $Items.Count; $i++) {
            if ($Items[$i].Id -eq $Draft.EditId) {
                $it.Id = $Draft.EditId
                $Items[$i] = $it
                $replaced = $true
                break
            }
        }
        if (-not $replaced) { Add-ItemToQueue $it }
    } else {
        Add-ItemToQueue $it
    }
    if ($it.VideoId) { Ensure-Meta $it.VideoId $it.Url }

    $Draft.Url = ''
    $Draft.Id = ''
    $Draft.EditId = 0
    $P.Id = $null
    $txtLink.Clear()
    Reset-DraftFields
    Clear-PreviewPanel
    if ($tabs.SelectedTab -eq $pgQueue) { Update-QueueGrid }
    return $true
}

# A new link becomes the draft; the previous one (if any) goes to the queue first
function Accept-Link([string]$url) {
    if ($Draft.Url) { if (-not (Send-Draft $false)) { return } }
    $txtLink.Clear()
    $Draft.Url = $url
    $Draft.Id = Get-LinkKey $url
    $Draft.EditId = 0
    Request-Preview $url
}

function Get-LinksFromText([string]$text) {
    $urls = @()
    foreach ($tok in @($text -split '\s+' | Where-Object { $_ -ne '' })) {
        $u = ConvertTo-AnyUrl $tok
        if ($u) { $urls += $u }
    }
    return ,$urls
}

function Add-PastedLinks($urls) {
    $urls = @($urls)
    if ($urls.Count -eq 1) { Accept-Link $urls[0]; return }
    if ($Draft.Url) { if (-not (Send-Draft $false)) { return } }
    foreach ($u in $urls) { Add-DefaultItem $u }
    $txtLink.Clear()
    Clear-PreviewPanel
    if ($tabs.SelectedTab -eq $pgQueue) { Update-QueueGrid }
}

function Invoke-SmartPaste {
    $clip = ''
    try { $clip = [System.Windows.Forms.Clipboard]::GetText() } catch { }
    if (-not $clip) { return }
    $urls = @(Get-LinksFromText $clip)
    if ($urls.Count -eq 0) { $txtLink.SelectedText = $clip.Trim(); return }
    Add-PastedLinks $urls
}

function Invoke-LinkEnter {
    $typed = $txtLink.Text.Trim()
    if (-not $typed) { return }
    $urls = @(Get-LinksFromText $typed)
    if ($urls.Count -gt 0) { Add-PastedLinks $urls }
}

# ---------------------------------------------------------------------
#  Queue tab
# ---------------------------------------------------------------------
function Get-ClipText($c) {
    $a1 = [string]$c.Start
    $b1 = [string]$c.End
    if ($a1 -eq '') { $a1 = (Tx 'clip_start') }
    if ($b1 -eq '') { $b1 = (Tx 'clip_end') }
    return ('{0} -> {1}' -f $a1, $b1)
}

function Update-QueueGrid {
    $grid.Rows.Clear()
    $n = 0
    foreach ($it in $Items) {
        $clips = @($it.Clips)
        $count = [math]::Max(1, $clips.Count)
        $title = $it.Url
        if ($it.VideoId -and $P.Cache.ContainsKey($it.VideoId) -and $P.Cache[$it.VideoId].Title) { $title = $P.Cache[$it.VideoId].Title }
        for ($i = 0; $i -lt $count; $i++) {
            $n = $n + 1
            $key = '{0}|{1}' -f $it.Id, $i
            $clipText = (Tx 'clip_whole')
            if ($clips.Count -gt 0) { $clipText = Get-ClipText $clips[$i] }
            $code = 'Queued'
            if ($RowStatus.ContainsKey($key)) { $code = $RowStatus[$key] }
            $file = ''
            if ($RowFile.ContainsKey($key)) { $file = $RowFile[$key] }
            $ri = $grid.Rows.Add([object[]]@($n, $title, $FormatLabels[$it.Fmt], $clipText, (Tx ('rs_' + $code)), $file))
            $grid.Rows[$ri].Tag = $key
        }
    }
}

function Get-SelectedItemIds {
    $ids = @()
    foreach ($r in $grid.SelectedRows) {
        $key = [string]$r.Tag
        $cut = $key.IndexOf('|')
        if ($cut -gt 0) {
            $id = [int]$key.Substring(0, $cut)
            if ($ids -notcontains $id) { $ids += $id }
        }
    }
    return ,$ids
}

function Remove-SelectedItems {
    $ids = Get-SelectedItemIds
    if ($ids.Count -eq 0) { [void](Show-Msg (Tx 'msg_sel_one') 'videoprep' 'OK' 'Information'); return }
    for ($i = $Items.Count - 1; $i -ge 0; $i--) {
        if ($ids -contains $Items[$i].Id) { $Items.RemoveAt($i) }
    }
    Update-QueueGrid
}

function Move-SelectedItem([int]$dir) {
    $ids = Get-SelectedItemIds
    if ($ids.Count -ne 1) { return }
    $idx = -1
    for ($i = 0; $i -lt $Items.Count; $i++) { if ($Items[$i].Id -eq $ids[0]) { $idx = $i; break } }
    $j = $idx + $dir
    if ($idx -lt 0 -or $j -lt 0 -or $j -ge $Items.Count) { return }
    $tmp = $Items[$idx]
    $Items[$idx] = $Items[$j]
    $Items[$j] = $tmp
    Update-QueueGrid
    foreach ($row in $grid.Rows) {
        if ([string]$row.Tag -like ('{0}|*' -f $ids[0])) { $row.Selected = $true; break }
    }
}

function Edit-SelectedItem {
    $ids = Get-SelectedItemIds
    if ($ids.Count -ne 1) { [void](Show-Msg (Tx 'msg_sel_one') 'videoprep' 'OK' 'Information'); return }
    $it = $null
    foreach ($x in $Items) { if ($x.Id -eq $ids[0]) { $it = $x; break } }
    if ($null -eq $it) { return }
    if ($Draft.Url) { if (-not (Send-Draft $false)) { return } }

    $Draft.Url = $it.Url
    $Draft.Id = $it.VideoId
    $Draft.EditId = $it.Id
    Clear-ClipRows
    if ($it.Kind -eq 'audio') { $radAudio.Checked = $true } else { $radVideo.Checked = $true }
    Update-FormatList
    $ix = [array]::IndexOf(@($UiState.FmtNow), $it.Fmt)
    if ($ix -ge 0) { $cmbFmt.SelectedIndex = $ix }
    Update-ResList
    $capText = ''
    foreach ($k in $ResMap.Keys) { if ($ResMap[$k] -eq $it.Cap) { $capText = $k } }
    $ci = [array]::IndexOf(@($cmbRes.Items), $capText)
    if ($ci -ge 0) { $cmbRes.SelectedIndex = $ci }
    switch ($it.NameMode) {
        'custom' { $radN2.Checked = $true; $txtCustom.Text = $it.Custom }
        'series' { $radN3.Checked = $true; $txtSeries.Text = $it.Prefix }
        default  { $radN1.Checked = $true }
    }
    foreach ($c in @($it.Clips)) { Add-ClipRow ([string]$c.Start) ([string]$c.End) }
    Update-NameControls
    Update-Hint
    Update-Example
    $tabs.SelectedTab = $pgDownload
    if ($it.VideoId) { Request-Preview $it.Url }
}

function Import-LinksFromFile([string]$path) {
    $text = ''
    try { $text = Get-Content -LiteralPath $path -Raw } catch { }
    $urls = @(Get-LinksFromText $text)
    if ($urls.Count -eq 0) {
        [void](Show-Msg (Tx 'msg_nolinks') 'videoprep' 'OK' 'Information')
        return
    }
    foreach ($u in $urls) { Add-DefaultItem $u }
    if ($tabs.SelectedTab -eq $pgQueue) { Update-QueueGrid }
}

# ---------------------------------------------------------------------
#  Settings storage
# ---------------------------------------------------------------------
function Save-GuiSettings {
    try {
        New-Item -ItemType Directory -Force -Path $SettingsDir | Out-Null
        $o = [ordered]@{
            folder     = $txtFolder.Text
            naming     = (Get-DefaultNaming).Mode
            prefix     = $txtSeries.Text
            cookie     = $cmbCookie.SelectedIndex
            cookieFile = $txtCookieFile.Text
            subs       = $Opt.Subs
            subLangs   = $Opt.SubLangs
            thumbs     = $Opt.Thumbs
            archive    = $Opt.Archive
            fallback   = $Opt.Fallback
            keepFull   = $Opt.KeepFull
            crf        = [int]$Opt.Crf
            limit      = [int]$Opt.Limit
            sleep      = [int]$Opt.Sleep
            theme      = $Opt.Theme
            customColor = $Opt.CustomColor
            lang       = $Opt.Lang
            autoUpdate = $Opt.AutoUpdate
            lastUpdate = $S.LastUpdate
            sound      = $Opt.Sound
            openDone   = $Opt.OpenDone
        }
        ($o | ConvertTo-Json) | Set-Content -LiteralPath $SettingsFile -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------------
#  Theme
# ---------------------------------------------------------------------
function Set-ThemeOn($ctl, $p) {
    if ($ctl -is [System.Windows.Forms.TabPage] -or $ctl -is [System.Windows.Forms.Form]) {
        $ctl.BackColor = $p.bg
        $ctl.ForeColor = $p.tx
    }
    elseif ($ctl -is [System.Windows.Forms.TabControl]) { }
    elseif ($ctl -is [System.Windows.Forms.GroupBox]) {
        $ctl.BackColor = $p.card
        $ctl.ForeColor = $p.tx
    }
    elseif ($ctl -is [System.Windows.Forms.Panel]) {
        $ctl.BackColor = $p.card
        $ctl.ForeColor = $p.tx
    }
    elseif ($ctl -is [System.Windows.Forms.Label]) {
        $ctl.BackColor = [System.Drawing.Color]::Transparent
        if ($ctl.Tag -eq 'muted') { $ctl.ForeColor = $p.mu }
        elseif ($ctl.Tag -eq 'link') { $ctl.ForeColor = $p.ot }
        else { $ctl.ForeColor = $p.tx }
    }
    elseif ($ctl -is [System.Windows.Forms.TextBox]) {
        if ($ctl.Tag -ne 'log') {
            $ctl.BackColor = $p.inp
            $ctl.ForeColor = $p.tx
        }
    }
    elseif ($ctl -is [System.Windows.Forms.ComboBox] -or $ctl -is [System.Windows.Forms.NumericUpDown]) {
        $ctl.BackColor = $p.inp
        $ctl.ForeColor = $p.tx
    }
    elseif ($ctl -is [System.Windows.Forms.Button]) {
        $ctl.FlatStyle = 'Flat'
        $ctl.FlatAppearance.BorderColor = $p.bd
        $ctl.UseVisualStyleBackColor = $false
        switch ([string]$ctl.Tag) {
            'g' { $ctl.BackColor = $p.gb; $ctl.ForeColor = $p.gt; $ctl.FlatAppearance.BorderColor = $p.gb }
            'r' { $ctl.BackColor = $p.rb; $ctl.ForeColor = $p.rt; $ctl.FlatAppearance.BorderColor = $p.rb }
            'o' { $ctl.BackColor = $p.ob; $ctl.ForeColor = $p.ot; $ctl.FlatAppearance.BorderColor = $p.ob }
            default { $ctl.BackColor = $p.card; $ctl.ForeColor = $p.tx }
        }
    }
    elseif ($ctl -is [System.Windows.Forms.CheckBox] -or $ctl -is [System.Windows.Forms.RadioButton]) {
        $ctl.BackColor = [System.Drawing.Color]::Transparent
        $ctl.ForeColor = $p.tx
    }
    elseif ($ctl -is [System.Windows.Forms.PictureBox]) {
        $ctl.BackColor = $p.bg
    }
    elseif ($ctl -is [System.Windows.Forms.DataGridView]) {
        $ctl.BackgroundColor = $p.bg
        $ctl.GridColor = $p.bd
        $ctl.EnableHeadersVisualStyles = $false
        $ctl.ColumnHeadersDefaultCellStyle.BackColor = $p.card
        $ctl.ColumnHeadersDefaultCellStyle.ForeColor = $p.tx
        $ctl.DefaultCellStyle.BackColor = $p.card
        $ctl.DefaultCellStyle.ForeColor = $p.tx
        $ctl.DefaultCellStyle.SelectionBackColor = $p.ob
        $ctl.DefaultCellStyle.SelectionForeColor = $p.ot
    }
    foreach ($ch in $ctl.Controls) { Set-ThemeOn $ch $p }
}

function Apply-Theme {
    $script:Pal = Get-Palette $Opt.Theme
    Set-ThemeOn $form $Pal
    $tabs.Invalidate()
    $btnPickColor.Visible = ($Opt.Theme -eq 'custom')
    foreach ($r in $ClipRows) { Test-ClipText $r.T1; Test-ClipText $r.T2 }
}

# ---------------------------------------------------------------------
#  Language
# ---------------------------------------------------------------------
function Register-Text($ctl, [string]$key) { [void]$LangMap.Add(@($ctl, $key)) }

function Apply-Language {
    foreach ($pair in $LangMap) { $pair[0].Text = (Tx $pair[1]) }
    foreach ($cr in $ClipRows) { $cr.L1.Text = (Tx 'lbl_start'); $cr.L2.Text = (Tx 'lbl_end') }
    $txtLink.CueText = (Tx 'ph_link')
    $lblAbout.Text = ((Tx 'txt_about') -f $AppVersion)

    $grid.Columns['colNum'].HeaderText = (Tx 'col_num')
    $grid.Columns['colName'].HeaderText = (Tx 'col_name')
    $grid.Columns['colFmt'].HeaderText = (Tx 'col_fmt')
    $grid.Columns['colClip'].HeaderText = (Tx 'col_clip')
    $grid.Columns['colStatus'].HeaderText = (Tx 'col_status')
    $grid.Columns['colFile'].HeaderText = (Tx 'col_file')

    $tip.SetToolTip($lblClipHelp, (Tx 'tip_tc'))
    $tip.SetToolTip($btnFolderIcon, (Tx 'tip_folder'))

    $UiState.Busy = $true
    $sel = $cmbCookie.SelectedIndex
    if ($sel -lt 0) { $sel = 0 }
    $cmbCookie.Items.Clear()
    [void]$cmbCookie.Items.Add((Tx 'ck_auto'))
    foreach ($b in $BrowserDefs) { [void]$cmbCookie.Items.Add($b.Name) }
    [void]$cmbCookie.Items.Add((Tx 'ck_file'))
    [void]$cmbCookie.Items.Add((Tx 'ck_none'))
    $cmbCookie.SelectedIndex = $sel

    $ti = [array]::IndexOf($ThemeNames, $Opt.Theme)
    if ($ti -lt 0) { $ti = 0 }
    $cmbTheme.Items.Clear()
    foreach ($n in $ThemeNames) { [void]$cmbTheme.Items.Add((Tx ('th_' + $n))) }
    $cmbTheme.SelectedIndex = $ti
    $UiState.Busy = $false

    if ($S.Mode -eq 'idle') { $lblStatus.Text = (Tx 'st_ready') }
    if ($Draft.Id) { Show-Preview $Draft.Id } else { Clear-PreviewPanel }
    Update-Hint
    Update-Example
    $tabs.Invalidate()
    if ($tabs.SelectedTab -eq $pgQueue) { Update-QueueGrid }
}

# ---------------------------------------------------------------------
#  Options window
# ---------------------------------------------------------------------
function Show-OptionsDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = (Tx 'dlg_options')
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $dlg.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    $dlg.AutoScaleMode = 'Dpi'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterParent'
    $dlg.ClientSize = New-Object System.Drawing.Size(540, 330)

    $oSubs = New-Ctl 'System.Windows.Forms.CheckBox' 16 14 300 22 (Tx 'opt_subs') $dlg
    $lSub = New-Ctl 'System.Windows.Forms.Label' 330 17 80 20 (Tx 'opt_langs') $dlg
    $tSub = New-Ctl 'System.Windows.Forms.TextBox' 412 14 110 24 ([string]$Opt.SubLangs) $dlg
    $oThumbs = New-Ctl 'System.Windows.Forms.CheckBox' 16 46 500 22 (Tx 'opt_thumbs') $dlg
    $oArch = New-Ctl 'System.Windows.Forms.CheckBox' 16 78 500 22 (Tx 'opt_skip') $dlg
    $oConv = New-Ctl 'System.Windows.Forms.CheckBox' 16 110 510 22 (Tx 'opt_conv') $dlg
    $oKeep = New-Ctl 'System.Windows.Forms.CheckBox' 16 142 510 22 (Tx 'opt_keep') $dlg
    $lCrf = New-Ctl 'System.Windows.Forms.Label' 16 180 400 20 (Tx 'opt_crf') $dlg
    $nCrf = New-Ctl 'System.Windows.Forms.NumericUpDown' 440 177 70 24 $null $dlg
    $lLim = New-Ctl 'System.Windows.Forms.Label' 16 212 400 20 (Tx 'opt_limit') $dlg
    $nLim = New-Ctl 'System.Windows.Forms.NumericUpDown' 440 209 70 24 $null $dlg
    $lSlp = New-Ctl 'System.Windows.Forms.Label' 16 244 400 20 (Tx 'opt_sleep') $dlg
    $nSlp = New-Ctl 'System.Windows.Forms.NumericUpDown' 440 241 70 24 $null $dlg
    $bOk = New-Ctl 'System.Windows.Forms.Button' 340 286 90 30 (Tx 'btn_ok') $dlg
    $bCan = New-Ctl 'System.Windows.Forms.Button' 436 286 90 30 (Tx 'btn_cancel') $dlg
    $nCrf.Minimum = 10; $nCrf.Maximum = 28
    $nLim.Minimum = 0; $nLim.Maximum = 500
    $nSlp.Minimum = 0; $nSlp.Maximum = 30
    $oSubs.Checked = [bool]$Opt.Subs
    $oThumbs.Checked = [bool]$Opt.Thumbs
    $oArch.Checked = [bool]$Opt.Archive
    $oConv.Checked = [bool]$Opt.Fallback
    $oKeep.Checked = [bool]$Opt.KeepFull
    $nCrf.Value = [int]$Opt.Crf
    $nLim.Value = [int]$Opt.Limit
    $nSlp.Value = [int]$Opt.Sleep
    $bOk.DialogResult = 'OK'
    $bCan.DialogResult = 'Cancel'
    $dlg.AcceptButton = $bOk
    $dlg.CancelButton = $bCan
    Set-ThemeOn $dlg $Pal

    if ($dlg.ShowDialog($form) -eq 'OK') {
        $Opt.Subs = $oSubs.Checked
        $Opt.SubLangs = $tSub.Text.Trim()
        $Opt.Thumbs = $oThumbs.Checked
        $Opt.Archive = $oArch.Checked
        $Opt.Fallback = $oConv.Checked
        $Opt.KeepFull = $oKeep.Checked
        $Opt.Crf = [int]$nCrf.Value
        $Opt.Limit = [int]$nLim.Value
        $Opt.Sleep = [int]$nSlp.Value
        Save-GuiSettings
        Reset-Details
    }
    $dlg.Dispose()
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

function Get-FmtGroup {
    $f = Get-SelFmt
    if ($f -eq 'mp4' -or $f -eq 'movh' -or (Get-FormatKind $f) -eq 'audio') { return 'h264' }
    return 'any'
}

function On-FormatChanged {
    if ($UiState.Busy) { return }
    Update-ResList
    Update-Hint
    Update-Example
    $grp = Get-FmtGroup
    if ($grp -ne $UiState.Group) {
        $UiState.Group = $grp
        Reset-Details
    } elseif ($Draft.Id) {
        Show-Preview $Draft.Id
    }
}

function Open-SaveFolder {
    $f = $txtFolder.Text.Trim('" ')
    if ($f -and (Test-Path -LiteralPath $f)) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $f) }
    else { [void](Show-Msg (Tx 'msg_nofolder') 'videoprep' 'OK' 'Information') }
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
    $tabs.DrawMode = 'OwnerDrawFixed'
    $tabs.SizeMode = 'Fixed'
    $tabs.ItemSize = New-Object System.Drawing.Size(110, 26)
    $form.Controls.Add($tabs)

    $pgDownload = New-Page ''
    $pgQueue    = New-Page ''
    $pgSettings = New-Page ''
    $pgLog      = New-Page ''

    # ================= DOWNLOAD TAB =================
    $txtLink = New-Ctl 'PasteBox' 8 10 720 26 $null $pgDownload
    $txtLink.AllowDrop = $true

    $pnlFmt = New-Ctl 'System.Windows.Forms.Panel' 8 44 720 64 $null $pgDownload
    $pnlFmt.BorderStyle = 'FixedSingle'
    $lblType = New-Ctl 'System.Windows.Forms.Label' 10 11 44 20 '' $pnlFmt
    $lblType.Tag = 'muted'
    $radVideo = New-Ctl 'System.Windows.Forms.RadioButton' 58 9 80 22 '' $pnlFmt
    $radAudio = New-Ctl 'System.Windows.Forms.RadioButton' 140 9 100 22 '' $pnlFmt
    $lblFmt = New-Ctl 'System.Windows.Forms.Label' 248 11 56 20 '' $pnlFmt
    $lblFmt.Tag = 'muted'
    $cmbFmt = New-Ctl 'System.Windows.Forms.ComboBox' 306 7 200 24 $null $pnlFmt
    $cmbFmt.DropDownStyle = 'DropDownList'
    $lblRes = New-Ctl 'System.Windows.Forms.Label' 514 11 100 20 '' $pnlFmt
    $lblRes.Tag = 'muted'
    $cmbRes = New-Ctl 'System.Windows.Forms.ComboBox' 618 7 90 24 $null $pnlFmt
    $cmbRes.DropDownStyle = 'DropDownList'
    $lblHint = New-Ctl 'System.Windows.Forms.Label' 10 38 700 20 '' $pnlFmt
    $lblHint.Tag = 'muted'

    $pnlClipCard = New-Ctl 'System.Windows.Forms.Panel' 8 116 470 196 $null $pgDownload
    $pnlClipCard.BorderStyle = 'FixedSingle'
    $lblClips = New-Ctl 'System.Windows.Forms.Label' 10 8 330 20 '' $pnlClipCard
    $lblClips.Tag = 'muted'
    $lblClipHelp = New-Ctl 'System.Windows.Forms.Label' 344 8 30 20 '(?)' $pnlClipCard
    $lblClipHelp.Tag = 'link'
    $lblClipHelp.Cursor = [System.Windows.Forms.Cursors]::Help
    $pnlClips = New-Ctl 'System.Windows.Forms.Panel' 8 32 452 122 $null $pnlClipCard
    $pnlClips.AutoScroll = $true
    $btnAddClip = New-Ctl 'System.Windows.Forms.Button' 10 160 170 26 '' $pnlClipCard

    $pnlPrev = New-Ctl 'System.Windows.Forms.Panel' 486 116 242 196 $null $pgDownload
    $pnlPrev.BorderStyle = 'FixedSingle'
    $picThumb = New-Ctl 'System.Windows.Forms.PictureBox' 8 8 224 126 $null $pnlPrev
    $picThumb.SizeMode = 'Zoom'
    $lblTitle = New-Ctl 'System.Windows.Forms.Label' 8 138 224 20 '' $pnlPrev
    $lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $lblTitle.AutoEllipsis = $true
    $lblMeta = New-Ctl 'System.Windows.Forms.Label' 8 158 224 34 '' $pnlPrev
    $lblMeta.Tag = 'muted'
    $lblMeta.AutoEllipsis = $true

    $grpNames = New-Ctl 'System.Windows.Forms.GroupBox' 8 320 720 124 '' $pgDownload
    $radN1 = New-Ctl 'System.Windows.Forms.RadioButton' 14 22 260 22 '' $grpNames
    $radN2 = New-Ctl 'System.Windows.Forms.RadioButton' 14 48 190 22 '' $grpNames
    $txtCustom = New-Ctl 'System.Windows.Forms.TextBox' 210 46 220 24 $null $grpNames
    $radN3 = New-Ctl 'System.Windows.Forms.RadioButton' 14 74 190 22 '' $grpNames
    $txtSeries = New-Ctl 'System.Windows.Forms.TextBox' 210 72 220 24 $null $grpNames
    $lblExample = New-Ctl 'System.Windows.Forms.Label' 14 100 520 18 '' $grpNames
    $lblExample.Tag = 'muted'
    $btnOptions = New-Ctl 'System.Windows.Forms.Button' 556 30 150 30 '' $grpNames
    $btnSend = New-Ctl 'System.Windows.Forms.Button' 556 70 150 36 '' $grpNames
    $btnSend.Tag = 'o'

    $btnFolderIcon = New-Ctl 'System.Windows.Forms.Button' 8 452 38 30 ([char]::ConvertFromUtf32(0x1F4C1)) $pgDownload
    $btnFolderIcon.Font = New-Object System.Drawing.Font('Segoe UI Emoji', 11)
    $btnBrowse = New-Ctl 'System.Windows.Forms.Button' 52 452 100 30 '' $pgDownload
    $lblSaveTo = New-Ctl 'System.Windows.Forms.Label' 160 459 74 20 '' $pgDownload
    $lblSaveTo.Tag = 'muted'
    $txtFolder = New-Ctl 'System.Windows.Forms.TextBox' 236 456 288 24 $null $pgDownload
    $btnStart = New-Ctl 'System.Windows.Forms.Button' 532 450 112 34 '' $pgDownload
    $btnStart.Tag = 'g'
    $btnStart.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $btnStop = New-Ctl 'System.Windows.Forms.Button' 650 450 78 34 '' $pgDownload
    $btnStop.Tag = 'r'
    $btnStop.Enabled = $false

    $bar = New-Ctl 'System.Windows.Forms.ProgressBar' 8 496 720 16 $null $pgDownload
    $bar.Minimum = 0
    $bar.Maximum = 100
    $lblStatus = New-Ctl 'System.Windows.Forms.Label' 8 516 720 20 '' $pgDownload

    # ================= QUEUE TAB =================
    $grid = New-Ctl 'System.Windows.Forms.DataGridView' 8 8 720 468 $null $pgQueue
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.ReadOnly = $true
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $true
    $grid.AutoSizeColumnsMode = 'None'
    [void]$grid.Columns.Add('colNum', '#')
    [void]$grid.Columns.Add('colName', 'Name')
    [void]$grid.Columns.Add('colFmt', 'Format')
    [void]$grid.Columns.Add('colClip', 'Clip')
    [void]$grid.Columns.Add('colStatus', 'Status')
    [void]$grid.Columns.Add('colFile', 'File')
    $grid.Columns['colNum'].Width = 32
    $grid.Columns['colName'].Width = 228
    $grid.Columns['colFmt'].Width = 140
    $grid.Columns['colClip'].Width = 132
    $grid.Columns['colStatus'].Width = 90
    $grid.Columns['colFile'].Width = 80
    foreach ($col in $grid.Columns) { $col.SortMode = 'NotSortable' }

    $btnEdit = New-Ctl 'System.Windows.Forms.Button' 8 486 90 28 '' $pgQueue
    $btnRemove = New-Ctl 'System.Windows.Forms.Button' 104 486 90 28 '' $pgQueue
    $btnUp = New-Ctl 'System.Windows.Forms.Button' 200 486 80 28 '' $pgQueue
    $btnDown = New-Ctl 'System.Windows.Forms.Button' 286 486 90 28 '' $pgQueue
    $btnRetry = New-Ctl 'System.Windows.Forms.Button' 382 486 190 28 '' $pgQueue
    $btnRetry.Enabled = $false
    $btnLoadTxt = New-Ctl 'System.Windows.Forms.Button' 8 520 130 28 '' $pgQueue
    $btnClearQ = New-Ctl 'System.Windows.Forms.Button' 144 520 150 28 '' $pgQueue
    $lblQHelp = New-Ctl 'System.Windows.Forms.Label' 8 556 720 34 '' $pgQueue
    $lblQHelp.Tag = 'muted'

    # ================= SETTINGS TAB =================
    $lblCookies = New-Ctl 'System.Windows.Forms.Label' 12 16 260 20 '' $pgSettings
    $cmbCookie = New-Ctl 'System.Windows.Forms.ComboBox' 278 13 446 24 $null $pgSettings
    $cmbCookie.DropDownStyle = 'DropDownList'
    $lblCookieFile = New-Ctl 'System.Windows.Forms.Label' 12 50 200 20 '' $pgSettings
    $txtCookieFile = New-Ctl 'System.Windows.Forms.TextBox' 218 47 396 24 $null $pgSettings
    $btnCookieFile = New-Ctl 'System.Windows.Forms.Button' 622 46 102 26 'Browse...' $pgSettings
    $lblPrivacy = New-Ctl 'System.Windows.Forms.Label' 12 80 712 54 '' $pgSettings
    $lblPrivacy.Tag = 'muted'

    $grpTools = New-Ctl 'System.Windows.Forms.GroupBox' 12 140 712 130 '' $pgSettings
    $lblTools = New-Ctl 'System.Windows.Forms.Label' 14 22 684 66 '' $grpTools
    $btnRecheck = New-Ctl 'System.Windows.Forms.Button' 14 92 150 28 '' $grpTools
    $btnUpdate = New-Ctl 'System.Windows.Forms.Button' 172 92 200 28 '' $grpTools

    $chkAutoUpdate = New-Ctl 'System.Windows.Forms.CheckBox' 12 284 712 22 '' $pgSettings
    $chkSound = New-Ctl 'System.Windows.Forms.CheckBox' 12 314 712 22 '' $pgSettings
    $chkOpenDone = New-Ctl 'System.Windows.Forms.CheckBox' 12 344 712 22 '' $pgSettings
    $btnClearArchive = New-Ctl 'System.Windows.Forms.Button' 12 378 330 28 '' $pgSettings

    $lblTheme = New-Ctl 'System.Windows.Forms.Label' 12 428 60 20 '' $pgSettings
    $cmbTheme = New-Ctl 'System.Windows.Forms.ComboBox' 76 425 190 24 $null $pgSettings
    $cmbTheme.DropDownStyle = 'DropDownList'
    $btnPickColor = New-Ctl 'System.Windows.Forms.Button' 274 424 140 28 '' $pgSettings
    $lblLang = New-Ctl 'System.Windows.Forms.Label' 440 428 70 20 '' $pgSettings
    $cmbLang = New-Ctl 'System.Windows.Forms.ComboBox' 512 425 170 24 $null $pgSettings
    $cmbLang.DropDownStyle = 'DropDownList'
    [void]$cmbLang.Items.Add('Español')
    [void]$cmbLang.Items.Add('English')
    $lblAbout = New-Ctl 'System.Windows.Forms.Label' 12 478 712 40 '' $pgSettings
    $lblAbout.Tag = 'muted'

    # ================= LOG TAB =================
    $txtLog = New-Ctl 'System.Windows.Forms.TextBox' 8 8 720 534 $null $pgLog
    $txtLog.Multiline = $true
    $txtLog.ReadOnly = $true
    $txtLog.WordWrap = $false
    $txtLog.ScrollBars = 'Both'
    $txtLog.Tag = 'log'
    $txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
    $txtLog.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $txtLog.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
    $btnCopyLog = New-Ctl 'System.Windows.Forms.Button' 8 550 140 30 '' $pgLog
    $btnSaveLog = New-Ctl 'System.Windows.Forms.Button' 154 550 150 30 '' $pgLog
    $btnClearLog = New-Ctl 'System.Windows.Forms.Button' 310 550 100 30 '' $pgLog
    $btnTest = New-Ctl 'System.Windows.Forms.Button' 416 550 190 30 '' $pgLog

    # Texts that change with the language
    Register-Text $pgDownload 'tab_dl'; Register-Text $pgQueue 'tab_q'; Register-Text $pgSettings 'tab_st'; Register-Text $pgLog 'tab_log'
    Register-Text $lblType 'lbl_type'; Register-Text $radVideo 'rad_video'; Register-Text $radAudio 'rad_audio'
    Register-Text $lblFmt 'lbl_fmt'; Register-Text $lblRes 'lbl_res'; Register-Text $lblClips 'lbl_clips'
    Register-Text $btnAddClip 'btn_addclip'; Register-Text $grpNames 'lbl_names'
    Register-Text $radN1 'rad_n1'; Register-Text $radN2 'rad_n2'; Register-Text $radN3 'rad_n3'
    Register-Text $btnOptions 'btn_options'; Register-Text $btnSend 'btn_send'; Register-Text $btnBrowse 'btn_browse'
    Register-Text $btnCookieFile 'btn_browse'
    Register-Text $lblSaveTo 'lbl_saveto'; Register-Text $btnStart 'btn_download'; Register-Text $btnStop 'btn_stop'
    Register-Text $btnEdit 'btn_edit'; Register-Text $btnRemove 'btn_remove'; Register-Text $btnUp 'btn_up'; Register-Text $btnDown 'btn_down'
    Register-Text $btnRetry 'btn_retry'; Register-Text $btnLoadTxt 'btn_loadtxt'; Register-Text $btnClearQ 'btn_clearq'; Register-Text $lblQHelp 'lbl_qhelp'
    Register-Text $lblCookies 'lbl_cookies'; Register-Text $lblCookieFile 'lbl_cookiefile'; Register-Text $lblPrivacy 'txt_privacy'
    Register-Text $grpTools 'grp_tools'; Register-Text $btnRecheck 'btn_recheck'; Register-Text $btnUpdate 'btn_update'
    Register-Text $chkAutoUpdate 'chk_autoupdate'; Register-Text $chkSound 'chk_sound'; Register-Text $chkOpenDone 'chk_opendone'
    Register-Text $btnClearArchive 'btn_cleararchive'; Register-Text $lblTheme 'lbl_theme'; Register-Text $btnPickColor 'btn_pickcolor'; Register-Text $lblLang 'lbl_lang'
    Register-Text $btnCopyLog 'btn_copylog'; Register-Text $btnSaveLog 'btn_savelog'; Register-Text $btnClearLog 'btn_clearlog'; Register-Text $btnTest 'btn_test'

    $LockCtls = @(
        $txtLink, $radVideo, $radAudio, $cmbFmt, $btnAddClip, $pnlClips, $radN1, $radN2, $radN3,
        $btnOptions, $btnSend, $btnBrowse, $txtFolder, $btnStart,
        $btnEdit, $btnRemove, $btnUp, $btnDown, $btnLoadTxt, $btnClearQ,
        $cmbCookie, $txtCookieFile, $btnCookieFile, $btnRecheck, $btnUpdate,
        $chkAutoUpdate, $chkSound, $chkOpenDone, $btnClearArchive
    )

    # ---- defaults + saved settings ----
    $defaultFolder = [Environment]::GetFolderPath('MyVideos')
    if (-not $defaultFolder) { $defaultFolder = [Environment]::GetFolderPath('Desktop') }
    $txtFolder.Text = $defaultFolder
    $txtSeries.Text = 'Video'
    $radN1.Checked = $true
    $radVideo.Checked = $true
    $cmbCookie.SelectedIndex = -1
    $txtCookieFile.Text = ''

    $cfg = Read-GuiSettings
    $cookieIdx = 0
    if ($cfg) {
        if ($cfg.folder) { $txtFolder.Text = [string]$cfg.folder }
        if ($cfg.prefix) { $txtSeries.Text = [string]$cfg.prefix }
        if ($cfg.naming -eq 'series') { $radN3.Checked = $true }
        if ($null -ne $cfg.cookie) { $cookieIdx = [int]$cfg.cookie }
        if ($cfg.cookieFile) { $txtCookieFile.Text = [string]$cfg.cookieFile }
        if ($null -ne $cfg.subs) { $Opt.Subs = [bool]$cfg.subs }
        if ($cfg.subLangs) { $Opt.SubLangs = [string]$cfg.subLangs }
        if ($null -ne $cfg.thumbs) { $Opt.Thumbs = [bool]$cfg.thumbs }
        if ($null -ne $cfg.archive) { $Opt.Archive = [bool]$cfg.archive }
        if ($null -ne $cfg.fallback) { $Opt.Fallback = [bool]$cfg.fallback }
        if ($null -ne $cfg.keepFull) { $Opt.KeepFull = [bool]$cfg.keepFull }
        if ($null -ne $cfg.crf) { $v = [int]$cfg.crf; if ($v -ge 10 -and $v -le 28) { $Opt.Crf = $v } }
        if ($null -ne $cfg.limit) { $v = [int]$cfg.limit; if ($v -ge 0 -and $v -le 500) { $Opt.Limit = $v } }
        if ($null -ne $cfg.sleep) { $v = [int]$cfg.sleep; if ($v -ge 0 -and $v -le 30) { $Opt.Sleep = $v } }
        if ($cfg.theme -and ($ThemeNames -contains [string]$cfg.theme)) { $Opt.Theme = [string]$cfg.theme }
        if ($cfg.customColor) { $Opt.CustomColor = [string]$cfg.customColor }
        if ($cfg.lang -eq 'es' -or $cfg.lang -eq 'en') { $Opt.Lang = [string]$cfg.lang }
        if ($null -ne $cfg.autoUpdate) { $Opt.AutoUpdate = [bool]$cfg.autoUpdate }
        if ($cfg.lastUpdate) { $S.LastUpdate = [string]$cfg.lastUpdate }
        if ($null -ne $cfg.sound) { $Opt.Sound = [bool]$cfg.sound }
        if ($null -ne $cfg.openDone) { $Opt.OpenDone = [bool]$cfg.openDone }
    }
    $chkAutoUpdate.Checked = $Opt.AutoUpdate
    $chkSound.Checked = $Opt.Sound
    $chkOpenDone.Checked = $Opt.OpenDone
    if ($Opt.Lang -eq 'es') { $cmbLang.SelectedIndex = 0 } else { $cmbLang.SelectedIndex = 1 }

    $UiState.Busy = $true
    Apply-Language
    $UiState.Busy = $true
    if ($cookieIdx -ge 0 -and $cookieIdx -lt $cmbCookie.Items.Count) { $cmbCookie.SelectedIndex = $cookieIdx } else { $cmbCookie.SelectedIndex = 0 }
    $UiState.Busy = $false
    Apply-Theme
    Update-FormatList
    $UiState.Group = (Get-FmtGroup)
    Update-NameControls
    Update-Example
    Clear-PreviewPanel

    # ---- tabs drawn with the theme colors ----
    $tabs.Add_DrawItem({
        param($sender, $ev)
        $pal = $Pal
        if ($null -eq $pal) { return }
        $rect = $ev.Bounds
        $brush = New-Object System.Drawing.SolidBrush($pal.bg)
        $ev.Graphics.FillRectangle($brush, $rect)
        $brush.Dispose()
        $sel = ($ev.Index -eq $tabs.SelectedIndex)
        $col = $pal.mu
        if ($sel) { $col = $pal.tx }
        $flags = [System.Windows.Forms.TextFormatFlags]'HorizontalCenter, VerticalCenter'
        [System.Windows.Forms.TextRenderer]::DrawText($ev.Graphics, $tabs.TabPages[$ev.Index].Text, $form.Font, $rect, $col, $flags)
        if ($sel) {
            $pen = New-Object System.Drawing.Pen($pal.ot, 2)
            $ev.Graphics.DrawLine($pen, ($rect.Left + 8), ($rect.Bottom - 2), ($rect.Right - 8), ($rect.Bottom - 2))
            $pen.Dispose()
        }
    })

    # ---- events: link box ----
    $selectAll = {
        param($sender, $ev)
        if ($ev.Control -and $ev.KeyCode -eq 'A') {
            $sender.SelectAll()
            $ev.SuppressKeyPress = $true
        }
    }
    $txtLink.Add_KeyDown($selectAll)
    $txtLog.Add_KeyDown($selectAll)
    $txtLink.Add_Pasting({ try { Invoke-SmartPaste } catch { } })
    $txtLink.Add_KeyDown({
        param($sender, $ev)
        if ($ev.KeyCode -eq 'Return') {
            $ev.SuppressKeyPress = $true
            try { Invoke-LinkEnter } catch { }
        }
    })

    $dragEnter = {
        param($sender, $ev)
        $ev.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    }
    $dragDrop = {
        param($sender, $ev)
        try {
            if ($ev.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
                foreach ($f in @($ev.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))) {
                    if ($f -and (Test-Path -LiteralPath $f)) { Import-LinksFromFile $f }
                }
            } elseif ($ev.Data.GetDataPresent([System.Windows.Forms.DataFormats]::Text)) {
                $urls = @(Get-LinksFromText ([string]$ev.Data.GetData([System.Windows.Forms.DataFormats]::Text)))
                if ($urls.Count -gt 0) { Add-PastedLinks $urls }
            }
        } catch { }
    }
    $txtLink.Add_DragEnter($dragEnter)
    $txtLink.Add_DragDrop($dragDrop)
    $pgDownload.AllowDrop = $true
    $pgDownload.Add_DragEnter($dragEnter)
    $pgDownload.Add_DragDrop($dragDrop)

    # ---- events: format, names, clips ----
    $radVideo.Add_CheckedChanged({ if (-not $UiState.Busy) { Update-FormatList; On-FormatChanged } })
    $cmbFmt.Add_SelectedIndexChanged({ On-FormatChanged })
    $cmbRes.Add_SelectedIndexChanged({ if (-not $UiState.Busy) { Reset-Details } })
    $radN1.Add_CheckedChanged({ Update-NameControls; Update-Example })
    $radN2.Add_CheckedChanged({ Update-NameControls; Update-Example })
    $radN3.Add_CheckedChanged({ Update-NameControls; Update-Example })
    $txtCustom.Add_TextChanged({ Update-Example })
    $txtSeries.Add_TextChanged({ Update-Example })
    $btnAddClip.Add_Click({ Add-ClipRow })
    $btnOptions.Add_Click({ try { Show-OptionsDialog } catch { Write-Log ('Options window error: ' + $_.Exception.Message) } })
    $btnSend.Add_Click({ [void](Send-Draft $true) })

    # ---- events: save folder and actions ----
    $btnFolderIcon.Add_Click({ Open-SaveFolder })
    $btnBrowse.Add_Click({
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.ShowNewFolderButton = $true
        if ($txtFolder.Text -and (Test-Path -LiteralPath $txtFolder.Text)) { $d.SelectedPath = $txtFolder.Text }
        if ($d.ShowDialog() -eq 'OK') { $txtFolder.Text = $d.SelectedPath }
    })
    $btnStart.Add_Click({ Start-Batch })
    $btnStop.Add_Click({
        if ($S.Runner) {
            $S.Cancelled = $true
            $S.Runner.Kill()
            $lblStatus.Text = (Tx 'st_stopping')
        }
    })

    # ---- events: queue tab ----
    $tabs.Add_SelectedIndexChanged({
        if ($tabs.SelectedTab -eq $pgQueue) { try { Update-QueueGrid } catch { } }
    })
    $btnEdit.Add_Click({ try { Edit-SelectedItem } catch { Write-Log ('Edit error: ' + $_.Exception.Message) } })
    $btnRemove.Add_Click({ try { Remove-SelectedItems } catch { } })
    $btnUp.Add_Click({ try { Move-SelectedItem -1 } catch { } })
    $btnDown.Add_Click({ try { Move-SelectedItem 1 } catch { } })
    $btnRetry.Add_Click({ Start-Retry })
    $btnLoadTxt.Add_Click({
        $d = New-Object System.Windows.Forms.OpenFileDialog
        $d.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
        if ($d.ShowDialog() -eq 'OK') { Import-LinksFromFile $d.FileName }
    })
    $btnClearQ.Add_Click({ $Items.Clear(); Update-QueueGrid })

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
            [void](Show-Msg (Tx 'msg_tools_missing') 'videoprep' 'OK' 'Information')
            return
        }
        $S.LastUpdate = (Get-Date).ToString('o')
        $tabs.SelectedTab = $pgLog
        [void](Start-UpdateRun)
    })
    $btnClearArchive.Add_Click({
        $ans = Show-Msg (Tx 'msg_cleararchive') 'videoprep' 'YesNo' 'Question'
        if ($ans -eq 'Yes') {
            if (Test-Path -LiteralPath $ArchiveFile) { Remove-Item -LiteralPath $ArchiveFile -Force -ErrorAction SilentlyContinue }
            Write-Log 'History of downloaded videos cleared.'
        }
    })
    $chkAutoUpdate.Add_CheckedChanged({ $Opt.AutoUpdate = $chkAutoUpdate.Checked })
    $chkSound.Add_CheckedChanged({ $Opt.Sound = $chkSound.Checked })
    $chkOpenDone.Add_CheckedChanged({ $Opt.OpenDone = $chkOpenDone.Checked })
    $cmbTheme.Add_SelectedIndexChanged({
        if ($UiState.Busy) { return }
        $i = $cmbTheme.SelectedIndex
        if ($i -ge 0) { $Opt.Theme = $ThemeNames[$i]; Apply-Theme; Save-GuiSettings }
    })
    $btnPickColor.Add_Click({
        $d = New-Object System.Windows.Forms.ColorDialog
        $d.FullOpen = $true
        try { $d.Color = ConvertFrom-Hex $Opt.CustomColor } catch { }
        if ($d.ShowDialog() -eq 'OK') {
            $Opt.CustomColor = ('#{0:x2}{1:x2}{2:x2}' -f $d.Color.R, $d.Color.G, $d.Color.B)
            Apply-Theme
            Save-GuiSettings
        }
    })
    $cmbLang.Add_SelectedIndexChanged({
        if ($UiState.Busy) { return }
        if ($cmbLang.SelectedIndex -eq 0) { $Opt.Lang = 'es' } else { $Opt.Lang = 'en' }
        Apply-Language
        Save-GuiSettings
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
        param($sender, $ev)
        if ($S.Runner -and -not $S.Runner.Done) {
            $ans = Show-Msg (Tx 'msg_running') 'videoprep' 'YesNo' 'Question'
            if ($ans -ne 'Yes') { $ev.Cancel = $true; return }
            $S.Cancelled = $true
            $S.Runner.Kill()
        }
        Stop-DetailRun
        Save-GuiSettings
    })

    $form.Add_Shown({
        Update-ToolStatus
        $missing = @(Get-MissingTools)
        if ($missing.Count -gt 0) {
            Write-Log ('First run: press Download and the app will fetch what it needs (' + ($missing -join ', ') + ', about 200 MB, once).')
        } else {
            Write-Log 'Ready. Paste a link, choose the format and press Send to queue, then Download.'
        }
        $found = @($BrowserDefs | Where-Object { Test-Path -LiteralPath $_.Path } | ForEach-Object { $_.Name })
        if ($found.Count -gt 0) { Write-Log ('Browsers found on this PC: ' + ($found -join ', ')) }

        if ($Opt.AutoUpdate -and $missing.Count -eq 0) {
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
