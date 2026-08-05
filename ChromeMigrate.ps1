<#
.SYNOPSIS
    Chrome Profile Migrator 1.0 - moves a profile out of any Chromium-based
    browser into an isolated Chrome instance backed by its own --user-data-dir,
    then gives that instance its own taskbar button and Start menu entry.

.DESCRIPTION
    Run this ON THE MACHINE WHERE THE SOURCE BROWSER IS INSTALLED, signed in as
    the Windows account that owns the profile. That is what makes the encrypted
    data movable: the key is DPAPI-wrapped to the account, not to the browser.

    Run it with no parameters for an interactive menu. Every action is also
    reachable from the command line - see the parameter list.

    Sources: Sidekick, Edge, Brave, Vivaldi, Yandex, Opera, Opera GX,
    Cent Browser, SRWare Iron, Comodo Dragon, Chromium.
    Chrome itself is deliberately absent - it is the destination.

    Moved automatically:
        Bookmarks, History, Favicons, Top Sites, Shortcuts
        Web Data  - autofill entries, saved addresses, custom search engines

    Moved on request:
        -IncludePasswords   saved logins (both password stores)
        -IncludeCards       saved credit cards (inside Web Data)
        -IncludeCookies     live sessions      (OFF by default)
        -IncludePreferences browser settings, with the extension block stripped

    How the encrypted items move
    ----------------------------
    The source keeps an AES-256 key in its Local State, DPAPI-wrapped to your
    Windows account. This unwraps it, generates a NEW random key for the target,
    writes that into the target's Local State, and re-encrypts every secret from
    the old key to the new one. Secrets exist only in memory - no plaintext CSV
    is ever written, and the new instance gets its own independent key.

    Rows that fail to decrypt are copied through untouched and reported. That is
    usually harmless: when a profile's key is regenerated, Chromium orphans the
    old rows and saves fresh ones alongside, so an unreadable row normally has a
    readable twin.

    Not moved: cache (disposable, version-specific) and extensions (must be
    reinstalled - store URLs are printed, and Manifest V2 ones are flagged since
    current Chrome refuses to load them).

    The source profile is only ever read. Migration refuses to start while the
    source browser is running, because a live database copies in a torn state.

.PARAMETER Menu
    Force the interactive menu even when other parameters are present.

.PARAMETER List
    Show every detected browser, its profiles, and their saved-login counts.

.PARAMETER Source
    Which browser to migrate from, e.g. Vivaldi. See -List.

.PARAMETER Name
    Label for the instance. Becomes the folder, Chrome profile name, shortcut
    name and icon letters. Also selects the instance for the taskbar actions.

.PARAMETER Root
    Parent folder holding the instance data dirs. Default C:\Browsers.

.PARAMETER SetTaskbarIcon
    Capture the instance's AppUserModelID and stamp it onto its shortcut, so a
    pinned taskbar button keeps the instance icon instead of the Chrome logo.

.PARAMETER StartMenu
    Install a Start-menu copy of the instance shortcut so it can be pinned.

.PARAMETER ShowAumid
    Print the AppUserModelID currently written on the instance shortcut.

.PARAMETER IgnoreRunningCheck
    Last resort. Skips the "source browser is running" guard. Only use this if
    the guard is misfiring - migrating a live profile can copy a torn database.

.EXAMPLE
    irm https://raw.githubusercontent.com/steathy/chrome-migration/main/ChromeMigrate.ps1 | iex

    Runs the interactive menu with nothing to download or install by hand.

.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/steathy/chrome-migration/main/ChromeMigrate.ps1))) -List

    Same script, with parameters. Piping to iex cannot pass arguments, so the
    scriptblock form is the one to use for command-line runs.

.EXAMPLE
    .\ChromeMigrate.ps1 -Source Vivaldi -Name Dad -IncludePasswords -DryRun

.EXAMPLE
    .\ChromeMigrate.ps1 -Name Dad -SetTaskbarIcon

.LINK
    https://github.com/steathy/chrome-migration
#>
[CmdletBinding()]
param(
    [switch] $Menu,
    [switch] $List,

    [string] $Source,
    [ValidatePattern('^[A-Za-z0-9 _.-]{1,40}$')]
    [string] $Name,

    [string] $Root = 'C:\Browsers',
    [string] $SourceProfile,
    [string] $SourceUserData,
    [string] $ChromePath,
    [switch] $IncludePasswords,
    [switch] $IncludeCards,
    [switch] $IncludeCookies,
    [switch] $IncludePreferences,
    [switch] $NoShortcut,
    [string] $ShortcutPath,
    [switch] $Force,
    [switch] $DryRun,
    [switch] $IgnoreRunningCheck,

    [switch] $SetTaskbarIcon,
    [switch] $StartMenu,
    [switch] $ShowAumid,
    [string] $Shortcut,
    [string] $Aumid,

    [switch] $Version
)

$ErrorActionPreference = 'Stop'
$SCRIPT_VERSION = '1.0'
$SCRIPT_HOME    = 'https://github.com/steathy/chrome-migration'

Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Drawing

function Say ($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok  ($m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }

# Abort without killing the host. `exit` would tear down the whole session when
# this script is run through `irm | iex`, so failures travel as an exception
# carrying a marker the top-level handler recognises and prints plainly.
function Die ($m) { throw "ABORT::$m" }

function Write-Failure ($err) {
    $m = [string]$err.Exception.Message
    if ($m.StartsWith('ABORT::')) {
        Write-Host "[x] $($m.Substring(7))" -ForegroundColor Red
    } else {
        Write-Host "[x] $m" -ForegroundColor Red
        if ($err.InvocationInfo) {
            Write-Host ("    line {0}: {1}" -f $err.InvocationInfo.ScriptLineNumber, $err.InvocationInfo.Line.Trim()) -ForegroundColor DarkGray
        }
    }
}

$LA = $env:LOCALAPPDATA
$RA = $env:APPDATA
$PF = ${env:ProgramFiles}
$PX = ${env:ProgramFiles(x86)}

#===========================================================================
# Browser registry.
#   UserData : candidate profile roots, first hit wins
#   Exe      : candidate executables - used to tell a running instance apart
#              from other browsers. Cent Browser and SRWare Iron both ship
#              their binary AS chrome.exe, so matching on process NAME alone
#              would flag real Chrome.
#   RootIsProfile : Opera keeps profile files at the root, with no Default dir
#
# Chrome is intentionally not listed. It is the destination, and migrating
# Chrome to Chrome is just a folder copy.
#===========================================================================
$BROWSERS = @(
    @{ Name='Sidekick';    UserData=@("$LA\Sidekick\User Data");
       Exe=@("$LA\Sidekick\Application\sidekick.exe") }
    @{ Name='Edge';        UserData=@("$LA\Microsoft\Edge\User Data");
       Exe=@("$PX\Microsoft\Edge\Application\msedge.exe","$PF\Microsoft\Edge\Application\msedge.exe") }
    @{ Name='Brave';       UserData=@("$LA\BraveSoftware\Brave-Browser\User Data");
       Exe=@("$PF\BraveSoftware\Brave-Browser\Application\brave.exe","$PX\BraveSoftware\Brave-Browser\Application\brave.exe","$LA\BraveSoftware\Brave-Browser\Application\brave.exe") }
    @{ Name='Vivaldi';     UserData=@("$LA\Vivaldi\User Data");
       Exe=@("$LA\Vivaldi\Application\vivaldi.exe","$PF\Vivaldi\Application\vivaldi.exe","$PX\Vivaldi\Application\vivaldi.exe") }
    # Yandex does not use Login Data / Web Data at all, and its password blobs
    # carry neither a v10 header nor a DPAPI one - it ships its own crypto with
    # its own key table. Everything unencrypted still migrates; secrets do not.
    # It installs machine-wide as often as per-user, hence the Program Files
    # entries: without them the browser reads as "not installed" and, worse,
    # the running check has no executable to match against.
    @{ Name='Yandex';      UserData=@("$LA\Yandex\YandexBrowser\User Data");
       Exe=@("$PF\Yandex\YandexBrowser\Application\browser.exe",
             "$PX\Yandex\YandexBrowser\Application\browser.exe",
             "$LA\Yandex\YandexBrowser\Application\browser.exe");
       LoginFiles=@('Ya Passman Data'); CardDb='Ya Credit Cards'; ProprietaryCrypto=$true }
    @{ Name='Opera';       UserData=@("$RA\Opera Software\Opera Stable");
       Exe=@("$PF\Opera\opera.exe","$PX\Opera\opera.exe","$LA\Programs\Opera\opera.exe"); RootIsProfile=$true }
    @{ Name='OperaGX';     UserData=@("$RA\Opera Software\Opera GX Stable");
       Exe=@("$PF\Opera GX\opera.exe","$PX\Opera GX\opera.exe","$LA\Programs\Opera GX\opera.exe"); RootIsProfile=$true }
    @{ Name='CentBrowser'; UserData=@("$LA\CentBrowser\User Data");
       Exe=@("$PF\CentBrowser\Application\chrome.exe","$PX\CentBrowser\Application\chrome.exe","$LA\CentBrowser\Application\chrome.exe") }
    # SRWare Iron ships its binary AS chrome.exe (like Cent), in a folder whose
    # name carries the bitness. It also stores user data in Chromium's own
    # directory - so that path is listed under SharedUserData, which is only
    # claimed when Iron's executable is actually present. Otherwise an
    # uninstalled Iron would shadow a genuine Chromium profile.
    @{ Name='Iron';
       UserData=@("$PF\SRWare Iron (64-Bit)\User Data","$PX\SRWare Iron\User Data",
                  "$LA\Iron\User Data","$LA\SRWare Iron\User Data");
       SharedUserData=@("$LA\Chromium\User Data");
       Exe=@("$PF\SRWare Iron (64-Bit)\chrome.exe","$PF\SRWare Iron\chrome.exe",
             "$PX\SRWare Iron (64-Bit)\chrome.exe","$PX\SRWare Iron\chrome.exe",
             "$PF\SRWare Iron (64-Bit)\iron.exe","$PX\SRWare Iron\iron.exe",
             "$LA\SRWare Iron\chrome.exe") }
    @{ Name='Dragon';      UserData=@("$LA\Comodo\Dragon\User Data");
       Exe=@("$PF\Comodo\Dragon\dragon.exe","$PX\Comodo\Dragon\dragon.exe") }
    @{ Name='Chromium';    UserData=@("$LA\Chromium\User Data");
       Exe=@("$PF\Chromium\Application\chrome.exe","$LA\Chromium\Application\chrome.exe") }
)

# Where Chrome itself lives - the migration target, resolved separately.
$CHROME_CANDIDATES = @(
    "$PF\Google\Chrome\Application\chrome.exe"
    "$PX\Google\Chrome\Application\chrome.exe"
    "$LA\Google\Chrome\Application\chrome.exe"
)

#===========================================================================
# Small console helpers for the interactive mode
#===========================================================================
function Read-YesNo {
    param([string]$Question, [bool]$Default = $false)
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $a = (Read-Host "  $Question $hint").Trim()
        if ($a -eq '')            { return $Default }
        if ($a -match '^(y|yes)$'){ return $true }
        if ($a -match '^(n|no)$') { return $false }
        Write-Host '    answer y or n' -ForegroundColor DarkGray
    }
}

# Returns a 0-based index, or -1 for "go back".
function Read-Index {
    param([string]$Prompt, [int]$Count)
    while ($true) {
        $a = (Read-Host "  $Prompt").Trim()
        if ($a -match '^(q|quit|b|back|0|)$') { return -1 }
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $Count) { return ($n - 1) }
        Write-Host "    enter 1-$Count, or 0 to go back" -ForegroundColor DarkGray
    }
}

function Read-InstanceName {
    param([string]$Root)
    while ($true) {
        $n = (Read-Host '  instance name (e.g. Dad, Lili, Banking)').Trim()
        if ($n -eq '') { return $null }
        if ($n -notmatch '^[A-Za-z0-9 _.-]{1,40}$') {
            Write-Host '    letters, digits, space, dot, dash and underscore only (max 40)' -ForegroundColor DarkGray
            continue
        }
        if (Test-Path (Join-Path $Root $n)) {
            Warn "$Root\$n already exists"
            if (Read-YesNo 'overwrite it?' $false) { return $n }
            continue
        }
        return $n
    }
}

function Write-Banner {
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor DarkGray
    Write-Host "   Chrome Profile Migrator $SCRIPT_VERSION" -ForegroundColor White
    Write-Host '   isolated Chrome instances from any Chromium browser' -ForegroundColor DarkGray
    Write-Host '  ============================================================' -ForegroundColor DarkGray
}

#===========================================================================
# Browser detection
#===========================================================================

# Pulls os_crypt.encrypted_key out of a Local State file.
# Windows PowerShell's ConvertFrom-Json builds a PSCustomObject and throws on
# empty or case-duplicate property names, which several Chromium forks emit
# (Vivaldi does). Fall back to a tolerant parser, then to plain text extraction.
function Get-OsCryptKeyB64 {
    param([string]$Path)
    $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    try {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $o = $raw | ConvertFrom-Json -AsHashtable
        } else {
            Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
            $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $ser.MaxJsonLength  = [int]::MaxValue
            $ser.RecursionLimit = 512
            $o = $ser.DeserializeObject($raw)
        }
        if ($o -and $o['os_crypt'] -and $o['os_crypt']['encrypted_key']) {
            return [string]$o['os_crypt']['encrypted_key']
        }
    } catch { }
    $m = [regex]::Match($raw, '"encrypted_key"\s*:\s*"([A-Za-z0-9+/=]+)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Resolve-Browser {
    param($Entry)
    $exe = $null
    foreach ($c in $Entry.Exe) { if (Test-Path $c) { $exe = $c; break } }

    $ud = $null
    foreach ($c in $Entry.UserData) { if (Test-Path $c) { $ud = $c; break } }

    # Directories another browser also uses are only claimed when this browser's
    # executable is genuinely installed.
    if (-not $ud -and $exe -and $Entry.SharedUserData) {
        foreach ($c in $Entry.SharedUserData) { if (Test-Path $c) { $ud = $c; break } }
    }
    if (-not $ud) { return $null }
    $logins = $Entry.LoginFiles
    if (-not $logins) { $logins = @('Login Data', 'Login Data For Account') }
    $cardDb = $Entry.CardDb
    if (-not $cardDb) { $cardDb = 'Web Data' }
    return New-Object PSObject -Property ([ordered]@{
        Name = $Entry.Name; UserData = $ud; Exe = $exe
        RootIsProfile     = [bool]$Entry.RootIsProfile
        LoginFiles        = $logins
        CardDb            = $cardDb
        ProprietaryCrypto = [bool]$Entry.ProprietaryCrypto
    })
}

# When several entries land on one directory, the installed browser owns it.
# SRWare Iron keeps its profile in Chromium's directory, so on a machine with
# Iron but no Chromium both would otherwise be listed for the same data - and
# the one without an executable is the guess. Entries with no executable are
# kept only when nothing installed claims that directory, so an orphaned
# profile left behind by an uninstall is still reachable.
function Get-DetectedBrowsers {
    $all = @()
    foreach ($e in $BROWSERS) {
        $b = Resolve-Browser $e
        if ($b) { $all += $b }
    }
    $ownedByInstalled = @{}
    foreach ($b in $all) { if ($b.Exe) { $ownedByInstalled[$b.UserData.ToLower()] = $true } }
    return @($all | Where-Object { $_.Exe -or -not $ownedByInstalled[$_.UserData.ToLower()] })
}

# Profile dirs. Opera keeps everything at the root; the rest use Default / Profile N.
function Get-BrowserProfiles {
    param($B)
    $out = @()
    if ($B.RootIsProfile -and (Test-Path (Join-Path $B.UserData 'Bookmarks'))) {
        $out += New-Object PSObject -Property @{ Name = '.'; Path = $B.UserData }
    }
    foreach ($d in Get-ChildItem $B.UserData -Directory -EA SilentlyContinue) {
        if ($d.Name -ne 'Default' -and $d.Name -notlike 'Profile *') { continue }
        if (-not (Test-Path (Join-Path $d.FullName 'Preferences'))) { continue }
        $out += New-Object PSObject -Property @{ Name = $d.Name; Path = $d.FullName }
    }
    # Unary comma: PowerShell unrolls a one-element array on return, and the
    # caller would then get a bare PSObject whose .Count is empty.
    return ,$out
}

function Resolve-ChromePath {
    param([string]$Preferred)
    if ($Preferred) {
        if (-not (Test-Path $Preferred)) { Die "Chrome not found at: $Preferred" }
        return $Preferred
    }
    foreach ($c in $CHROME_CANDIDATES) { if (Test-Path $c) { return $c } }
    Die 'Chrome not found. Install it, or pass -ChromePath.'
}

#===========================================================================
# "Is it still running?" - three independent signals, any one is enough.
#
#   1. a process running out of the browser's install directory
#   2. a process with the browser's user-data path on its command line
#   3. a profile database held open by somebody
#
# Signal 3 is the backstop: it needs no knowledge of where the browser was
# installed, so a source we failed to locate on disk still cannot slip past.
# Copying a live SQLite database yields a torn file, which is why this blocks.
#===========================================================================
$script:ProcCache = $null
function Get-ProcessTable {
    if ($null -eq $script:ProcCache) {
        $script:ProcCache = @(Get-CimInstance Win32_Process -EA SilentlyContinue |
            Select-Object ProcessId, Name, ExecutablePath, CommandLine)
    }
    return $script:ProcCache
}
function Reset-ProcessTable { $script:ProcCache = $null }

# FileShare.None fails if ANY other handle to the file is open, whatever
# sharing mode that handle asked for - which is exactly the question here.
function Test-FileLocked {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $fs.Close(); $fs.Dispose()
        return $false
    }
    catch [IO.IOException] { return $true }
    catch { return $false }        # permissions, read-only - not evidence of a live browser
}

function Get-ProfileProbeFiles {
    param($B)
    $f = @()
    foreach ($p in (Get-BrowserProfiles $B)) {
        $f += Join-Path $p.Path 'Network\Cookies'
        $f += Join-Path $p.Path 'Web Data'
        $f += Join-Path $p.Path 'History'
        foreach ($lf in $B.LoginFiles) { $f += Join-Path $p.Path $lf }
    }
    return @($f | Where-Object { Test-Path -LiteralPath $_ })
}

function Get-BrowserRunState {
    param($B)
    $reasons = @()
    $procIds = @()
    $procs   = Get-ProcessTable

    if ($B.Exe) {
        $dir  = (Split-Path $B.Exe -Parent).TrimEnd('\')
        $pfx  = "$dir\"
        $hits = @($procs | Where-Object {
            $_.ProcessId -ne $PID -and $_.ExecutablePath -and
            $_.ExecutablePath.StartsWith($pfx, 'OrdinalIgnoreCase')
        })
        if ($hits.Count -gt 0) {
            $reasons += "$($hits.Count) process(es) running from $dir"
            $procIds += $hits.ProcessId
        }
    }

    $ud   = $B.UserData
    $hits = @($procs | Where-Object {
        $_.ProcessId -ne $PID -and $_.CommandLine -and
        $_.CommandLine.IndexOf($ud, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
    if ($hits.Count -gt 0) {
        $reasons += "$($hits.Count) process(es) with this profile path on the command line"
        $procIds += $hits.ProcessId
    }

    $locked = @(Get-ProfileProbeFiles $B | Where-Object { Test-FileLocked $_ })
    if ($locked.Count -gt 0) {
        $names = @($locked | ForEach-Object { Split-Path $_ -Leaf } | Select-Object -Unique)
        $reasons += "profile files are held open: $($names -join ', ')"
    }

    return New-Object PSObject -Property ([ordered]@{
        Running = ($reasons.Count -gt 0)
        Reasons = $reasons
        Pids    = @($procIds | Select-Object -Unique)
    })
}

function Test-BrowserRunning { param($B) return (Get-BrowserRunState $B).Running }

function Write-RunStateHelp {
    param($B, $State)
    Warn "$($B.Name) is still running:"
    foreach ($r in $State.Reasons) { Write-Host "      - $r" -ForegroundColor DarkGray }
    if ($State.Pids.Count -gt 0 -and $State.Pids.Count -le 12) {
        Write-Host "      PIDs: $($State.Pids -join ', ')" -ForegroundColor DarkGray
    }
    if ($B.Name -eq 'Edge') {
        Write-Host '      Edge keeps background processes alive when Startup Boost is on.' -ForegroundColor DarkGray
        Write-Host '      Turn it off at edge://settings/system, then end any msedge.exe left.' -ForegroundColor DarkGray
    }
}

function Assert-BrowserClosed {
    param($B, [switch]$Interactive, [switch]$Ignore, [switch]$WarnOnly)
    while ($true) {
        Reset-ProcessTable
        $st = Get-BrowserRunState $B
        if (-not $st.Running) { return }
        # A dry run only reads and reports, so it is worth letting through - but
        # say plainly that the real thing will not start in this state.
        if ($WarnOnly) {
            Write-RunStateHelp $B $st
            Warn 'a dry run only reads, so it continues - the real migration will refuse until this is closed.'
            return
        }
        if ($Ignore) {
            Write-RunStateHelp $B $st
            Warn '-IgnoreRunningCheck was passed - continuing anyway. The copy may be torn.'
            return
        }
        if (-not $Interactive) {
            Write-RunStateHelp $B $st
            Die "close $($B.Name) and run again. (-IgnoreRunningCheck overrides this, at your own risk)"
        }
        Write-Host ''
        Write-RunStateHelp $B $st
        Write-Host ''
        if (-not (Read-YesNo "close $($B.Name) completely, then retry?" $true)) {
            Die "migration cancelled - $($B.Name) is running"
        }
    }
}

#===========================================================================
# Native interop: winsqlite3 + BCrypt AES-GCM (PS 5.1 has no AesGcm type).
# Versioned type name - .NET cannot unload a type, so an older copy loaded in
# the same session would otherwise shadow this one. Bump the suffix whenever
# this class gains or changes a method.
#===========================================================================
if (-not ('CmNativeV1' -as [type])) {
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CmNativeV1 {
  [DllImport("winsqlite3.dll", EntryPoint="sqlite3_open16", CharSet=CharSet.Unicode)]
  public static extern int Open(string f, out IntPtr db);
  [DllImport("winsqlite3.dll", EntryPoint="sqlite3_close_v2")]
  public static extern int Close(IntPtr db);
  [DllImport("winsqlite3.dll", EntryPoint="sqlite3_prepare16_v2", CharSet=CharSet.Unicode)]
  public static extern int Prep(IntPtr db, string sql, int n, out IntPtr st, IntPtr tail);
  [DllImport("winsqlite3.dll", EntryPoint="sqlite3_step")]
  public static extern int Step(IntPtr st);
  [DllImport("winsqlite3.dll", EntryPoint="sqlite3_finalize")]
  public static extern int Fin(IntPtr st);
  [DllImport("winsqlite3.dll", EntryPoint="sqlite3_errmsg16")]
  public static extern IntPtr ErrMsg(IntPtr db);
  [DllImport("winsqlite3.dll", EntryPoint="sqlite3_column_blob")]
  public static extern IntPtr ColBlob(IntPtr st, int i);
  [DllImport("winsqlite3.dll", EntryPoint="sqlite3_column_bytes")]
  public static extern int ColBytes(IntPtr st, int i);
  [DllImport("winsqlite3.dll", EntryPoint="sqlite3_column_int64")]
  public static extern long ColInt64(IntPtr st, int i);
  [DllImport("winsqlite3.dll", EntryPoint="sqlite3_column_text16")]
  public static extern IntPtr ColText(IntPtr st, int i);
  [DllImport("winsqlite3.dll", EntryPoint="sqlite3_bind_blob")]
  public static extern int BindBlob(IntPtr st, int i, byte[] v, int n, IntPtr d);
  [DllImport("winsqlite3.dll", EntryPoint="sqlite3_bind_int64")]
  public static extern int BindInt64(IntPtr st, int i, long v);
  [DllImport("winsqlite3.dll", EntryPoint="sqlite3_reset")]
  public static extern int Reset(IntPtr st);

  [StructLayout(LayoutKind.Sequential)]
  public struct AuthInfo {
    public int cbSize; public int dwInfoVersion;
    public IntPtr pbNonce;      public int cbNonce;
    public IntPtr pbAuthData;   public int cbAuthData;
    public IntPtr pbTag;        public int cbTag;
    public IntPtr pbMacContext; public int cbMacContext;
    public int cbAAD; public long cbData; public int dwFlags;
  }
  [DllImport("bcrypt.dll")] static extern int BCryptOpenAlgorithmProvider(out IntPtr h, [MarshalAs(UnmanagedType.LPWStr)] string a, [MarshalAs(UnmanagedType.LPWStr)] string i, uint f);
  [DllImport("bcrypt.dll")] static extern int BCryptCloseAlgorithmProvider(IntPtr h, uint f);
  [DllImport("bcrypt.dll")] static extern int BCryptSetProperty(IntPtr h, [MarshalAs(UnmanagedType.LPWStr)] string p, byte[] v, int cb, uint f);
  [DllImport("bcrypt.dll")] static extern int BCryptGenerateSymmetricKey(IntPtr ha, out IntPtr hk, IntPtr ko, int cko, byte[] s, int cs, uint f);
  [DllImport("bcrypt.dll")] static extern int BCryptDestroyKey(IntPtr hk);
  [DllImport("bcrypt.dll")] static extern int BCryptDecrypt(IntPtr hk, byte[] i, int ci, ref AuthInfo p, byte[] iv, int civ, byte[] o, int co, out int r, uint f);
  [DllImport("bcrypt.dll")] static extern int BCryptEncrypt(IntPtr hk, byte[] i, int ci, ref AuthInfo p, byte[] iv, int civ, byte[] o, int co, out int r, uint f);

  static IntPtr NewKey(byte[] key, out IntPtr alg) {
    int rc = BCryptOpenAlgorithmProvider(out alg, "AES", null, 0);
    if (rc != 0) throw new Exception("OpenAlg 0x" + rc.ToString("X8"));
    byte[] gcm = System.Text.Encoding.Unicode.GetBytes("ChainingModeGCM\0");
    rc = BCryptSetProperty(alg, "ChainingMode", gcm, gcm.Length, 0);
    if (rc != 0) throw new Exception("SetProp 0x" + rc.ToString("X8"));
    IntPtr hk;
    rc = BCryptGenerateSymmetricKey(alg, out hk, IntPtr.Zero, 0, key, key.Length, 0);
    if (rc != 0) throw new Exception("GenKey 0x" + rc.ToString("X8"));
    return hk;
  }
  public static byte[] GcmDecrypt(byte[] key, byte[] nonce, byte[] ct, byte[] tag) {
    IntPtr alg; IntPtr hk = NewKey(key, out alg);
    GCHandle gn = GCHandle.Alloc(nonce, GCHandleType.Pinned), gt = GCHandle.Alloc(tag, GCHandleType.Pinned);
    try {
      AuthInfo ai = new AuthInfo();
      ai.cbSize = Marshal.SizeOf(typeof(AuthInfo)); ai.dwInfoVersion = 1;
      ai.pbNonce = gn.AddrOfPinnedObject(); ai.cbNonce = nonce.Length;
      ai.pbTag   = gt.AddrOfPinnedObject(); ai.cbTag   = tag.Length;
      byte[] o = new byte[ct.Length]; int r;
      int rc = BCryptDecrypt(hk, ct, ct.Length, ref ai, null, 0, o, o.Length, out r, 0);
      if (rc != 0) throw new Exception("Decrypt 0x" + rc.ToString("X8"));
      byte[] f = new byte[r]; Array.Copy(o, f, r); return f;
    } finally { gn.Free(); gt.Free(); BCryptDestroyKey(hk); BCryptCloseAlgorithmProvider(alg, 0); }
  }
  public static byte[] GcmEncrypt(byte[] key, byte[] nonce, byte[] pt, out byte[] tag) {
    IntPtr alg; IntPtr hk = NewKey(key, out alg);
    tag = new byte[16];
    GCHandle gn = GCHandle.Alloc(nonce, GCHandleType.Pinned), gt = GCHandle.Alloc(tag, GCHandleType.Pinned);
    try {
      AuthInfo ai = new AuthInfo();
      ai.cbSize = Marshal.SizeOf(typeof(AuthInfo)); ai.dwInfoVersion = 1;
      ai.pbNonce = gn.AddrOfPinnedObject(); ai.cbNonce = nonce.Length;
      ai.pbTag   = gt.AddrOfPinnedObject(); ai.cbTag   = 16;
      byte[] o = new byte[pt.Length]; int r;
      int rc = BCryptEncrypt(hk, pt, pt.Length, ref ai, null, 0, o, o.Length, out r, 0);
      if (rc != 0) throw new Exception("Encrypt 0x" + rc.ToString("X8"));
      byte[] f = new byte[r]; Array.Copy(o, f, r); return f;
    } finally { gn.Free(); gt.Free(); BCryptDestroyKey(hk); BCryptCloseAlgorithmProvider(alg, 0); }
  }
}
'@
}

$SQLITE_ROW = 100; $SQLITE_DONE = 101; $TRANSIENT = [IntPtr](-1)

function Open-Db([string]$p) {
    $db = [IntPtr]::Zero
    $rc = [CmNativeV1]::Open($p, [ref]$db)
    if ($rc -ne 0) { throw "cannot open '$p' (rc=$rc)" }
    return $db
}
function Close-Db([IntPtr]$db) { $null = [CmNativeV1]::Close($db) }

function Invoke-Db([IntPtr]$db, [string]$sql) {
    $st = [IntPtr]::Zero
    if ([CmNativeV1]::Prep($db, $sql, -1, [ref]$st, [IntPtr]::Zero) -ne 0) {
        throw ("sqlite: " + [Runtime.InteropServices.Marshal]::PtrToStringUni([CmNativeV1]::ErrMsg($db)))
    }
    try { while ([CmNativeV1]::Step($st) -eq $SQLITE_ROW) { } }
    finally { $null = [CmNativeV1]::Fin($st) }
}

function Get-RowCount([string]$dbPath, [string]$table) {
    if (-not (Test-Path $dbPath)) { return -1 }
    $tmp = Join-Path $env:TEMP ('_cm_' + [IO.Path]::GetRandomFileName() + '.db')
    try {
        Copy-Item $dbPath $tmp -Force
        $db = Open-Db $tmp
        try {
            $st = [IntPtr]::Zero
            if ([CmNativeV1]::Prep($db, "SELECT count(*) FROM [$table]", -1, [ref]$st, [IntPtr]::Zero) -ne 0) { return -1 }
            $n = -1
            if ([CmNativeV1]::Step($st) -eq $SQLITE_ROW) { $n = [CmNativeV1]::ColInt64($st, 0) }
            $null = [CmNativeV1]::Fin($st)
            return [int]$n
        } finally { Close-Db $db }
    } catch { return -1 }
    finally { Remove-Item $tmp -Force -EA SilentlyContinue }
}

function Test-DbTable([IntPtr]$db, [string]$t) {
    $st = [IntPtr]::Zero
    $null = [CmNativeV1]::Prep($db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='$t'", -1, [ref]$st, [IntPtr]::Zero)
    $n = 0
    if ([CmNativeV1]::Step($st) -eq $SQLITE_ROW) { $n = [CmNativeV1]::ColInt64($st, 0) }
    $null = [CmNativeV1]::Fin($st)
    return ($n -gt 0)
}
function Test-DbColumn([IntPtr]$db, [string]$t, [string]$c) {
    $st = [IntPtr]::Zero
    $null = [CmNativeV1]::Prep($db, "PRAGMA table_info($t)", -1, [ref]$st, [IntPtr]::Zero)
    $f = $false
    while ([CmNativeV1]::Step($st) -eq $SQLITE_ROW) {
        if ([Runtime.InteropServices.Marshal]::PtrToStringUni([CmNativeV1]::ColText($st, 1)) -eq $c) { $f = $true }
    }
    $null = [CmNativeV1]::Fin($st)
    return $f
}

#===========================================================================
# os_crypt: "v10" || 12-byte nonce || ciphertext || 16-byte tag.
# Anything without a version prefix predates Chrome 80 and is DPAPI-wrapped
# directly; Chrome still reads those, so we do too.
#===========================================================================
function Unprotect-OsCryptValue {
    param([byte[]]$Blob, [byte[]]$Key)
    if ($null -eq $Blob -or $Blob.Length -eq 0) { return $null }
    $prefix = ''
    if ($Blob.Length -ge 3) { $prefix = [Text.Encoding]::ASCII.GetString($Blob[0..2]) }
    # NOTE the leading commas on every return. An empty password decrypts to a
    # zero-length byte[], and PowerShell unrolls an empty array on return - it
    # would arrive as $null and be misread as "could not decrypt". The comma
    # wraps it so the empty array survives intact.
    if ($prefix -ne 'v10' -and $prefix -ne 'v11') {
        if ($prefix -eq 'v20') { return $null }        # app-bound, key not ours
        try   { return ,[Security.Cryptography.ProtectedData]::Unprotect($Blob, $null, 'CurrentUser') }
        catch { return $null }
    }
    if ($Blob.Length -lt 31) { return $null }
    $nonce = $Blob[3..14]
    $ctLen = $Blob.Length - 31
    $ct = New-Object byte[] $ctLen
    if ($ctLen -gt 0) { [Array]::Copy($Blob, 15, $ct, 0, $ctLen) }
    $tag = New-Object byte[] 16
    [Array]::Copy($Blob, $Blob.Length - 16, $tag, 0, 16)
    return ,[CmNativeV1]::GcmDecrypt($Key, $nonce, $ct, $tag)
}

function Protect-OsCryptValue {
    param([byte[]]$Plain, [byte[]]$Key)
    $nonce = New-Object byte[] 12
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($nonce)
    $tag = $null
    $ct  = [CmNativeV1]::GcmEncrypt($Key, $nonce, $Plain, [ref]$tag)
    $out = New-Object byte[] (31 + $ct.Length)
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('v10'), 0, $out, 0, 3)
    [Array]::Copy($nonce, 0, $out, 3, 12)
    [Array]::Copy($ct, 0, $out, 15, $ct.Length)
    [Array]::Copy($tag, 0, $out, 15 + $ct.Length, 16)
    return ,$out
}

function Convert-EncryptedColumn {
    param([string]$DbPath, [string]$Table, [string]$Column, [byte[]]$OldKey, [byte[]]$NewKey)
    if (-not (Test-Path $DbPath)) { return @{ Total=0; Converted=0; Skipped=0 } }
    $db = Open-Db $DbPath
    try {
        if (-not (Test-DbTable $db $Table))          { return @{ Total=0; Converted=0; Skipped=0 } }
        if (-not (Test-DbColumn $db $Table $Column)) { return @{ Total=0; Converted=0; Skipped=0 } }

        $rows = @()
        $st = [IntPtr]::Zero
        $null = [CmNativeV1]::Prep($db, "SELECT rowid, [$Column] FROM [$Table]", -1, [ref]$st, [IntPtr]::Zero)
        while ([CmNativeV1]::Step($st) -eq $SQLITE_ROW) {
            $rid = [CmNativeV1]::ColInt64($st, 0)
            $n   = [CmNativeV1]::ColBytes($st, 1)
            $buf = $null
            if ($n -gt 0) {
                $buf = New-Object byte[] $n
                [Runtime.InteropServices.Marshal]::Copy([CmNativeV1]::ColBlob($st, 1), $buf, 0, $n)
            }
            $rows += , @($rid, $buf)
        }
        $null = [CmNativeV1]::Fin($st)

        $conv = 0; $skip = 0
        Invoke-Db $db 'BEGIN IMMEDIATE'
        $up = [IntPtr]::Zero
        $null = [CmNativeV1]::Prep($db, "UPDATE [$Table] SET [$Column]=?1 WHERE rowid=?2", -1, [ref]$up, [IntPtr]::Zero)
        try {
            foreach ($r in $rows) {
                $plain = $null
                try { $plain = Unprotect-OsCryptValue -Blob $r[1] -Key $OldKey } catch { $plain = $null }
                if ($null -eq $plain) { $skip++; continue }
                $new = Protect-OsCryptValue -Plain $plain -Key $NewKey
                [Array]::Clear($plain, 0, $plain.Length)
                $null = [CmNativeV1]::Reset($up)
                $null = [CmNativeV1]::BindBlob($up, 1, $new, $new.Length, $TRANSIENT)
                $null = [CmNativeV1]::BindInt64($up, 2, $r[0])
                if ([CmNativeV1]::Step($up) -ne $SQLITE_DONE) {
                    throw ("update failed: " + [Runtime.InteropServices.Marshal]::PtrToStringUni([CmNativeV1]::ErrMsg($db)))
                }
                $conv++
            }
        } finally { $null = [CmNativeV1]::Fin($up) }
        Invoke-Db $db 'COMMIT'
        return @{ Total=$rows.Count; Converted=$conv; Skipped=$skip }
    }
    finally { Close-Db $db }
}

#===========================================================================
# Icon: coloured disc with the instance initials, as PNG-in-ICO
#===========================================================================
function New-InstanceIcon {
    param([string]$Text, [string]$Path, [System.Drawing.Color]$Color)
    $size = 256
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush($Color)
    $g.FillEllipse($brush, 8, 8, $size - 16, $size - 16)
    $letters = $Text.Substring(0, [Math]::Min(2, $Text.Length)).ToUpper()
    $fs = 120; if ($letters.Length -eq 2) { $fs = 92 }
    $font = New-Object System.Drawing.Font('Segoe UI', $fs, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $g.DrawString($letters, $font, $white, (New-Object System.Drawing.RectangleF(0,0,$size,$size)), $fmt)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $png = $ms.ToArray()
    $ms.Dispose(); $bmp.Dispose(); $brush.Dispose(); $white.Dispose(); $font.Dispose()
    $ico = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ico)
    $bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]1)
    $bw.Write([Byte]0); $bw.Write([Byte]0); $bw.Write([Byte]0); $bw.Write([Byte]0)
    $bw.Write([UInt16]1); $bw.Write([UInt16]32)
    $bw.Write([UInt32]$png.Length); $bw.Write([UInt32]22)
    $bw.Write($png); $bw.Flush()
    [IO.File]::WriteAllBytes($Path, $ico.ToArray())
    $bw.Dispose(); $ico.Dispose()
}
function Get-NameColor([string]$s) {
    $p = @(
        [System.Drawing.Color]::FromArgb(46,125,185),  [System.Drawing.Color]::FromArgb(196,86,58),
        [System.Drawing.Color]::FromArgb(74,143,90),   [System.Drawing.Color]::FromArgb(139,84,163),
        [System.Drawing.Color]::FromArgb(198,142,42),  [System.Drawing.Color]::FromArgb(52,141,148),
        [System.Drawing.Color]::FromArgb(178,68,116)
    )
    $h = 0
    foreach ($c in $s.ToCharArray()) { $h = ($h * 31 + [int]$c) % 100000 }
    return $p[$h % $p.Count]
}

#===========================================================================
# Shell link AppUserModelID
#
# A shortcut's icon only applies to the shortcut. Once Chrome is running, the
# taskbar button is driven by the window's AppUserModelID, and Chrome supplies
# its own icon for that. Chrome does give each --user-data-dir a distinct AUMID
# of the form 'Chrome.scopeddir<hash>.Default', so instances already group
# separately - they just all show the Chrome logo. If a PINNED shortcut
# declares the same AUMID, Windows merges the running window into that pinned
# item and uses the shortcut's icon.
#===========================================================================
if (-not ('CmLnkV1' -as [type])) {
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public struct CmPropertyKey { public Guid fmtid; public uint pid; }

// Full-size PROPVARIANT: 16 bytes on x86, 24 on x64. Undersizing it makes
// GetValue write past the buffer, which is how this silently failed before.
[StructLayout(LayoutKind.Sequential)]
public struct CmPropVariant {
  public ushort vt;
  public ushort r1, r2, r3;
  public IntPtr p;
  public IntPtr p2;
}

[ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ICmPropertyStore {
  [PreserveSig] int GetCount(out uint c);
  [PreserveSig] int GetAt(uint i, out CmPropertyKey k);
  [PreserveSig] int GetValue(ref CmPropertyKey k, out CmPropVariant v);
  [PreserveSig] int SetValue(ref CmPropertyKey k, ref CmPropVariant v);
  [PreserveSig] int Commit();
}

[ComImport, Guid("0000010b-0000-0000-C000-000000000046"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ICmPersistFile {
  void GetClassID(out Guid pClassID);
  [PreserveSig] int IsDirty();
  void Load([MarshalAs(UnmanagedType.LPWStr)] string f, int mode);
  void Save([MarshalAs(UnmanagedType.LPWStr)] string f, [MarshalAs(UnmanagedType.Bool)] bool remember);
  void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string f);
  void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string f);
}

public static class CmLnkV1 {
  static readonly Guid CLSID_ShellLink = new Guid("00021401-0000-0000-C000-000000000046");
  static CmPropertyKey AppIdKey() {
    CmPropertyKey k = new CmPropertyKey();
    k.fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    k.pid = 5;
    return k;
  }

  public static string Get(string lnk) {
    object o = Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_ShellLink));
    try {
      ((ICmPersistFile)o).Load(lnk, 0);
      CmPropertyKey k = AppIdKey();
      CmPropVariant v;
      int hr = ((ICmPropertyStore)o).GetValue(ref k, out v);
      if (hr < 0) throw new Exception("GetValue 0x" + hr.ToString("X8"));
      if (v.vt != 31) return null;
      return Marshal.PtrToStringUni(v.p);
    } finally { Marshal.ReleaseComObject(o); }
  }

  // Windows 11's Start menu binds pins through the app model. A shortcut
  // carrying an AUMID that matches no registered app pins to nothing, so the
  // Start-menu copy must not declare one.
  public static void Clear(string lnk) {
    object o = Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_ShellLink));
    try {
      ICmPersistFile pf = (ICmPersistFile)o;
      pf.Load(lnk, 2);
      CmPropertyKey k = AppIdKey();
      CmPropVariant v = new CmPropVariant();     // vt = 0 = VT_EMPTY
      ICmPropertyStore ps = (ICmPropertyStore)o;
      int hr = ps.SetValue(ref k, ref v);
      if (hr < 0) throw new Exception("SetValue 0x" + hr.ToString("X8"));
      hr = ps.Commit();
      if (hr < 0) throw new Exception("Commit 0x" + hr.ToString("X8"));
      pf.Save(lnk, true);
    } finally { Marshal.ReleaseComObject(o); }
  }

  public static void Set(string lnk, string aumid) {
    object o = Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_ShellLink));
    IntPtr str = IntPtr.Zero;
    try {
      ICmPersistFile pf = (ICmPersistFile)o;
      pf.Load(lnk, 2);                           // STGM_READWRITE
      CmPropertyKey k = AppIdKey();
      CmPropVariant v = new CmPropVariant();
      v.vt = 31;                                 // VT_LPWSTR
      str = Marshal.StringToCoTaskMemUni(aumid);
      v.p = str;
      ICmPropertyStore ps = (ICmPropertyStore)o;
      // S_FALSE (1) is a success code here - only negative HRESULTs are errors.
      int hr = ps.SetValue(ref k, ref v);
      if (hr < 0) throw new Exception("SetValue 0x" + hr.ToString("X8"));
      hr = ps.Commit();
      if (hr < 0) throw new Exception("Commit 0x" + hr.ToString("X8"));
      pf.Save(lnk, true);                        // explicit path; Save(null,..) can no-op
    } finally {
      if (str != IntPtr.Zero) Marshal.FreeCoTaskMem(str);
      Marshal.ReleaseComObject(o);
    }
  }
}
'@
}

$AUMID_KEY = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FeatureUsage\AppSwitched'

# AUMID -> number of times the user has switched to it.
function Get-SwitchCounts {
    param([string]$Key = $AUMID_KEY)
    $h = @{}
    if (-not (Test-Path $Key)) { return $h }
    foreach ($p in (Get-ItemProperty $Key).PSObject.Properties) {
        if ($p.Name -like 'Chrome*' -and $p.Value -is [int]) { $h[$p.Name] = [int]$p.Value }
    }
    return $h
}

function Resolve-InstanceShortcut {
    param([string]$Name, [string]$Shortcut)
    if ($Shortcut) {
        if (-not (Test-Path $Shortcut)) { Die "shortcut not found: $Shortcut" }
        return $Shortcut
    }
    $cands = @(
        (Join-Path ([Environment]::GetFolderPath('Desktop')) "$Name (Chrome).lnk")
        (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) "$Name (Chrome).lnk")
    )
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    Die ("no shortcut found for '$Name'. Looked for:`n      " + ($cands -join "`n      ") + "`n    pass -Shortcut '<path>' if it lives elsewhere.")
}

#===========================================================================
# Instances already on this machine
#===========================================================================
function Get-ChromeInstances {
    param([string]$Root)
    if (-not (Test-Path $Root)) { return @() }
    $out = @()
    foreach ($d in Get-ChildItem $Root -Directory -EA SilentlyContinue) {
        if ($d.Name -eq '_icons') { continue }
        if (-not (Test-Path (Join-Path $d.FullName 'Local State'))) { continue }
        $lnk = $null
        foreach ($c in @((Join-Path ([Environment]::GetFolderPath('Desktop')) "$($d.Name) (Chrome).lnk"))) {
            if (Test-Path $c) { $lnk = $c }
        }
        $aumid = $null
        if ($lnk) { try { $aumid = [CmLnkV1]::Get($lnk) } catch { } }
        $out += New-Object PSObject -Property ([ordered]@{
            Name = $d.Name; Path = $d.FullName; Shortcut = $lnk; Aumid = $aumid
        })
    }
    return ,$out
}

function Show-Instances {
    param([string]$Root)
    $inst = @(Get-ChromeInstances -Root $Root)
    Write-Host ''
    Write-Host "  Instances under $Root" -ForegroundColor White
    Write-Host '  ---------------------------------------------' -ForegroundColor DarkGray
    if ($inst.Count -eq 0) {
        Warn "none found. Migrate one first, or pass -Root if they live elsewhere."
        return ,$inst
    }
    $i = 0
    foreach ($x in $inst) {
        $i++
        Write-Host ("   {0,2}  {1}" -f $i, $x.Name) -ForegroundColor Cyan
        $lnkTxt = if ($x.Shortcut) { $x.Shortcut } else { '(no desktop shortcut)' }
        Write-Host ("       shortcut : {0}" -f $lnkTxt) -ForegroundColor DarkGray
        $aumTxt = if ($x.Aumid) { $x.Aumid } else { '(not set - taskbar will show the Chrome logo)' }
        Write-Host ("       taskbar  : {0}" -f $aumTxt) -ForegroundColor DarkGray
    }
    return ,$inst
}

#===========================================================================
# Action: list detected browsers
#===========================================================================
function Show-BrowserList {
    Write-Host ''
    Write-Host '  Detected Chromium browsers' -ForegroundColor White
    Write-Host '  --------------------------' -ForegroundColor DarkGray
    $all = Get-DetectedBrowsers

    # Anything still doubled up is genuinely ambiguous: both are installed.
    $claims = @{}
    foreach ($b in $all) {
        $k = $b.UserData.ToLower()
        if (-not $claims.ContainsKey($k)) { $claims[$k] = @() }
        $claims[$k] += $b.Name
    }

    foreach ($b in $all) {
        $run = ''
        if (Test-BrowserRunning $b) { $run = '  [RUNNING - close before migrating]' }
        $ver = '  (executable not found)'
        if ($b.Exe) { $ver = " $((Get-Item $b.Exe).VersionInfo.ProductVersion)" }
        Write-Host ''
        Write-Host ("  {0}{1}{2}" -f $b.Name, $ver, $run) -ForegroundColor Cyan
        Write-Host "    $($b.UserData)" -ForegroundColor DarkGray
        $sharers = @($claims[$b.UserData.ToLower()] | Where-Object { $_ -ne $b.Name })
        if ($sharers.Count -gt 0) {
            Write-Host ("    NOTE: same directory as $($sharers -join ', ') - they share one profile store") -ForegroundColor Yellow
        }
        if ($b.ProprietaryCrypto) {
            Write-Host '    passwords and cards use this vendor''s own crypto - not migratable' -ForegroundColor Yellow
        }
        foreach ($p in Get-BrowserProfiles $b) {
            $tot = 0
            foreach ($lf in $b.LoginFiles) {
                $n = Get-RowCount (Join-Path $p.Path $lf) 'logins'
                if ($n -gt 0) { $tot += $n }
            }
            $cards = Get-RowCount (Join-Path $p.Path $b.CardDb) 'credit_cards'
            if ($cards -lt 0) { $cards = 0 }
            $exts = 0
            $er = Join-Path $p.Path 'Extensions'
            if (Test-Path $er) { $exts = (Get-ChildItem $er -Directory -EA SilentlyContinue).Count }
            Write-Host ("    profile {0,-12} logins={1,-6} cards={2,-4} extensions={3}" -f $p.Name, $tot, $cards, $exts)
        }
    }
    if ($all.Count -eq 0) { Warn 'no supported source browsers found' }
    Write-Host ''
    Write-Host '  Chrome is not listed - it is the destination.' -ForegroundColor DarkGray
    Write-Host '  Migrate with:  -Source <name> -Name <label> -IncludePasswords' -ForegroundColor Gray
    return ,$all
}

#===========================================================================
# Action: migrate
#===========================================================================
function Invoke-Migration {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Name,
        [string]$Root = 'C:\Browsers',
        [string]$SourceProfile,
        [string]$SourceUserData,
        [string]$ChromePath,
        [switch]$IncludePasswords,
        [switch]$IncludeCards,
        [switch]$IncludeCookies,
        [switch]$IncludePreferences,
        [switch]$NoShortcut,
        [string]$ShortcutPath,
        [switch]$Force,
        [switch]$DryRun,
        [switch]$IgnoreRunningCheck,
        [switch]$Interactive
    )

    if ($Name -notmatch '^[A-Za-z0-9 _.-]{1,40}$') {
        Die "invalid -Name '$Name'. Letters, digits, space, dot, dash, underscore; max 40."
    }

    Write-Host ''
    Write-Host "  $Source -> isolated Chrome instance '$Name'" -ForegroundColor White
    Write-Host '  ------------------------------------------------' -ForegroundColor DarkGray

    $entry = $BROWSERS | Where-Object { $_.Name -eq $Source }
    if (-not $entry) {
        Die ("unknown source '$Source'. Known: " + (($BROWSERS | ForEach-Object { $_.Name }) -join ', '))
    }
    $B = Resolve-Browser $entry
    if ($SourceUserData) {
        if (-not (Test-Path $SourceUserData)) { Die "not found: $SourceUserData" }
        if (-not $B) {
            $B = New-Object PSObject -Property ([ordered]@{
                Name = $Source; Exe = $null; RootIsProfile = [bool]$entry.RootIsProfile
                LoginFiles = $(if ($entry.LoginFiles) { $entry.LoginFiles } else { @('Login Data','Login Data For Account') })
                CardDb = $(if ($entry.CardDb) { $entry.CardDb } else { 'Web Data' })
                ProprietaryCrypto = [bool]$entry.ProprietaryCrypto
            })
        }
        $B | Add-Member -NotePropertyName UserData -NotePropertyValue $SourceUserData -Force
    }
    if (-not $B) { Die "$Source is not installed for this user. Pass -SourceUserData '<path>' if it lives elsewhere." }

    $profiles = @(Get-BrowserProfiles $B)
    if ($profiles.Count -eq 0) { Die "no profiles found under $($B.UserData)" }

    if ($SourceProfile) {
        $sel = $profiles | Where-Object { $_.Name -eq $SourceProfile }
        if (-not $sel) { Die ("profile '$SourceProfile' not found. Available: " + (($profiles | ForEach-Object { $_.Name }) -join ', ')) }
    } else {
        $sel = $profiles[0]
        if ($profiles.Count -gt 1) {
            Warn ("$($profiles.Count) profiles found; using '$($sel.Name)'. Others: " + (($profiles | Select-Object -Skip 1 | ForEach-Object { $_.Name }) -join ', '))
        }
    }
    $srcProfile = $sel.Path
    Say "source : $srcProfile"

    $ChromePath = Resolve-ChromePath $ChromePath
    Say "target browser : $ChromePath ($((Get-Item $ChromePath).VersionInfo.ProductVersion))"

    # Hard gate: a live SQLite database copies in a torn state.
    Assert-BrowserClosed -B $B -Interactive:$Interactive -Ignore:$IgnoreRunningCheck -WarnOnly:$DryRun

    $target = Join-Path $Root $Name
    if ((Test-Path $target) -and -not $Force) { Die "target exists: $target  (use -Force to overwrite)" }
    $holders = @(Get-ProcessTable | Where-Object {
        $_.Name -eq 'chrome.exe' -and $_.CommandLine -and
        $_.CommandLine.IndexOf($target, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
    if ($holders.Count -gt 0) { Die "a Chrome instance is already running on $target - close it first." }
    Say "target : $target"
    if ($DryRun) { Warn 'DRY RUN - nothing will be written' }

    #-- extension inventory -------------------------------------------------
    $exts = @()
    $extRoot = Join-Path $srcProfile 'Extensions'
    if (Test-Path $extRoot) {
        foreach ($d in Get-ChildItem $extRoot -Directory -EA SilentlyContinue) {
            $v = Get-ChildItem $d.FullName -Directory -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
            if (-not $v) { continue }
            $mf = Join-Path $v.FullName 'manifest.json'
            if (-not (Test-Path $mf)) { continue }
            try { $j = Get-Content $mf -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            $nm = $j.name
            if ($nm -like '__MSG_*') {
                $k = $nm -replace '^__MSG_','' -replace '__$',''
                foreach ($loc in @($j.default_locale,'en','en_US','en_GB','zh_CN','ru')) {
                    if (-not $loc) { continue }
                    $lm = Join-Path $v.FullName "_locales\$loc\messages.json"
                    if (-not (Test-Path $lm)) { continue }
                    try { $lj = Get-Content $lm -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
                    if ($lj.$k.message) { $nm = $lj.$k.message; break }
                }
            }
            if ($nm -like '__MSG_*') { $nm = "(name unresolved) $($d.Name)" }
            $exts += New-Object PSObject -Property ([ordered]@{ Id=$d.Name; Name=$nm; Version=$j.version; MV=[int]$j.manifest_version })
        }
    }

    $plain = @('Bookmarks','History','Favicons','Top Sites','Shortcuts','Web Data','Network Action Predictor')

    if ($DryRun) {
        Write-Host ''
        Say 'would copy:'
        foreach ($f in $plain) {
            $p = Join-Path $srcProfile $f
            if (Test-Path $p) { Write-Host ("     {0,-26} {1,9:N0} KB" -f $f, ((Get-Item $p).Length/1KB)) }
        }
        if ($IncludePasswords) {
            foreach ($f in $B.LoginFiles) {
                $n = Get-RowCount (Join-Path $srcProfile $f) 'logins'
                if ($n -ge 0) { Write-Host ("     {0,-26} {1} rows (re-encrypted)" -f $f, $n) }
            }
        }
        if ($IncludeCards) {
            $n = Get-RowCount (Join-Path $srcProfile $B.CardDb) 'credit_cards'
            if ($n -ge 0) { Write-Host ("     {0,-26} {1} rows (re-encrypted)" -f 'credit cards', $n) }
        }
        if ($IncludeCookies) { Write-Host '     Cookies                    (re-encrypted)' }
        Write-Host ''
        Say "$($exts.Count) extensions found (never copied)"
        foreach ($e in $exts) {
            $flag = 'MV3 ok'; if ($e.MV -lt 3) { $flag = 'MV2 DEAD' }
            Write-Host ("     [{0,-8}] {1}" -f $flag, $e.Name)
        }
        Write-Host ''
        Ok 'dry run complete'
        return $null
    }

    #-- build ---------------------------------------------------------------
    $dstProfile = Join-Path $target 'Default'
    New-Item -ItemType Directory -Force -Path $dstProfile | Out-Null

    $copied = @()
    foreach ($f in $plain) {
        $s = Join-Path $srcProfile $f
        if (-not (Test-Path $s)) { continue }
        Copy-Item $s (Join-Path $dstProfile $f) -Force
        $copied += $f
    }
    foreach ($pat in @('*-wal','*-shm','*-journal')) {
        foreach ($x in Get-ChildItem $dstProfile -Filter $pat -EA SilentlyContinue) {
            Remove-Item -LiteralPath $x.FullName -Force -EA SilentlyContinue
        }
    }
    Ok "copied $($copied.Count) data files: $($copied -join ', ')"

    $lsPath = Join-Path $B.UserData 'Local State'
    if (-not (Test-Path $lsPath)) { Die "source Local State missing: $lsPath" }
    $srcKeyB64 = Get-OsCryptKeyB64 $lsPath
    if (-not $srcKeyB64) { Die "$($B.Name) Local State has no readable os_crypt.encrypted_key" }

    $wrapped = [Convert]::FromBase64String($srcKeyB64)
    try   { $oldKey = [Security.Cryptography.ProtectedData]::Unprotect($wrapped[5..($wrapped.Length-1)], $null, 'CurrentUser') }
    catch { Die "could not unwrap $($B.Name)'s key via DPAPI - are you the Windows user that created the profile? ($($_.Exception.Message))" }

    $newKey = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($newKey)
    $newWrapped = [Security.Cryptography.ProtectedData]::Protect($newKey, $null, 'CurrentUser')
    $withPrefix = New-Object byte[] (5 + $newWrapped.Length)
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('DPAPI'), 0, $withPrefix, 0, 5)
    [Array]::Copy($newWrapped, 0, $withPrefix, 5, $newWrapped.Length)

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $localState = [ordered]@{
        os_crypt = [ordered]@{ encrypted_key = [Convert]::ToBase64String($withPrefix) }
        profile  = [ordered]@{
            info_cache = [ordered]@{ Default = [ordered]@{ name = $Name; is_using_default_name = $false } }
            last_used  = 'Default'
        }
    }
    [IO.File]::WriteAllText((Join-Path $target 'Local State'), ($localState | ConvertTo-Json -Depth 10), $utf8NoBom)
    Ok 'generated a fresh encryption key for this instance'

    $prefs = [ordered]@{ profile = [ordered]@{ name = $Name } }
    if ($IncludePreferences) {
        $sp = Join-Path $srcProfile 'Preferences'
        if (Test-Path $sp) {
            try {
                $o = Get-Content $sp -Raw -Encoding UTF8 | ConvertFrom-Json
                $o.PSObject.Properties.Remove('extensions')
                if ($o.profile) { $o.profile | Add-Member -NotePropertyName name -NotePropertyValue $Name -Force }
                else { $o | Add-Member -NotePropertyName profile -NotePropertyValue ([pscustomobject]@{ name = $Name }) -Force }
                $prefs = $o
                Ok 'carried Preferences over (extension block stripped)'
            } catch { Warn "could not parse Preferences: $($_.Exception.Message)" }
        }
    }
    [IO.File]::WriteAllText((Join-Path $dstProfile 'Preferences'), ($prefs | ConvertTo-Json -Depth 100 -Compress), $utf8NoBom)

    if ($B.ProprietaryCrypto -and ($IncludePasswords -or $IncludeCards)) {
        Write-Host ''
        Warn "$($B.Name) encrypts passwords and cards with its own scheme, not Chromium's"
        Warn 'os_crypt - there is no key here to convert from, so they cannot be migrated.'
        Warn 'Export them from the browser instead:'
        Warn "  $($B.Name.ToLower())://settings  ->  passwords  ->  export to CSV"
        Warn '  then chrome://password-manager/settings -> Import in the new instance.'
        Warn '  Delete the CSV afterwards - it is plaintext.'
        Write-Host ''
        $IncludePasswords = $false
        $IncludeCards     = $false
    }

    try {
        if ($IncludePasswords) {
            # Both stores: profile-local, and account-scoped when signed in.
            foreach ($f in $B.LoginFiles) {
                $src = Join-Path $srcProfile $f
                if (-not (Test-Path $src)) { continue }
                $dst = Join-Path $dstProfile $f
                Copy-Item $src $dst -Force
                foreach ($sfx in @('-journal','-wal','-shm')) { Remove-Item -LiteralPath "$dst$sfx" -Force -EA SilentlyContinue }
                $r = Convert-EncryptedColumn -DbPath $dst -Table 'logins' -Column 'password_value' -OldKey $oldKey -NewKey $newKey
                if ($r.Total -eq 0) { Say "$f : empty"; continue }
                $msg = "$f : $($r.Converted)/$($r.Total) re-encrypted"
                if ($r.Skipped -gt 0) { $msg += ", $($r.Skipped) skipped" }
                Ok $msg
                if ($r.Skipped -gt 0) {
                    Warn '  skipped rows are usually stale duplicates of readable ones - check the'
                    Warn '  new instance at chrome://password-manager/passwords before deleting anything'
                }
            }
        }

        if ($IncludeCards) {
            $wd = Join-Path $dstProfile 'Web Data'
            if (Test-Path $wd) {
                $r = Convert-EncryptedColumn -DbPath $wd -Table 'credit_cards' -Column 'card_number_encrypted' -OldKey $oldKey -NewKey $newKey
                if ($r.Total -gt 0) { Ok "saved cards: $($r.Converted)/$($r.Total) re-encrypted" } else { Say 'no saved cards' }
            }
        } elseif ($copied -contains 'Web Data') {
            Warn 'Web Data copied, but saved card numbers stay unreadable without -IncludeCards'
        }

        if ($IncludeCookies) {
            $src = Join-Path $srcProfile 'Network\Cookies'
            if (-not (Test-Path $src)) { $src = Join-Path $srcProfile 'Cookies' }
            if (Test-Path $src) {
                $netDir = Join-Path $dstProfile 'Network'
                New-Item -ItemType Directory -Force -Path $netDir | Out-Null
                $dst = Join-Path $netDir 'Cookies'
                Copy-Item $src $dst -Force
                foreach ($sfx in @('-journal','-wal','-shm')) { Remove-Item -LiteralPath "$dst$sfx" -Force -EA SilentlyContinue }
                $r = Convert-EncryptedColumn -DbPath $dst -Table 'cookies' -Column 'encrypted_value' -OldKey $oldKey -NewKey $newKey
                Ok "cookies: $($r.Converted)/$($r.Total) re-encrypted"
            } else { Warn 'no Cookies database in source profile' }
        }
    }
    finally {
        [Array]::Clear($oldKey, 0, $oldKey.Length)
        [Array]::Clear($newKey, 0, $newKey.Length)
    }

    $lnk = $null
    if (-not $NoShortcut) {
        $iconDir = Join-Path $Root '_icons'
        New-Item -ItemType Directory -Force -Path $iconDir | Out-Null
        $icon = Join-Path $iconDir "$Name.ico"
        New-InstanceIcon -Text $Name -Path $icon -Color (Get-NameColor $Name)
        $lnkDir = $ShortcutPath
        if (-not $lnkDir) { $lnkDir = [Environment]::GetFolderPath('Desktop') }
        New-Item -ItemType Directory -Force -Path $lnkDir | Out-Null
        $lnk = Join-Path $lnkDir "$Name (Chrome).lnk"
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
        $s.TargetPath       = $ChromePath
        $s.Arguments        = "--user-data-dir=`"$target`" --no-first-run --no-default-browser-check"
        $s.IconLocation     = "$icon,0"
        $s.WorkingDirectory = Split-Path $ChromePath -Parent
        $s.Description      = "Isolated Chrome instance: $Name (from $($B.Name))"
        $s.Save()
        Ok "shortcut: $lnk"
    }

    Write-Host ''
    Write-Host "  Extensions ($($exts.Count)) - reinstall by hand, none were copied" -ForegroundColor White
    foreach ($e in $exts | Sort-Object MV, Name) {
        if ($e.MV -lt 3) {
            Write-Host ("    MV2  {0}" -f $e.Name) -ForegroundColor Red
            Write-Host '         will NOT run in current Chrome - find an MV3 replacement' -ForegroundColor DarkGray
        } else {
            Write-Host ("    MV3  {0}" -f $e.Name) -ForegroundColor Green
            Write-Host ("         https://chromewebstore.google.com/detail/$($e.Id)") -ForegroundColor DarkGray
        }
    }

    Write-Host ''
    Ok "instance '$Name' ready at $target"
    Write-Host ''
    Write-Host '  Do NOT sign in to a Google account with sync enabled - sync follows the' -ForegroundColor Yellow
    Write-Host '  account, not the data dir, and will pool this with your other instances.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  $($B.Name) was not modified." -ForegroundColor Gray

    return New-Object PSObject -Property ([ordered]@{
        Name = $Name; Target = $target; Shortcut = $lnk; ChromePath = $ChromePath; SourceName = $B.Name
    })
}

#===========================================================================
# Action: taskbar identity
#
# Capture needs one click from you: Windows only records an AUMID in
# ...\Explorer\FeatureUsage\AppSwitched when a human switches to the window.
# Launching it programmatically is not enough.
#===========================================================================
function Set-TaskbarIdentity {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [string]$Root = 'C:\Browsers',
        [string]$Shortcut,
        [string]$Aumid
    )
    $lnk = Resolve-InstanceShortcut -Name $Name -Shortcut $Shortcut
    Say "shortcut : $lnk"

    if (-not $Aumid) {
        $target = Join-Path $Root $Name
        if (-not (Test-Path $target)) { Die "instance data dir not found: $target" }

        # AppSwitched stores a USE COUNT per AUMID. An instance you have already
        # used is present with a count, so looking only for new names finds
        # nothing. Diff the counts instead: the one you switch to increments.
        $before = Get-SwitchCounts

        $chrome = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).TargetPath
        if (-not (Test-Path $chrome)) { Die "shortcut target missing: $chrome" }

        Say "launching $Name so Windows can register its AUMID"
        Start-Process $chrome -ArgumentList "--user-data-dir=`"$target`" --no-first-run --no-default-browser-check about:blank"

        Write-Host ''
        Write-Host '  ACTION NEEDED' -ForegroundColor Yellow
        Write-Host "  1. Wait for the $Name window to appear." -ForegroundColor Gray
        Write-Host '  2. Click some OTHER window first (this console is fine).' -ForegroundColor Gray
        Write-Host "  3. Now click the $Name TASKBAR BUTTON to switch back to it." -ForegroundColor Gray
        Write-Host '     Repeat that switch 2-3 times - it must be a real user switch,' -ForegroundColor Gray
        Write-Host '     and do not switch to any other Chrome window in between.' -ForegroundColor Gray
        Write-Host '  4. Come back here and press Enter.' -ForegroundColor Gray
        Write-Host ''
        Read-Host '  press Enter once you have switched to it a few times' | Out-Null

        $after   = Get-SwitchCounts
        $changed = @()
        foreach ($k in $after.Keys) {
            $old = 0
            if ($before.ContainsKey($k)) { $old = $before[$k] }
            if ($after[$k] -gt $old) {
                $changed += New-Object PSObject -Property @{ Id = $k; Delta = ($after[$k] - $old) }
            }
        }

        if ($changed.Count -eq 0) {
            Write-Host ''
            Warn 'nothing incremented. Known Chrome AUMIDs on this machine:'
            foreach ($k in ($after.Keys | Sort-Object)) { Write-Host "    $k" }
            Die 'switch to the window via its TASKBAR BUTTON (not Alt-Tab from the window itself), or pass -Aumid explicitly.'
        }

        $changed = @($changed | Sort-Object Delta -Descending)
        if ($changed.Count -gt 1) {
            Warn 'more than one AUMID incremented:'
            $changed | ForEach-Object { Write-Host "    +$($_.Delta)  $($_.Id)" }
            Warn "picking the highest: $($changed[0].Id)"
            Warn 'if that looks wrong, close other Chrome windows and rerun, or pass -Aumid.'
        }
        $Aumid = $changed[0].Id
        Ok "captured AUMID: $Aumid (+$($changed[0].Delta) switches)"
    }

    [CmLnkV1]::Set($lnk, $Aumid)
    $verify = [CmLnkV1]::Get($lnk)
    if ($verify -ne $Aumid) { Die "write-back failed (read '$verify')" }
    Ok "shortcut now declares: $verify"

    Write-Host ''
    Write-Host '  Finish in Explorer:' -ForegroundColor White
    Write-Host '   1. Close the instance.' -ForegroundColor Gray
    Write-Host '   2. If it is already pinned, unpin it (the old pin has no AUMID).' -ForegroundColor Gray
    Write-Host "   3. Right-click '$lnk' -> Pin to taskbar." -ForegroundColor Gray
    Write-Host '   4. Launch it from that pinned icon.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  The running window should now merge into the pinned button and keep' -ForegroundColor Gray
    Write-Host '  your custom icon instead of reverting to the Chrome logo.' -ForegroundColor Gray
}

function Install-StartMenuEntry {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [string]$Shortcut
    )
    $lnk   = Resolve-InstanceShortcut -Name $Name -Shortcut $Shortcut
    $progs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    New-Item -ItemType Directory -Force -Path $progs | Out-Null
    $dest = Join-Path $progs (Split-Path $lnk -Leaf)

    Copy-Item $lnk $dest -Force
    [CmLnkV1]::Clear($dest)

    $left = [CmLnkV1]::Get($dest)
    if ($left) { Die "could not strip AUMID from the Start copy (still '$left')" }

    $chk = (New-Object -ComObject WScript.Shell).CreateShortcut($dest)
    Ok "installed for Start menu: $dest"
    Write-Host "    target : $($chk.TargetPath)"
    Write-Host "    args   : $($chk.Arguments)"
    Write-Host "    icon   : $($chk.IconLocation)"
    Write-Host ''
    Write-Host '  Now: open Start -> All apps -> find this entry -> right-click -> Pin to Start.' -ForegroundColor Gray
    Write-Host '  It may take a few seconds to appear in All apps.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  Your desktop shortcut keeps its AUMID, so the taskbar pin is unaffected.' -ForegroundColor Gray
}

function Show-ShortcutAumid {
    param([Parameter(Mandatory=$true)][string]$Name, [string]$Shortcut)
    $lnk = Resolve-InstanceShortcut -Name $Name -Shortcut $Shortcut
    Say "shortcut : $lnk"
    $cur = [CmLnkV1]::Get($lnk)
    if ($cur) { Ok "current AUMID: $cur" } else { Warn 'no AUMID set on this shortcut' }
}

#===========================================================================
# Interactive mode
#===========================================================================
function Select-Instance {
    param([string]$Root, [string]$Prompt = 'instance number (0 = back)')
    $inst = @(Show-Instances -Root $Root)
    if ($inst.Count -eq 0) { return $null }
    Write-Host ''
    $i = Read-Index $Prompt $inst.Count
    if ($i -lt 0) { return $null }
    return $inst[$i]
}

function Invoke-MenuMigrate {
    param([string]$Root)

    Reset-ProcessTable
    $browsers = @(Get-DetectedBrowsers)
    if ($browsers.Count -eq 0) {
        Warn 'no supported source browsers found on this machine'
        Warn '(Chrome is not a source - it is the destination)'
        return
    }

    Write-Host ''
    Write-Host '  Source browsers' -ForegroundColor White
    Write-Host '  ---------------------------------------------' -ForegroundColor DarkGray
    $i = 0
    foreach ($b in $browsers) {
        $i++
        $tags = @()
        if (-not $b.Exe)          { $tags += 'not installed - leftover profile' }
        if ($b.ProprietaryCrypto) { $tags += 'passwords not migratable' }
        if (Test-BrowserRunning $b) { $tags += 'RUNNING' }
        $n = @(Get-BrowserProfiles $b).Count
        $word = if ($n -eq 1) { 'profile' } else { 'profiles' }
        $suffix = ''
        if ($tags.Count -gt 0) { $suffix = "  [$($tags -join '; ')]" }
        Write-Host ("   {0,2}  {1,-13} {2} {3}{4}" -f $i, $b.Name, $n, $word, $suffix) -ForegroundColor Cyan
        Write-Host ("       {0}" -f $b.UserData) -ForegroundColor DarkGray
    }
    Write-Host ''
    $pick = Read-Index 'source number (0 = back)' $browsers.Count
    if ($pick -lt 0) { return }
    $B = $browsers[$pick]

    # profile
    $profiles = @(Get-BrowserProfiles $B)
    if ($profiles.Count -eq 0) { Warn "no usable profiles under $($B.UserData)"; return }
    $srcProfileName = $profiles[0].Name
    if ($profiles.Count -gt 1) {
        Write-Host ''
        Write-Host "  Profiles in $($B.Name)" -ForegroundColor White
        $i = 0
        foreach ($p in $profiles) {
            $i++
            $tot = 0
            foreach ($lf in $B.LoginFiles) {
                $n = Get-RowCount (Join-Path $p.Path $lf) 'logins'
                if ($n -gt 0) { $tot += $n }
            }
            Write-Host ("   {0,2}  {1,-12} {2} saved login(s)" -f $i, $p.Name, $tot) -ForegroundColor Cyan
        }
        Write-Host ''
        $pp = Read-Index 'profile number (0 = back)' $profiles.Count
        if ($pp -lt 0) { return }
        $srcProfileName = $profiles[$pp].Name
    }

    Write-Host ''
    $name = Read-InstanceName -Root $Root
    if (-not $name) { return }

    Write-Host ''
    Write-Host '  What should move across?' -ForegroundColor White
    Write-Host '  Bookmarks, history, favicons, autofill and search engines always do.' -ForegroundColor DarkGray
    Write-Host ''
    $wantPw    = $false
    $wantCards = $false
    if ($B.ProprietaryCrypto) {
        Warn "$($B.Name) uses its own password crypto - logins and cards cannot be converted."
        Warn 'Export them to CSV from the browser and import into the new instance instead.'
    } else {
        $wantPw    = Read-YesNo 'saved passwords?' $true
        $wantCards = Read-YesNo 'saved credit cards?' $false
    }
    $wantCookies = Read-YesNo 'cookies (keeps you logged in - also carries session risk)?' $false
    $wantPrefs   = Read-YesNo 'browser settings / preferences?' $false

    Write-Host ''
    Write-Host '  Summary' -ForegroundColor White
    Write-Host "    source    : $($B.Name) / $srcProfileName" -ForegroundColor Gray
    Write-Host "    target    : $(Join-Path $Root $name)" -ForegroundColor Gray
    $incl = @('bookmarks','history','autofill')
    if ($wantPw)      { $incl += 'passwords' }
    if ($wantCards)   { $incl += 'cards' }
    if ($wantCookies) { $incl += 'cookies' }
    if ($wantPrefs)   { $incl += 'preferences' }
    Write-Host "    including : $($incl -join ', ')" -ForegroundColor Gray
    Write-Host ''

    $common = @{
        Source             = $B.Name
        Name               = $name
        Root               = $Root
        SourceProfile      = $srcProfileName
        IncludePasswords   = $wantPw
        IncludeCards       = $wantCards
        IncludeCookies     = $wantCookies
        IncludePreferences = $wantPrefs
        Force              = $true
        Interactive        = $true
    }

    if (Read-YesNo 'dry run first (shows what would move, writes nothing)?' $true) {
        Invoke-Migration @common -DryRun | Out-Null
        Write-Host ''
        if (-not (Read-YesNo 'go ahead for real?' $true)) { Warn 'cancelled'; return }
    } else {
        if (-not (Read-YesNo 'start migrating now?' $false)) { Warn 'cancelled'; return }
    }

    $res = Invoke-Migration @common
    if (-not $res) { return }

    Write-Host ''
    if (Read-YesNo 'set the taskbar icon for this instance now (needs a few clicks)?' $true) {
        Set-TaskbarIdentity -Name $res.Name -Root $Root -Shortcut $res.Shortcut
        Write-Host ''
        if (Read-YesNo 'also add it to the Start menu?' $true) {
            Install-StartMenuEntry -Name $res.Name -Shortcut $res.Shortcut
        }
    }
}

function Start-Instance {
    param([string]$Root)
    $inst = Select-Instance -Root $Root -Prompt 'launch which instance? (0 = back)'
    if (-not $inst) { return }
    $chrome = Resolve-ChromePath $null
    Say "launching $($inst.Name)"
    Start-Process $chrome -ArgumentList "--user-data-dir=`"$($inst.Path)`" --no-first-run --no-default-browser-check"
}

function Show-MainMenu {
    param([string]$Root)
    $script:Interactive = $true
    Write-Banner
    Write-Host "   instance root: $Root" -ForegroundColor DarkGray

    while ($true) {
        Write-Host ''
        Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
        Write-Host '   1  Scan for browsers and profiles' -ForegroundColor Gray
        Write-Host '   2  Migrate a profile into an isolated Chrome instance' -ForegroundColor Gray
        Write-Host '   3  Fix the taskbar icon for an instance' -ForegroundColor Gray
        Write-Host '   4  Add an instance to the Start menu' -ForegroundColor Gray
        Write-Host '   5  Show existing instances' -ForegroundColor Gray
        Write-Host '   6  Launch an instance' -ForegroundColor Gray
        Write-Host '   7  Change the instance root folder' -ForegroundColor Gray
        Write-Host '   0  Exit' -ForegroundColor Gray
        Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
        $c = (Read-Host '  choice').Trim()

        try {
            switch ($c) {
                '1' { Reset-ProcessTable; Show-BrowserList | Out-Null }
                '2' { Invoke-MenuMigrate -Root $Root }
                '3' {
                    $inst = Select-Instance -Root $Root -Prompt 'taskbar icon for which instance? (0 = back)'
                    if ($inst) { Set-TaskbarIdentity -Name $inst.Name -Root $Root -Shortcut $inst.Shortcut }
                }
                '4' {
                    $inst = Select-Instance -Root $Root -Prompt 'Start menu entry for which instance? (0 = back)'
                    if ($inst) { Install-StartMenuEntry -Name $inst.Name -Shortcut $inst.Shortcut }
                }
                '5' { Show-Instances -Root $Root | Out-Null }
                '6' { Start-Instance -Root $Root }
                '7' {
                    $r = (Read-Host "  new instance root (blank keeps $Root)").Trim()
                    if ($r) { $Root = $r; Ok "instance root is now $Root" }
                }
                '0'      { Write-Host ''; return }
                'q'      { Write-Host ''; return }
                'quit'   { Write-Host ''; return }
                'exit'   { Write-Host ''; return }
                default  { Write-Host '    pick a number from the list' -ForegroundColor DarkGray }
            }
        } catch {
            Write-Host ''
            Write-Failure $_
        }
    }
}

#===========================================================================
# Dispatch
#===========================================================================
$script:Interactive = $false
$ranAsFile = [bool]$PSCommandPath
$failed    = $false

try {
    if ($Version) {
        Write-Host "Chrome Profile Migrator $SCRIPT_VERSION  -  $SCRIPT_HOME"
    }
    elseif ($List) {
        Show-BrowserList | Out-Null
    }
    elseif ($ShowAumid) {
        if (-not $Name) { Die '-ShowAumid needs -Name' }
        Show-ShortcutAumid -Name $Name -Shortcut $Shortcut
    }
    elseif ($StartMenu -and -not $Source) {
        if (-not $Name) { Die '-StartMenu needs -Name' }
        Install-StartMenuEntry -Name $Name -Shortcut $Shortcut
    }
    elseif ($SetTaskbarIcon) {
        if (-not $Name) { Die '-SetTaskbarIcon needs -Name' }
        Set-TaskbarIdentity -Name $Name -Root $Root -Shortcut $Shortcut -Aumid $Aumid
    }
    elseif ($Source -and -not $Menu) {
        if (-not $Name) { Die '-Source needs -Name (the label for the new instance)' }
        $r = Invoke-Migration -Source $Source -Name $Name -Root $Root `
                -SourceProfile $SourceProfile -SourceUserData $SourceUserData -ChromePath $ChromePath `
                -IncludePasswords:$IncludePasswords -IncludeCards:$IncludeCards `
                -IncludeCookies:$IncludeCookies -IncludePreferences:$IncludePreferences `
                -NoShortcut:$NoShortcut -ShortcutPath $ShortcutPath `
                -Force:$Force -DryRun:$DryRun -IgnoreRunningCheck:$IgnoreRunningCheck
        if ($r) {
            Write-Host ''
            Write-Host '  Next:' -ForegroundColor Gray
            Write-Host '    1. Launch it, verify bookmarks / history / passwords' -ForegroundColor DarkGray
            Write-Host "    2. -Name $Name -SetTaskbarIcon   (taskbar icon)" -ForegroundColor DarkGray
            Write-Host "    3. -Name $Name -StartMenu        (Start menu pin)" -ForegroundColor DarkGray
            Write-Host ''
        }
    }
    elseif ($Name -and -not $Source -and -not $Menu) {
        Die "-Name on its own does nothing. Add -Source <browser>, -SetTaskbarIcon, -StartMenu or -ShowAumid."
    }
    else {
        Show-MainMenu -Root $Root
    }
}
catch {
    Write-Failure $_
    $failed = $true
}

# `exit` would take the whole session down under `irm | iex`, so it is only used
# when this really is a script file being run non-interactively.
if ($failed -and $ranAsFile -and -not $script:Interactive) { exit 1 }
