<#
.SYNOPSIS
    Signal Secure Window für Windows: Signals Profil liegt in einem
    VeraCrypt-Container, der nur eingehängt ist, solange Signal läuft.

.DESCRIPTION
    Start   -> VeraCrypt fragt das Passwort ab (sicherer Desktop), Container
               wird eingehängt, Signal startet
    Ende    -> Signal wird beendet, Container ausgehängt
    Zusätzlich wird Signal bei Bildschirmsperre (Win+L) und optional nach
    Inaktivität geschlossen und der Container gesperrt.

    %APPDATA%\Signal ist eine Verzeichnisverbindung (Junction) in den
    Container. Ist dieser gesperrt, zeigt sie ins Leere: Signal findet keine
    Daten und kann auch kein neues, unverschlüsseltes Profil anlegen.

.EXAMPLE
    .\SignalSecureWindow.ps1 init
    .\SignalSecureWindow.ps1 install-shortcut
    .\SignalSecureWindow.ps1 run -IdleMinutes 10
    .\SignalSecureWindow.ps1 lock
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('run', 'init', 'lock', 'status', 'install-shortcut', 'help')]
    [string]$Command = 'run',

    # Signal nach so vielen Minuten ohne Eingabe schließen (0 = aus)
    [int]$IdleMinutes = 0,

    # Signal bei Bildschirmsperre NICHT schließen
    [switch]$NoScreenLock,

    # Fehler/Hinweise als Dialog anzeigen (für den Start über die Verknüpfung)
    [switch]$Gui,

    # Nur für 'init'
    [string]$DriveLetter,
    [int]$SizeGB = 4,
    [string]$VaultPath,

    # Weitere Argumente direkt an Signal
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$SignalArgs
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$AppDir        = Join-Path $env:LOCALAPPDATA 'SignalSecureWindow'
$ConfigFile    = Join-Path $AppDir 'config.json'
$ProfileDir    = Join-Path $env:APPDATA 'Signal'
$MarkerName    = '.signal-secure-window'
$MutexName     = 'Local\SignalSecureWindow'
$LockEventName = 'Local\SignalSecureWindow-Lock'

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

function Write-Log([string]$Message) {
    Write-Host "SignalSecureWindow: $Message"
}

function Show-Message([string]$Message, [string]$Icon = 'Information') {
    if (-not $Gui) { return }
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($Message, 'Signal Secure Window', 'OK', $Icon)
}

function Fail([string]$Message) {
    Write-Host "SignalSecureWindow: Fehler: $Message" -ForegroundColor Red
    Show-Message $Message 'Error'
    exit 1
}

Add-Type -Namespace SSW -Name Native -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true)]
static extern IntPtr OpenDesktop(string name, uint flags, bool inherit, uint access);
[DllImport("user32.dll")] static extern bool SwitchDesktop(IntPtr h);
[DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);

[StructLayout(LayoutKind.Sequential)]
struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
[DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO info);

// Gesperrt, wenn der normale Desktop nicht der aktive Eingabe-Desktop ist
public static bool InputDesktopUnavailable() {
    IntPtr h = OpenDesktop("Default", 0, false, 0x0100 /* DESKTOP_SWITCHDESKTOP */);
    if (h == IntPtr.Zero) return true;
    bool ok = SwitchDesktop(h);
    CloseDesktop(h);
    return !ok;
}

public static uint IdleMilliseconds() {
    LASTINPUTINFO info = new LASTINPUTINFO();
    info.cbSize = (uint)Marshal.SizeOf(info);
    if (!GetLastInputInfo(ref info)) return 0;
    return unchecked((uint)Environment.TickCount - info.dwTime);
}
'@

function Test-SessionLocked {
    # Auch UAC-Abfragen belegen kurz den sicheren Desktop – daher zusätzlich
    # prüfen, ob der Sperrbildschirm (LogonUI) aktiv ist.
    if (-not [SSW.Native]::InputDesktopUnavailable()) { return $false }
    return [bool](Get-Process -Name LogonUI -ErrorAction SilentlyContinue)
}

function Get-Config {
    $cfg = [ordered]@{
        VaultPath   = Join-Path $AppDir 'signal.hc'
        DriveLetter = ''
    }
    if (Test-Path $ConfigFile) {
        $saved = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        foreach ($k in @('VaultPath', 'DriveLetter')) {
            if ($saved.PSObject.Properties.Name -contains $k -and $saved.$k) { $cfg[$k] = $saved.$k }
        }
    }
    if ($VaultPath)   { $cfg.VaultPath = $VaultPath }
    if ($DriveLetter) { $cfg.DriveLetter = $DriveLetter.TrimEnd(':').ToUpper() }
    return $cfg
}

function Find-VeraCrypt([string]$Exe = 'VeraCrypt.exe') {
    foreach ($dir in @("$env:ProgramFiles\VeraCrypt", "${env:ProgramFiles(x86)}\VeraCrypt")) {
        $p = Join-Path $dir $Exe
        if (Test-Path $p) { return $p }
    }
    Fail "VeraCrypt nicht gefunden. Bitte von https://veracrypt.fr installieren."
}

function Find-Signal {
    $p = Join-Path $env:LOCALAPPDATA 'Programs\signal-desktop\Signal.exe'
    if (Test-Path $p) { return $p }
    Fail "Signal Desktop nicht gefunden ($p)."
}

function Get-SignalProcesses {
    # Alle Signal-Prozesse (Haupt- und Hilfsprozesse) dieser Installation
    $exe = Find-Signal
    Get-Process -Name Signal -ErrorAction SilentlyContinue |
        Where-Object { $null -eq $_.Path -or $_.Path -eq $exe }
}

function Get-FreeDriveLetter {
    $used = (Get-PSDrive -PSProvider FileSystem).Name
    foreach ($l in 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'R', 'Q', 'P') {
        if ($used -notcontains $l) { return $l }
    }
    Fail "Kein freier Laufwerksbuchstabe gefunden."
}

function Test-VaultMounted($cfg) {
    return Test-Path (Join-Path "$($cfg.DriveLetter):\" $MarkerName)
}

function Invoke-VeraCrypt([string[]]$Arguments) {
    $vc = Find-VeraCrypt
    # Nicht versteckt starten, sonst wäre auch der Passwortdialog unsichtbar
    $p = Start-Process -FilePath $vc -ArgumentList $Arguments -Wait -PassThru
    return $p.ExitCode
}

function Mount-Vault($cfg) {
    if (Test-VaultMounted $cfg) { return }
    if (-not (Test-Path $cfg.VaultPath)) { Fail "Kein Container gefunden. Erst 'init' ausführen." }
    if (Test-Path "$($cfg.DriveLetter):\") {
        Fail "Laufwerk $($cfg.DriveLetter): ist bereits belegt (nicht der Signal-Container)."
    }
    # Passwort gibt der Nutzer direkt in VeraCrypts Dialog ein (sicherer Desktop),
    # es wird nicht zwischengespeichert und nicht in der Verlaufsliste gemerkt.
    $rc = Invoke-VeraCrypt @(
        '/volume', "`"$($cfg.VaultPath)`"", '/letter', $cfg.DriveLetter,
        '/quit', '/cache', 'n', '/history', 'n', '/secureDesktop', 'y', '/nowaitdlg', 'y'
    )
    if ($rc -ne 0 -or -not (Test-VaultMounted $cfg)) {
        Fail "Container konnte nicht entsperrt werden (abgebrochen oder falsches Passwort)."
    }
    Write-Log "Container entsperrt ($($cfg.DriveLetter):)."
}

function Dismount-Vault($cfg) {
    if (-not (Test-Path "$($cfg.DriveLetter):\")) { return }
    for ($i = 0; $i -lt 10; $i++) {
        [void](Invoke-VeraCrypt @('/dismount', $cfg.DriveLetter, '/quit', '/silent'))
        if (-not (Test-Path "$($cfg.DriveLetter):\")) { Write-Log 'Container gesperrt.'; return }
        Start-Sleep -Milliseconds 500
    }
    Write-Log 'Warnung: Container noch in Benutzung – erzwinge Aushängen.'
    [void](Invoke-VeraCrypt @('/dismount', $cfg.DriveLetter, '/force', '/quit', '/silent'))
    if (Test-Path "$($cfg.DriveLetter):\") {
        Show-Message "Container $($cfg.DriveLetter): konnte nicht ausgehängt werden!" 'Warning'
    }
}

function Stop-Signal {
    $procs = @(Get-SignalProcesses)
    if ($procs.Count -eq 0) { return }
    # Erst höflich (Fenster schließen), dann hart beenden
    foreach ($p in $procs) { try { [void]$p.CloseMainWindow() } catch { } }
    for ($i = 0; $i -lt 20; $i++) {
        if (@(Get-SignalProcesses).Count -eq 0) { return }
        Start-Sleep -Milliseconds 500
    }
    Get-SignalProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

function Test-ProfileJunction($cfg) {
    # GetAttributes folgt der Verknüpfung nicht – funktioniert auch, wenn
    # der Container gesperrt ist und die Junction ins Leere zeigt.
    try { $attr = [IO.File]::GetAttributes($ProfileDir) } catch { return $false }
    if (-not ($attr -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    if (-not (Test-VaultMounted $cfg)) { return $true }
    $item = Get-Item -LiteralPath $ProfileDir -Force
    return $item.LinkType -eq 'Junction' -and (@($item.Target)[0] -like "$($cfg.DriveLetter):\Signal*")
}

# ---------------------------------------------------------------------------
# Befehle
# ---------------------------------------------------------------------------

function Invoke-Run {
    $cfg = Get-Config
    if (-not $cfg.DriveLetter) { Fail "Nicht eingerichtet. Erst 'init' ausführen." }
    $signalExe = Find-Signal

    # Nur eine Instanz
    $mutex = New-Object System.Threading.Mutex($false, $MutexName)
    $owned = $false
    try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) {
        # Signal-Fenster nach vorne holen (Signal übergibt an die laufende Instanz)
        if (@(Get-SignalProcesses).Count -gt 0) { Start-Process -FilePath $signalExe }
        Write-Log 'Signal läuft bereits im Secure Window.'
        return
    }

    $lockEvent = New-Object System.Threading.EventWaitHandle($false,
        [System.Threading.EventResetMode]::AutoReset, $LockEventName)
    $reason = $null
    $mounted = $false
    try {
        if (@(Get-SignalProcesses).Count -gt 0) {
            Fail 'Signal läuft bereits ungeschützt. Bitte erst beenden (auch im Infobereich).'
        }
        if (-not (Test-ProfileJunction $cfg)) {
            Fail "$ProfileDir zeigt nicht in den Container. Bitte 'init' ausführen."
        }

        Mount-Vault $cfg
        $mounted = $true
        if (-not (Test-ProfileJunction $cfg)) {
            Fail "$ProfileDir zeigt nicht nach $($cfg.DriveLetter):\Signal."
        }

        $startArgs = @{ FilePath = $signalExe }
        if ($SignalArgs) { $startArgs.ArgumentList = $SignalArgs }
        Start-Process @startArgs
        for ($i = 0; $i -lt 40 -and @(Get-SignalProcesses).Count -eq 0; $i++) {
            Start-Sleep -Milliseconds 250
        }

        $idleLimit = [uint32]$IdleMinutes * 60000
        while (@(Get-SignalProcesses).Count -gt 0) {
            if ($lockEvent.WaitOne(0)) { $reason = 'Sperre angefordert'; break }
            if (-not $NoScreenLock -and (Test-SessionLocked)) { $reason = 'Bildschirm gesperrt'; break }
            if ($IdleMinutes -gt 0 -and [SSW.Native]::IdleMilliseconds() -ge $idleLimit) {
                $reason = 'Inaktivität'; break
            }
            Start-Sleep -Seconds 2
        }
        if ($reason) { Write-Log "$reason – schließe Signal und sperre den Container." }
        else { Write-Log 'Signal beendet.' }
    }
    finally {
        # Nur aufräumen, was wir selbst geöffnet haben – ein ungeschützt
        # laufendes Signal oder ein fremdes Laufwerk bleiben unberührt.
        if ($mounted) {
            Stop-Signal
            Dismount-Vault $cfg
        }
        $lockEvent.Dispose()
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

function Invoke-Init {
    $cfg = Get-Config
    if (Test-Path $cfg.VaultPath) { Fail "Container existiert bereits: $($cfg.VaultPath)" }
    if (@(Get-SignalProcesses).Count -gt 0) { Fail 'Bitte Signal vor der Einrichtung beenden.' }
    $format = Find-VeraCrypt 'VeraCrypt Format.exe'
    if (-not $cfg.DriveLetter) { $cfg.DriveLetter = Get-FreeDriveLetter }
    if (Test-Path "$($cfg.DriveLetter):\") { Fail "Laufwerk $($cfg.DriveLetter): ist belegt." }

    if (Test-ProfileJunction $cfg) {
        Fail "$ProfileDir ist bereits eine Verknüpfung – wurde schon eingerichtet?"
    }
    $existing = Test-Path -LiteralPath $ProfileDir
    if ($existing) {
        $sizeMB = [math]::Ceiling(((Get-ChildItem $ProfileDir -Recurse -Force -File |
            Measure-Object Length -Sum).Sum) / 1MB)
        if ($sizeMB * 1.5 -gt $SizeGB * 1024) {
            Fail "Profil ist $sizeMB MB groß – bitte größeren Container wählen (-SizeGB)."
        }
    }

    $pw1 = Read-Host 'Neues Container-Passwort' -AsSecureString
    $pw2 = Read-Host 'Passwort wiederholen' -AsSecureString
    $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw1))
    $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw2))
    if ($plain1 -ne $plain2) { Fail 'Passwörter stimmen nicht überein.' }
    if ($plain1.Length -lt 12) { Fail 'Bitte mindestens 12 Zeichen verwenden.' }
    if ($plain1.Contains('"')) { Fail 'Das Passwort darf kein Anführungszeichen (") enthalten.' }
    $plain2 = $null

    New-Item -ItemType Directory -Force -Path (Split-Path $cfg.VaultPath) | Out-Null
    Write-Log "Erstelle $SizeGB GB Container $($cfg.VaultPath) (das kann dauern) ..."
    # VeraCrypt Format nimmt das Passwort nur auf der Kommandozeile an; es ist
    # dort nur für die Dauer der Erstellung sichtbar.
    $p = Start-Process -FilePath $format -Wait -PassThru -WindowStyle Hidden -ArgumentList @(
        '/create', "`"$($cfg.VaultPath)`"", '/size', "$($SizeGB)G",
        '/password', "`"$plain1`"", '/encryption', 'AES', '/hash', 'sha512',
        '/filesystem', 'NTFS', '/silent'
    )
    if ($p.ExitCode -ne 0) { $plain1 = $null; Fail "Container-Erstellung fehlgeschlagen (Code $($p.ExitCode))." }

    $rc = Invoke-VeraCrypt @(
        '/volume', "`"$($cfg.VaultPath)`"", '/letter', $cfg.DriveLetter,
        '/password', "`"$plain1`"", '/quit', '/silent', '/cache', 'n', '/history', 'n'
    )
    $plain1 = $null
    if ($rc -ne 0) { Fail "Neuer Container ließ sich nicht einhängen (Code $rc)." }

    try {
        $root = "$($cfg.DriveLetter):\"
        Set-Content -Path (Join-Path $root $MarkerName) -Value 'Signal Secure Window'
        $dest = Join-Path $root 'Signal'
        New-Item -ItemType Directory -Force -Path $dest | Out-Null

        if ($existing) {
            Write-Log 'Kopiere vorhandenes Signal-Profil in den Container ...'
            & robocopy.exe $ProfileDir $dest /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
            if ($LASTEXITCODE -ge 8) { Fail "Kopieren fehlgeschlagen (robocopy $LASTEXITCODE). Original unverändert." }
            $src = Get-ChildItem $ProfileDir -Recurse -Force -File | Measure-Object Length -Sum
            $dst = Get-ChildItem $dest -Recurse -Force -File | Measure-Object Length -Sum
            if ($src.Count -ne $dst.Count -or $src.Sum -ne $dst.Sum) {
                Fail 'Kopie stimmt nicht mit dem Original überein. Original unverändert.'
            }
            Write-Log "Profil kopiert ($($dst.Count) Dateien)."

            $answer = Read-Host 'Unverschlüsseltes Original jetzt löschen? [j/N]'
            if ($answer -match '^[jJyY]') {
                Remove-Item -LiteralPath $ProfileDir -Recurse -Force
                Write-Log "Original gelöscht. Freien Speicher überschreiben: cipher /w:$env:APPDATA"
                Write-Log '(Auf SSDs ist auch das keine Garantie – BitLocker empfohlen.)'
            }
            else {
                $backup = "$ProfileDir.unverschluesselt.$(Get-Date -Format yyyyMMddHHmmss)"
                Rename-Item -LiteralPath $ProfileDir -NewName (Split-Path $backup -Leaf)
                Write-Log "Original verschoben nach $backup – bitte selbst sicher löschen."
            }
        }

        New-Item -ItemType Junction -Path $ProfileDir -Target $dest | Out-Null
        Write-Log "$ProfileDir -> $dest"
    }
    finally {
        Dismount-Vault $cfg
    }

    New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
    [ordered]@{ VaultPath = $cfg.VaultPath; DriveLetter = $cfg.DriveLetter } |
        ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8
    Write-Log "Fertig. Jetzt '.\SignalSecureWindow.ps1 install-shortcut' ausführen."
    Write-Log 'Wichtig: In Signal "Beim Anmelden starten" ausschalten.'
}

function Invoke-Lock {
    $ev = $null
    if ([System.Threading.EventWaitHandle]::TryOpenExisting($LockEventName, [ref]$ev)) {
        [void]$ev.Set()
        $ev.Dispose()
        Write-Log 'Sperranforderung gesendet.'
    }
    else {
        $cfg = Get-Config
        if ($cfg.DriveLetter -and (Test-VaultMounted $cfg)) { Stop-Signal; Dismount-Vault $cfg }
    }
}

function Invoke-Status {
    $cfg = Get-Config
    "Container:    $($cfg.VaultPath) $(if (Test-Path $cfg.VaultPath) { '(vorhanden)' } else { '(fehlt)' })"
    "Laufwerk:     $(if ($cfg.DriveLetter) { "$($cfg.DriveLetter):" } else { '(nicht eingerichtet)' })"
    "Profil:       $ProfileDir $(if (Test-ProfileJunction $cfg) { '-> Container (ok)' } else { '(NICHT umgeleitet)' })"
    "Zustand:      $(if ($cfg.DriveLetter -and (Test-VaultMounted $cfg)) { 'ENTSPERRT' } else { 'gesperrt' })"
    $ev = $null
    $protected = [System.Threading.EventWaitHandle]::TryOpenExisting($LockEventName, [ref]$ev)
    if ($ev) { $ev.Dispose() }
    $running = @(Get-SignalProcesses).Count -gt 0
    "Signal:       $(if ($running -and $protected) { 'läuft im Secure Window' } elseif ($running) { 'läuft UNGESCHÜTZT' } else { 'beendet' })"
}

function Invoke-InstallShortcut {
    $signalExe = Find-Signal
    $self = $PSCommandPath
    $shell = New-Object -ComObject WScript.Shell
    $targets = @(
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'Signal (Secure Window).lnk'),
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Signal (Secure Window).lnk')
    )
    foreach ($path in $targets) {
        $lnk = $shell.CreateShortcut($path)
        $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$self`" run -Gui"
        $lnk.IconLocation = "$signalExe,0"
        $lnk.Description = 'Signal mit verschlüsseltem Profil'
        $lnk.Save()
        Write-Log "Verknüpfung erstellt: $path"
    }
    Write-Log 'Die normalen Signal-Verknüpfungen funktionieren bei gesperrtem Container nicht mehr.'
}

switch ($Command) {
    'run'              { Invoke-Run }
    'init'             { Invoke-Init }
    'lock'             { Invoke-Lock }
    'status'           { Invoke-Status }
    'install-shortcut' { Invoke-InstallShortcut }
    'help'             { Get-Help $PSCommandPath -Detailed }
}
