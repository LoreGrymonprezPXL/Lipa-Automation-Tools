<#
.SYNOPSIS
    Lipa Toolkit - setup, controle en ticket-generatie voor nieuwe Windows-pc's (Werk of Gaming).

.DESCRIPTION
    Menu dat blijft draaien: kies losse acties (1,5,7) of "A" voor alles in volgorde.

      SETUP       1 Toestelnaam   2 Regio/tijd   3 Energie   4 Beveiliging basis
      ACCOUNTS    5 Clientadmin   6 Klantaccount
      SOFTWARE    7 Debloat       8 Software     9 Updates
      CONTROLE    10 Hardware testen   11 Controle   12 Ticket + rapport
      TOOLS       P Opdracht/ticket-info   F Herstel fouten   K Wachtwoorden   A Alles   Q Stop

    Slim ticket: het script leest (optioneel) de ticketbeschrijving van je klembord,
    detecteert software en hardware, en noteert in het ticket ENKEL wat relevant is
    (bv. geen M365-regels zonder Office, geen kaartlezer-test zonder kaartlezer).

    Wachtwoorden worden niet naar schijf geschreven (tenzij -IncludePasswordsInTicket).

.EXAMPLE
    .\Lipa-Toolkit.ps1
.EXAMPLE
    .\Lipa-Toolkit.ps1 -PcType Gaming -FromClipboard          # ticket eerst kopieren in Autotask
.EXAMPLE
    .\Lipa-Toolkit.ps1 -Run 7,8,11,12                          # zonder menu: debloat, software, controle, ticket
.EXAMPLE
    .\Lipa-Toolkit.ps1 -VerifyOnly                             # na herstart: enkel controle + ticket

.NOTES
    Uitvoeren als Administrator:
      powershell -ExecutionPolicy Bypass -File .\Lipa-Toolkit.ps1
    Geen mooie lijnen in je console? Gebruik -Ascii.
#>
[CmdletBinding()]
param(
    [ValidateSet('Gaming', 'Werk')][string]$PcType,
    [string]$CustomerName,
    [string]$TicketNr,
    [string]$CustomerUser,
    [string]$AdminUser = 'Clientadmin',
    [string]$ExpectedHostname,
    [int]$Days = 14,
    [string]$OutDir = 'C:\temp',
    [string[]]$Run,
    [switch]$VerifyOnly,
    [switch]$FromClipboard,
    [switch]$IncludePasswordsInTicket,
    [switch]$FullSpecs,
    [switch]$CopyToClipboard,
    [switch]$Ascii,
    [switch]$NoClear
)

# ============================================================================
# CONFIG
# ============================================================================
$MaxHostnameLength = 15
$SplashtopUrl = 'https://my.splashtop.eu/sos/packages/download/XW2PS2PZ5KSKEU'
$SplashtopDesktopName = 'SOS Lipa.exe'
$MinPasswordLength = $null      # bv. 8      ($null = niet aanraken)
$MaxPasswordAgeDays = $null     # bv. 0 = nooit verlopen, 90

# Pakketcatalogus (Default = voorgeselecteerd voor die PcType, Vendor = enkel op dat merk)
$AppCatalog = @(
    @{ Name = 'Splashtop SOS (Lipa)';  Special = 'Splashtop'; Default = 'Werk', 'Gaming' },
    @{ Name = 'RustDesk';              Winget = 'RustDesk.RustDesk'; Choco = 'rustdesk'; Match = '*RustDesk*'; Default = 'Werk' },
    @{ Name = 'Mozilla Firefox';       Winget = 'Mozilla.Firefox'; Choco = 'firefox'; Match = '*Firefox*'; Default = 'Werk', 'Gaming' },
    @{ Name = 'Google Chrome';         Winget = 'Google.Chrome'; Choco = 'googlechrome'; Match = '*Google Chrome*'; Default = 'Werk', 'Gaming' },
    @{ Name = 'Adobe Acrobat Reader';  Winget = 'Adobe.Acrobat.Reader.64-bit'; Choco = 'adobereader'; Match = '*Acrobat*'; Default = 'Werk', 'Gaming' },
    @{ Name = 'Foxit PDF Reader';      Winget = 'Foxit.FoxitReader'; Choco = 'foxitreader'; Match = '*Foxit*'; Default = 'Werk' },
    @{ Name = 'Belgian eID middleware'; Winget = 'BelgianGovernment.eIDmiddleware'; Choco = 'eid-belgium', 'belgian-eid-middleware'; Match = '*eID*Middleware*|*Belgium eID*'; Default = 'Werk' },
    @{ Name = 'Belgian eID viewer';    Winget = 'BelgianGovernment.eIDViewer'; Choco = 'eid-belgium-viewer', 'belgian-eid-viewer'; Match = '*eID Viewer*'; Default = 'Werk' },
    @{ Name = 'OpenVPN Connect';       Winget = 'OpenVPNTechnologies.OpenVPNConnect'; Choco = 'openvpn-connect'; Match = '*OpenVPN Connect*'; Default = 'Werk' },
    @{ Name = 'VLC media player';      Winget = 'VideoLAN.VLC'; Choco = 'vlc'; Match = '*VLC*'; Default = 'Werk', 'Gaming' },
    @{ Name = 'Microsoft 365 Apps (licentie nodig)'; Winget = 'Microsoft.Office'; Choco = 'office365business', 'office365proplus'; Match = '*Microsoft 365*|*Office 16*'; Default = @(); Job = 'Office' },
    @{ Name = 'Steam';                 Winget = 'Valve.Steam'; Choco = 'steam'; Match = 'Steam'; Default = 'Gaming' },
    @{ Name = 'Epic Games Launcher';   Winget = 'EpicGames.EpicGamesLauncher'; Choco = 'epicgameslauncher'; Match = '*Epic Games Launcher*'; Default = 'Gaming' },
    @{ Name = 'Discord';               Winget = 'Discord.Discord'; Choco = 'discord'; Match = '*Discord*'; Default = @() },
    @{ Name = 'HP programmable key';   Winget = '9MW15F21R5G8'; Default = 'Werk'; Vendor = 'HP' },
    @{ Name = 'HP Support Assistant';  Choco = 'hpsupportassistant'; Match = '*HP Support Assistant*'; Default = 'Werk'; Vendor = 'HP' },
    @{ Name = 'HP Image Assistant';    Winget = 'HP.ImageAssistant'; Choco = 'hpimageassistant'; Match = '*HP Image Assistant*'; Default = 'Werk'; Vendor = 'HP' }
)

# Debloat: WHITELIST van wat weg mag (alles wat hier niet in staat blijft ongemoeid). Level 1 licht, 2 medium, 3 zwaar.
$DebloatRules = @(
    @{ Level = 1; Kind = 'Win32'; Pattern = 'McAfee*';      Why = 'Trial antivirus' },
    @{ Level = 1; Kind = 'Win32'; Pattern = 'WebAdvisor*';  Why = 'McAfee adware' },
    @{ Level = 1; Kind = 'Win32'; Pattern = 'Norton*';      Why = 'Trial antivirus' },
    @{ Level = 1; Kind = 'Win32'; Pattern = 'Avast*';       Why = 'Concurrerend antivirus' },
    @{ Level = 1; Kind = 'Win32'; Pattern = 'AVG*';         Why = 'Concurrerend antivirus' },
    @{ Level = 1; Kind = 'Win32'; Pattern = 'WildTangent*'; Why = 'Spelletjes-adware' },
    @{ Level = 1; Kind = 'Win32'; Pattern = 'ExpressVPN*';  Why = 'Trial VPN' },
    @{ Level = 1; Kind = 'Win32'; Pattern = 'Dropbox promotion*'; Why = 'OEM promo' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*CandyCrush*';  Why = 'Promo-spel' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*BubbleWitch*'; Why = 'Promo-spel' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*FarmVille*';   Why = 'Promo-spel' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*MarchofEmpires*'; Why = 'Promo-spel' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*RoyalRevolt*'; Why = 'Promo-spel' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*TikTok*';      Why = 'Promo-app' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*Disney*';      Why = 'Promo-app' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*Netflix*';     Why = 'Promo-app' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*Facebook*';    Why = 'Promo-app' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*Instagram*';   Why = 'Promo-app' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*Twitter*';     Why = 'Promo-app' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*Hulu*';        Why = 'Promo-app' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*Booking*';     Why = 'Promo-app' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*AmazonPrimeVideo*'; Why = 'Promo-app' },
    @{ Level = 2; Kind = 'Appx';  Pattern = '*Spotify*';     Why = 'Promo-app' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Clipchamp*';    Why = 'Videobewerker' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Microsoft.MicrosoftSolitaireCollection'; Why = 'Spelletjes' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Microsoft.BingNews';    Why = 'Nieuws' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Microsoft.BingWeather'; Why = 'Weer' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Microsoft.GetHelp';     Why = 'Get Help' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Microsoft.Getstarted';  Why = 'Tips' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Microsoft.WindowsFeedbackHub'; Why = 'Feedback Hub' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Microsoft.MicrosoftOfficeHub'; Why = 'Office-hub (promo)' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Microsoft.549981C3F5F10';     Why = 'Cortana' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'MSTeams';               Why = 'Teams (consumer)' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'MicrosoftTeams';        Why = 'Teams (consumer)' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Microsoft.PowerAutomateDesktop'; Why = 'Power Automate' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Microsoft.MixedReality.Portal';  Why = 'Mixed Reality' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Microsoft.People';      Why = 'People' },
    @{ Level = 3; Kind = 'Appx';  Pattern = 'Microsoft.YourPhone';   Why = 'Phone Link' },
    @{ Level = 3; Kind = 'Appx';  Pattern = 'Microsoft.WindowsMaps'; Why = 'Kaarten' },
    @{ Level = 3; Kind = 'Appx';  Pattern = 'Microsoft.Copilot';     Why = 'Copilot-app' },
    @{ Level = 3; Kind = 'Appx';  Pattern = 'Microsoft.OutlookForWindows'; Why = 'Nieuwe Outlook' },
    @{ Level = 3; Kind = 'Appx';  Pattern = 'MicrosoftCorporationII.MicrosoftFamily'; Why = 'Family' },
    @{ Level = 3; Kind = 'Appx';  Pattern = 'Microsoft.Windows.DevHome'; Why = 'Dev Home' },
    @{ Level = 3; Kind = 'Appx';  Pattern = 'Microsoft.BingSearch';  Why = 'Bing-zoeken' },
    @{ Level = 3; Kind = 'Win32'; Pattern = 'Microsoft 365 - *';     Why = 'Office-PROEFVERSIE (verwijdert ook betaalde Office!)' }
)

# ============================================================================
# STATE
# ============================================================================
$ErrorActionPreference = 'Continue'
$script:Results = New-Object System.Collections.Generic.List[object]
$script:ActionLog = New-Object System.Collections.Generic.List[string]
$script:Creds = New-Object System.Collections.Generic.List[object]
$script:InstallOk = New-Object System.Collections.Generic.List[string]
$script:InstallFail = New-Object System.Collections.Generic.List[string]
$script:Done = @{}
$script:HwTests = [ordered]@{}
$script:Job = @{ Office = $false; TrendMicro = $false; Datto = $false; DataTransfer = $false; Backup = $false }
$script:JobText = @{ DataTransfer = ''; TMCustomer = '' }
$script:TicketInfo = @{}
$script:SoftwareSelection = @()
$script:PendingName = $null
$script:NeedReboot = $false
$script:ChocoDeclined = $false
$script:PendingUpdateCount = $null
$script:Hw = $null
$script:CustomerUserResolved = $null
$script:LastReport = $null

# ============================================================================
# UI
# ============================================================================
if ($Ascii) {
    $U = @{ H = '-'; V = '|'; TL = '+'; TR = '+'; BL = '+'; BR = '+'; Ok = '[+]'; Bad = '[x]'; Warn = '[!]'; Info = '[i]'; Dot = '*'; Arrow = '>' }
}
else {
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    $U = @{
        H = [string][char]0x2500; V = [string][char]0x2502; TL = [string][char]0x250C; TR = [string][char]0x2510
        BL = [string][char]0x2514; BR = [string][char]0x2518; Ok = [string][char]0x2713; Bad = [string][char]0x2717
        Warn = '!'; Info = 'i'; Dot = [string][char]0x25CF; Arrow = [string][char]0x25B8
    }
}
$BoxWidth = 84

function Say { param([string]$m, [string]$c = 'Gray') Write-Host $m -ForegroundColor $c }
function Say-Ok { param([string]$m) Write-Host "  $($U.Ok) " -NoNewline -ForegroundColor Green; Write-Host $m }
function Say-Warn { param([string]$m) Write-Host "  $($U.Warn) " -NoNewline -ForegroundColor Yellow; Write-Host $m -ForegroundColor Yellow }
function Say-Bad { param([string]$m) Write-Host "  $($U.Bad) " -NoNewline -ForegroundColor Red; Write-Host $m -ForegroundColor Red }
function Say-Info { param([string]$m) Write-Host "  $($U.Arrow) " -NoNewline -ForegroundColor Cyan; Write-Host $m -ForegroundColor Gray }
function Log-Action { param([string]$m) $script:ActionLog.Add($m); Say-Ok $m }
function Cut { param([string]$s, [int]$n) if ($s.Length -gt $n) { return $s.Substring(0, $n - 3) + '...' } return $s }
function Pause-Menu { Write-Host ''; [void](Read-Host '  Enter = terug naar menu') }

function Write-Section {
    param([string]$T)
    Write-Host ''
    Write-Host ("$($U.H * 3) $T " + ($U.H * [math]::Max(3, ($BoxWidth - 6 - $T.Length)))) -ForegroundColor Cyan
}

# Lines: string | hashtable @{T;C} | array of such segments
function Write-Box {
    param([string]$Title, $Lines, [string]$BorderColor = 'DarkCyan')
    $inner = $BoxWidth - 2
    $t = if ($Title) { " $Title " } else { '' }
    Write-Host ($U.TL + ($U.H * 2) + $t + ($U.H * [math]::Max(0, $inner - 2 - $t.Length)) + $U.TR) -ForegroundColor $BorderColor
    foreach ($l in $Lines) {
        if ($l -is [string]) { $segs = @(@{ T = $l; C = 'Gray' }) }
        elseif ($l -is [hashtable]) { $segs = @($l) }
        else { $segs = $l }
        $len = 0
        foreach ($s in $segs) { $len += $s.T.Length }
        Write-Host $U.V -NoNewline -ForegroundColor $BorderColor
        Write-Host ' ' -NoNewline
        foreach ($s in $segs) { Write-Host $s.T -NoNewline -ForegroundColor $s.C }
        Write-Host ((' ' * [math]::Max(0, $inner - 2 - $len)) + ' ') -NoNewline
        Write-Host $U.V -ForegroundColor $BorderColor
    }
    Write-Host ($U.BL + ($U.H * $inner) + $U.BR) -ForegroundColor $BorderColor
}

function Ask-YesNo {
    param([string]$Question, [bool]$Default = $true)
    $hint = if ($Default) { '[J/n]' } else { '[j/N]' }
    while ($true) {
        $a = (Read-Host "  $Question $hint").Trim().ToLower()
        if (-not $a) { return $Default }
        if ($a -in 'j', 'y', 'ja', 'yes') { return $true }
        if ($a -in 'n', 'nee', 'no') { return $false }
    }
}

function Ask-Choice {
    param([string]$Question, [string[]]$Options, [int]$Default = 1)
    Write-Host "  $Question" -ForegroundColor Yellow
    for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host ("    {0}. {1}" -f ($i + 1), $Options[$i]) }
    while ($true) {
        $a = Read-Host "  Keuze [$Default]"
        if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) { return $n }
    }
}

# ============================================================================
# CORE HELPERS
# ============================================================================
function Add-Check {
    param(
        [string]$Section, [string]$Item,
        [ValidateSet('OK', 'WARN', 'FAIL', 'INFO')][string]$Status,
        [string]$Detail = '', [string]$Fix = ''
    )
    $script:Results.Add([pscustomobject]@{ Section = $Section; Item = $Item; Status = $Status; Detail = [string]$Detail; Fix = $Fix })
}

function Invoke-Safe {
    param([string]$Name, [scriptblock]$Code)
    try { & $Code } catch { Add-Check $Name 'Sectie niet volledig uitgevoerd' 'WARN' $_.Exception.Message }
}

function Get-InstalledSoftware {
    $paths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent } |
        ForEach-Object {
            $d = $null
            if ($_.InstallDate -match '^\d{8}$') { try { $d = [datetime]::ParseExact($_.InstallDate, 'yyyyMMdd', $null) } catch { } }
            [pscustomobject]@{
                Name = $_.DisplayName; Version = $_.DisplayVersion; Publisher = $_.Publisher; InstallDate = $d
                Uninstall = $_.UninstallString; QuietUninstall = $_.QuietUninstallString
            }
        } | Sort-Object Name -Unique
}

function Test-NameMatch {
    param([string]$Name, [string]$PatternList)
    foreach ($p in ($PatternList -split '\|')) { if ($Name -like $p) { return $true } }
    return $false
}

function Test-LocalAdmin {
    param([string]$Name)
    $m = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue | ForEach-Object { ($_.Name -split '\\')[-1] })
    return ($m -contains $Name)
}

function ConvertTo-PlainText { param([securestring]$Secure) return (New-Object System.Net.NetworkCredential('', $Secure)).Password }

function New-RandomPassword {
    param([int]$Length = 14)
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#$%&*?')
    $all = $sets -join ''
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $pick = {
        param([string]$s)
        $b = New-Object byte[] 4
        $rng.GetBytes($b)
        $s[[int]([BitConverter]::ToUInt32($b, 0) % $s.Length)]
    }
    $chars = New-Object System.Collections.Generic.List[char]
    foreach ($s in $sets) { $chars.Add((& $pick $s)) }
    while ($chars.Count -lt $Length) { $chars.Add((& $pick $all)) }
    return (-join ($chars | Sort-Object { Get-Random }))
}

# Geeft @{Secure;Plain;Empty} of $null (overslaan)
function Get-NewPassword {
    param([string]$User, [switch]$AllowEmpty)
    $opts = @('Random wachtwoord genereren (aanbevolen)', 'Eigen wachtwoord invoeren', 'Overslaan')
    if ($AllowEmpty) { $opts = @('Random wachtwoord genereren (aanbevolen)', 'Eigen wachtwoord invoeren', 'GEEN wachtwoord', 'Overslaan') }
    $c = Ask-Choice "Wachtwoord voor '$User':" $opts 1
    if ($c -eq $opts.Count) { return $null }
    if ($AllowEmpty -and $c -eq 3) { return @{ Secure = $null; Plain = ''; Empty = $true } }
    if ($c -eq 1) {
        $p = New-RandomPassword
        return @{ Secure = (ConvertTo-SecureString $p -AsPlainText -Force); Plain = $p; Empty = $false }
    }
    while ($true) {
        $s1 = Read-Host "  Wachtwoord voor '$User'" -AsSecureString
        $s2 = Read-Host '  Bevestig' -AsSecureString
        if ($s1.Length -eq 0) { Say-Warn 'Wachtwoord mag niet leeg zijn.'; continue }
        $p1 = ConvertTo-PlainText $s1
        if ($p1 -ne (ConvertTo-PlainText $s2)) { Say-Warn 'Wachtwoorden komen niet overeen.'; continue }
        return @{ Secure = $s1; Plain = $p1; Empty = $false }
    }
}

function Get-HardwareInventory {
    param([switch]$Refresh)
    if ($script:Hw -and -not $Refresh) { return $script:Hw }
    $audio = @(Get-PnpDevice -Class AudioEndpoint -Status OK -ErrorAction SilentlyContinue)
    $mics = @($audio | Where-Object { $_.FriendlyName -match 'Mic|Microfoon' })
    $spk = @($audio | Where-Object { $_.FriendlyName -notmatch 'Mic|Microfoon' })
    $cam = @(Get-PnpDevice -Class Camera, Image -Status OK -ErrorAction SilentlyContinue)
    $sc = @(Get-PnpDevice -Class SmartCardReader -Status OK -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -notmatch 'Virtual|Software|Hello|Plug and Play' })
    $bt = @(Get-PnpDevice -Class Bluetooth -Status OK -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match '^(USB|PCI)\\' })
    $nics = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
    $gpus = @(Get-CimInstance Win32_VideoController)
    $mon = @(Get-CimInstance -Namespace 'root\wmi' -ClassName WmiMonitorID -ErrorAction SilentlyContinue)
    $laptop = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    $script:Hw = [pscustomobject]@{
        Camera       = $cam
        Mic          = $mics
        Speakers     = $spk
        CardReader   = $sc
        Bluetooth    = $bt
        Lan          = @($nics | Where-Object { $_.PhysicalMediaType -match '802.3' })
        Wifi         = @($nics | Where-Object { $_.PhysicalMediaType -match '802.11' })
        Gpus         = $gpus
        DedicatedGpu = [bool]($gpus | Where-Object { $_.Name -match 'NVIDIA|Radeon RX|Radeon Pro|Arc' })
        Laptop       = $laptop
        ExtMonitors  = [math]::Max(0, $mon.Count - $(if ($laptop) { 1 } else { 0 }))
    }
    return $script:Hw
}

function Sync-JobWithDetection {
    $sw = @(Get-InstalledSoftware)
    if ($sw | Where-Object { $_.Name -match 'Microsoft 365|Microsoft Office|Office 16' }) { $script:Job.Office = $true }
    if ($sw | Where-Object { Test-NameMatch $_.Name '*Trend Micro*|*Worry-Free*|*Security Agent*|*Apex One*' }) { $script:Job.TrendMicro = $true }
    if ($sw | Where-Object { Test-NameMatch $_.Name '*Datto*|*CentraStage*|*Autotask Endpoint*' }) { $script:Job.Datto = $true }
}

# ============================================================================
# PREFLIGHT
# ============================================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'Dit script moet als Administrator draaien.' -ForegroundColor Red; exit 1 }
$cs = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$os = Get-CimInstance Win32_OperatingSystem
$isHome = $os.Caption -match 'Home'
$vendor = if ($cs.Manufacturer -match 'HP|Hewlett') { 'HP' } elseif ($cs.Manufacturer -match 'LENOVO') { 'Lenovo' } elseif ($cs.Manufacturer -match 'Dell') { 'Dell' } else { $cs.Manufacturer }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# ============================================================================
# ATOMAIRE INSTELLINGEN (ook gebruikt door "Herstel fouten")
# ============================================================================
function Set-FastStartupOff {
    $pw = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    if ((Get-ItemProperty $pw -ErrorAction SilentlyContinue).HiberbootEnabled -ne 0) {
        Set-ItemProperty -Path $pw -Name HiberbootEnabled -Value 0 -Type DWord -Force
        Log-Action 'Snel opstarten uitgeschakeld'
    }
    else { Say-Ok 'Snel opstarten stond al UIT' }
}
function Set-TimeZoneBE {
    if ((Get-TimeZone).Id -ne 'Romance Standard Time') { Set-TimeZone -Id 'Romance Standard Time'; Log-Action 'Tijdzone ingesteld op Brussel' }
    else { Say-Ok 'Tijdzone al Brussel' }
}
function Set-RegionBE {
    try {
        if ((Get-WinHomeLocation).GeoId -ne 21) { Set-WinHomeLocation -GeoId 21; Log-Action 'Land/regio ingesteld op Belgie' }
        else { Say-Ok 'Regio al Belgie' }
    }
    catch { Say-Warn "Regio: $($_.Exception.Message)" }
}
function Set-TimeSync {
    try {
        Set-Service w32time -StartupType Automatic -ErrorAction Stop
        if ((Get-Service w32time).Status -ne 'Running') { Start-Service w32time }
        & w32tm /resync /force 2>&1 | Out-Null
        Log-Action 'Tijdsynchronisatie actief en gesynchroniseerd'
    }
    catch { Say-Warn "Tijdsync: $($_.Exception.Message)" }
}
function Set-FirewallOn {
    $off = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Enabled })
    if ($off.Count) { Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True; Log-Action 'Windows Firewall ingeschakeld' }
    else { Say-Ok 'Firewall stond al aan' }
}
function Disable-Guest {
    $g = @(Get-LocalUser | Where-Object { $_.SID.Value -match '-501$' -and $_.Enabled })
    if ($g.Count) { $g | ForEach-Object { Disable-LocalUser $_ }; Log-Action 'Gastaccount uitgeschakeld' } else { Say-Ok 'Gastaccount al uit' }
}
function Disable-BuiltinAdmin {
    $b = @(Get-LocalUser | Where-Object { $_.SID.Value -match '-500$' -and $_.Enabled })
    if (-not $b.Count) { Say-Ok 'Ingebouwde Administrator al uit'; return }
    $ca = Get-LocalUser -Name $AdminUser -ErrorAction SilentlyContinue
    if ($ca -and $ca.Enabled -and (Test-LocalAdmin $AdminUser)) { $b | ForEach-Object { Disable-LocalUser $_ }; Log-Action 'Ingebouwde Administrator uitgeschakeld' }
    else { Say-Warn "Niet uitgeschakeld: er is nog geen werkende '$AdminUser' (lockout-risico)." }
}
function Set-PowerPlanForType {
    $scheme = if ($PcType -eq 'Gaming') { 'SCHEME_MIN' } else { 'SCHEME_BALANCED' }
    $label = if ($PcType -eq 'Gaming') { 'Hoge prestaties' } else { 'Gebalanceerd' }
    & powercfg /setactive $scheme 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Log-Action "Energieplan: $label" } else { Say-Warn "Energieplan '$label' niet beschikbaar - handmatig instellen." }
}

# ============================================================================
# MENU-ACTIES  1 - 6
# ============================================================================
function Action-Rename {
    Write-Section '1  Toestelnaam'
    $cur = $env:COMPUTERNAME
    Say-Info "Huidige naam: $cur$(if ($script:PendingName) { "  (wacht op herstart: $($script:PendingName))" })"
    $sug = if ($ExpectedHostname) { $ExpectedHostname } else { 'PC-' + (Get-Date -Format 'yyMMdd') }
    $n = Read-Host "  Nieuwe naam (max $MaxHostnameLength tekens; Enter = '$sug'; x = niet wijzigen)"
    if ([string]::IsNullOrWhiteSpace($n)) { $n = $sug }
    if ($n -eq 'x') { return }
    if ($n.Length -gt $MaxHostnameLength -or $n -notmatch '^(?!\d+$)[A-Za-z0-9-]+$') { Say-Warn "Ongeldige naam '$n' (max $MaxHostnameLength tekens; letters/cijfers/koppelteken)."; return }
    if ($n -ieq $cur) { Say-Ok 'Naam is al correct.'; $script:Done['1'] = $true; return }
    try {
        Rename-Computer -NewName $n -Force -ErrorAction Stop
        $script:PendingName = $n; $script:NeedReboot = $true; $script:Done['1'] = $true
        Log-Action "Toestelnaam gewijzigd van $cur naar $n (herstart nodig)"
    }
    catch { Say-Bad "Naam wijzigen mislukt: $($_.Exception.Message)" }
}

function Action-Region {
    Write-Section '2  Regio, tijdzone & tijdsync'
    Set-TimeZoneBE; Set-RegionBE; Set-TimeSync
    Say-Info 'Taal en toetsenbord controleer je visueel (Instellingen > Tijd en taal).'
    $script:Done['2'] = $true
}

function Action-Power {
    Write-Section '3  Energie'
    Set-FastStartupOff; Set-PowerPlanForType
    if ($null -ne $MinPasswordLength) { & net accounts /minpwlen:$MinPasswordLength | Out-Null; Log-Action "Wachtwoordbeleid: minimale lengte $MinPasswordLength" }
    if ($null -ne $MaxPasswordAgeDays) {
        $age = if ($MaxPasswordAgeDays -eq 0) { 'unlimited' } else { $MaxPasswordAgeDays }
        & net accounts /maxpwage:$age | Out-Null; Log-Action "Wachtwoordbeleid: maximum leeftijd $age"
    }
    $script:Done['3'] = $true
}

function Action-Security {
    Write-Section '4  Beveiliging basis'
    Set-FirewallOn; Disable-Guest; Disable-BuiltinAdmin
    $script:Done['4'] = $true
}

function Action-ClientAdmin {
    Write-Section "5  Beheeraccount '$AdminUser'"
    $ca = Get-LocalUser -Name $AdminUser -ErrorAction SilentlyContinue
    if (-not $ca) {
        Say-Warn "'$AdminUser' bestaat niet."
        if (-not (Ask-YesNo 'Nu aanmaken?')) { return }
        $p = Get-NewPassword $AdminUser
        if (-not $p) { return }
        try {
            New-LocalUser -Name $AdminUser -Password $p.Secure -FullName $AdminUser -Description 'Lipa beheeraccount' -PasswordNeverExpires -AccountNeverExpires -ErrorAction Stop | Out-Null
            Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $AdminUser -ErrorAction Stop
            $script:Creds.Add(@{ User = $AdminUser; Password = $p.Plain })
            Log-Action "Account '$AdminUser' aangemaakt (administrator, wachtwoord verloopt nooit)"
            $script:Done['5'] = $true
        }
        catch { Say-Bad "Aanmaken mislukt: $($_.Exception.Message)" }
        return
    }
    Say-Ok "'$AdminUser' bestaat al."
    if (-not $ca.Enabled) { Enable-LocalUser -Name $AdminUser; Log-Action "'$AdminUser' ingeschakeld" }
    if (-not (Test-LocalAdmin $AdminUser)) { Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $AdminUser; Log-Action "'$AdminUser' toegevoegd aan Administrators" }
    if (Ask-YesNo "Wachtwoord van '$AdminUser' opnieuw instellen?" $false) {
        $p = Get-NewPassword $AdminUser
        if ($p) {
            try { Set-LocalUser -Name $AdminUser -Password $p.Secure -ErrorAction Stop; $script:Creds.Add(@{ User = $AdminUser; Password = $p.Plain }); Log-Action "Wachtwoord van '$AdminUser' gewijzigd" }
            catch { Say-Bad "Wijzigen mislukt: $($_.Exception.Message)" }
        }
    }
    $script:Done['5'] = $true
}

function Action-Customer {
    Write-Section '6  Klantaccount'
    $name = $script:CustomerUserResolved
    if (-not $name) { $name = $CustomerUser }
    if (-not $name) { $name = Read-Host '  Gebruikersnaam klantaccount (Enter = overslaan)' }
    if (-not $name) { return }
    $script:CustomerUserResolved = $name
    $cu = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
    if ($cu) {
        Say-Ok "Account '$name' bestaat al (bron: $($cu.PrincipalSource))."
        if ($cu.PrincipalSource -eq 'MicrosoftAccount') { Say-Warn 'Microsoft-account: registreren in klantdossier + ticket.' }
        if ($cu.PrincipalSource -eq 'Local' -and (Ask-YesNo "Wachtwoord van '$name' opnieuw instellen?" $false)) {
            $p = Get-NewPassword $name -AllowEmpty
            if ($p) {
                try {
                    if ($p.Empty) { Set-LocalUser -Name $name -Password (New-Object System.Security.SecureString) } else { Set-LocalUser -Name $name -Password $p.Secure }
                    $script:Creds.Add(@{ User = $name; Password = $(if ($p.Empty) { '(geen wachtwoord)' } else { $p.Plain }) })
                    Log-Action "Wachtwoord van '$name' gewijzigd"
                }
                catch { Say-Bad "Wijzigen mislukt: $($_.Exception.Message)" }
            }
        }
        $script:Done['6'] = $true
        return
    }
    $rights = Ask-Choice "Rechten voor '$name':" @('Standaardgebruiker', 'Administrator (installatierechten)') 1
    $p = Get-NewPassword $name -AllowEmpty
    if (-not $p) { return }
    try {
        if ($p.Empty) { New-LocalUser -Name $name -NoPassword -FullName $name -ErrorAction Stop | Out-Null }
        else { New-LocalUser -Name $name -Password $p.Secure -FullName $name -ErrorAction Stop | Out-Null }
        Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $name -ErrorAction SilentlyContinue
        if ($rights -eq 2) { Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $name }
        $script:Creds.Add(@{ User = $name; Password = $(if ($p.Empty) { '(geen wachtwoord)' } else { $p.Plain }) })
        Log-Action "Lokaal account '$name' aangemaakt ($(if ($rights -eq 2) { 'administrator' } else { 'standaardgebruiker' }))"
        $script:Done['6'] = $true
    }
    catch { Say-Bad "Aanmaken mislukt: $($_.Exception.Message)" }
}

# ============================================================================
# MENU-ACTIES  7 - 9 (debloat, software, updates)
# ============================================================================
function Get-DebloatCandidates {
    param([int]$Level)
    $sw = @(Get-InstalledSoftware)
    $appx = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { -not $_.IsFramework -and -not $_.NonRemovable })
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($r in $DebloatRules) {
        if ($r.Level -gt $Level) { continue }
        if ($r.Kind -eq 'Win32') {
            foreach ($s in ($sw | Where-Object { $_.Name -like $r.Pattern })) {
                $found.Add([pscustomobject]@{ Kind = 'Programma'; Name = $s.Name; Level = $r.Level; Why = $r.Why; Sw = $s })
            }
        }
        else {
            foreach ($g in ($appx | Where-Object { $_.Name -like $r.Pattern } | Group-Object Name)) {
                $found.Add([pscustomobject]@{ Kind = 'Store-app'; Name = $g.Name; Level = $r.Level; Why = $r.Why; Sw = $null })
            }
        }
    }
    return @($found | Sort-Object Name -Unique)
}

function Remove-Candidate {
    param($c)
    if ($c.Kind -eq 'Store-app') {
        Get-AppxPackage -AllUsers -Name $c.Name -ErrorAction SilentlyContinue | ForEach-Object { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop }
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $c.Name } | ForEach-Object {
            Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null
        }
        return $true
    }
    $s = $c.Sw
    if ($s.Uninstall -match '(?i)msiexec' -and $s.Uninstall -match '\{[0-9A-Fa-f\-]{36}\}') {
        $p = Start-Process msiexec.exe -ArgumentList "/x $($Matches[0]) /qn /norestart" -Wait -PassThru
        return ($p.ExitCode -in 0, 3010)
    }
    if ($s.QuietUninstall) {
        $p = Start-Process cmd.exe -ArgumentList "/c `"$($s.QuietUninstall)`"" -Wait -PassThru
        return ($p.ExitCode -in 0, 3010)
    }
    return $false
}

function Action-Debloat {
    Write-Section '7  Debloat'
    if ($isHome) {
        Say-Warn 'Windows HOME: geen clean install; debloat enkel in overleg (zie ticket).'
        if (-not (Ask-YesNo 'Is de debloat besproken en mag je doorgaan?' $false)) { return }
    }
    $lvl = Ask-Choice 'Hoe zwaar debloaten?' @(
        'Licht   - trial-antivirus, adware, promo-spelletjes/social apps',
        'Medium  - + overbodige Microsoft-apps (Nieuws, Weer, Clipchamp, Solitaire, Teams, Tips, ...)',
        'Zwaar   - + Phone Link, Kaarten, Copilot, nieuwe Outlook, Office-proefversie, ...',
        'Annuleren') 2
    if ($lvl -eq 4) { return }
    Say-Info 'Zoeken naar kandidaten...'
    $cands = Get-DebloatCandidates -Level $lvl
    if ($cands.Count -eq 0) { Say-Ok 'Niets gevonden om te verwijderen.'; $script:Done['7'] = $true; return }
    Write-Host ''
    for ($i = 0; $i -lt $cands.Count; $i++) {
        Write-Host ("   {0,2}. [L{1}] {2,-10} {3}" -f ($i + 1), $cands[$i].Level, $cands[$i].Kind, (Cut $cands[$i].Name 44)) -NoNewline
        Write-Host "  $($cands[$i].Why)" -ForegroundColor DarkGray
    }
    Write-Host ''
    Say '  Enter = ALLES verwijderen | nummers = UITSLUITEN (bv. 3,7) | s = annuleren' 'Yellow'
    $ans = (Read-Host '  Keuze').Trim()
    if ($ans -eq 's') { return }
    $exclude = @()
    if ($ans) { $exclude = @($ans -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }) }
    $removed = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $cands.Count; $i++) {
        if ($exclude -contains ($i + 1)) { continue }
        $c = $cands[$i]
        try {
            if (Remove-Candidate $c) { Say-Ok "Verwijderd: $($c.Name)"; $removed.Add($c.Name) }
            else { Say-Warn "Handmatig verwijderen (evt. vendor-removal tool): $($c.Name)" }
        }
        catch { Say-Bad "Mislukt: $($c.Name) - $($_.Exception.Message)" }
    }
    if ($removed.Count) { $script:ActionLog.Add("Bloatware verwijderd ($($removed.Count)): $($removed -join ', ')"); $script:NeedReboot = $true }
    $script:Done['7'] = $true
}

function Test-AppInstalled {
    param($App, $Software)
    if ($App.Special -eq 'Splashtop') { return (Test-Path (Join-Path 'C:\Users\Public\Desktop' $SplashtopDesktopName)) }
    if (-not $App.Match) { return $false }
    foreach ($s in $Software) { if (Test-NameMatch $s.Name $App.Match) { return $true } }
    return $false
}

function Install-ChocolateyIfNeeded {
    if (Get-Command choco -ErrorAction SilentlyContinue) { return $true }
    if ($script:ChocoDeclined) { return $false }
    if (-not (Ask-YesNo 'Chocolatey ontbreekt. Installeren als fallback?' $true)) { $script:ChocoDeclined = $true; return $false }
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')) | Out-Null
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
        return [bool](Get-Command choco -ErrorAction SilentlyContinue)
    }
    catch { Say-Warn "Chocolatey installeren mislukt: $($_.Exception.Message)"; return $false }
}

function Install-Splashtop {
    $dl = Join-Path $env:USERPROFILE 'Downloads'
    $start = Get-Date
    Say-Info 'Downloadpagina wordt geopend in de browser...'
    Start-Process $SplashtopUrl
    Say-Info 'Wachten op gedownload Splashtop-bestand (max 2 min)...'
    $file = $null
    for ($i = 0; $i -lt 24 -and -not $file; $i++) {
        Start-Sleep -Seconds 5
        $file = Get-ChildItem $dl -Filter '*Splashtop*.exe' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $start.AddSeconds(-5) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if (-not $file) { return $false }
    Copy-Item $file.FullName (Join-Path 'C:\Users\Public\Desktop' $SplashtopDesktopName) -Force
    return $true
}

function Install-App {
    param($App)
    if ($App.Special -eq 'Splashtop') { return $(if (Install-Splashtop) { 'download' } else { $null }) }
    if ($App.Winget -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        $src = if ($App.Winget -match '^9[A-Z0-9]{11}$') { 'msstore' } else { 'winget' }
        Say-Info "winget ($src): $($App.Winget)"
        & winget install --id $App.Winget --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements --source $src
        if ($LASTEXITCODE -in 0, -1978335189, -1978335135) { return 'winget' }
        Say-Warn "winget faalde (exit $LASTEXITCODE)"
    }
    if ($App.Choco -and (Install-ChocolateyIfNeeded)) {
        foreach ($id in @($App.Choco)) {
            Say-Info "chocolatey: $id"
            & choco install $id -y --no-progress
            if ($LASTEXITCODE -in 0, 1641, 3010) { return 'chocolatey' }
        }
    }
    return $null
}

function Action-Software {
    Write-Section '8  Software installeren'
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Say-Warn 'winget niet gevonden - enkel Chocolatey/download-fallback beschikbaar.' }
    $list = @($AppCatalog | Where-Object { -not $_.Vendor -or $_.Vendor -eq $vendor })
    $sel = @{}
    for ($i = 0; $i -lt $list.Count; $i++) {
        $sel[$i] = ((@($list[$i].Default) -contains $PcType) -or ($list[$i].Job -and $script:Job[$list[$i].Job]))
    }
    while ($true) {
        Write-Host ''
        for ($i = 0; $i -lt $list.Count; $i++) {
            $on = $sel[$i]
            Write-Host ("   {0,2}. " -f ($i + 1)) -NoNewline
            Write-Host $(if ($on) { '[x] ' } else { '[ ] ' }) -NoNewline -ForegroundColor $(if ($on) { 'Green' } else { 'DarkGray' })
            Write-Host $list[$i].Name -ForegroundColor $(if ($on) { 'White' } else { 'DarkGray' })
        }
        $a = (Read-Host "`n  Nummers = aan/uit | a = alles | n = niets | Enter = starten | q = annuleren").Trim().ToLower()
        if (-not $a) { break }
        if ($a -eq 'q') { return }
        if ($a -eq 'a') { for ($i = 0; $i -lt $list.Count; $i++) { $sel[$i] = $true }; continue }
        if ($a -eq 'n') { for ($i = 0; $i -lt $list.Count; $i++) { $sel[$i] = $false }; continue }
        foreach ($t in ($a -split '[,\s]+')) { $n = 0; if ([int]::TryParse($t, [ref]$n) -and $n -ge 1 -and $n -le $list.Count) { $sel[$n - 1] = -not $sel[$n - 1] } }
    }
    $script:SoftwareSelection = @(for ($i = 0; $i -lt $list.Count; $i++) { if ($sel[$i]) { $list[$i].Name } })
    $sw = @(Get-InstalledSoftware)
    $newly = New-Object System.Collections.Generic.List[string]
    $total = $script:SoftwareSelection.Count; $n = 0
    for ($i = 0; $i -lt $list.Count; $i++) {
        if (-not $sel[$i]) { continue }
        $n++; $app = $list[$i]
        Write-Section "[$n/$total] $($app.Name)"
        if (Test-AppInstalled $app $sw) { Say-Ok 'Reeds geinstalleerd.'; continue }
        $method = Install-App $app
        if ($method) { Say-Ok "Geinstalleerd via $method"; $newly.Add($app.Name); $script:InstallOk.Add($app.Name) }
        else { Say-Bad 'Installatie MISLUKT - handmatig doen.'; $script:InstallFail.Add($app.Name) }
    }
    if ($newly.Count) { $script:ActionLog.Add("Software geinstalleerd: $($newly -join ', ')") }
    $script:Done['8'] = $true
}

function Action-Updates {
    Write-Section '9  Windows Updates'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
        if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
            Say-Info 'NuGet provider installeren...'; Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:$false | Out-Null
        }
        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Say-Info 'PSWindowsUpdate installeren...'; Install-Module -Name PSWindowsUpdate -Force -Confirm:$false
        }
        Import-Module PSWindowsUpdate -ErrorAction Stop
    }
    catch { Say-Bad "PSWindowsUpdate niet beschikbaar: $($_.Exception.Message)"; return }
    Say-Info 'Zoeken naar updates (kan even duren)...'
    $updates = @(Get-WindowsUpdate -MicrosoftUpdate -ErrorAction SilentlyContinue)
    if ($updates.Count -eq 0) {
        Say-Ok 'Geen updates meer beschikbaar.'
        $script:PendingUpdateCount = 0; $script:Done['9'] = $true
        if (-not ($script:ActionLog -contains 'Alle Windows-updates en drivers geinstalleerd')) { $script:ActionLog.Add('Alle Windows-updates en drivers geinstalleerd') }
        return
    }
    Say-Info "$($updates.Count) update(s) gevonden:"
    $updates | ForEach-Object { Write-Host "     - $(Cut $_.Title 74)" }
    if (-not (Ask-YesNo 'Alle updates installeren?')) { $script:PendingUpdateCount = $updates.Count; return }
    Get-WindowsUpdate -MicrosoftUpdate -Install -AcceptAll -IgnoreReboot | Out-Null
    $script:NeedReboot = $true; $script:PendingUpdateCount = $null
    Log-Action "Windows-updates geinstalleerd ($($updates.Count)); herstart en herhaal tot er geen meer zijn"
    Say-Info 'Denk ook aan fabrikant-tools (Lenovo Vantage / HP Image Assistant / Dell Command) en niet-Microsoft software.'
    $script:Done['9'] = $true
}

# ============================================================================
# MENU-ACTIE 10 - HARDWARE TESTEN (alleen wat gedetecteerd is)
# ============================================================================
function Action-HwTest {
    Write-Section '10  Hardware testen'
    $hw = Get-HardwareInventory -Refresh
    $tests = New-Object System.Collections.Generic.List[object]
    if ($hw.Camera.Count) { $tests.Add(@{ Name = 'Camera'; Hint = 'Camera-app wordt geopend'; Launch = { Start-Process 'microsoft.windows.camera:' } }) }
    if ($hw.Mic.Count) { $tests.Add(@{ Name = 'Microfoon'; Hint = 'Geluidsinstellingen: spreek en kijk naar het invoerniveau'; Launch = { Start-Process 'ms-settings:sound' } }) }
    if ($hw.Speakers.Count) { $tests.Add(@{ Name = 'Luidsprekers/headset'; Hint = 'Er wordt een testgeluid afgespeeld'; Launch = { [System.Media.SystemSounds]::Exclamation.Play(); Start-Sleep -Milliseconds 800; [System.Media.SystemSounds]::Asterisk.Play() } }) }
    if ($hw.Lan.Count) {
        $tests.Add(@{ Name = 'LAN-poort'; Hint = 'Steek een netwerkkabel in'; Auto = {
                    $up = Get-NetAdapter -Physical | Where-Object { $_.PhysicalMediaType -match '802.3' -and $_.Status -eq 'Up' }
                    if ($up -and (Test-Connection 1.1.1.1 -Count 2 -Quiet -ErrorAction SilentlyContinue)) { return $true }
                    return $null } })
    }
    if ($hw.Wifi.Count) { $tests.Add(@{ Name = 'WiFi'; Hint = 'Verbind met een wifi-netwerk'; Launch = { Start-Process 'ms-settings:network-wifi' } }) }
    if ($hw.Bluetooth.Count) { $tests.Add(@{ Name = 'Bluetooth'; Hint = 'Koppel eventueel een apparaat'; Launch = { Start-Process 'ms-settings:bluetooth' } }) }
    if ($hw.CardReader.Count) { $tests.Add(@{ Name = 'Kaartlezer (eID)'; Hint = 'Test met een eID en de eID Viewer' }) }
    if ($hw.ExtMonitors -gt 0) {
        $res = ($hw.Gpus | Where-Object { $_.CurrentHorizontalResolution } | ForEach-Object { "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution) @ $($_.CurrentRefreshRate) Hz" }) -join ', '
        $tests.Add(@{ Name = 'Extern scherm'; Hint = "Actueel: $res"; Launch = { Start-Process 'ms-settings:display' } })
    }
    if ($hw.Laptop) { $tests.Add(@{ Name = 'Voeding/oplader'; Hint = 'Laadt het toestel op via de meegeleverde oplader?' }) }
    if ($tests.Count -eq 0) { Say-Info 'Geen testbare hardware gedetecteerd.'; return }

    Say-Info "Gedetecteerd: $($tests.Count) onderdelen. Enter = OK | n = defect | s = overslaan"
    foreach ($t in $tests) {
        Write-Host ''
        Write-Host "  $($U.Arrow) $($t.Name)" -ForegroundColor White -NoNewline
        Write-Host "   $($t.Hint)" -ForegroundColor DarkGray
        if ($t.Auto) {
            $r = & $t.Auto
            if ($r -eq $true) { Say-Ok 'Automatisch getest: OK'; $script:HwTests[$t.Name] = 'OK'; continue }
        }
        if ($t.Launch) { try { & $t.Launch } catch { } }
        $a = (Read-Host '  Resultaat').Trim().ToLower()
        if ($a -eq 'n') { $script:HwTests[$t.Name] = 'DEFECT'; Say-Bad "$($t.Name): DEFECT genoteerd" }
        elseif ($a -eq 's') { Say-Info 'Overgeslagen' }
        else { $script:HwTests[$t.Name] = 'OK'; Say-Ok "$($t.Name): OK" }
    }
    $script:Done['10'] = $true
}

# ============================================================================
# MENU-ACTIE 11 - CONTROLE
# ============================================================================
function Invoke-Verification {
    $script:Results.Clear()
    $cutoff = (Get-Date).AddDays(-$Days)
    $cs = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $effName = if ($script:PendingName) { $script:PendingName } else { $env:COMPUTERNAME }
    $software = @(Get-InstalledSoftware)
    $hw = Get-HardwareInventory -Refresh
    Sync-JobWithDetection

    Invoke-Safe 'Toestel' {
        Add-Check 'Toestel' 'Fabrikant / model' 'INFO' "$($cs.Manufacturer) $($cs.Model)"
        Add-Check 'Toestel' 'Productnummer (PN)' 'INFO' $cs.SystemSKUNumber
        Add-Check 'Toestel' 'Serienummer (SN)' 'INFO' $bios.SerialNumber
        Add-Check 'Toestel' 'BIOS-versie' 'INFO' "$($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate.ToString('dd/MM/yyyy')))"
        Add-Check 'Toestel' 'Processor' 'INFO' $cpu.Name.Trim()
        if ($script:TicketInfo.SN -and $script:TicketInfo.SN -ne $bios.SerialNumber) { Add-Check 'Toestel' 'Serienummer komt NIET overeen met ticket' 'FAIL' "Ticket: $($script:TicketInfo.SN) | Toestel: $($bios.SerialNumber) - verkeerd toestel?" }
        elseif ($script:TicketInfo.SN) { Add-Check 'Toestel' 'Serienummer komt overeen met ticket' 'OK' $bios.SerialNumber }
        if ($script:TicketInfo.PN -and $script:TicketInfo.PN -ne $cs.SystemSKUNumber) { Add-Check 'Toestel' 'Productnummer wijkt af van ticket' 'WARN' "Ticket: $($script:TicketInfo.PN) | Toestel: $($cs.SystemSKUNumber)" }
        $ram = [math]::Round($cs.TotalPhysicalMemory / 1GB); $min = if ($PcType -eq 'Gaming') { 16 } else { 8 }
        Add-Check 'Toestel' 'Geheugen (RAM)' $(if ($ram -ge $min) { 'OK' } else { 'WARN' }) "$ram GB (verwacht minstens $min GB)"
        if ($effName.Length -gt $MaxHostnameLength) { Add-Check 'Toestel' 'Hostname' 'FAIL' "$effName ($($effName.Length) tekens, max $MaxHostnameLength)" -Fix 'Hostname' }
        elseif ($ExpectedHostname -and $effName -ne $ExpectedHostname) { Add-Check 'Toestel' 'Hostname' 'FAIL' "Is '$effName', verwacht '$ExpectedHostname'" -Fix 'Hostname' }
        elseif ($script:PendingName) { Add-Check 'Toestel' 'Hostname' 'WARN' "$effName - herstart nodig (huidig: $($env:COMPUTERNAME))" }
        else { Add-Check 'Toestel' 'Hostname' 'OK' $effName }
        $sys = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"; $pct = [math]::Round(($sys.FreeSpace / $sys.Size) * 100)
        Add-Check 'Toestel' 'Schijf C: vrije ruimte' $(if ($pct -ge 20) { 'OK' } else { 'WARN' }) ("{0} GB vrij van {1} GB ({2}%)" -f [math]::Round($sys.FreeSpace / 1GB), [math]::Round($sys.Size / 1GB), $pct)
        foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) { Add-Check 'Toestel' "Schijfgezondheid: $($d.FriendlyName)" $(if ($d.HealthStatus -eq 'Healthy') { 'OK' } else { 'FAIL' }) "$($d.MediaType), $($d.HealthStatus)" }
    }

    Invoke-Safe 'Windows' {
        Add-Check 'Windows' 'Editie / build' 'INFO' "$($os.Caption) (build $($os.BuildNumber))"
        $lic = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" | Where-Object { $_.LicenseStatus -eq 1 } | Select-Object -First 1
        Add-Check 'Windows' 'Activatie' $(if ($lic) { 'OK' } else { 'FAIL' }) $(if ($lic) { 'Geactiveerd' } else { 'NIET geactiveerd' })
        $ui = (Get-UICulture).Name
        Add-Check 'Windows' 'Weergavetaal' $(if ($ui -like 'nl-*') { 'OK' } else { 'WARN' }) $ui
        try { $g = Get-WinHomeLocation; Add-Check 'Windows' 'Land / regio' $(if ($g.GeoId -eq 21) { 'OK' } else { 'WARN' }) $g.HomeLocation -Fix $(if ($g.GeoId -ne 21) { 'Region' } else { '' }) } catch { }
        Add-Check 'Windows' 'Toetsenbord (visueel testen)' 'INFO' ((Get-WinUserLanguageList | ForEach-Object { "$($_.LanguageTag): $($_.InputMethodTips -join ', ')" }) -join '; ')
        $tz = Get-TimeZone
        Add-Check 'Windows' 'Tijdzone' $(if ($tz.Id -eq 'Romance Standard Time') { 'OK' } else { 'WARN' }) "$($tz.Id) - $($tz.DisplayName)" -Fix $(if ($tz.Id -ne 'Romance Standard Time') { 'TimeZone' } else { '' })
        $w32 = Get-Service w32time -ErrorAction SilentlyContinue
        if ($w32) { Add-Check 'Windows' 'Tijdsynchronisatie-service' $(if ($w32.Status -eq 'Running') { 'OK' } else { 'WARN' }) "$($w32.Status) | nu: $(Get-Date -Format 'dd/MM/yyyy HH:mm')" -Fix $(if ($w32.Status -ne 'Running') { 'TimeSync' } else { '' }) }
    }

    Invoke-Safe 'Accounts' {
        $users = Get-LocalUser
        foreach ($u in $users) {
            if ($u.SID.Value -match '-(501|503|504)$') { continue }
            $adm = Test-LocalAdmin $u.Name
            $last = if ($u.LastLogon) { $u.LastLogon.ToString('dd/MM/yyyy HH:mm') } else { 'nooit' }
            Add-Check 'Accounts' "Account: $($u.Name)" 'INFO' "Actief: $($u.Enabled) | Admin: $adm | Bron: $($u.PrincipalSource) | Laatste login: $last"
            if ($u.PrincipalSource -eq 'MicrosoftAccount') { Add-Check 'Accounts' "MS-account gekoppeld: $($u.Name)" 'WARN' 'Registreren in klantdossier + ticket.' }
        }
        $b = $users | Where-Object { $_.SID.Value -match '-500$' }
        if ($b) { Add-Check 'Accounts' 'Ingebouwde Administrator uitgeschakeld' $(if (-not $b.Enabled) { 'OK' } else { 'WARN' }) "Actief: $($b.Enabled)" -Fix $(if ($b.Enabled) { 'BuiltinAdmin' } else { '' }) }
        $g = $users | Where-Object { $_.SID.Value -match '-501$' }
        if ($g) { Add-Check 'Accounts' 'Gastaccount uitgeschakeld' $(if (-not $g.Enabled) { 'OK' } else { 'FAIL' }) "Actief: $($g.Enabled)" -Fix $(if ($g.Enabled) { 'Guest' } else { '' }) }
        $ca = $users | Where-Object { $_.Name -eq $AdminUser }
        if (-not $ca) { Add-Check 'Accounts' "Beheeraccount '$AdminUser'" 'FAIL' 'Niet gevonden (menu 5)' }
        else { $ok = $ca.Enabled -and (Test-LocalAdmin $AdminUser); Add-Check 'Accounts' "Beheeraccount '$AdminUser' actief + admin" $(if ($ok) { 'OK' } else { 'FAIL' }) "Actief: $($ca.Enabled)" }
        $cuN = if ($script:CustomerUserResolved) { $script:CustomerUserResolved } else { $CustomerUser }
        if ($cuN) {
            $cu = $users | Where-Object { $_.Name -eq $cuN }
            if (-not $cu) { Add-Check 'Accounts' "Klantaccount '$cuN'" 'FAIL' 'Niet gevonden (menu 6)' }
            else { Add-Check 'Accounts' "Klantaccount '$cuN' actief" $(if ($cu.Enabled) { 'OK' } else { 'FAIL' }) "Actief: $($cu.Enabled)" }
        }
    }

    Invoke-Safe 'Netwerk' {
        foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
            $kind = if ($a.PhysicalMediaType -match '802.11') { 'WiFi' } elseif ($a.PhysicalMediaType -match '802.3') { 'LAN' } else { $a.PhysicalMediaType }
            Add-Check 'Netwerk' "Adapter ($kind): $($a.Name)" $(if ($a.Status -eq 'Up') { 'OK' } else { 'INFO' }) "$($a.Status) @ $($a.LinkSpeed)"
        }
        Add-Check 'Netwerk' 'Internet (ping 1.1.1.1)' $(if (Test-Connection 1.1.1.1 -Count 2 -Quiet -ErrorAction SilentlyContinue) { 'OK' } else { 'FAIL' }) ''
    }

    Invoke-Safe 'Software' {
        $recent = $software | Where-Object { $_.InstallDate -and $_.InstallDate -ge $cutoff } | Sort-Object InstallDate -Descending
        $txt = if ($recent) { ($recent | ForEach-Object { "{0:dd/MM/yyyy}  {1} {2}" -f $_.InstallDate, $_.Name, $_.Version }) -join "`n" } else { 'Geen programma''s met installatiedatum in dit venster.' }
        Add-Check 'Software' "Recent geinstalleerd (laatste $Days dagen)" 'INFO' $txt

        # Verwacht = wat je koos in menu 8, anders de standaard voor dit type + wat de opdracht vraagt
        $expected = @($AppCatalog | Where-Object {
                (-not $_.Vendor -or $_.Vendor -eq $vendor) -and
                $(if ($script:SoftwareSelection.Count) { $script:SoftwareSelection -contains $_.Name } else { (@($_.Default) -contains $PcType) -or ($_.Job -and $script:Job[$_.Job]) })
            })
        foreach ($app in $expected) {
            if (-not $app.Match -and -not $app.Special) { continue }
            if (Test-AppInstalled $app $software) { Add-Check 'Software' "Verwacht: $($app.Name)" 'OK' 'Aanwezig' }
            else { Add-Check 'Software' "Verwacht: $($app.Name)" 'FAIL' 'Niet gevonden (kan per-gebruiker zijn - controleer manueel)' }
        }
        $tm = $software | Where-Object { Test-NameMatch $_.Name '*Trend Micro*|*Worry-Free*|*Security Agent*|*Apex One*' } | Select-Object -First 1
        if ($tm) { Add-Check 'Software' 'Trend Micro' 'OK' $tm.Name }
        elseif ($script:Job.TrendMicro) { Add-Check 'Software' 'Trend Micro' 'WARN' 'Gevraagd in opdracht maar niet gevonden' }
        $dt = $software | Where-Object { Test-NameMatch $_.Name '*Datto*|*CentraStage*|*Autotask Endpoint*' } | Select-Object -First 1
        if ($dt) { Add-Check 'Software' 'Datto RMM' 'OK' $dt.Name } elseif ($script:Job.Datto) { Add-Check 'Software' 'Datto RMM' 'WARN' 'Gevraagd in opdracht maar niet gevonden' }
        if ($script:Job.Office -and -not ($software | Where-Object { $_.Name -match 'Microsoft 365|Office 16|Microsoft Office' })) { Add-Check 'Software' 'Office' 'WARN' 'Gevraagd in opdracht maar niet gevonden' }

        $left = @(Get-InstalledSoftware | Where-Object { $_.Name -match 'McAfee|Norton|WildTangent|ExpressVPN|Avast|AVG|WebAdvisor' })
        $leftAppx = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'CandyCrush|TikTok|Disney|Netflix|Booking|Facebook|Instagram|McAfee|Norton' -and -not $_.IsFramework } | Select-Object -ExpandProperty Name -Unique)
        if ($left.Count -or $leftAppx.Count) { Add-Check 'Software' 'Resterende bloatware' 'WARN' ((@($left | ForEach-Object { "Programma: $($_.Name)" }) + @($leftAppx | ForEach-Object { "Store-app: $_" })) -join "`n") }
        else { Add-Check 'Software' 'Bloatware' 'OK' 'Geen bekende bloatware gevonden' }
        $su = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue)
        if ($su.Count) { Add-Check 'Software' "Opstartitems ($($su.Count))" $(if ($su.Count -le 12) { 'INFO' } else { 'WARN' }) (($su | ForEach-Object { $_.Name }) -join ', ') }
    }

    Invoke-Safe 'Beveiliging' {
        $av = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue)
        if ($av.Count -eq 0) { Add-Check 'Beveiliging' 'Antivirus' 'FAIL' 'Geen antivirus gedetecteerd' }
        else { Add-Check 'Beveiliging' 'Antivirus' $(if ($av.Count -eq 1) { 'OK' } else { 'WARN' }) ((($av | ForEach-Object { $_.displayName }) -join ', ') + $(if ($av.Count -gt 1) { ' (meerdere AV-producten!)' } else { '' })) }
        $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
        if ($mp) { Add-Check 'Beveiliging' 'Defender definities' $(if ($mp.AntivirusSignatureAge -le 3) { 'OK' } else { 'WARN' }) "Leeftijd: $($mp.AntivirusSignatureAge) dag(en), realtime: $($mp.RealTimeProtectionEnabled)" }
        $off = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Enabled })
        Add-Check 'Beveiliging' 'Windows Firewall' $(if ($off.Count) { 'WARN' } else { 'OK' }) $(if ($off.Count) { "Uit: $(($off.Name) -join ', ')" } else { 'Alle profielen actief' }) -Fix $(if ($off.Count) { 'Firewall' } else { '' })
        $uac = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).EnableLUA
        Add-Check 'Beveiliging' 'UAC' $(if ($uac -eq 1) { 'OK' } else { 'WARN' }) "EnableLUA = $uac"
        try { $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop; if ($bl.ProtectionStatus -eq 'On') { Add-Check 'Beveiliging' 'BitLocker actief op C:' 'WARN' 'Herstelsleutel bewaren in klantdossier!' } } catch { }
    }

    Invoke-Safe 'Updates' {
        $pend = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        Add-Check 'Updates' 'Herstart in afwachting' $(if ($pend) { 'WARN' } else { 'OK' }) $(if ($pend) { 'Herstart de pc' } else { 'Geen' })
        $hf = Get-HotFix -ErrorAction SilentlyContinue | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1
        if ($hf) { Add-Check 'Updates' 'Laatste Windows-update' $(if ($hf.InstalledOn -ge (Get-Date).AddDays(-45)) { 'OK' } else { 'WARN' }) "$($hf.HotFixID) op $($hf.InstalledOn.ToString('dd/MM/yyyy'))" }
        if ($null -ne $script:PendingUpdateCount) {
            Add-Check 'Updates' 'Openstaande updates' $(if ($script:PendingUpdateCount -eq 0) { 'OK' } else { 'FAIL' }) "$($script:PendingUpdateCount) openstaand (menu 9)"
        }
        else {
            try {
                $res = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0')
                $titles = for ($i = 0; $i -lt $res.Updates.Count; $i++) { $res.Updates.Item($i).Title }
                Add-Check 'Updates' 'Openstaande updates' $(if ($res.Updates.Count -eq 0) { 'OK' } else { 'FAIL' }) $(if ($res.Updates.Count) { $titles -join "`n" } else { 'Geen - up-to-date' })
                if ($res.Updates.Count -eq 0) { $script:PendingUpdateCount = 0 }
            }
            catch { Add-Check 'Updates' 'Openstaande updates' 'INFO' 'Kon niet gecontroleerd worden' }
        }
    }

    Invoke-Safe 'Energie' {
        $fs = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled
        Add-Check 'Energie' 'Snel opstarten UIT' $(if ($fs -eq 0) { 'OK' } else { 'FAIL' }) $(if ($fs -eq 0) { 'Uitgeschakeld' } else { 'Staat AAN' }) -Fix $(if ($fs -ne 0) { 'FastStartup' } else { '' })
        $scheme = (& powercfg /getactivescheme) -join ' '
        $bad = $scheme -match 'Power saver|Energiespaarstand|a1841308'
        Add-Check 'Energie' 'Actief energieplan' $(if ($bad) { 'WARN' } else { 'INFO' }) $scheme -Fix $(if ($bad) { 'PowerPlan' } else { '' })
    }

    Invoke-Safe 'Hardware' {
        $bad = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
        if ($bad.Count) { Add-Check 'Hardware' 'Apparaten met driverprobleem' 'FAIL' (($bad | ForEach-Object { "$($_.Name) (code $($_.ConfigManagerErrorCode))" }) -join "`n") }
        else { Add-Check 'Hardware' 'Apparaten met driverprobleem' 'OK' 'Geen' }
        foreach ($g in $hw.Gpus) {
            $dd = if ($g.DriverDate) { $g.DriverDate.ToString('dd/MM/yyyy') } else { '?' }
            $res = if ($g.CurrentHorizontalResolution) { "$($g.CurrentHorizontalResolution)x$($g.CurrentVerticalResolution) @ $($g.CurrentRefreshRate) Hz" } else { 'geen actief scherm' }
            $st = if ($PcType -eq 'Gaming' -and $g.DriverDate -and $g.DriverDate -lt (Get-Date).AddDays(-120) -and $g.Name -match 'NVIDIA|Radeon') { 'WARN' } else { 'INFO' }
            Add-Check 'Hardware' "Grafische kaart: $($g.Name)" $st "Driver $($g.DriverVersion) van $dd | $res"
        }
        if ($PcType -eq 'Gaming' -and -not $hw.DedicatedGpu) { Add-Check 'Hardware' 'Dedicated GPU' 'FAIL' 'Geen dedicated GPU gedetecteerd' }
        foreach ($k in $script:HwTests.Keys) { Add-Check 'Hardware' "Test: $k" $(if ($script:HwTests[$k] -eq 'OK') { 'OK' } else { 'FAIL' }) $script:HwTests[$k] }
        $untested = @(Get-UntestedHardware)
        if ($untested.Count) { Add-Check 'Hardware' 'Gedetecteerd maar niet getest' 'INFO' ($untested -join ', ') }
    }

    Invoke-Safe 'Foutlogs' {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $cutoff } -MaxEvents 1000 -ErrorAction SilentlyContinue)
        Add-Check 'Foutlogs' "Kritieke/fout-events ($Days d)" 'INFO' "$($ev.Count) events"
        if ($ev.Count) { Add-Check 'Foutlogs' 'Top bronnen' 'INFO' (($ev | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { "$($_.Count)x $($_.Name)" }) -join "`n") }
        $kp = @($ev | Where-Object { $_.Id -eq 41 -and $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' })
        if ($kp.Count) { Add-Check 'Foutlogs' 'Onverwachte uitschakeling (Kernel-Power 41)' 'WARN' "$($kp.Count)x" }
        $bc = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1001; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; StartTime = $cutoff } -ErrorAction SilentlyContinue)
        Add-Check 'Foutlogs' 'Blauwe schermen' $(if ($bc.Count) { 'FAIL' } else { 'OK' }) $(if ($bc.Count) { "$($bc.Count)x" } else { 'Geen' })
    }

    Invoke-Safe 'Bureaublad' {
        $paths = @('C:\Users\Public\Desktop')
        $cuN = if ($script:CustomerUserResolved) { $script:CustomerUserResolved } else { $CustomerUser }
        if ($cuN) { $paths += "C:\Users\$cuN\Desktop" }
        $items = foreach ($p in $paths) { if (Test-Path $p) { Get-ChildItem $p -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object { $_.Name } } }
        Add-Check 'Bureaublad' "Pictogrammen ($(@($items).Count))" 'INFO' (($items | Sort-Object -Unique) -join ', ')
        $has = [bool]($items | Where-Object { $_ -match 'Helpdesk|Lipa|SOS' })
        Add-Check 'Bureaublad' 'Lipa-supportsnelkoppeling (SOS Lipa)' $(if ($has) { 'OK' } else { 'WARN' }) $(if ($has) { 'Aanwezig' } else { 'Niet gevonden (menu 8)' })
    }
}

function Get-UntestedHardware {
    $hw = Get-HardwareInventory
    $names = @()
    if ($hw.Camera.Count) { $names += 'Camera' }
    if ($hw.Mic.Count) { $names += 'Microfoon' }
    if ($hw.Speakers.Count) { $names += 'Luidsprekers/headset' }
    if ($hw.Lan.Count) { $names += 'LAN-poort' }
    if ($hw.Wifi.Count) { $names += 'WiFi' }
    if ($hw.Bluetooth.Count) { $names += 'Bluetooth' }
    if ($hw.CardReader.Count) { $names += 'Kaartlezer (eID)' }
    if ($hw.ExtMonitors -gt 0) { $names += 'Extern scherm' }
    if ($hw.Laptop) { $names += 'Voeding/oplader' }
    return @($names | Where-Object { -not $script:HwTests.Contains($_) })
}

function Show-CheckSummary {
    $cnt = @{ OK = 0; WARN = 0; FAIL = 0; INFO = 0 }
    foreach ($r in $script:Results) { $cnt[$r.Status]++ }
    $lines = New-Object System.Collections.Generic.List[object]
    $lines.Add(@(@{ T = "$($U.Ok) $($cnt.OK) OK    "; C = 'Green' }, @{ T = "$($U.Warn) $($cnt.WARN) WARN    "; C = 'Yellow' }, @{ T = "$($U.Bad) $($cnt.FAIL) FAIL"; C = 'Red' }))
    $issues = @($script:Results | Where-Object { $_.Status -in 'FAIL', 'WARN' } | Sort-Object { if ($_.Status -eq 'FAIL') { 0 } else { 1 } })
    if ($issues.Count) {
        $lines.Add('')
        foreach ($i in $issues) {
            $c = if ($i.Status -eq 'FAIL') { 'Red' } else { 'Yellow' }
            $fix = if ($i.Fix -and $script:FixMap.ContainsKey($i.Fix)) { '  [auto-fix]' } else { '' }
            $lines.Add(@(@{ T = ("{0,-5} " -f $i.Status); C = $c }, @{ T = (Cut "$($i.Item)" 58); C = 'White' }, @{ T = $fix; C = 'Cyan' }))
        }
    }
    else { $lines.Add(@{ T = 'Geen aandachtspunten - alles ziet er goed uit.'; C = 'Green' }) }
    Write-Box 'Resultaat controle' $lines $(if ($cnt.FAIL) { 'Red' } elseif ($cnt.WARN) { 'Yellow' } else { 'Green' })
    return $cnt
}

function Action-Check {
    Write-Section '11  Controle'
    Say-Info 'Controles uitvoeren (even geduld)...'
    Invoke-Verification
    [void](Show-CheckSummary)
    $script:Done['11'] = $true
    if (@($script:Results | Where-Object { $_.Status -in 'WARN', 'FAIL' -and $_.Fix -and $script:FixMap.ContainsKey($_.Fix) }).Count) {
        Say-Info 'Sommige punten kan het script zelf herstellen: kies F in het menu.'
    }
}

function Action-Fix {
    Write-Section 'F  Herstel fouten uit controle'
    if ($script:Results.Count -eq 0) { Say-Info 'Eerst controle uitvoeren...'; Invoke-Verification }
    $fixable = @($script:Results | Where-Object { $_.Status -in 'WARN', 'FAIL' -and $_.Fix -and $script:FixMap.ContainsKey($_.Fix) })
    if ($fixable.Count -eq 0) { Say-Ok 'Niets dat automatisch hersteld kan worden.'; return }
    for ($i = 0; $i -lt $fixable.Count; $i++) { Write-Host ("   {0,2}. [{1}] {2}" -f ($i + 1), $fixable[$i].Status, $fixable[$i].Item) }
    $a = (Read-Host "`n  Enter = alles herstellen | nummers = enkel die | s = annuleren").Trim().ToLower()
    if ($a -eq 's') { return }
    $sel = if ($a) { @($a -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { $fixable[[int]$_ - 1] } | Where-Object { $_ }) } else { $fixable }
    foreach ($k in ($sel | ForEach-Object { $_.Fix } | Sort-Object -Unique)) {
        try { & $script:FixMap[$k] } catch { Say-Bad "Herstel '$k' mislukt: $($_.Exception.Message)" }
    }
    if (Ask-YesNo 'Controle opnieuw uitvoeren?' $true) { Action-Check }
}

# ============================================================================
# OPDRACHT / TICKET-INFO (P)
# ============================================================================
function Get-Rx {
    param([string]$Text, [string]$Pattern)
    $m = [regex]::Match($Text, $Pattern, 'IgnoreCase,Multiline')
    if (-not $m.Success) { return $null }
    if ($m.Groups.Count -gt 1) { return $m.Groups[1].Value.Trim() }
    return $m.Value
}

function Read-TicketText {
    param([string]$Text)
    $r = @{}
    $r.Ticket = Get-Rx $Text 'T\d{8}\.\d{4}'
    $r.Hostname = Get-Rx $Text '^\s*(?:Device name|Hostname)\s*[:=]\s*(\S+)'
    $r.User = Get-Rx $Text '^\s*Gebruiker\s*[:=]\s*(.+)$'
    $r.PN = Get-Rx $Text 'Productnummer\s*\(PN\)\s*:\s*(\S+)'
    $r.SN = Get-Rx $Text 'Serienummer\s*\(SN\)\s*:\s*(\S+)'
    $r.OS = Get-Rx $Text 'Windows\s*11\s*(Home|Pro)'
    $r.Customer = Get-Rx $Text '^\s*Klant\s*:\s*(.+)$'
    $r.TMCustomer = Get-Rx $Text 'Nieuwe klant aanmaken in TM\s*:\s*(.+)$'
    $r.TrendMicro = [bool](Get-Rx $Text 'trend\s?micro')
    $r.Office = [bool](Get-Rx $Text '\b(?:office|microsoft\s?365|m365)\b')
    $r.Datto = [bool](Get-Rx $Text '\bdatto\b')
    $r.Data = Get-Rx $Text '^\s*Overzetten data\s*:\s*(.+)$'
    $r.Backup = [bool](Get-Rx $Text '\bbackup\b')
    return $r
}

function Import-TicketFromClipboard {
    $text = $null
    try { $text = Get-Clipboard -Raw -ErrorAction Stop } catch { }
    if ([string]::IsNullOrWhiteSpace($text)) {
        Say-Info 'Klembord is leeg. Plak de ticketbeschrijving en sluit af met een lege regel:'
        $buf = New-Object System.Collections.Generic.List[string]
        while ($true) { $l = Read-Host; if ([string]::IsNullOrWhiteSpace($l)) { break }; $buf.Add($l) }
        $text = $buf -join "`n"
    }
    if ([string]::IsNullOrWhiteSpace($text)) { Say-Warn 'Geen tekst ontvangen.'; return }
    $t = Read-TicketText $text
    $script:TicketInfo = $t
    if ($t.Ticket -and -not $script:TicketNr) { $script:TicketNr = $t.Ticket }
    if ($t.Hostname -and -not $script:ExpectedHostname) { $script:ExpectedHostname = $t.Hostname }
    if ($t.User -and -not $script:CustomerUser) { $script:CustomerUser = $t.User }
    $cname = if ($t.Customer) { $t.Customer } elseif ($t.TMCustomer) { $t.TMCustomer } else { $null }
    if ($cname -and -not $script:CustomerName) { $script:CustomerName = $cname }
    if ($t.TrendMicro) { $script:Job.TrendMicro = $true; if ($t.TMCustomer) { $script:JobText.TMCustomer = $t.TMCustomer } }
    if ($t.Office) { $script:Job.Office = $true }
    if ($t.Datto) { $script:Job.Datto = $true }
    if ($t.Backup) { $script:Job.Backup = $true }
    if ($t.Data) { $script:Job.DataTransfer = $true; $script:JobText.DataTransfer = $t.Data }
    $found = @()
    foreach ($k in 'Ticket', 'Hostname', 'User', 'PN', 'SN', 'OS', 'TMCustomer', 'Data') { if ($t[$k]) { $found += "$k=$($t[$k])" } }
    Say-Ok "Ticket ingelezen: $($found -join ' | ')"
}

function Action-Job {
    Write-Section 'P  Opdracht & ticket-info'
    if ($isHome -or $script:TicketInfo.OS -eq 'Home') { Say-Warn 'Windows Home: geen clean install, doorstarten en bloatware verwijderen in overleg.' }
    if (Ask-YesNo 'Ticketbeschrijving van het klembord inlezen? (kopieer die eerst in Autotask)' $true) { Import-TicketFromClipboard }
    Sync-JobWithDetection
    $toggles = @(
        @{ K = 'Office'; L = 'Microsoft 365 / Office' },
        @{ K = 'TrendMicro'; L = 'Trend Micro' },
        @{ K = 'Datto'; L = 'Datto RMM (servicecontract)' },
        @{ K = 'DataTransfer'; L = 'Data overzetten' },
        @{ K = 'Backup'; L = 'Backup instellen' }
    )
    while ($true) {
        Write-Host ''
        for ($i = 0; $i -lt $toggles.Count; $i++) {
            $on = $script:Job[$toggles[$i].K]
            Write-Host ("   {0,2}. " -f ($i + 1)) -NoNewline
            Write-Host $(if ($on) { '[x] ' } else { '[ ] ' }) -NoNewline -ForegroundColor $(if ($on) { 'Green' } else { 'DarkGray' })
            Write-Host $toggles[$i].L
        }
        Write-Host ("   {0,2}.     Type pc        : {1}" -f 6, $PcType)
        Write-Host ("   {0,2}.     Klant          : {1}" -f 7, $CustomerName)
        Write-Host ("   {0,2}.     Ticketnummer   : {1}" -f 8, $TicketNr)
        Write-Host ("   {0,2}.     Klantgebruiker : {1}" -f 9, $(if ($script:CustomerUserResolved) { $script:CustomerUserResolved } else { $CustomerUser }))
        Write-Host ("   {0,2}.     Verwachte host : {1}" -f 10, $ExpectedHostname)
        $a = (Read-Host "`n  Nummer = wijzigen | Enter = klaar").Trim()
        if (-not $a) { break }
        foreach ($t in ($a -split '[,\s]+')) {
            $n = 0
            if (-not [int]::TryParse($t, [ref]$n)) { continue }
            if ($n -ge 1 -and $n -le 5) {
                $k = $toggles[$n - 1].K
                $script:Job[$k] = -not $script:Job[$k]
                if ($script:Job[$k] -and $k -eq 'DataTransfer') { $script:JobText.DataTransfer = Read-Host '  Toelichting (bv. in regie)' }
                if ($script:Job[$k] -and $k -eq 'TrendMicro') { $d = if ($script:JobText.TMCustomer) { $script:JobText.TMCustomer } else { $CustomerName }; $v = Read-Host "  Klantnaam in Trend Micro (Enter = '$d')"; $script:JobText.TMCustomer = $(if ($v) { $v } else { $d }) }
            }
            elseif ($n -eq 6) { $script:PcType = $(if ($PcType -eq 'Gaming') { 'Werk' } else { 'Gaming' }) }
            elseif ($n -eq 7) { $script:CustomerName = Read-Host '  Klant' }
            elseif ($n -eq 8) { $script:TicketNr = Read-Host '  Ticketnummer' }
            elseif ($n -eq 9) { $script:CustomerUser = Read-Host '  Gebruikersnaam klant'; $script:CustomerUserResolved = $script:CustomerUser }
            elseif ($n -eq 10) { $script:ExpectedHostname = Read-Host '  Verwachte hostname' }
        }
    }
    $script:Done['P'] = $true
}

# ============================================================================
# MENU-ACTIE 12 - TICKET + RAPPORT (slim: enkel wat relevant is)
# ============================================================================
function New-TicketText {
    Sync-JobWithDetection
    $hw = Get-HardwareInventory
    $cs = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
    $effName = if ($script:PendingName) { $script:PendingName } else { $env:COMPUTERNAME }
    $ram = [math]::Round($cs.TotalPhysicalMemory / 1GB)
    $disk = [math]::Round((Get-CimInstance Win32_DiskDrive | Measure-Object Size -Sum).Sum / 1GB)
    $diskTxt = if ($disk -ge 900) { "$([math]::Round($disk / 1000.0, 1)) TB" } else { "$disk GB" }
    $users = @(Get-LocalUser | Where-Object { $_.Enabled -and $_.SID.Value -notmatch '-(500|501|503|504)$' })
    $msAcc = @($users | Where-Object { $_.PrincipalSource -eq 'MicrosoftAccount' })
    $L = New-Object System.Collections.Generic.List[string]

    # --- Toestel
    $L.Add('Klant- en Apparaatgegevens:')
    if ($CustomerName) { $L.Add("Klant: $CustomerName") }
    $L.Add("Apparaat: $($cs.Model)")
    $L.Add("Productnummer (PN): $($cs.SystemSKUNumber)")
    $L.Add("Serienummer (SN): $($bios.SerialNumber)")
    $L.Add("Hostname: $effName")
    $L.Add("BIOS-versie: $($bios.SMBIOSBIOSVersion)")
    if ($script:TicketInfo.SN -and $script:TicketInfo.SN -ne $bios.SerialNumber) { $L.Add("LET OP: serienummer op ticket ($($script:TicketInfo.SN)) wijkt af van het toestel!") }
    $L.Add('')
    $L.Add('Systeemspecificaties:')
    $L.Add("Processor: $cpu")
    if ($hw.DedicatedGpu -or $PcType -eq 'Gaming') { $L.Add("Grafische kaart: $((($hw.Gpus | Sort-Object { $_.Name -notmatch 'NVIDIA|Radeon RX|Arc' }) | Select-Object -First 1).Name)") }
    $L.Add("Geheugen (RAM): $ram GB")
    $L.Add("Opslag: $diskTxt")
    if ($FullSpecs) {
        $devId = try { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SQMClient' -ErrorAction Stop).MachineId } catch { '' }
        $prodId = try { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').ProductId } catch { '' }
        $L.Add("Apparaat-ID: $devId"); $L.Add("Product-ID: $prodId")
    }
    $L.Add('')

    # --- Configuratie (enkel relevante regels)
    $L.Add('Configuratie:')
    $L.Add("Windows: $($os.Caption)$(if ($isHome) { ' - geen clean install, doorgestart' })")
    $L.Add("Lokale accounts: $((@($AdminUser) + @($users | ForEach-Object { if ($_.PrincipalSource -eq 'MicrosoftAccount') { "$($_.Name) (Microsoft-account)" } else { $_.Name } })) -join ', ')")
    $av = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue | ForEach-Object { $_.displayName })
    if ($av.Count) { $L.Add("Antivirus: $($av -join ', ')") }
    $L.Add('')

    # --- Uitgevoerde handelingen (enkel wat echt gebeurd is)
    $acts = @($script:ActionLog | Select-Object -Unique)
    $upd = $script:Results | Where-Object { $_.Item -eq 'Openstaande updates' -and $_.Status -eq 'OK' }
    if ($upd -and -not ($acts -contains 'Alle Windows-updates en drivers geinstalleerd')) { $acts += 'Alle Windows-updates en drivers geinstalleerd' }
    if ($acts.Count) { $L.Add('Uitgevoerde handelingen:'); foreach ($a in $acts) { $L.Add("- $a") }; $L.Add('') }

    # --- Hardware (enkel gedetecteerd + getest)
    $okTests = @($script:HwTests.Keys | Where-Object { $script:HwTests[$_] -eq 'OK' })
    $badTests = @($script:HwTests.Keys | Where-Object { $script:HwTests[$_] -eq 'DEFECT' })
    if ($okTests.Count) { $L.Add("Hardware getest (OK): $($okTests -join ', ')") }
    if ($badTests.Count) { $L.Add("HARDWARE DEFECT: $($badTests -join ', ')") }
    if ($okTests.Count -or $badTests.Count) { $L.Add('') }

    # --- Aandachtspunten (enkel WARN/FAIL)
    $issues = @($script:Results | Where-Object { $_.Status -in 'WARN', 'FAIL' } | ForEach-Object { "[$($_.Status)] $($_.Item)" } | Select-Object -Unique)
    foreach ($f in $script:InstallFail) { $issues += "[FAIL] Niet geinstalleerd: $f" }
    if ($issues.Count) { $L.Add('Openstaande aandachtspunten:'); foreach ($i in $issues) { $L.Add("- $i") }; $L.Add('') }

    # --- Voorwaardelijke blokken
    $cond = New-Object System.Collections.Generic.List[string]
    if ($script:Job.Office -or $msAcc.Count) { $cond.Add('Aangemeld bij MS365: ______   Outlook: ______   OneDrive: ______') }
    if ($script:Job.TrendMicro) { $cond.Add("Trend Micro geinstalleerd en geactiveerd: ______   (klant in TM: $(if ($script:JobText.TMCustomer) { $script:JobText.TMCustomer } else { $CustomerName }))") }
    if ($script:Job.Datto) { $cond.Add('Datto geinstalleerd: ______') }
    if ($script:Job.DataTransfer) { $cond.Add("Data overgezet ($(if ($script:JobText.DataTransfer) { $script:JobText.DataTransfer } else { 'ja' })): ______") }
    if ($script:Job.Backup) { $cond.Add('Backup ingesteld en getest: ______') }
    if ($cond.Count) { foreach ($c in $cond) { $L.Add($c) }; $L.Add('') }

    # --- Internal Only
    $L.Add('Internal Only')
    foreach ($n in (@($AdminUser) + @($users | ForEach-Object { $_.Name }) | Select-Object -Unique)) {
        $c = $script:Creds | Where-Object { $_.User -eq $n } | Select-Object -Last 1
        if ($c -and $IncludePasswordsInTicket) { $L.Add("Lokale gebruiker $n -> $($c.Password)") }
        else { $L.Add("Lokale gebruiker $n -> (Keeper: ______________)") }
    }
    if ($msAcc.Count -or $script:Job.Office) { $L.Add('Microsoft-account (e-mail) -> ______________  (Keeper: ______________)') }
    if ($script:Job.TrendMicro) { $L.Add('Trend Micro Client ID -> ______________') }
    $L.Add('')

    # --- Slimme TODO
    $todo = New-Object System.Collections.Generic.List[string]
    $untested = @(Get-UntestedHardware)
    if ($untested.Count) { $todo.Add("Test hardware: $($untested -join ', ')") }
    if ($badTests.Count) { $todo.Add("Defecte hardware melden (HR-bon via Leen): $($badTests -join ', ')") }
    $todo.Add('Labels op toestel en doos; serienummers noteren in ticket')
    $todo.Add('Wachtwoorden in Keeper + klantendossier (lokale accounts)')
    if ($script:Job.Office -or $msAcc.Count) { $todo.Add('M365: licentie/admin-account in klantendossier; MS-account registreren in ticket + afdruk voor klant') }
    if ($script:Job.TrendMicro) { $todo.Add('Trend Micro: klantendossier bijwerken (enkel nieuwe TM-klant) + Client ID koppelen bij Autotask-klant') }
    if ($script:Job.Datto) { $todo.Add('Datto toevoegen (servicecontract)') }
    if ($script:Job.DataTransfer) { $todo.Add("Data overzetten afronden ($(if ($script:JobText.DataTransfer) { $script:JobText.DataTransfer } else { 'ja' }))") }
    if ($script:Job.Backup) { $todo.Add('Backup instellen en testen') }
    if ($PcType -eq 'Gaming') {
        if ($hw.ExtMonitors -gt 0) { $todo.Add('Monitor op max Hz + gewenste resolutie (Windows > Geavanceerde weergave)') }
        $todo.Add('XMP/EXPO in BIOS + temperaturen onder load controleren')
    }
    foreach ($f in $script:InstallFail) { $todo.Add("Handmatig installeren: $f") }
    if ($script:NeedReboot) { $todo.Add('Herstart en controle opnieuw uitvoeren (-VerifyOnly)') }
    $todo.Add('Lipa-sticker; toestel poetsen en inpakken met alle accessoires; Lipa-media terug in archief')
    $todo.Add('Tag sales in ticket (Bieke en Leen) en laat ticket controleren')
    $todo.Add('Klant verwittigen (datum + tijd noteren); toestel klaarzetten met werkbon')
    $L.Add('TODO:')
    foreach ($t in $todo) { $L.Add("- [ ] $t") }
    return ($L -join "`r`n")
}

function Write-Reports {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $effName = if ($script:PendingName) { $script:PendingName } else { $env:COMPUTERNAME }
    $base = Join-Path $OutDir "Handover_${effName}_$stamp"
    $cs = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $cnt = @{ OK = 0; WARN = 0; FAIL = 0; INFO = 0 }
    foreach ($r in $script:Results) { $cnt[$r.Status]++ }
    $verdict = if ($cnt.FAIL) { 'NIET KLAAR - FAIL-punten oplossen' } elseif ($cnt.WARN) { 'KLAAR MET OPMERKINGEN' } else { 'AUTOMATISCH OK' }

    # Ticket
    $ticketPath = Join-Path $OutDir "Ticket_${effName}_$stamp.txt"
    $ticket = New-TicketText
    $ticket | Out-File -FilePath $ticketPath -Encoding UTF8

    # Detailrapport (txt)
    $sym = @{ OK = '[ OK ]'; WARN = '[WARN]'; FAIL = '[FAIL]'; INFO = '[INFO]' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("OVERDRACHTSCONTROLE - $effName"); [void]$sb.AppendLine("Ticket: $TicketNr | Klant: $CustomerName | Type: $PcType | $(Get-Date -Format 'dd/MM/yyyy HH:mm') door $env:USERNAME")
    [void]$sb.AppendLine("PN/SN: $($cs.SystemSKUNumber) / $($bios.SerialNumber)")
    [void]$sb.AppendLine("Resultaat: $verdict ($($cnt.OK) OK | $($cnt.WARN) WARN | $($cnt.FAIL) FAIL)"); [void]$sb.AppendLine('')
    foreach ($grp in ($script:Results | Group-Object Section -NoElement | ForEach-Object { $_.Name })) {
        [void]$sb.AppendLine("--- $grp ---")
        foreach ($r in ($script:Results | Where-Object Section -eq $grp)) {
            [void]$sb.AppendLine("$($sym[$r.Status]) $($r.Item)")
            foreach ($line in ($r.Detail -split "`r?`n")) { if ($line.Trim()) { [void]$sb.AppendLine("        $line") } }
        }
        [void]$sb.AppendLine('')
    }
    $txtPath = "$base.txt"; $sb.ToString() | Out-File -FilePath $txtPath -Encoding UTF8

    # Detailrapport (html)
    $he = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $h = New-Object System.Text.StringBuilder
    [void]$h.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"><title>Overdrachtscontrole</title><style>:root{--bg:#fff;--fg:#1d2733;--card:#f5f7fa;--bd:#d8dee6;--ok:#dff3e4;--warn:#fff1c9;--fail:#f9d6d9;--info:#eef2f7}@media(prefers-color-scheme:dark){:root{--bg:#14181d;--fg:#e6ebf1;--card:#1c222a;--bd:#2c3540;--ok:#1f3a29;--warn:#43381a;--fail:#4a2226;--info:#222a34}}body{font-family:Segoe UI,Arial,sans-serif;margin:24px;background:var(--bg);color:var(--fg)}h1{margin:0 0 4px}.sub{color:#7b8794;margin-bottom:16px}.pills span{display:inline-block;padding:6px 14px;border-radius:20px;margin-right:8px;font-weight:600}table{border-collapse:collapse;width:100%;margin:8px 0 22px}td,th{border:1px solid var(--bd);padding:6px 9px;vertical-align:top;font-size:13px}th{background:var(--card);text-align:left}pre{margin:0;font-family:Consolas,monospace;white-space:pre-wrap}tr.OK{background:var(--ok)}tr.WARN{background:var(--warn)}tr.FAIL{background:var(--fail)}tr.INFO{background:var(--info)}</style></head><body>')
    [void]$h.AppendLine("<h1>$(& $he $effName)</h1><div class='sub'>Ticket $(& $he $TicketNr) &middot; $(& $he $CustomerName) &middot; $PcType &middot; PN/SN $(& $he $cs.SystemSKUNumber) / $(& $he $bios.SerialNumber) &middot; $(Get-Date -Format 'dd/MM/yyyy HH:mm')</div>")
    [void]$h.AppendLine("<div class='pills'><span style='background:var(--ok)'>$($cnt.OK) OK</span><span style='background:var(--warn)'>$($cnt.WARN) WARN</span><span style='background:var(--fail)'>$($cnt.FAIL) FAIL</span><strong>$(& $he $verdict)</strong></div>")
    foreach ($grp in ($script:Results | Group-Object Section -NoElement | ForEach-Object { $_.Name })) {
        [void]$h.AppendLine("<h2>$(& $he $grp)</h2><table><tr><th style='width:70px'>Status</th><th style='width:32%'>Controle</th><th>Details</th></tr>")
        foreach ($r in ($script:Results | Where-Object Section -eq $grp)) { [void]$h.AppendLine("<tr class='$($r.Status)'><td><b>$($r.Status)</b></td><td>$(& $he $r.Item)</td><td><pre>$(& $he $r.Detail)</pre></td></tr>") }
        [void]$h.AppendLine('</table>')
    }
    [void]$h.AppendLine('</body></html>')
    $htmlPath = "$base.html"; $h.ToString() | Out-File -FilePath $htmlPath -Encoding UTF8

    $script:LastReport = @{ Ticket = $ticketPath; Txt = $txtPath; Html = $htmlPath; Text = $ticket }
}

function Action-Report {
    Write-Section '12  Ticket + rapport'
    if ($script:Results.Count -eq 0) { Say-Info 'Eerst controle uitvoeren...'; Invoke-Verification }
    Write-Reports
    $r = $script:LastReport
    Write-Box 'Bestanden' @(
        @(@{ T = 'Ticket-tekst  '; C = 'White' }, @{ T = (Cut $r.Ticket 66); C = 'Cyan' }),
        @(@{ T = 'Controle txt  '; C = 'White' }, @{ T = (Cut $r.Txt 66); C = 'Cyan' }),
        @(@{ T = 'Controle html '; C = 'White' }, @{ T = (Cut $r.Html 66); C = 'Cyan' })
    ) 'DarkCyan'
    if ($CopyToClipboard -or (Ask-YesNo 'Ticket-tekst naar klembord kopieren?' $true)) { $r.Text | Set-Clipboard; Say-Ok 'Gekopieerd - plak in Autotask (Resolution/Note).' }
    if (Ask-YesNo 'Ticket-tekst hier tonen?' $false) { Write-Host ''; Write-Host $r.Text -ForegroundColor Gray }
    if (Ask-YesNo 'Detailrapport (html) openen?' $false) { Start-Process $r.Html -ErrorAction SilentlyContinue }
    $script:Done['12'] = $true
}

# ============================================================================
# WACHTWOORDEN TONEN (K)
# ============================================================================
function Action-Credentials {
    if ($script:Creds.Count -eq 0) { Say-Info 'Geen wachtwoorden aangemaakt in deze sessie.'; return }
    $lines = New-Object System.Collections.Generic.List[object]
    foreach ($c in $script:Creds) { $lines.Add(@(@{ T = ("{0,-24}" -f $c.User); C = 'White' }, @{ T = $c.Password; C = 'Yellow' })) }
    $lines.Add('')
    $lines.Add(@{ T = 'Niet opgeslagen. Zet ze nu in Keeper en het klantendossier.'; C = 'DarkGray' })
    Write-Box 'Wachtwoorden van deze sessie' $lines 'Yellow'
    [void](Read-Host '  Enter = scherm wissen')
    if (-not $NoClear) { Clear-Host }
}

# ============================================================================
# DASHBOARD + MENU
# ============================================================================
function Get-Pills {
    $d = $U.Dot
    $p = New-Object System.Collections.Generic.List[object]
    $name = $env:COMPUTERNAME; if ($script:PendingName) { $name = "$name > $($script:PendingName)" }
    $p.Add(@{ T = "$d Naam $name"; C = $(if ($script:PendingName) { 'Yellow' } else { 'Green' }) })
    $fs = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled
    $p.Add(@{ T = "$d Snel opstarten $(if ($fs -eq 0) { 'UIT' } else { 'AAN' })"; C = $(if ($fs -eq 0) { 'Green' } else { 'Red' }) })
    $ca = Get-LocalUser -Name $AdminUser -ErrorAction SilentlyContinue
    $p.Add(@{ T = "$d $AdminUser $(if ($ca -and $ca.Enabled) { 'OK' } else { 'ontbreekt' })"; C = $(if ($ca -and $ca.Enabled) { 'Green' } else { 'Red' }) })
    $cn = if ($script:CustomerUserResolved) { $script:CustomerUserResolved } else { $CustomerUser }
    if ($cn) { $cu = Get-LocalUser -Name $cn -ErrorAction SilentlyContinue; $p.Add(@{ T = "$d $cn $(if ($cu) { 'OK' } else { 'ontbreekt' })"; C = $(if ($cu) { 'Green' } else { 'Yellow' }) }) }
    $tzOk = (Get-TimeZone).Id -eq 'Romance Standard Time'
    $p.Add(@{ T = "$d Tijdzone $(if ($tzOk) { 'BE' } else { 'fout' })"; C = $(if ($tzOk) { 'Green' } else { 'Yellow' }) })
    $p.Add(@{ T = "$d Debloat $(if ($script:Done['7']) { 'gedaan' } else { '-' })"; C = $(if ($script:Done['7']) { 'Green' } else { 'DarkGray' }) })
    $p.Add(@{ T = "$d Software $(if ($script:Done['8']) { 'gedaan' } else { '-' })"; C = $(if ($script:Done['8']) { 'Green' } else { 'DarkGray' }) })
    $p.Add(@{ T = "$d Updates $(if ($script:PendingUpdateCount -eq 0) { 'actueel' } elseif ($script:Done['9']) { 'gedaan' } else { '-' })"; C = $(if ($script:Done['9'] -or $script:PendingUpdateCount -eq 0) { 'Green' } else { 'DarkGray' }) })
    if ($script:HwTests.Count) { $bad = @($script:HwTests.Keys | Where-Object { $script:HwTests[$_] -ne 'OK' }).Count; $p.Add(@{ T = "$d HW getest $($script:HwTests.Count)$(if ($bad) { " ($bad defect)" })"; C = $(if ($bad) { 'Red' } else { 'Green' }) }) }
    if ($script:Done['11']) {
        $f = @($script:Results | Where-Object Status -eq 'FAIL').Count; $w = @($script:Results | Where-Object Status -eq 'WARN').Count
        $p.Add(@{ T = "$d Controle $f FAIL / $w WARN"; C = $(if ($f) { 'Red' } elseif ($w) { 'Yellow' } else { 'Green' }) })
    }
    return $p
}

function Show-Dashboard {
    $lines = New-Object System.Collections.Generic.List[object]
    $lines.Add(@(@{ T = (Cut "$($cs.Manufacturer) $($cs.Model)" 44); C = 'White' }, @{ T = "  SN $($bios.SerialNumber)"; C = 'DarkGray' }))
    $jobs = @(); foreach ($k in 'Office', 'TrendMicro', 'Datto', 'DataTransfer', 'Backup') { if ($script:Job[$k]) { $jobs += $k } }
    $lines.Add(@(@{ T = "$(Cut $os.Caption 22) | $PcType | "; C = 'Gray' }, @{ T = (Cut "$(if ($CustomerName) { $CustomerName } else { 'klant ?' }) | $(if ($TicketNr) { $TicketNr } else { 'ticket ?' })" 50); C = 'Gray' }))
    $lines.Add(@(@{ T = 'Opdracht: '; C = 'DarkGray' }, @{ T = $(if ($jobs.Count) { $jobs -join ', ' } elseif ($script:Done['P']) { 'standaard (geen extra opties)' } else { 'nog niet ingesteld - kies P' }); C = $(if ($jobs.Count) { 'Cyan' } else { 'DarkGray' }) }))
    if ($isHome) { $lines.Add(@{ T = "$($U.Warn) Windows HOME: geen clean install, debloat in overleg"; C = 'Yellow' }) }
    $lines.Add('')
    $row = New-Object System.Collections.Generic.List[object]; $len = 0
    foreach ($pill in (Get-Pills)) {
        if ($len + $pill.T.Length + 3 -gt ($BoxWidth - 6)) { $lines.Add($row.ToArray()); $row = New-Object System.Collections.Generic.List[object]; $len = 0 }
        $row.Add($pill); $row.Add(@{ T = '   '; C = 'Gray' }); $len += $pill.T.Length + 3
    }
    if ($row.Count) { $lines.Add($row.ToArray()) }
    Write-Box 'LIPA TOOLKIT' $lines 'Cyan'
}

$script:MenuItems = @(
    @{ Group = 'SETUP';    Key = '1';  Label = 'Toestelnaam wijzigen';                         Do = { Action-Rename } },
    @{ Group = 'SETUP';    Key = '2';  Label = 'Regio, tijdzone & tijdsync';                   Do = { Action-Region } },
    @{ Group = 'SETUP';    Key = '3';  Label = 'Energie: snel opstarten UIT + energieplan';    Do = { Action-Power } },
    @{ Group = 'SETUP';    Key = '4';  Label = 'Beveiliging basis (firewall, gast/admin uit)'; Do = { Action-Security } },
    @{ Group = 'ACCOUNTS'; Key = '5';  Label = 'Clientadmin aanmaken / controleren';           Do = { Action-ClientAdmin } },
    @{ Group = 'ACCOUNTS'; Key = '6';  Label = 'Klantaccount aanmaken / controleren';          Do = { Action-Customer } },
    @{ Group = 'SOFTWARE'; Key = '7';  Label = 'Debloat (licht / medium / zwaar)';             Do = { Action-Debloat } },
    @{ Group = 'SOFTWARE'; Key = '8';  Label = 'Standaardsoftware installeren';                Do = { Action-Software } },
    @{ Group = 'SOFTWARE'; Key = '9';  Label = 'Windows Updates (incl. drivers)';              Do = { Action-Updates } },
    @{ Group = 'CONTROLE'; Key = '10'; Label = 'Hardware testen (enkel wat aanwezig is)';      Do = { Action-HwTest } },
    @{ Group = 'CONTROLE'; Key = '11'; Label = 'Controle uitvoeren';                           Do = { Action-Check } },
    @{ Group = 'CONTROLE'; Key = '12'; Label = 'Ticket-tekst + rapport maken';                 Do = { Action-Report } },
    @{ Group = 'TOOLS';    Key = 'P';  Label = 'Opdracht & ticket-info (klembord inlezen)';    Do = { Action-Job } },
    @{ Group = 'TOOLS';    Key = 'F';  Label = 'Herstel automatisch wat de controle afkeurde'; Do = { Action-Fix } },
    @{ Group = 'TOOLS';    Key = 'K';  Label = 'Wachtwoorden van deze sessie tonen';           Do = { Action-Credentials } }
)

$script:FixMap = @{
    FastStartup  = { Set-FastStartupOff }
    TimeZone     = { Set-TimeZoneBE }
    Region       = { Set-RegionBE }
    TimeSync     = { Set-TimeSync }
    Firewall     = { Set-FirewallOn }
    Guest        = { Disable-Guest }
    BuiltinAdmin = { Disable-BuiltinAdmin }
    PowerPlan    = { Set-PowerPlanForType }
    Hostname     = { Action-Rename }
}

function Show-MenuBox {
    $lines = New-Object System.Collections.Generic.List[object]
    $group = ''
    foreach ($m in $script:MenuItems) {
        if ($m.Group -ne $group) {
            if ($group) { $lines.Add('') }
            $lines.Add(@{ T = $m.Group; C = 'DarkCyan' }); $group = $m.Group
        }
        $done = $script:Done[$m.Key]
        $lines.Add(@(
                @{ T = ("  {0,-3}" -f $m.Key); C = 'Yellow' },
                @{ T = ("{0,-56}" -f $m.Label); C = 'White' },
                @{ T = $(if ($done) { '[x]' } else { '[ ]' }); C = $(if ($done) { 'Green' } else { 'DarkGray' }) }))
    }
    $lines.Add('')
    $lines.Add(@(@{ T = '  A   '; C = 'Yellow' }, @{ T = 'Alles geleid in volgorde (P, 1 t/m 12)'; C = 'White' }))
    $lines.Add(@(@{ T = '  Q   '; C = 'Yellow' }, @{ T = 'Stoppen'; C = 'White' }))
    Write-Box 'MENU' $lines 'DarkCyan'
}

function Invoke-MenuKey {
    param([string]$Key)
    if ($Key -eq 'A') {
        if (-not (Ask-YesNo 'Alles geleid doorlopen (P, 1 t/m 12)?' $true)) { return }
        foreach ($x in @('P', '1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11', '12')) { Invoke-MenuKey $x }
        return
    }
    $item = $script:MenuItems | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
    if (-not $item) { Say-Warn "Onbekende keuze: $Key"; return }
    try { & $item.Do } catch { Say-Bad "Fout in '$($item.Label)': $($_.Exception.Message)" }
}

function Show-ExitSummary {
    if ($script:Creds.Count) { Action-Credentials }
    if ($script:NeedReboot) {
        Say-Warn 'Een herstart is nodig (naamswijziging, verwijderde software of updates).'
        Say-Info 'Na herstart: .\Lipa-Toolkit.ps1 -VerifyOnly  (en herhaal menu 9 tot er geen updates meer zijn)'
        if (Ask-YesNo 'Nu herstarten?' $false) { Restart-Computer -Force }
    }
}

# ============================================================================
# MAIN
# ============================================================================
if (-not $PcType) {
    $c = Ask-Choice 'Type pc?' @('Werk-pc', 'Gaming-pc') 1
    $PcType = if ($c -eq 2) { 'Gaming' } else { 'Werk' }
}
if ($FromClipboard) { Import-TicketFromClipboard; $script:Done['P'] = $true }
if ($VerifyOnly) { $Run = @('11', '12') }

if ($Run) {
    foreach ($k in $Run) { Invoke-MenuKey ($k.ToString().ToUpper()) }
    Show-ExitSummary
    return
}

while ($true) {
    if (-not $NoClear) { Clear-Host }
    Show-Dashboard
    Show-MenuBox
    $in = (Read-Host '  Kies (bv. 1,5,7 | A = alles | Q = stoppen)').Trim().ToUpper()
    if (-not $in) { continue }
    $keys = @($in -split '[,\s]+' | Where-Object { $_ })
    if ($keys -contains 'Q') { break }
    foreach ($k in $keys) { Invoke-MenuKey $k }
    Pause-Menu
}
Show-ExitSummary
