<#
.SYNOPSIS
    Lipa: geleide setup + overdrachtscontrole voor een nieuwe Windows-pc (Werk of Gaming).

.DESCRIPTION
    Stappen (kies er zoveel je wil, of alles):
      1 Basis        : toestelnaam, tijdzone, regio, tijdsync, snel opstarten UIT, firewall, energieplan
      2 Accounts     : Clientadmin + klantaccount aanmaken/controleren, wachtwoord (random/eigen)
      3 Debloat      : kies zwaarte (licht/medium/zwaar), lijst nakijken, uitsluiten, verwijderen
      4 Software     : standaardpakketten (winget -> chocolatey -> download), Splashtop SOS Lipa
      5 Updates      : Windows Update via PSWindowsUpdate (incl. drivers)
      6 Controle     : volledige check + rapport (txt/html) + ticket-tekst voor Autotask

    Wachtwoorden worden NIET naar schijf geschreven (tenzij -IncludePasswordsInTicket).
    Ze worden op het einde eenmalig getoond zodat je ze in Keeper kan zetten.

.EXAMPLE
    .\Lipa-Setup-and-Handover.ps1 -PcType Gaming -CustomerName "Smeers Sam" -CustomerUser Sam -TicketNr T20261007.0003

.EXAMPLE
    .\Lipa-Setup-and-Handover.ps1 -VerifyOnly          # enkel controle + rapport (bv. na herstart)

.EXAMPLE
    .\Lipa-Setup-and-Handover.ps1 -Run 3,4             # enkel debloat en software

.NOTES
    Uitvoeren als Administrator:
      powershell -ExecutionPolicy Bypass -File .\Lipa-Setup-and-Handover.ps1
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
    [int[]]$Run,
    [switch]$VerifyOnly,
    [switch]$IncludePasswordsInTicket,
    [switch]$CopyToClipboard
)

# ============================================================================
# CONFIG (aanpassen naar eigen standaard)
# ============================================================================
$MaxHostnameLength = 15        # Windows/NetBIOS limiet (checklist zegt 16, maar 15 is de echte grens)
$SplashtopUrl      = 'https://my.splashtop.eu/sos/packages/download/XW2PS2PZ5KSKEU'
$SplashtopDesktopName = 'SOS Lipa.exe'
$MinPasswordLength = $null     # bv. 8  -> net accounts /minpwlen   ($null = niet aanraken)
$MaxPasswordAgeDays = $null    # bv. 0 = nooit verlopen, 90 -> /maxpwage ($null = niet aanraken)

# Pakketcatalogus. Default = voor welke PcType voorgeselecteerd. Vendor = enkel tonen op dat merk.
# Winget-id van 9xxxxxxxxxxx = Microsoft Store id. Choco mag een lijst zijn (wordt in volgorde geprobeerd).
$AppCatalog = @(
    @{ Name = 'Splashtop SOS (Lipa)';     Special = 'Splashtop'; Default = 'Werk', 'Gaming' },
    @{ Name = 'RustDesk';                 Winget = 'RustDesk.RustDesk';                 Choco = 'rustdesk';        Match = '*RustDesk*';          Default = 'Werk' },
    @{ Name = 'Mozilla Firefox';          Winget = 'Mozilla.Firefox';                   Choco = 'firefox';         Match = '*Firefox*';           Default = 'Werk', 'Gaming' },
    @{ Name = 'Google Chrome';            Winget = 'Google.Chrome';                     Choco = 'googlechrome';    Match = '*Google Chrome*';     Default = 'Werk', 'Gaming' },
    @{ Name = 'Adobe Acrobat Reader';     Winget = 'Adobe.Acrobat.Reader.64-bit';       Choco = 'adobereader';     Match = '*Acrobat*';           Default = 'Werk', 'Gaming' },
    @{ Name = 'Foxit PDF Reader';         Winget = 'Foxit.FoxitReader';                 Choco = 'foxitreader';     Match = '*Foxit*';             Default = 'Werk' },
    @{ Name = 'Belgian eID middleware';   Winget = 'BelgianGovernment.eIDmiddleware';   Choco = 'eid-belgium', 'belgian-eid-middleware'; Match = '*eID*Middleware*|*Belgium eID*'; Default = 'Werk' },
    @{ Name = 'Belgian eID viewer';       Winget = 'BelgianGovernment.eIDViewer';       Choco = 'eid-belgium-viewer', 'belgian-eid-viewer'; Match = '*eID Viewer*'; Default = 'Werk' },
    @{ Name = 'OpenVPN Connect';          Winget = 'OpenVPNTechnologies.OpenVPNConnect'; Choco = 'openvpn-connect'; Match = '*OpenVPN Connect*';   Default = 'Werk' },
    @{ Name = 'VLC media player';         Winget = 'VideoLAN.VLC';                      Choco = 'vlc';             Match = '*VLC*';               Default = 'Werk', 'Gaming' },
    @{ Name = 'Microsoft 365 Apps (licentie nodig!)'; Winget = 'Microsoft.Office';      Choco = 'office365business', 'office365proplus'; Match = '*Microsoft 365*|*Office 16*'; Default = @() },
    @{ Name = 'Steam';                    Winget = 'Valve.Steam';                       Choco = 'steam';           Match = 'Steam';               Default = 'Gaming' },
    @{ Name = 'Epic Games Launcher';      Winget = 'EpicGames.EpicGamesLauncher';       Choco = 'epicgameslauncher'; Match = '*Epic Games Launcher*'; Default = 'Gaming' },
    @{ Name = 'Discord';                  Winget = 'Discord.Discord';                   Choco = 'discord';         Match = '*Discord*';           Default = @() },
    @{ Name = 'HP programmable key';      Winget = '9MW15F21R5G8';                                                                                   Default = 'Werk'; Vendor = 'HP' },
    @{ Name = 'HP Support Assistant';     Choco = 'hpsupportassistant';                                            Match = '*HP Support Assistant*'; Default = 'Werk'; Vendor = 'HP' },
    @{ Name = 'HP Image Assistant';       Winget = 'HP.ImageAssistant'; Choco = 'hpimageassistant';                Match = '*HP Image Assistant*';   Default = 'Werk'; Vendor = 'HP' }
)

# Debloat-regels (WHITELIST van wat verwijderd mag worden: alles wat hier niet staat blijft onaangeroerd).
# Level 1 = licht, 2 = medium, 3 = zwaar.
$DebloatRules = @(
    # --- Level 1: trials, adware, promo-apps
    @{ Level = 1; Kind = 'Win32'; Pattern = 'McAfee*';          Why = 'Trial antivirus' },
    @{ Level = 1; Kind = 'Win32'; Pattern = 'WebAdvisor*';      Why = 'McAfee adware' },
    @{ Level = 1; Kind = 'Win32'; Pattern = 'Norton*';          Why = 'Trial antivirus' },
    @{ Level = 1; Kind = 'Win32'; Pattern = 'Avast*';           Why = 'Concurrerend antivirus' },
    @{ Level = 1; Kind = 'Win32'; Pattern = 'AVG*';             Why = 'Concurrerend antivirus' },
    @{ Level = 1; Kind = 'Win32'; Pattern = 'WildTangent*';     Why = 'Spelletjes-adware' },
    @{ Level = 1; Kind = 'Win32'; Pattern = 'ExpressVPN*';      Why = 'Trial VPN' },
    @{ Level = 1; Kind = 'Win32'; Pattern = 'Dropbox promotion*'; Why = 'OEM promo' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*CandyCrush*';     Why = 'Promo-spel' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*BubbleWitch*';    Why = 'Promo-spel' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*FarmVille*';      Why = 'Promo-spel' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*MarchofEmpires*'; Why = 'Promo-spel' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*RoyalRevolt*';    Why = 'Promo-spel' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*TikTok*';         Why = 'Promo-app' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*Disney*';         Why = 'Promo-app' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*Netflix*';        Why = 'Promo-app' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*Facebook*';       Why = 'Promo-app' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*Instagram*';      Why = 'Promo-app' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*Twitter*';        Why = 'Promo-app' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*Hulu*';           Why = 'Promo-app' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*Booking*';        Why = 'Promo-app' },
    @{ Level = 1; Kind = 'Appx';  Pattern = '*AmazonPrimeVideo*'; Why = 'Promo-app' },
    # --- Level 2: overbodige Microsoft-apps
    @{ Level = 2; Kind = 'Appx';  Pattern = '*Spotify*';        Why = 'Promo-app' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Clipchamp*';       Why = 'Videobewerker' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Microsoft.MicrosoftSolitaireCollection'; Why = 'Spelletjes' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Microsoft.BingNews';     Why = 'Nieuws' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Microsoft.BingWeather';  Why = 'Weer' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Microsoft.GetHelp';      Why = 'Get Help' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Microsoft.Getstarted';   Why = 'Tips' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Microsoft.WindowsFeedbackHub'; Why = 'Feedback Hub' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Microsoft.MicrosoftOfficeHub'; Why = 'Office-hub (promo)' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Microsoft.549981C3F5F10';      Why = 'Cortana' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'MSTeams';                Why = 'Teams (consumer)' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'MicrosoftTeams';         Why = 'Teams (consumer)' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Microsoft.PowerAutomateDesktop'; Why = 'Power Automate' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Microsoft.MixedReality.Portal';  Why = 'Mixed Reality' },
    @{ Level = 2; Kind = 'Appx';  Pattern = 'Microsoft.People';       Why = 'People' },
    # --- Level 3: zwaar (kan door klant gebruikt worden: bespreek!)
    @{ Level = 3; Kind = 'Appx';  Pattern = 'Microsoft.YourPhone';    Why = 'Phone Link' },
    @{ Level = 3; Kind = 'Appx';  Pattern = 'Microsoft.WindowsMaps';  Why = 'Kaarten' },
    @{ Level = 3; Kind = 'Appx';  Pattern = 'Microsoft.Copilot';      Why = 'Copilot-app' },
    @{ Level = 3; Kind = 'Appx';  Pattern = 'Microsoft.OutlookForWindows'; Why = 'Nieuwe Outlook' },
    @{ Level = 3; Kind = 'Appx';  Pattern = 'MicrosoftCorporationII.MicrosoftFamily'; Why = 'Family' },
    @{ Level = 3; Kind = 'Appx';  Pattern = 'Microsoft.Windows.DevHome'; Why = 'Dev Home' },
    @{ Level = 3; Kind = 'Appx';  Pattern = 'Microsoft.BingSearch';   Why = 'Bing-zoeken' },
    @{ Level = 3; Kind = 'Win32'; Pattern = 'Microsoft 365 - *';      Why = 'Office-PROEFVERSIE (verwijdert ook een betaalde Office!)' }
)

# ============================================================================
# STATE + HELPERS
# ============================================================================
$ErrorActionPreference = 'Continue'
$script:Results       = New-Object System.Collections.Generic.List[object]
$script:ActionLog     = New-Object System.Collections.Generic.List[string]
$script:Creds         = New-Object System.Collections.Generic.List[object]
$script:InstallOk     = New-Object System.Collections.Generic.List[string]
$script:InstallFail   = New-Object System.Collections.Generic.List[string]
$script:PendingName   = $null
$script:ChocoDeclined = $false
$script:NeedReboot    = $false

function Say { param([string]$m, [string]$c = 'Gray') Write-Host $m -ForegroundColor $c }
function Header { param([string]$m) Write-Host ''; Write-Host ('=' * 78) -ForegroundColor DarkGray; Write-Host "  $m" -ForegroundColor Cyan; Write-Host ('=' * 78) -ForegroundColor DarkGray }
function Log-Action { param([string]$m) $script:ActionLog.Add($m); Say "  [+] $m" 'Green' }
function Warn-Action { param([string]$m) Say "  [!] $m" 'Yellow' }

function Ask-YesNo {
    param([string]$Question, [bool]$Default = $true)
    $hint = if ($Default) { '[J/n]' } else { '[j/N]' }
    while ($true) {
        $a = (Read-Host "$Question $hint").Trim().ToLower()
        if (-not $a) { return $Default }
        if ($a -in 'j', 'y', 'ja', 'yes') { return $true }
        if ($a -in 'n', 'nee', 'no') { return $false }
    }
}

function Ask-Choice {
    param([string]$Question, [string[]]$Options, [int]$Default = 1)
    Write-Host $Question -ForegroundColor Yellow
    for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $Options[$i]) }
    while ($true) {
        $a = Read-Host "Keuze [$Default]"
        if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) { return $n }
    }
}

function Add-Check {
    param(
        [string]$Section, [string]$Item,
        [ValidateSet('OK', 'WARN', 'FAIL', 'INFO')][string]$Status,
        [string]$Detail = ''
    )
    $script:Results.Add([pscustomobject]@{ Section = $Section; Item = $Item; Status = $Status; Detail = [string]$Detail })
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

function ConvertTo-PlainText {
    param([securestring]$Secure)
    return (New-Object System.Net.NetworkCredential('', $Secure)).Password
}

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

# Geeft @{ Secure; Plain } of $null (overslaan). Optie 'none' enkel indien AllowEmpty.
function Get-NewPassword {
    param([string]$User, [switch]$AllowEmpty)
    $opts = @('Random wachtwoord genereren (aanbevolen)', 'Eigen wachtwoord invoeren', 'Overslaan')
    if ($AllowEmpty) { $opts = @('Random wachtwoord genereren (aanbevolen)', 'Eigen wachtwoord invoeren', 'GEEN wachtwoord', 'Overslaan') }
    $c = Ask-Choice "Wachtwoord voor '$User':" $opts 1
    $skipIdx = $opts.Count
    if ($c -eq $skipIdx) { return $null }
    if ($AllowEmpty -and $c -eq 3) { return @{ Secure = $null; Plain = ''; Empty = $true } }
    if ($c -eq 1) {
        $p = New-RandomPassword
        return @{ Secure = (ConvertTo-SecureString $p -AsPlainText -Force); Plain = $p; Empty = $false }
    }
    while ($true) {
        $s1 = Read-Host "Wachtwoord voor '$User'" -AsSecureString
        $s2 = Read-Host 'Bevestig' -AsSecureString
        if ($s1.Length -eq 0) { Warn-Action 'Wachtwoord mag niet leeg zijn.'; continue }
        $p1 = ConvertTo-PlainText $s1
        if ($p1 -ne (ConvertTo-PlainText $s2)) { Warn-Action 'Wachtwoorden komen niet overeen.'; continue }
        return @{ Secure = $s1; Plain = $p1; Empty = $false }
    }
}

# ============================================================================
# PREFLIGHT
# ============================================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Dit script moet als Administrator draaien.' -ForegroundColor Red
    exit 1
}

$cs = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$os = Get-CimInstance Win32_OperatingSystem
$isHome = $os.Caption -match 'Home'
$vendor = if ($cs.Manufacturer -match 'HP|Hewlett') { 'HP' } elseif ($cs.Manufacturer -match 'LENOVO') { 'Lenovo' } elseif ($cs.Manufacturer -match 'Dell') { 'Dell' } else { $cs.Manufacturer }

Header 'Lipa Setup & Handover'
Say "Toestel : $($cs.Manufacturer) $($cs.Model)  (SN $($bios.SerialNumber))"
Say "Windows : $($os.Caption) build $($os.BuildNumber)"
if ($isHome) {
    Write-Host '  OPGELET: Windows HOME - geen clean install; debloat enkel in overleg;' -ForegroundColor Red
    Write-Host '  pas op met Microsoft personal accounts.' -ForegroundColor Red
}

if (-not $PcType) {
    $c = Ask-Choice 'Type pc?' @('Werk-pc', 'Gaming-pc') 1
    $PcType = if ($c -eq 2) { 'Gaming' } else { 'Werk' }
}
if (-not $CustomerName -and -not $VerifyOnly) { $CustomerName = Read-Host 'Klantnaam (voor ticket, Enter = leeg)' }
if (-not $TicketNr -and -not $VerifyOnly) { $TicketNr = Read-Host 'Ticketnummer (Enter = leeg)' }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# ============================================================================
# STAP 1 - BASIS
# ============================================================================
function Step-Basis {
    Header 'Stap 1 - Basisinstellingen'

    # --- Toestelnaam
    $cur = $env:COMPUTERNAME
    Say "Huidige toestelnaam: $cur" 'Yellow'
    $sug = if ($ExpectedHostname) { $ExpectedHostname } else { 'PC-' + (Get-Date -Format 'yyMMdd') }
    $n = Read-Host "Nieuwe toestelnaam (max $MaxHostnameLength tekens; Enter = '$sug'; 'x' = niet wijzigen)"
    if ([string]::IsNullOrWhiteSpace($n)) { $n = $sug }
    if ($n -ne 'x') {
        if ($n.Length -gt $MaxHostnameLength -or $n -notmatch '^(?!\d+$)[A-Za-z0-9-]+$') {
            Warn-Action "Ongeldige naam '$n' (max $MaxHostnameLength tekens, enkel letters/cijfers/koppelteken). Niet gewijzigd."
        }
        elseif ($n -ieq $cur) { Say 'Naam is al correct.' 'Green' }
        else {
            try {
                Rename-Computer -NewName $n -Force -ErrorAction Stop
                $script:PendingName = $n
                $script:NeedReboot = $true
                Log-Action "Toestelnaam gewijzigd van $cur naar $n (herstart nodig)"
            }
            catch { Warn-Action "Naam wijzigen mislukt: $($_.Exception.Message)" }
        }
    }

    if (-not (Ask-YesNo 'Standaardinstellingen automatisch toepassen/corrigeren (tijdzone, regio, tijdsync, snel opstarten UIT, firewall, energieplan)?')) { return }

    # --- Tijdzone
    if ((Get-TimeZone).Id -ne 'Romance Standard Time') {
        Set-TimeZone -Id 'Romance Standard Time'; Log-Action 'Tijdzone ingesteld op Brussel (Romance Standard Time)'
    }
    # --- Regio Belgie
    try {
        if ((Get-WinHomeLocation).GeoId -ne 21) { Set-WinHomeLocation -GeoId 21; Log-Action 'Land/regio ingesteld op Belgie' }
    }
    catch { }
    # --- Tijdsync
    try {
        Set-Service w32time -StartupType Automatic -ErrorAction Stop
        if ((Get-Service w32time).Status -ne 'Running') { Start-Service w32time }
        & w32tm /resync /force 2>&1 | Out-Null
        Log-Action 'Tijdsynchronisatie actief en gesynchroniseerd'
    }
    catch { Warn-Action "Tijdsync: $($_.Exception.Message)" }
    # --- Snel opstarten UIT
    $pw = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    if ((Get-ItemProperty $pw -ErrorAction SilentlyContinue).HiberbootEnabled -ne 0) {
        Set-ItemProperty -Path $pw -Name HiberbootEnabled -Value 0 -Type DWord -Force
        Log-Action 'Snel opstarten uitgeschakeld'
    }
    else { Say '  Snel opstarten stond al UIT.' 'DarkGray' }
    # --- Firewall
    $off = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Enabled })
    if ($off.Count) { Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True; Log-Action 'Windows Firewall ingeschakeld voor alle profielen' }
    # --- Energieplan
    try {
        if ($PcType -eq 'Gaming') {
            & powercfg /setactive SCHEME_MIN 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Log-Action 'Energieplan: Hoge prestaties' } else { Warn-Action 'Plan Hoge prestaties niet beschikbaar - handmatig instellen.' }
        }
        else {
            & powercfg /setactive SCHEME_BALANCED 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Log-Action 'Energieplan: Gebalanceerd' }
        }
    }
    catch { }
    # --- Wachtwoordbeleid (optioneel via config)
    if ($null -ne $MinPasswordLength) { & net accounts /minpwlen:$MinPasswordLength | Out-Null; Log-Action "Wachtwoordbeleid: minimale lengte $MinPasswordLength" }
    if ($null -ne $MaxPasswordAgeDays) {
        $age = if ($MaxPasswordAgeDays -eq 0) { 'unlimited' } else { $MaxPasswordAgeDays }
        & net accounts /maxpwage:$age | Out-Null; Log-Action "Wachtwoordbeleid: maximum leeftijd $age"
    }
}

# ============================================================================
# STAP 2 - ACCOUNTS
# ============================================================================
function Step-Accounts {
    Header 'Stap 2 - Accounts'

    # --- Clientadmin
    $ca = Get-LocalUser -Name $AdminUser -ErrorAction SilentlyContinue
    if (-not $ca) {
        Warn-Action "Beheeraccount '$AdminUser' bestaat niet."
        if (Ask-YesNo "'$AdminUser' nu aanmaken?") {
            $p = Get-NewPassword $AdminUser
            if ($p) {
                try {
                    New-LocalUser -Name $AdminUser -Password $p.Secure -FullName $AdminUser -Description 'Lipa beheeraccount' -PasswordNeverExpires -AccountNeverExpires -ErrorAction Stop | Out-Null
                    Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $AdminUser -ErrorAction Stop
                    $script:Creds.Add(@{ User = $AdminUser; Password = $p.Plain })
                    Log-Action "Account '$AdminUser' aangemaakt (administrator, wachtwoord verloopt nooit)"
                }
                catch { Warn-Action "Aanmaken mislukt: $($_.Exception.Message)" }
            }
        }
    }
    else {
        Say "Beheeraccount '$AdminUser' bestaat al." 'Green'
        if (-not $ca.Enabled) { Enable-LocalUser -Name $AdminUser; Log-Action "'$AdminUser' ingeschakeld" }
        if (-not (Test-LocalAdmin $AdminUser)) { Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $AdminUser; Log-Action "'$AdminUser' toegevoegd aan Administrators" }
        if (Ask-YesNo "Wachtwoord van '$AdminUser' opnieuw instellen?" $false) {
            $p = Get-NewPassword $AdminUser
            if ($p) {
                try { Set-LocalUser -Name $AdminUser -Password $p.Secure -ErrorAction Stop; $script:Creds.Add(@{ User = $AdminUser; Password = $p.Plain }); Log-Action "Wachtwoord van '$AdminUser' gewijzigd" }
                catch { Warn-Action "Wijzigen mislukt: $($_.Exception.Message)" }
            }
        }
    }

    # --- Klantaccount
    $cuName = $CustomerUser
    if (-not $cuName) { $cuName = Read-Host 'Gebruikersnaam klantaccount (Enter = overslaan)' }
    if ($cuName) {
        $cu = Get-LocalUser -Name $cuName -ErrorAction SilentlyContinue
        if ($cu) {
            Say "Klantaccount '$cuName' bestaat al (bron: $($cu.PrincipalSource))." 'Green'
            if ($cu.PrincipalSource -eq 'MicrosoftAccount') { Warn-Action 'Dit is een Microsoft-account: registreren in klantdossier + ticket.' }
            if ($cu.PrincipalSource -eq 'Local' -and (Ask-YesNo "Wachtwoord van '$cuName' opnieuw instellen?" $false)) {
                $p = Get-NewPassword $cuName -AllowEmpty
                if ($p) {
                    try {
                        if ($p.Empty) { Set-LocalUser -Name $cuName -Password ([securestring]::new()) } else { Set-LocalUser -Name $cuName -Password $p.Secure }
                        $script:Creds.Add(@{ User = $cuName; Password = $(if ($p.Empty) { '(geen wachtwoord)' } else { $p.Plain }) })
                        Log-Action "Wachtwoord van '$cuName' gewijzigd"
                    }
                    catch { Warn-Action "Wijzigen mislukt: $($_.Exception.Message)" }
                }
            }
        }
        else {
            $rights = Ask-Choice "Rechten voor '$cuName':" @('Standaardgebruiker', 'Administrator (installatierechten)') 1
            $p = Get-NewPassword $cuName -AllowEmpty
            if ($p) {
                try {
                    if ($p.Empty) { New-LocalUser -Name $cuName -NoPassword -FullName $cuName -ErrorAction Stop | Out-Null }
                    else { New-LocalUser -Name $cuName -Password $p.Secure -FullName $cuName -ErrorAction Stop | Out-Null }
                    Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $cuName -ErrorAction SilentlyContinue
                    if ($rights -eq 2) { Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $cuName }
                    $script:Creds.Add(@{ User = $cuName; Password = $(if ($p.Empty) { '(geen wachtwoord)' } else { $p.Plain }) })
                    Log-Action "Lokaal account '$cuName' aangemaakt ($(if ($rights -eq 2) { 'administrator' } else { 'standaardgebruiker' }))"
                }
                catch { Warn-Action "Aanmaken mislukt: $($_.Exception.Message)" }
            }
        }
        $script:CustomerUserResolved = $cuName
    }

    # --- Ingebouwde accounts
    Get-LocalUser | Where-Object { $_.SID.Value -match '-501$' -and $_.Enabled } | ForEach-Object { Disable-LocalUser $_; Log-Action 'Gastaccount uitgeschakeld' }
    $b = Get-LocalUser | Where-Object { $_.SID.Value -match '-500$' -and $_.Enabled }
    if ($b) {
        if ((Get-LocalUser -Name $AdminUser -ErrorAction SilentlyContinue).Enabled -and (Test-LocalAdmin $AdminUser)) {
            Disable-LocalUser $b; Log-Action 'Ingebouwde Administrator uitgeschakeld'
        }
        else { Warn-Action 'Ingebouwde Administrator staat AAN maar er is nog geen werkende Clientadmin - niet uitgeschakeld.' }
    }
}

# ============================================================================
# STAP 3 - DEBLOAT
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
        Get-AppxPackage -AllUsers -Name $c.Name -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop
        }
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $c.Name } | ForEach-Object {
            Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null
        }
        return $true
    }
    $s = $c.Sw
    if ($s.Uninstall -match '(?i)msiexec' -and $s.Uninstall -match '\{[0-9A-Fa-f\-]{36}\}') {
        $guid = $Matches[0]
        $p = Start-Process msiexec.exe -ArgumentList "/x $guid /qn /norestart" -Wait -PassThru
        return ($p.ExitCode -in 0, 3010)
    }
    if ($s.QuietUninstall) {
        $p = Start-Process cmd.exe -ArgumentList "/c `"$($s.QuietUninstall)`"" -Wait -PassThru
        return ($p.ExitCode -in 0, 3010)
    }
    return $false
}

function Step-Debloat {
    Header 'Stap 3 - Debloat'
    if ($isHome) {
        Write-Host 'Windows Home: debloat enkel in overleg (zie ticket).' -ForegroundColor Red
        if (-not (Ask-YesNo 'Is de debloat besproken en mag je doorgaan?' $false)) { Say 'Debloat overgeslagen.' 'Yellow'; return }
    }
    $lvl = Ask-Choice 'Hoe zwaar debloaten?' @(
        'Licht   - trial-antivirus, adware, promo-spelletjes/social apps',
        'Medium  - + overbodige Microsoft-apps (Nieuws, Weer, Clipchamp, Solitaire, Teams consumer, Tips, Cortana, ...)',
        'Zwaar   - + Phone Link, Kaarten, Copilot, nieuwe Outlook, Office-proefversie, Family, ...',
        'Overslaan') 2
    if ($lvl -eq 4) { Say 'Debloat overgeslagen.' 'Yellow'; return }

    Say 'Zoeken naar kandidaten...' 'Gray'
    $cands = Get-DebloatCandidates -Level $lvl
    if ($cands.Count -eq 0) { Say 'Niets gevonden om te verwijderen.' 'Green'; return }

    Write-Host ''
    for ($i = 0; $i -lt $cands.Count; $i++) {
        Write-Host ("  {0,2}. [L{1}] {2,-10} {3}  - {4}" -f ($i + 1), $cands[$i].Level, $cands[$i].Kind, $cands[$i].Name, $cands[$i].Why)
    }
    Write-Host ''
    Say 'Enter = ALLES verwijderen | nummers = UITSLUITEN (bv. 3,7) | s = overslaan' 'Yellow'
    $ans = (Read-Host 'Keuze').Trim()
    if ($ans -eq 's') { Say 'Debloat overgeslagen.' 'Yellow'; return }
    $exclude = @()
    if ($ans) { $exclude = @($ans -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }) }

    for ($i = 0; $i -lt $cands.Count; $i++) {
        if ($exclude -contains ($i + 1)) { continue }
        $c = $cands[$i]
        Write-Host "  Verwijderen: $($c.Name) ..." -ForegroundColor Gray
        try {
            if (Remove-Candidate $c) { Log-Action "Verwijderd: $($c.Name)" }
            else { Warn-Action "Niet automatisch verwijderbaar (handmatig doen, evt. via vendor-removal tool): $($c.Name)" }
        }
        catch { Warn-Action "Mislukt: $($c.Name) - $($_.Exception.Message)" }
    }
    $script:NeedReboot = $true
}

# ============================================================================
# STAP 4 - SOFTWARE
# ============================================================================
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
        Log-Action 'Chocolatey geinstalleerd (fallback)'
        return [bool](Get-Command choco -ErrorAction SilentlyContinue)
    }
    catch { Warn-Action "Chocolatey installeren mislukt: $($_.Exception.Message)"; return $false }
}

function Install-Splashtop {
    $dl = Join-Path $env:USERPROFILE 'Downloads'
    $start = Get-Date
    Say '  Downloadpagina wordt geopend in de browser...' 'Cyan'
    Start-Process $SplashtopUrl
    Say '  Wachten op gedownload Splashtop-bestand (max 2 min)...' 'Gray'
    $file = $null
    for ($i = 0; $i -lt 24 -and -not $file; $i++) {
        Start-Sleep -Seconds 5
        $file = Get-ChildItem $dl -Filter '*Splashtop*.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $start.AddSeconds(-5) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if (-not $file) { return $false }
    Copy-Item $file.FullName (Join-Path 'C:\Users\Public\Desktop' $SplashtopDesktopName) -Force
    Log-Action "Splashtop SOS op bureaublad geplaatst als '$SplashtopDesktopName'"
    return $true
}

function Install-App {
    param($App)
    if ($App.Special -eq 'Splashtop') { return $(if (Install-Splashtop) { 'download' } else { $null }) }

    # 1. winget
    if ($App.Winget -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        $src = if ($App.Winget -match '^9[A-Z0-9]{11}$') { 'msstore' } else { 'winget' }
        Say "  winget ($src): $($App.Winget)" 'Gray'
        & winget install --id $App.Winget --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements --source $src
        if ($LASTEXITCODE -in 0, -1978335189, -1978335135) { return 'winget' }
        Say "  winget faalde (exit $LASTEXITCODE)" 'Yellow'
    }
    # 2. chocolatey
    if ($App.Choco) {
        if (Install-ChocolateyIfNeeded) {
            foreach ($id in @($App.Choco)) {
                Say "  chocolatey: $id" 'Gray'
                & choco install $id -y --no-progress
                if ($LASTEXITCODE -in 0, 1641, 3010) { return 'chocolatey' }
            }
        }
    }
    return $null
}

function Step-Software {
    Header 'Stap 4 - Software installeren'
    $list = @($AppCatalog | Where-Object { -not $_.Vendor -or $_.Vendor -eq $vendor })
    $sel = @{}
    for ($i = 0; $i -lt $list.Count; $i++) { $sel[$i] = (@($list[$i].Default) -contains $PcType) }

    while ($true) {
        Write-Host ''
        for ($i = 0; $i -lt $list.Count; $i++) {
            $mark = if ($sel[$i]) { '[x]' } else { '[ ]' }
            Write-Host ("  {0,2}. {1} {2}" -f ($i + 1), $mark, $list[$i].Name)
        }
        $a = (Read-Host "`nNummers om aan/uit te zetten (bv. 2,5) - Enter = starten, s = overslaan").Trim()
        if (-not $a) { break }
        if ($a -eq 's') { Say 'Software overgeslagen.' 'Yellow'; return }
        foreach ($t in ($a -split '[,\s]+')) { $n = 0; if ([int]::TryParse($t, [ref]$n) -and $n -ge 1 -and $n -le $list.Count) { $sel[$n - 1] = -not $sel[$n - 1] } }
    }

    $sw = @(Get-InstalledSoftware)
    for ($i = 0; $i -lt $list.Count; $i++) {
        if (-not $sel[$i]) { continue }
        $app = $list[$i]
        Header "[$($i + 1)/$($list.Count)] $($app.Name)"
        if (Test-AppInstalled $app $sw) { Say '  Reeds geinstalleerd - overgeslagen.' 'Green'; $script:InstallOk.Add($app.Name); continue }
        $method = Install-App $app
        if ($method) { $script:InstallOk.Add($app.Name); Log-Action "Geinstalleerd: $($app.Name) ($method)" }
        else { $script:InstallFail.Add($app.Name); Warn-Action "Installatie MISLUKT: $($app.Name) - handmatig installeren." }
    }
    if ($script:InstallFail.Count) { Say "`nMislukt: $($script:InstallFail -join ', ')" 'Red' }
}

# ============================================================================
# STAP 5 - UPDATES
# ============================================================================
function Step-Updates {
    Header 'Stap 5 - Windows Updates (PSWindowsUpdate)'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
        if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
            Say 'NuGet provider installeren...' 'Gray'
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:$false | Out-Null
        }
        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Say 'PSWindowsUpdate installeren...' 'Gray'
            Install-Module -Name PSWindowsUpdate -Force -Confirm:$false
        }
        Import-Module PSWindowsUpdate -ErrorAction Stop
    }
    catch { Warn-Action "PSWindowsUpdate niet beschikbaar: $($_.Exception.Message)"; return }

    Say 'Zoeken naar updates (kan even duren)...' 'Gray'
    $updates = @(Get-WindowsUpdate -MicrosoftUpdate -ErrorAction SilentlyContinue)
    if ($updates.Count -eq 0) { Say 'Geen updates meer beschikbaar - systeem is up-to-date.' 'Green'; Log-Action 'Windows: geen openstaande updates'; return }
    Say "$($updates.Count) update(s) gevonden:" 'Yellow'
    $updates | ForEach-Object { Write-Host "  - $($_.Title)" }
    if (-not (Ask-YesNo 'Alle updates installeren?')) { return }
    Get-WindowsUpdate -MicrosoftUpdate -Install -AcceptAll -IgnoreReboot | Out-Null
    $script:NeedReboot = $true
    Log-Action "Windows-updates geinstalleerd ($($updates.Count)); herstart en herhaal stap 5 tot er geen meer verschijnen"
    Say 'Denk ook aan fabrikant-tools (Lenovo Vantage / HP Image Assistant / Dell Command) en niet-Microsoft software.' 'Yellow'
}

# ============================================================================
# STAP 6 - CONTROLE (verificatie)
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

    Invoke-Safe 'Toestel' {
        Add-Check 'Toestel' 'Fabrikant / model' 'INFO' "$($cs.Manufacturer) $($cs.Model)"
        Add-Check 'Toestel' 'Productnummer (PN)' 'INFO' $cs.SystemSKUNumber
        Add-Check 'Toestel' 'Serienummer (SN)' 'INFO' $bios.SerialNumber
        Add-Check 'Toestel' 'BIOS-versie' 'INFO' "$($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate.ToString('dd/MM/yyyy')))"
        Add-Check 'Toestel' 'Processor' 'INFO' $cpu.Name.Trim()
        $ram = [math]::Round($cs.TotalPhysicalMemory / 1GB)
        $min = if ($PcType -eq 'Gaming') { 16 } else { 8 }
        Add-Check 'Toestel' 'Geheugen (RAM)' $(if ($ram -ge $min) { 'OK' } else { 'WARN' }) "$ram GB (verwacht minstens $min GB)"

        if ($effName.Length -gt $MaxHostnameLength) { Add-Check 'Toestel' 'Hostname' 'FAIL' "$effName ($($effName.Length) tekens, max $MaxHostnameLength)" }
        elseif ($ExpectedHostname -and $effName -ne $ExpectedHostname) { Add-Check 'Toestel' 'Hostname' 'FAIL' "Is '$effName', verwacht '$ExpectedHostname'" }
        elseif ($script:PendingName) { Add-Check 'Toestel' 'Hostname' 'WARN' "$effName - herstart nodig om door te voeren (huidig: $($env:COMPUTERNAME))" }
        else { Add-Check 'Toestel' 'Hostname' 'OK' $effName }

        $sys = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        $pct = [math]::Round(($sys.FreeSpace / $sys.Size) * 100)
        Add-Check 'Toestel' 'Schijf C: vrije ruimte' $(if ($pct -ge 20) { 'OK' } else { 'WARN' }) ("{0} GB vrij van {1} GB ({2}%)" -f [math]::Round($sys.FreeSpace / 1GB), [math]::Round($sys.Size / 1GB), $pct)
        foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
            Add-Check 'Toestel' "Schijfgezondheid: $($d.FriendlyName)" $(if ($d.HealthStatus -eq 'Healthy') { 'OK' } else { 'FAIL' }) "$($d.MediaType), $($d.HealthStatus), $([math]::Round($d.Size / 1GB)) GB"
        }
    }

    Invoke-Safe 'Windows' {
        Add-Check 'Windows' 'Editie / build' 'INFO' "$($os.Caption) (build $($os.BuildNumber))"
        $lic = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" | Where-Object { $_.LicenseStatus -eq 1 } | Select-Object -First 1
        Add-Check 'Windows' 'Activatie' $(if ($lic) { 'OK' } else { 'FAIL' }) $(if ($lic) { 'Geactiveerd' } else { 'NIET geactiveerd' })
        $ui = (Get-UICulture).Name
        Add-Check 'Windows' 'Weergavetaal' $(if ($ui -like 'nl-*') { 'OK' } else { 'WARN' }) $ui
        try { $g = Get-WinHomeLocation; Add-Check 'Windows' 'Land / regio' $(if ($g.GeoId -eq 21) { 'OK' } else { 'WARN' }) $g.HomeLocation } catch { }
        $tips = (Get-WinUserLanguageList | ForEach-Object { "$($_.LanguageTag): $($_.InputMethodTips -join ', ')" }) -join '; '
        Add-Check 'Windows' 'Toetsenbord (visueel testen!)' 'INFO' $tips
        $tz = Get-TimeZone
        Add-Check 'Windows' 'Tijdzone' $(if ($tz.Id -eq 'Romance Standard Time') { 'OK' } else { 'WARN' }) "$($tz.Id) - $($tz.DisplayName)"
        Add-Check 'Windows' 'Datum & tijd (vergelijk met gsm)' 'INFO' (Get-Date -Format 'dd/MM/yyyy HH:mm:ss')
    }

    Invoke-Safe 'Accounts' {
        $users = Get-LocalUser
        foreach ($u in $users) {
            if ($u.SID.Value -match '-(501|503|504)$') { continue }
            $adm = Test-LocalAdmin $u.Name
            $last = if ($u.LastLogon) { $u.LastLogon.ToString('dd/MM/yyyy HH:mm') } else { 'nooit' }
            $pwd = if ($u.PasswordLastSet) { $u.PasswordLastSet.ToString('dd/MM/yyyy') } else { 'n.v.t.' }
            Add-Check 'Accounts' "Account: $($u.Name)" 'INFO' "Actief: $($u.Enabled) | Admin: $adm | Bron: $($u.PrincipalSource) | Laatste login: $last | Wachtwoord gewijzigd: $pwd | Wachtwoord vereist: $($u.PasswordRequired)"
            if ($u.PrincipalSource -eq 'MicrosoftAccount') { Add-Check 'Accounts' "MS-account gekoppeld: $($u.Name)" 'WARN' 'Registreren in klantdossier + ticket.' }
        }
        $b = $users | Where-Object { $_.SID.Value -match '-500$' }
        if ($b) { Add-Check 'Accounts' 'Ingebouwde Administrator uitgeschakeld' $(if (-not $b.Enabled) { 'OK' } else { 'WARN' }) "Actief: $($b.Enabled)" }
        $g = $users | Where-Object { $_.SID.Value -match '-501$' }
        if ($g) { Add-Check 'Accounts' 'Gastaccount uitgeschakeld' $(if (-not $g.Enabled) { 'OK' } else { 'FAIL' }) "Actief: $($g.Enabled)" }
        $ca = $users | Where-Object { $_.Name -eq $AdminUser }
        if (-not $ca) { Add-Check 'Accounts' "Beheeraccount '$AdminUser'" 'FAIL' 'Niet gevonden' }
        else { $ok = $ca.Enabled -and (Test-LocalAdmin $AdminUser); Add-Check 'Accounts' "Beheeraccount '$AdminUser' actief + admin" $(if ($ok) { 'OK' } else { 'FAIL' }) "Actief: $($ca.Enabled)" }
        $cuN = if ($script:CustomerUserResolved) { $script:CustomerUserResolved } else { $CustomerUser }
        if ($cuN) {
            $cu = $users | Where-Object { $_.Name -eq $cuN }
            if (-not $cu) { Add-Check 'Accounts' "Klantaccount '$cuN'" 'FAIL' 'Niet gevonden' }
            else { Add-Check 'Accounts' "Klantaccount '$cuN' actief" $(if ($cu.Enabled) { 'OK' } else { 'FAIL' }) "Actief: $($cu.Enabled)" }
        }
        $na = (& net accounts 2>$null) | Where-Object { $_ -match '\S' } | Select-Object -First 8
        Add-Check 'Accounts' 'Wachtwoordbeleid (net accounts)' 'INFO' ($na -join "`n")
    }

    Invoke-Safe 'Netwerk' {
        foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
            $kind = if ($a.PhysicalMediaType -match '802.11') { 'WiFi' } elseif ($a.PhysicalMediaType -match '802.3') { 'LAN' } else { $a.PhysicalMediaType }
            Add-Check 'Netwerk' "Adapter ($kind): $($a.Name)" $(if ($a.Status -eq 'Up') { 'OK' } else { 'INFO' }) "$($a.Status) @ $($a.LinkSpeed)"
        }
        if (-not (Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.PhysicalMediaType -match '802.3' -and $_.Status -eq 'Up' })) {
            Add-Check 'Netwerk' 'LAN-verbinding getest' 'WARN' 'Geen actieve LAN - test met kabel indien LAN-poort aanwezig.'
        }
        Add-Check 'Netwerk' 'Internet (ping 1.1.1.1)' $(if (Test-Connection 1.1.1.1 -Count 2 -Quiet -ErrorAction SilentlyContinue) { 'OK' } else { 'FAIL' }) ''
    }

    Invoke-Safe 'Software' {
        $recent = $software | Where-Object { $_.InstallDate -and $_.InstallDate -ge $cutoff } | Sort-Object InstallDate -Descending
        $txt = if ($recent) { ($recent | ForEach-Object { "{0:dd/MM/yyyy}  {1} {2}" -f $_.InstallDate, $_.Name, $_.Version }) -join "`n" } else { 'Geen programma''s met installatiedatum in dit venster.' }
        Add-Check 'Software' "Recent geinstalleerd (laatste $Days dagen)" 'INFO' $txt
        $msi = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; Id = 11707; StartTime = $cutoff } -ErrorAction SilentlyContinue
        if ($msi) { Add-Check 'Software' 'MSI-installaties (eventlog)' 'INFO' (($msi | ForEach-Object { "{0:dd/MM/yyyy HH:mm}  {1}" -f $_.TimeCreated, (($_.Message -split "`n")[0] -replace 'Product: ', '') }) -join "`n") }

        foreach ($app in ($AppCatalog | Where-Object { (@($_.Default) -contains $PcType) -and (-not $_.Vendor -or $_.Vendor -eq $vendor) })) {
            if (-not $app.Match -and -not $app.Special) { continue }
            if (Test-AppInstalled $app $software) { Add-Check 'Software' "Standaard: $($app.Name)" 'OK' 'Aanwezig' }
            else { Add-Check 'Software' "Standaard: $($app.Name)" 'FAIL' 'Niet gevonden (kan per-gebruiker zijn - controleer manueel)' }
        }
        $tm = $software | Where-Object { Test-NameMatch $_.Name '*Trend Micro*|*Worry-Free*|*Security Agent*|*Apex One*' } | Select-Object -First 1
        if ($tm) { Add-Check 'Software' 'Trend Micro' 'OK' $tm.Name } else { Add-Check 'Software' 'Trend Micro' 'WARN' 'Niet gevonden (Client ID koppelen aan Autotask!)' }
        $dt = $software | Where-Object { Test-NameMatch $_.Name '*Datto*|*CentraStage*|*Autotask Endpoint*' } | Select-Object -First 1
        Add-Check 'Software' 'Datto RMM' 'INFO' $(if ($dt) { $dt.Name } else { 'Niet geinstalleerd (enkel bij servicecontract)' })

        $left = @(Get-InstalledSoftware | Where-Object { $_.Name -match 'McAfee|Norton|WildTangent|ExpressVPN|Avast|AVG|WebAdvisor' })
        $leftAppx = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'CandyCrush|TikTok|Disney|Netflix|Booking|Facebook|Instagram|McAfee|Norton' -and -not $_.IsFramework } | Select-Object -ExpandProperty Name -Unique)
        if ($left.Count -or $leftAppx.Count) { Add-Check 'Software' 'Resterende bloatware' 'WARN' ((@($left | ForEach-Object { "Programma: $($_.Name)" }) + @($leftAppx | ForEach-Object { "Store-app: $_" })) -join "`n") }
        else { Add-Check 'Software' 'Bloatware' 'OK' 'Geen bekende bloatware gevonden' }
        $su = Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue
        if ($su) { Add-Check 'Software' "Opstartitems ($(@($su).Count))" $(if (@($su).Count -le 12) { 'INFO' } else { 'WARN' }) (($su | ForEach-Object { $_.Name }) -join ', ') }
    }

    Invoke-Safe 'Beveiliging' {
        $av = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue)
        if ($av.Count -eq 0) { Add-Check 'Beveiliging' 'Antivirus' 'FAIL' 'Geen antivirus gedetecteerd' }
        else { Add-Check 'Beveiliging' 'Antivirus' $(if ($av.Count -eq 1) { 'OK' } else { 'WARN' }) ((($av | ForEach-Object { $_.displayName }) -join ', ') + $(if ($av.Count -gt 1) { ' (meerdere AV-producten!)' } else { '' })) }
        $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
        if ($mp) { Add-Check 'Beveiliging' 'Defender definities' $(if ($mp.AntivirusSignatureAge -le 3) { 'OK' } else { 'WARN' }) "Leeftijd: $($mp.AntivirusSignatureAge) dag(en), realtime: $($mp.RealTimeProtectionEnabled)" }
        $off = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Enabled })
        Add-Check 'Beveiliging' 'Windows Firewall' $(if ($off.Count) { 'WARN' } else { 'OK' }) $(if ($off.Count) { "Uit: $(($off.Name) -join ', ')" } else { 'Alle profielen actief' })
        $uac = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).EnableLUA
        Add-Check 'Beveiliging' 'UAC' $(if ($uac -eq 1) { 'OK' } else { 'WARN' }) "EnableLUA = $uac"
        try { $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop; Add-Check 'Beveiliging' 'BitLocker / versleuteling C:' 'INFO' "$($bl.ProtectionStatus) - herstelsleutel bewaren indien actief!" }
        catch { Add-Check 'Beveiliging' 'BitLocker / versleuteling C:' 'INFO' 'Niet beschikbaar/actief (normaal op Home)' }
    }

    Invoke-Safe 'Updates' {
        $pend = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        Add-Check 'Updates' 'Herstart in afwachting' $(if ($pend) { 'WARN' } else { 'OK' }) $(if ($pend) { 'Herstart de pc' } else { 'Geen' })
        $hf = Get-HotFix -ErrorAction SilentlyContinue | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1
        if ($hf) { Add-Check 'Updates' 'Laatste Windows-update' $(if ($hf.InstalledOn -ge (Get-Date).AddDays(-45)) { 'OK' } else { 'WARN' }) "$($hf.HotFixID) op $($hf.InstalledOn.ToString('dd/MM/yyyy'))" }
        if ($script:UpdatesChecked) {
            Add-Check 'Updates' 'Openstaande updates' $(if ($script:PendingUpdateCount -eq 0) { 'OK' } else { 'FAIL' }) "$($script:PendingUpdateCount) openstaand"
        }
        else {
            try {
                $res = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0')
                $titles = for ($i = 0; $i -lt $res.Updates.Count; $i++) { $res.Updates.Item($i).Title }
                Add-Check 'Updates' 'Openstaande updates' $(if ($res.Updates.Count -eq 0) { 'OK' } else { 'FAIL' }) $(if ($res.Updates.Count) { $titles -join "`n" } else { 'Geen - up-to-date' })
            }
            catch { Add-Check 'Updates' 'Openstaande updates' 'INFO' 'Kon niet gecontroleerd worden' }
        }
    }

    Invoke-Safe 'Energie' {
        $fs = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled
        Add-Check 'Energie' 'Snel opstarten UIT' $(if ($fs -eq 0) { 'OK' } else { 'FAIL' }) $(if ($fs -eq 0) { 'Uitgeschakeld' } else { 'Staat AAN' })
        $scheme = (& powercfg /getactivescheme) -join ' '
        Add-Check 'Energie' 'Actief energieplan' $(if ($scheme -match 'Power saver|Energiespaarstand|a1841308') { 'WARN' } else { 'INFO' }) $scheme
    }

    Invoke-Safe 'Hardware' {
        $bad = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
        if ($bad.Count) { Add-Check 'Hardware' 'Apparaten met driverprobleem' 'FAIL' (($bad | ForEach-Object { "$($_.Name) (code $($_.ConfigManagerErrorCode))" }) -join "`n") }
        else { Add-Check 'Hardware' 'Apparaten met driverprobleem' 'OK' 'Geen' }
        $gpus = @(Get-CimInstance Win32_VideoController)
        foreach ($g in $gpus) {
            $dd = if ($g.DriverDate) { $g.DriverDate.ToString('dd/MM/yyyy') } else { '?' }
            $res = if ($g.CurrentHorizontalResolution) { "$($g.CurrentHorizontalResolution)x$($g.CurrentVerticalResolution) @ $($g.CurrentRefreshRate) Hz" } else { 'geen actief scherm' }
            $st = if ($PcType -eq 'Gaming' -and $g.DriverDate -and $g.DriverDate -lt (Get-Date).AddDays(-120) -and $g.Name -match 'NVIDIA|Radeon') { 'WARN' } else { 'INFO' }
            Add-Check 'Hardware' "Grafische kaart: $($g.Name)" $st "Driver $($g.DriverVersion) van $dd | $res"
        }
        if ($PcType -eq 'Gaming' -and -not ($gpus | Where-Object { $_.Name -match 'NVIDIA|Radeon RX|Radeon Pro|Arc' })) { Add-Check 'Hardware' 'Dedicated GPU' 'FAIL' 'Geen dedicated GPU gedetecteerd' }
        $audio = @(Get-PnpDevice -Class AudioEndpoint -Status OK -ErrorAction SilentlyContinue)
        Add-Check 'Hardware' 'Audio-apparaten' $(if ($audio.Count) { 'INFO' } else { 'WARN' }) (($audio.FriendlyName) -join "`n")
        $cam = @(Get-PnpDevice -Class Camera, Image -Status OK -ErrorAction SilentlyContinue)
        Add-Check 'Hardware' 'Webcam' 'INFO' $(if ($cam.Count) { ($cam.FriendlyName) -join ', ' } else { 'Geen gedetecteerd' })
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
        Add-Check 'Bureaublad' 'Lipa-supportsnelkoppeling (SOS Lipa)' $(if ($has) { 'OK' } else { 'WARN' }) $(if ($has) { 'Aanwezig' } else { 'Niet gevonden' })
    }
}

# ============================================================================
# RAPPORT + TICKET
# ============================================================================
$TodoList = @(
    'Voorzie labels op het toestel en doos',
    'Noteer serienummers van producten',
    'Test hardware: camera, microfoon, headset/speakers, card reader, wifi, voeding/kabel, extra devices (scherm, printer, ...)',
    'Update klantendossier -> lokale gebruikerswachtwoorden',
    'Update klantendossier -> Trend Micro (enkel bij nieuwe TM-klant) + Client ID koppelen in Autotask',
    'Update klantendossier -> M365 (enkel bij nieuwe licentie, admin account) + MS-account registreren + afdruk klant',
    'Voeg credentials toe aan Keeper (lokale accounts, M365, enz.)',
    'Voeg Datto toe (indien servicecontract)',
    'Data overgezet / backup ingesteld (indien afgesproken)',
    'Lipa-media verwijderd en terug in LIPA-archief',
    'Toestel gepoetst + ingepakt (kabels, accessoires, monitor, keyboard)',
    'Lipa-sticker op toestel gekleefd',
    'Tag sales in het ticket als je klaar bent (Bieke en Leen)',
    'Ticket laten controleren door verantwoordelijke',
    'Klant verwittigd (datum + tijd telefoontje noteren)',
    'Toestel klaargezet voor afhaling + werkbon erbij',
    'Ga nog eens over ticket, klantendossier en Keeper'
)
if ($PcType -eq 'Gaming') {
    $TodoList += 'Gaming: monitor op max Hz + gewenste resolutie (Windows > Geavanceerde weergave)'
    $TodoList += 'Gaming: GPU-driver recent, XMP/EXPO in BIOS gecontroleerd, temperaturen onder load OK'
    $TodoList += 'Gaming: Steam/Epic klaar voor klant, headset getest'
}

function New-TicketText {
    $cs = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
    $gpu = ((Get-CimInstance Win32_VideoController | Sort-Object { $_.Name -notmatch 'NVIDIA|Radeon RX|Arc' }) | Select-Object -First 1).Name
    $ram = [math]::Round($cs.TotalPhysicalMemory / 1GB)
    $disk = [math]::Round((Get-CimInstance Win32_DiskDrive | Measure-Object Size -Sum).Sum / 1GB)
    $effName = if ($script:PendingName) { $script:PendingName } else { $env:COMPUTERNAME }
    $devId = try { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SQMClient' -ErrorAction Stop).MachineId } catch { '' }
    $prodId = try { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').ProductId } catch { '' }
    $geo = try { (Get-WinHomeLocation).HomeLocation } catch { '' }
    $kb = try { (Get-WinUserLanguageList | ForEach-Object { $_.InputMethodTips -join ',' }) -join '; ' } catch { '' }
    $locals = (Get-LocalUser | Where-Object { $_.Enabled -and $_.SID.Value -notmatch '-(500|501|503|504)$' } | ForEach-Object { $_.Name }) -join ', '
    $ts = (Get-TimeZone).Id

    $L = New-Object System.Collections.Generic.List[string]
    $L.Add('Klant- en Apparaatgegevens:')
    $L.Add("Klant: $CustomerName")
    $L.Add("Apparaat: $($cs.Model)")
    $L.Add("Productnummer (PN): $($cs.SystemSKUNumber)")
    $L.Add("Serienummer (SN): $($bios.SerialNumber)")
    $L.Add("Hostname: $effName")
    $L.Add("BIOS-versie: $($bios.SMBIOSBIOSVersion)")
    $L.Add('')
    $L.Add('Systeemspecificaties:')
    $L.Add("Processor: $cpu")
    $L.Add("Grafische kaart: $gpu")
    $L.Add("Geheugen (RAM): $ram GB")
    $L.Add("Opslag: $disk GB")
    $L.Add("Apparaat-ID: $devId")
    $L.Add("Product-ID: $prodId")
    $L.Add('')
    $L.Add('Configuratie & Systeeminstellingen:')
    $L.Add("Windows: $((Get-CimInstance Win32_OperatingSystem).Caption)")
    $L.Add("Regio & Toetsenbord: $geo / $kb")
    $L.Add("Tijdzone: $ts")
    $L.Add("Lokale accounts: $locals + $AdminUser")
    $L.Add('Snel opstarten: uitgeschakeld')
    $L.Add('')
    $L.Add('Uitgevoerde handelingen:')
    if ($script:ActionLog.Count) { foreach ($a in $script:ActionLog) { $L.Add("- $a") } } else { $L.Add('- (geen wijzigingen via script)') }
    if ($script:InstallOk.Count) { $L.Add(''); $L.Add('Geinstalleerde software:'); foreach ($a in ($script:InstallOk | Sort-Object -Unique)) { $L.Add("- $a") } }
    if ($script:InstallFail.Count) { $L.Add(''); $L.Add('NIET geinstalleerd (manueel doen):'); foreach ($a in $script:InstallFail) { $L.Add("- $a") } }
    $issues = @($script:Results | Where-Object { $_.Status -in 'WARN', 'FAIL' })
    if ($issues.Count) { $L.Add(''); $L.Add('Openstaande aandachtspunten (uit controle):'); foreach ($i in $issues) { $L.Add("- [$($i.Status)] $($i.Item)") } }
    $L.Add('')
    $L.Add('Aangemeld bij MS365: ________    Outlook: ________    OneDrive: ________')
    $L.Add('Trend Micro geinstalleerd en geactiveerd: ________')
    $L.Add('')
    $L.Add('Internal Only')
    $names = @($AdminUser) + @($locals -split ', ' | Where-Object { $_ })
    foreach ($n in ($names | Sort-Object -Unique)) {
        $c = $script:Creds | Where-Object { $_.User -eq $n } | Select-Object -Last 1
        if ($c -and $IncludePasswordsInTicket) { $L.Add("Lokale gebruiker $n -> $($c.Password)") }
        else { $L.Add("Lokale gebruiker $n -> (wachtwoord in Keeper: ______________)") }
    }
    $L.Add('')
    $L.Add('TODO:')
    foreach ($t in $TodoList) { $L.Add("- [ ] $t") }
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
    $verdict = if ($cnt.FAIL) { 'NIET KLAAR - er zijn FAIL-punten op te lossen' } elseif ($cnt.WARN) { 'KLAAR MET OPMERKINGEN - controleer de WARN-punten' } else { 'AUTOMATISCH OK - rond de handmatige punten af' }

    # --- TXT
    $sym = @{ OK = '[ OK ]'; WARN = '[WARN]'; FAIL = '[FAIL]'; INFO = '[INFO]' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('OVERDRACHTSCONTROLE'); [void]$sb.AppendLine('===================')
    [void]$sb.AppendLine("Ticket     : $TicketNr"); [void]$sb.AppendLine("Klant      : $CustomerName")
    [void]$sb.AppendLine("Type       : $PcType-pc"); [void]$sb.AppendLine("Hostname   : $effName")
    [void]$sb.AppendLine("PN / SN    : $($cs.SystemSKUNumber) / $($bios.SerialNumber)")
    [void]$sb.AppendLine("Controle   : $(Get-Date -Format 'dd/MM/yyyy HH:mm') door $env:USERNAME")
    [void]$sb.AppendLine("Resultaat  : $verdict")
    [void]$sb.AppendLine("Totaal     : $($cnt.OK) OK | $($cnt.WARN) WARN | $($cnt.FAIL) FAIL"); [void]$sb.AppendLine('')
    foreach ($grp in ($script:Results | Group-Object Section -NoElement | ForEach-Object { $_.Name })) {
        [void]$sb.AppendLine("--- $grp ---")
        foreach ($r in ($script:Results | Where-Object Section -eq $grp)) {
            [void]$sb.AppendLine("$($sym[$r.Status]) $($r.Item)")
            foreach ($line in ($r.Detail -split "`r?`n")) { if ($line.Trim()) { [void]$sb.AppendLine("        $line") } }
        }
        [void]$sb.AppendLine('')
    }
    if ($script:ActionLog.Count) { [void]$sb.AppendLine('--- UITGEVOERDE HANDELINGEN DOOR SCRIPT ---'); foreach ($a in $script:ActionLog) { [void]$sb.AppendLine("- $a") }; [void]$sb.AppendLine('') }
    [void]$sb.AppendLine('--- WACHTWOORDEN / TOEGANG (zelf invullen; script schrijft geen wachtwoorden weg) ---')
    foreach ($n in (@($AdminUser) + @(Get-LocalUser | Where-Object { $_.Enabled -and $_.SID.Value -notmatch '-(500|501|503|504)$' } | ForEach-Object { $_.Name }) | Sort-Object -Unique)) {
        [void]$sb.AppendLine("Account $n  -> opgeslagen in: ____________________")
    }
    [void]$sb.AppendLine('MS-account (e-mail) : ____________________  opgeslagen in: ____________________')
    [void]$sb.AppendLine('BIOS-wachtwoord     : [ ] geen  [ ] ja, in: ____________________')
    [void]$sb.AppendLine('Trend Micro Client ID: ____________________'); [void]$sb.AppendLine('')
    [void]$sb.AppendLine('--- HANDMATIGE CHECKLIST ---')
    foreach ($t in $TodoList) { [void]$sb.AppendLine("[ ] $t") }
    $txtPath = "$base.txt"
    $sb.ToString() | Out-File -FilePath $txtPath -Encoding UTF8

    # --- Ticket-tekst
    $ticketPath = Join-Path $OutDir "Ticket_${effName}_$stamp.txt"
    $ticket = New-TicketText
    $ticket | Out-File -FilePath $ticketPath -Encoding UTF8

    # --- HTML
    $he = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $col = @{ OK = '#d9f2d9'; WARN = '#fff3cd'; FAIL = '#f8d7da'; INFO = '#eef2f7' }
    $h = New-Object System.Text.StringBuilder
    [void]$h.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"><title>Overdrachtscontrole</title><style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}table{border-collapse:collapse;width:100%;margin-bottom:20px}td,th{border:1px solid #ccc;padding:6px 8px;vertical-align:top;font-size:13px}th{background:#333;color:#fff;text-align:left}pre{margin:0;font-family:Consolas,monospace;white-space:pre-wrap}.v{font-size:18px;font-weight:bold;padding:10px;border-radius:6px;background:#eef2f7}</style></head><body>')
    [void]$h.AppendLine("<h1>Overdrachtscontrole - $(& $he $effName)</h1><p>Ticket <b>$(& $he $TicketNr)</b> | Klant <b>$(& $he $CustomerName)</b> | $PcType | PN/SN $(& $he $cs.SystemSKUNumber) / $(& $he $bios.SerialNumber) | $(Get-Date -Format 'dd/MM/yyyy HH:mm')</p>")
    [void]$h.AppendLine("<div class='v'>$(& $he $verdict) &mdash; $($cnt.OK) OK | $($cnt.WARN) WARN | $($cnt.FAIL) FAIL</div>")
    foreach ($grp in ($script:Results | Group-Object Section -NoElement | ForEach-Object { $_.Name })) {
        [void]$h.AppendLine("<h2>$(& $he $grp)</h2><table><tr><th style='width:70px'>Status</th><th style='width:32%'>Controle</th><th>Details</th></tr>")
        foreach ($r in ($script:Results | Where-Object Section -eq $grp)) {
            [void]$h.AppendLine("<tr style='background:$($col[$r.Status])'><td><b>$($r.Status)</b></td><td>$(& $he $r.Item)</td><td><pre>$(& $he $r.Detail)</pre></td></tr>")
        }
        [void]$h.AppendLine('</table>')
    }
    [void]$h.AppendLine('<h2>Handmatige checklist</h2><ul style="list-style:none;padding-left:0">')
    foreach ($t in $TodoList) { [void]$h.AppendLine("<li>&#9744; $(& $he $t)</li>") }
    [void]$h.AppendLine('</ul></body></html>')
    $htmlPath = "$base.html"
    $h.ToString() | Out-File -FilePath $htmlPath -Encoding UTF8

    if ($CopyToClipboard) { $ticket | Set-Clipboard; Say 'Ticket-tekst gekopieerd naar klembord.' 'Yellow' }

    Write-Host ''
    Write-Host "RESULTAAT: $verdict" -ForegroundColor $(if ($cnt.FAIL) { 'Red' } elseif ($cnt.WARN) { 'Yellow' } else { 'Green' })
    Say "  $($cnt.OK) OK | $($cnt.WARN) WARN | $($cnt.FAIL) FAIL"
    Say "  Ticket-tekst : $ticketPath"
    Say "  Controle txt : $txtPath"
    Say "  Controle html: $htmlPath"
    Start-Process $htmlPath -ErrorAction SilentlyContinue
}

function Step-Report {
    Header 'Stap 6 - Controle + rapport'
    Say 'Controles uitvoeren (even geduld)...' 'Gray'
    Invoke-Verification
    Write-Reports
}

function Show-Credentials {
    if ($script:Creds.Count -eq 0) { return }
    Header 'WACHTWOORDEN VAN DEZE SESSIE - noteer ze NU in Keeper'
    foreach ($c in $script:Creds) { Write-Host ("  {0,-20} {1}" -f $c.User, $c.Password) -ForegroundColor Yellow }
    Write-Host ''
    Say 'Ze worden niet opgeslagen. Druk Enter als ze in Keeper staan (scherm wordt gewist).' 'Gray'
    [void](Read-Host)
    Clear-Host
}

# ============================================================================
# MAIN
# ============================================================================
$StepNames = @{
    1 = 'Basis (naam, tijdzone, regio, tijdsync, snel opstarten, firewall, energieplan)'
    2 = 'Accounts (Clientadmin + klantaccount)'
    3 = 'Debloat'
    4 = 'Software installeren'
    5 = 'Windows Updates'
    6 = 'Controle + rapport + ticket-tekst'
}
if ($VerifyOnly) { $Run = @(6) }
elseif (-not $Run) {
    Write-Host ''
    1..6 | ForEach-Object { Write-Host ("  {0}. {1}" -f $_, $StepNames[$_]) }
    $a = Read-Host "`nWelke stappen? (Enter = alle, of bv. 1,2,6)"
    $Run = if ([string]::IsNullOrWhiteSpace($a)) { 1..6 } else { @($a -split '[,\s]+' | Where-Object { $_ -match '^[1-6]$' } | ForEach-Object { [int]$_ }) }
}

foreach ($s in ($Run | Sort-Object -Unique)) {
    switch ($s) {
        1 { Step-Basis }
        2 { Step-Accounts }
        3 { Step-Debloat }
        4 { Step-Software }
        5 { Step-Updates }
        6 { Step-Report }
    }
}

Show-Credentials

if ($script:NeedReboot) {
    Say 'Een herstart is nodig (naamswijziging / verwijderde software / updates).' 'Yellow'
    Say 'Na de herstart: .\Lipa-Setup-and-Handover.ps1 -VerifyOnly  (en herhaal -Run 5 tot er geen updates meer zijn)' 'Yellow'
    if (Ask-YesNo 'Nu herstarten?' $false) { Restart-Computer -Force }
}
