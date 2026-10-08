<#
.SYNOPSIS
    Overdrachtscontrole (handover check) voor een nieuwe/geconfigureerde Windows-pc.

.DESCRIPTION
    Controleert automatisch: toestelgegevens, Windows (activatie/taal/toetsenbord/tijd),
    lokale accounts, netwerk, recent geinstalleerde software (laatste X dagen), verplichte
    software, bloatware, beveiliging, updates, energiebeheer, drivers/hardware, foutlogs
    en bureaublad. Maakt een rapport (.txt voor in het ticket + .html) met:
      - automatische controles (OK / WARN / FAIL / INFO)
      - invulblok voor wachtwoorden (WORDEN NIET AUTOMATISCH OPGEHAALD)
      - handmatige checklist (stickers, klant verwittigen, serienummers, ...)

.EXAMPLE
    .\Lipa-Handover-Check.ps1 -PcType Gaming -CustomerUser Sam -TicketNr T20261007.0003 -ExpectedHostname LOQ-261007

.EXAMPLE
    .\Lipa-Handover-Check.ps1 -PcType Werk -CustomerUser jan -Days 7 -CheckWindowsUpdate -CopyToClipboard

.NOTES
    Uitvoeren als Administrator (rechtsklik > Als administrator uitvoeren).
    Indien scripts geblokkeerd zijn:
      powershell -ExecutionPolicy Bypass -File .\Lipa-Handover-Check.ps1 -PcType Gaming
#>
[CmdletBinding()]
param(
    [ValidateSet('Gaming', 'Werk')]
    [string]$PcType = 'Werk',

    [int]$Days = 14,                       # "recent geinstalleerd" venster
    [string]$CustomerUser,                 # naam van het klantaccount (bv. Sam)
    [string]$AdminUser = 'Clientadmin',    # naam van het beheeraccount
    [string]$TicketNr,
    [string]$CustomerName,
    [string]$ExpectedHostname,
    [string]$OutDir = [Environment]::GetFolderPath('Desktop'),
    [switch]$CheckWindowsUpdate,           # zoekt ook naar openstaande updates (kan enkele minuten duren)
    [switch]$CopyToClipboard
)

# ----------------------------------------------------------------------------
# CONFIG - pas aan naar eigen standaard
# ----------------------------------------------------------------------------
$MaxHostnameLength = 16

# Software die op ELK toestel verwacht wordt: Naam, Patroon in DisplayName, optioneel pad
$RequiredCommon = @(
    @{ Name = 'Adobe Acrobat / Reader'; Pattern = '*Acrobat*'; Path = $null },
    @{ Name = 'Google Chrome';          Pattern = '*Google Chrome*'; Path = 'C:\Program Files\Google\Chrome\Application\chrome.exe' },
    @{ Name = 'Mozilla Firefox';        Pattern = '*Firefox*'; Path = 'C:\Program Files\Mozilla Firefox\firefox.exe' }
)
# Extra voor gaming-pc
$RequiredGaming = @(
    @{ Name = 'Steam';               Pattern = 'Steam';              Path = 'C:\Program Files (x86)\Steam\steam.exe' },
    @{ Name = 'Epic Games Launcher'; Pattern = '*Epic Games Launcher*'; Path = 'C:\Program Files (x86)\Epic Games\Launcher\Portal\Binaries\Win32\EpicGamesLauncher.exe' },
    @{ Name = 'NVIDIA/AMD GPU-driver'; Pattern = '*NVIDIA Graphics Driver*|*AMD Software*|*Radeon Software*'; Path = $null }
)
# Management/beveiliging (alleen waarschuwing indien niet gevonden)
$ManagementTools = @(
    @{ Name = 'Trend Micro (Worry-Free/Apex)'; Pattern = '*Trend Micro*|*Worry-Free*|*Security Agent*|*Apex One*' },
    @{ Name = 'Remote support (Splashtop/Datto)'; Pattern = '*Splashtop*|*Datto*|*CentraStage*|*Autotask Endpoint*' }
)
# Bloatware / ongewenste software (WARN indien gevonden - verwijderen in overleg!)
$BloatPatterns = 'McAfee|Norton|WildTangent|ExpressVPN|Avast|AVG |Kaspersky|Candy|TikTok|Disney|Netflix|Booking|Amazon Prime|Spotify|Facebook|Instagram|LinkedIn|Dropbox promotion|WebAdvisor|Opera Browser|CyberLink|Bing'
# ----------------------------------------------------------------------------

$ErrorActionPreference = 'Continue'
$script:Results = New-Object System.Collections.Generic.List[object]
$script:RealAccounts = New-Object System.Collections.Generic.List[string]
$cutoff = (Get-Date).AddDays(-$Days)

function Add-Check {
    param(
        [string]$Section,
        [string]$Item,
        [ValidateSet('OK', 'WARN', 'FAIL', 'INFO')][string]$Status,
        [string]$Detail = ''
    )
    $script:Results.Add([pscustomobject]@{
            Section = $Section; Item = $Item; Status = $Status; Detail = [string]$Detail
        })
}

function Invoke-Section {
    param([string]$Name, [scriptblock]$Code)
    Write-Host "  - $Name ..." -ForegroundColor Cyan
    try { & $Code }
    catch { Add-Check $Name 'Sectie niet volledig uitgevoerd' 'WARN' $_.Exception.Message }
}

function Get-InstalledSoftware {
    $paths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent } |
        ForEach-Object {
            $d = $null
            if ($_.InstallDate -match '^\d{8}$') {
                try { $d = [datetime]::ParseExact($_.InstallDate, 'yyyyMMdd', $null) } catch { }
            }
            [pscustomobject]@{
                Name        = $_.DisplayName
                Version     = $_.DisplayVersion
                Publisher   = $_.Publisher
                InstallDate = $d
            }
        } | Sort-Object Name -Unique
}

function Test-NameMatch {
    param([string]$Name, [string]$PatternList)
    foreach ($p in ($PatternList -split '\|')) { if ($Name -like $p) { return $true } }
    return $false
}

# --- Admin check ------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning 'Script draait NIET als Administrator - sommige controles zullen mislukken.'
}

Write-Host "Overdrachtscontrole gestart ($PcType-pc, laatste $Days dagen)" -ForegroundColor Green

# ============================================================================
# 1. TOESTEL
# ============================================================================
$cs = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$os = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$hostName = $env:COMPUTERNAME

Invoke-Section 'Toestel' {
    Add-Check 'Toestel' 'Fabrikant / model' 'INFO' "$($cs.Manufacturer) $($cs.Model)"
    Add-Check 'Toestel' 'Productnummer (PN)' 'INFO' $cs.SystemSKUNumber
    Add-Check 'Toestel' 'Serienummer (SN)' 'INFO' $bios.SerialNumber
    Add-Check 'Toestel' 'BIOS-versie' 'INFO' "$($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate.ToString('dd/MM/yyyy')))"
    Add-Check 'Toestel' 'Processor' 'INFO' $cpu.Name.Trim()
    $ram = [math]::Round($cs.TotalPhysicalMemory / 1GB)
    $ramMin = if ($PcType -eq 'Gaming') { 16 } else { 8 }
    $st = if ($ram -ge $ramMin) { 'OK' } else { 'WARN' }
    Add-Check 'Toestel' 'Geheugen (RAM)' $st "$ram GB (verwacht minstens $ramMin GB)"

    # Hostname
    $len = $hostName.Length
    if ($len -gt $MaxHostnameLength) {
        Add-Check 'Toestel' 'Hostname' 'FAIL' "$hostName ($len tekens, max $MaxHostnameLength)"
    }
    elseif ($ExpectedHostname -and $hostName -ne $ExpectedHostname) {
        Add-Check 'Toestel' 'Hostname' 'FAIL' "Is '$hostName', verwacht '$ExpectedHostname'"
    }
    else {
        Add-Check 'Toestel' 'Hostname' 'OK' $hostName
    }

    # Opslag
    $sys = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $freePct = [math]::Round(($sys.FreeSpace / $sys.Size) * 100)
    $st = if ($freePct -ge 20) { 'OK' } else { 'WARN' }
    Add-Check 'Toestel' 'Schijf C: vrije ruimte' $st ("{0} GB vrij van {1} GB ({2}%)" -f [math]::Round($sys.FreeSpace / 1GB), [math]::Round($sys.Size / 1GB), $freePct)

    $pd = Get-PhysicalDisk -ErrorAction SilentlyContinue
    foreach ($d in $pd) {
        $st = if ($d.HealthStatus -eq 'Healthy') { 'OK' } else { 'FAIL' }
        Add-Check 'Toestel' "Schijf gezondheid: $($d.FriendlyName)" $st "$($d.MediaType), $($d.HealthStatus), $([math]::Round($d.Size/1GB)) GB"
    }
    Add-Check 'Toestel' 'Laatste opstart / uptime' 'INFO' ("{0:dd/MM/yyyy HH:mm}" -f $os.LastBootUpTime)
}

# ============================================================================
# 2. WINDOWS
# ============================================================================
Invoke-Section 'Windows' {
    $edition = $os.Caption
    Add-Check 'Windows' 'Editie / build' 'INFO' "$edition (build $($os.BuildNumber))"
    if ($edition -match 'Home') {
        Add-Check 'Windows' 'Windows Home - opgelet' 'INFO' 'Home PC: geen clean install, opletten met MS personal accounts.'
    }

    $lic = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" |
        Where-Object { $_.LicenseStatus -eq 1 } | Select-Object -First 1
    if ($lic) { Add-Check 'Windows' 'Activatie' 'OK' 'Windows is geactiveerd' }
    else { Add-Check 'Windows' 'Activatie' 'FAIL' 'Windows is NIET geactiveerd' }

    $ui = (Get-UICulture).Name
    $st = if ($ui -like 'nl-*') { 'OK' } else { 'WARN' }
    Add-Check 'Windows' 'Weergavetaal' $st $ui

    try {
        $geo = Get-WinHomeLocation
        $st = if ($geo.GeoId -eq 21) { 'OK' } else { 'WARN' }
        Add-Check 'Windows' 'Land / regio' $st $geo.HomeLocation
    }
    catch { }

    $langs = Get-WinUserLanguageList
    $tips = ($langs | ForEach-Object { "$($_.LanguageTag): $($_.InputMethodTips -join ', ')" }) -join '; '
    Add-Check 'Windows' 'Toetsenbord (controleer visueel!)' 'INFO' $tips

    $tz = Get-TimeZone
    $st = if ($tz.Id -eq 'Romance Standard Time') { 'OK' } else { 'WARN' }
    Add-Check 'Windows' 'Tijdzone' $st "$($tz.Id) - $($tz.DisplayName)"
    Add-Check 'Windows' 'Datum & tijd (vergelijk met je gsm)' 'INFO' (Get-Date -Format 'dd/MM/yyyy HH:mm:ss')

    $w32 = Get-Service w32time -ErrorAction SilentlyContinue
    if ($w32) {
        $st = if ($w32.Status -eq 'Running') { 'OK' } else { 'WARN' }
        Add-Check 'Windows' 'Tijdsynchronisatie-service' $st $w32.Status
    }
}

# ============================================================================
# 3. ACCOUNTS
# ============================================================================
Invoke-Section 'Accounts' {
    $adminNames = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue |
            ForEach-Object { ($_.Name -split '\\')[-1] })
    $users = Get-LocalUser

    foreach ($u in $users) {
        $sid = $u.SID.Value
        if ($sid -match '-(501|503|504)$') { continue }   # Guest, DefaultAccount, WDAGUtility
        $isBuiltinAdmin = $sid -match '-500$'
        $isAdminMember = $adminNames -contains $u.Name
        $last = if ($u.LastLogon) { $u.LastLogon.ToString('dd/MM/yyyy HH:mm') } else { 'nooit' }
        $pw = if ($u.PasswordLastSet) { $u.PasswordLastSet.ToString('dd/MM/yyyy') } else { 'n.v.t.' }
        $detail = "Actief: $($u.Enabled) | Admin: $isAdminMember | Bron: $($u.PrincipalSource) | Laatste login: $last | Wachtwoord gewijzigd: $pw | Wachtwoord vereist: $($u.PasswordRequired)"
        Add-Check 'Accounts' "Account: $($u.Name)" 'INFO' $detail
        if ($u.Enabled -and -not $isBuiltinAdmin) { $script:RealAccounts.Add($u.Name) }

        if ($u.PrincipalSource -eq 'MicrosoftAccount') {
            Add-Check 'Accounts' "MS-account gekoppeld: $($u.Name)" 'WARN' 'Microsoft-account aanwezig - registreren in klantdossier + ticket.'
        }
    }

    # Built-in administrator & guest
    $builtin = $users | Where-Object { $_.SID.Value -match '-500$' }
    if ($builtin) {
        $st = if (-not $builtin.Enabled) { 'OK' } else { 'WARN' }
        Add-Check 'Accounts' 'Ingebouwde Administrator uitgeschakeld' $st "Actief: $($builtin.Enabled)"
    }
    $guest = $users | Where-Object { $_.SID.Value -match '-501$' }
    if ($guest) {
        $st = if (-not $guest.Enabled) { 'OK' } else { 'FAIL' }
        Add-Check 'Accounts' 'Gastaccount uitgeschakeld' $st "Actief: $($guest.Enabled)"
    }

    # Clientadmin
    $ca = $users | Where-Object { $_.Name -eq $AdminUser }
    if (-not $ca) { Add-Check 'Accounts' "Beheeraccount '$AdminUser' bestaat" 'FAIL' 'Niet gevonden' }
    else {
        $okAdmin = $adminNames -contains $AdminUser
        $st = if ($ca.Enabled -and $okAdmin) { 'OK' } else { 'FAIL' }
        Add-Check 'Accounts' "Beheeraccount '$AdminUser' actief + lid van Administrators" $st "Actief: $($ca.Enabled) | Admin: $okAdmin"
    }

    # Klantaccount
    if ($CustomerUser) {
        $cu = $users | Where-Object { $_.Name -eq $CustomerUser }
        if (-not $cu) { Add-Check 'Accounts' "Klantaccount '$CustomerUser' bestaat" 'FAIL' 'Niet gevonden' }
        else {
            $st = if ($cu.Enabled) { 'OK' } else { 'FAIL' }
            Add-Check 'Accounts' "Klantaccount '$CustomerUser' actief" $st "Actief: $($cu.Enabled)"
            if ($cu.Enabled -and -not $cu.PasswordRequired) {
                Add-Check 'Accounts' 'Klantaccount heeft wachtwoord' 'WARN' 'Geen wachtwoord vereist - bewust?'
            }
        }
    }
    else {
        Add-Check 'Accounts' 'Klantaccount' 'INFO' 'Geen -CustomerUser opgegeven, niet gecontroleerd.'
    }

    $na = (& net accounts 2>$null) | Where-Object { $_ -match '\S' } | Select-Object -First 8
    Add-Check 'Accounts' 'Wachtwoordbeleid (net accounts) - zie stap 19' 'INFO' ($na -join "`n")
}

# ============================================================================
# 4. NETWERK
# ============================================================================
Invoke-Section 'Netwerk' {
    $ad = Get-NetAdapter -Physical -ErrorAction SilentlyContinue
    foreach ($a in $ad) {
        $kind = if ($a.PhysicalMediaType -match '802.11') { 'WiFi' } elseif ($a.PhysicalMediaType -match '802.3') { 'LAN' } else { $a.PhysicalMediaType }
        $st = if ($a.Status -eq 'Up') { 'OK' } else { 'INFO' }
        Add-Check 'Netwerk' "Adapter ($kind): $($a.Name)" $st "$($a.Status) @ $($a.LinkSpeed)"
    }
    if (-not ($ad | Where-Object { $_.PhysicalMediaType -match '802.3' -and $_.Status -eq 'Up' })) {
        Add-Check 'Netwerk' 'LAN-verbinding getest' 'WARN' 'Geen actieve LAN-verbinding - test met kabel indien toestel een LAN-poort heeft.'
    }
    $ping = Test-Connection -ComputerName 1.1.1.1 -Count 2 -Quiet -ErrorAction SilentlyContinue
    Add-Check 'Netwerk' 'Internet (ping 1.1.1.1)' $(if ($ping) { 'OK' } else { 'FAIL' }) ''
    try {
        $null = [System.Net.Dns]::GetHostAddresses('www.google.com')
        Add-Check 'Netwerk' 'DNS-resolutie' 'OK' 'www.google.com'
    }
    catch { Add-Check 'Netwerk' 'DNS-resolutie' 'FAIL' $_.Exception.Message }
}

# ============================================================================
# 5. SOFTWARE
# ============================================================================
$software = @(Get-InstalledSoftware)

Invoke-Section 'Software' {
    Add-Check 'Software' 'Aantal geinstalleerde programma''s' 'INFO' $software.Count

    # Recent geinstalleerd (registry)
    $recent = $software | Where-Object { $_.InstallDate -and $_.InstallDate -ge $cutoff } | Sort-Object InstallDate -Descending
    if ($recent) {
        $lines = $recent | ForEach-Object { "{0:dd/MM/yyyy}  {1} {2}" -f $_.InstallDate, $_.Name, $_.Version }
        Add-Check 'Software' "Recent geinstalleerd (laatste $Days dagen)" 'INFO' ($lines -join "`n")
    }
    else {
        Add-Check 'Software' "Recent geinstalleerd (laatste $Days dagen)" 'INFO' 'Geen programma''s met installatiedatum gevonden in dit venster.'
    }

    # Programma's zonder installatiedatum (kunnen ook recent zijn)
    $noDate = $software | Where-Object { -not $_.InstallDate }
    Add-Check 'Software' 'Programma''s zonder installatiedatum (volledige lijst)' 'INFO' (($noDate | ForEach-Object { "$($_.Name) $($_.Version)" }) -join "`n")

    # MSI-installaties via eventlog (aanvulling)
    $msi = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; Id = 11707; StartTime = $cutoff } -ErrorAction SilentlyContinue
    if ($msi) {
        $lines = $msi | ForEach-Object { "{0:dd/MM/yyyy HH:mm}  {1}" -f $_.TimeCreated, (($_.Message -split "`n")[0] -replace 'Product: ', '') }
        Add-Check 'Software' 'MSI-installaties (eventlog)' 'INFO' ($lines -join "`n")
    }

    # Verplichte software
    $req = @($RequiredCommon)
    if ($PcType -eq 'Gaming') { $req += $RequiredGaming }
    foreach ($r in $req) {
        $found = $software | Where-Object { Test-NameMatch $_.Name $r.Pattern } | Select-Object -First 1
        $pathOk = $r.Path -and (Test-Path $r.Path)
        if ($found) { Add-Check 'Software' "Verplicht: $($r.Name)" 'OK' "$($found.Name) $($found.Version)" }
        elseif ($pathOk) { Add-Check 'Software' "Verplicht: $($r.Name)" 'OK' "Gevonden op $($r.Path)" }
        else { Add-Check 'Software' "Verplicht: $($r.Name)" 'FAIL' 'Niet gevonden (kan per-gebruiker geinstalleerd zijn - controleer manueel)' }
    }

    # Management / beveiliging
    foreach ($m in $ManagementTools) {
        $found = $software | Where-Object { Test-NameMatch $_.Name $m.Pattern } | Select-Object -First 1
        if ($found) { Add-Check 'Software' "Beheer: $($m.Name)" 'OK' $found.Name }
        else { Add-Check 'Software' "Beheer: $($m.Name)" 'WARN' 'Niet gevonden - nodig voor dit toestel? (Trend Micro Client ID registreren!)' }
    }

    $office = $software | Where-Object { $_.Name -match 'Microsoft 365|Microsoft Office|Office 16' } | Select-Object -First 1
    if ($office) { Add-Check 'Software' 'Office geinstalleerd' 'INFO' "$($office.Name) - MS-account registreren in klantdossier + ticket + afdruk!" }

    # Bloatware
    $bloat = @($software | Where-Object { $_.Name -match $BloatPatterns })
    $appx = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $BloatPatterns -and -not $_.IsFramework } |
            Select-Object -ExpandProperty Name -Unique)
    if ($bloat.Count -or $appx.Count) {
        $lines = @($bloat | ForEach-Object { "Programma: $($_.Name)" }) + @($appx | ForEach-Object { "Store-app: $_" })
        Add-Check 'Software' 'Mogelijke bloatware (verwijderen in overleg)' 'WARN' ($lines -join "`n")
    }
    else {
        Add-Check 'Software' 'Bloatware' 'OK' 'Geen bekende bloatware gevonden'
    }

    # Opstartitems
    $startup = Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue
    if ($startup) {
        $st = if ($startup.Count -le 12) { 'INFO' } else { 'WARN' }
        Add-Check 'Software' "Opstartitems ($($startup.Count))" $st (($startup | ForEach-Object { $_.Name }) -join ', ')
    }
}

# ============================================================================
# 6. BEVEILIGING
# ============================================================================
Invoke-Section 'Beveiliging' {
    $av = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue)
    if ($av.Count -eq 0) { Add-Check 'Beveiliging' 'Antivirus' 'FAIL' 'Geen antivirus gedetecteerd' }
    else {
        $names = ($av | ForEach-Object { $_.displayName }) -join ', '
        $st = if ($av.Count -eq 1) { 'OK' } else { 'WARN' }
        $extra = if ($av.Count -gt 1) { ' (meerdere AV-producten - Defender schakelt zichzelf meestal uit bij 3rd-party AV; controleer!)' } else { '' }
        Add-Check 'Beveiliging' 'Antivirus' $st "$names$extra"
    }

    $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($mp) {
        $age = $mp.AntivirusSignatureAge
        $st = if ($age -le 3) { 'OK' } else { 'WARN' }
        Add-Check 'Beveiliging' 'Defender definities' $st "Leeftijd: $age dag(en), realtime: $($mp.RealTimeProtectionEnabled)"
    }

    $fw = Get-NetFirewallProfile -ErrorAction SilentlyContinue
    $off = @($fw | Where-Object { -not $_.Enabled })
    if ($off.Count) { Add-Check 'Beveiliging' 'Windows Firewall' 'WARN' "Uit voor profiel: $(($off.Name) -join ', ')" }
    else { Add-Check 'Beveiliging' 'Windows Firewall' 'OK' 'Alle profielen actief' }

    $uac = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).EnableLUA
    Add-Check 'Beveiliging' 'UAC' $(if ($uac -eq 1) { 'OK' } else { 'WARN' }) "EnableLUA = $uac"

    try {
        $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
        Add-Check 'Beveiliging' 'BitLocker / versleuteling C:' 'INFO' "$($bl.ProtectionStatus) ($($bl.VolumeStatus)) - herstelsleutel NIET kwijtraken indien actief!"
    }
    catch {
        Add-Check 'Beveiliging' 'BitLocker / versleuteling C:' 'INFO' 'Niet beschikbaar of niet actief (normaal op Home)'
    }
}

# ============================================================================
# 7. UPDATES
# ============================================================================
Invoke-Section 'Updates' {
    $pending = $false
    $reasons = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending = $true; $reasons += 'CBS' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending = $true; $reasons += 'WindowsUpdate' }
    if ($pending) { Add-Check 'Updates' 'Herstart in afwachting' 'WARN' "Herstart de pc ($($reasons -join ', '))" }
    else { Add-Check 'Updates' 'Herstart in afwachting' 'OK' 'Geen' }

    $hf = Get-HotFix -ErrorAction SilentlyContinue | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1
    if ($hf) {
        $st = if ($hf.InstalledOn -ge (Get-Date).AddDays(-45)) { 'OK' } else { 'WARN' }
        Add-Check 'Updates' 'Laatste Windows-update' $st "$($hf.HotFixID) op $($hf.InstalledOn.ToString('dd/MM/yyyy'))"
    }

    if ($CheckWindowsUpdate) {
        Write-Host '    (zoeken naar openstaande updates, even geduld...)' -ForegroundColor DarkGray
        $session = New-Object -ComObject Microsoft.Update.Session
        $res = $session.CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0')
        if ($res.Updates.Count -eq 0) { Add-Check 'Updates' 'Openstaande updates' 'OK' 'Geen - pc is up-to-date' }
        else {
            $titles = for ($i = 0; $i -lt $res.Updates.Count; $i++) { $res.Updates.Item($i).Title }
            Add-Check 'Updates' "Openstaande updates ($($res.Updates.Count))" 'FAIL' ($titles -join "`n")
        }
    }
    else {
        Add-Check 'Updates' 'Openstaande updates' 'INFO' 'Niet gecontroleerd (gebruik -CheckWindowsUpdate), controleer ook Lenovo Vantage/HP Support/Dell Update + niet-MS software.'
    }
}

# ============================================================================
# 8. ENERGIE
# ============================================================================
Invoke-Section 'Energie' {
    $fs = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled
    if ($fs -eq 0) { Add-Check 'Energie' 'Snel opstarten UIT (stap 19)' 'OK' 'Uitgeschakeld' }
    else { Add-Check 'Energie' 'Snel opstarten UIT (stap 19)' 'FAIL' 'Snel opstarten staat AAN' }

    $scheme = (& powercfg /getactivescheme) -join ' '
    $st = if ($scheme -match 'Power saver|Energiespaarstand|a1841308') { 'WARN' } else { 'INFO' }
    Add-Check 'Energie' 'Actief energieplan' $st $scheme
}

# ============================================================================
# 9. HARDWARE / DRIVERS
# ============================================================================
Invoke-Section 'Hardware' {
    $bad = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
    if ($bad.Count) {
        $lines = $bad | ForEach-Object { "$($_.Name) (foutcode $($_.ConfigManagerErrorCode))" }
        Add-Check 'Hardware' 'Apparaten met driverprobleem' 'FAIL' ($lines -join "`n")
    }
    else { Add-Check 'Hardware' 'Apparaten met driverprobleem' 'OK' 'Geen' }

    $gpus = @(Get-CimInstance Win32_VideoController)
    foreach ($g in $gpus) {
        $drvDate = if ($g.DriverDate) { $g.DriverDate.ToString('dd/MM/yyyy') } else { '?' }
        $res = if ($g.CurrentHorizontalResolution) { "$($g.CurrentHorizontalResolution)x$($g.CurrentVerticalResolution) @ $($g.CurrentRefreshRate) Hz" } else { 'geen actief scherm' }
        $st = 'INFO'
        if ($PcType -eq 'Gaming' -and $g.DriverDate -and $g.DriverDate -lt (Get-Date).AddDays(-120) -and $g.Name -match 'NVIDIA|Radeon') { $st = 'WARN' }
        Add-Check 'Hardware' "Grafische kaart: $($g.Name)" $st "Driver $($g.DriverVersion) van $drvDate | $res"
    }
    if ($PcType -eq 'Gaming') {
        if (-not ($gpus | Where-Object { $_.Name -match 'NVIDIA|Radeon RX|Radeon Pro|Arc' })) {
            Add-Check 'Hardware' 'Dedicated GPU aanwezig' 'FAIL' 'Geen NVIDIA/AMD/Intel Arc GPU gedetecteerd'
        }
        $maxHz = ($gpus | Measure-Object -Property CurrentRefreshRate -Maximum).Maximum
        Add-Check 'Hardware' 'Vernieuwingsfrequentie scherm (gaming monitor op max Hz?)' 'INFO' "$maxHz Hz actief"
    }

    $audio = @(Get-PnpDevice -Class AudioEndpoint -Status OK -ErrorAction SilentlyContinue)
    Add-Check 'Hardware' 'Audio-apparaten (headset/speakers/mic)' $(if ($audio.Count) { 'INFO' } else { 'WARN' }) (($audio.FriendlyName) -join "`n")

    $cam = @(Get-PnpDevice -Class Camera, Image -Status OK -ErrorAction SilentlyContinue)
    Add-Check 'Hardware' 'Webcam' 'INFO' $(if ($cam.Count) { ($cam.FriendlyName) -join ', ' } else { 'Geen gedetecteerd (n.v.t. bij desktop zonder webcam)' })
}

# ============================================================================
# 10. FOUTLOGS
# ============================================================================
Invoke-Section 'Foutlogs' {
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $cutoff } -MaxEvents 1000 -ErrorAction SilentlyContinue)
    Add-Check 'Foutlogs' "Kritieke/fout-events in Systeemlog ($Days d)" 'INFO' "$($ev.Count) events"
    if ($ev.Count) {
        $top = $ev | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { "$($_.Count)x $($_.Name)" }
        Add-Check 'Foutlogs' 'Top bronnen' 'INFO' ($top -join "`n")
    }
    $kp = @($ev | Where-Object { $_.Id -eq 41 -and $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' })
    if ($kp.Count) { Add-Check 'Foutlogs' 'Onverwachte uitschakeling (Kernel-Power 41)' 'WARN' "$($kp.Count)x - voeding/oververhitting/geforceerd uitzetten?" }
    $bc = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1001; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; StartTime = $cutoff } -ErrorAction SilentlyContinue)
    if ($bc.Count) { Add-Check 'Foutlogs' 'Blauwe schermen (BugCheck)' 'FAIL' "$($bc.Count)x in laatste $Days dagen" }
    else { Add-Check 'Foutlogs' 'Blauwe schermen (BugCheck)' 'OK' 'Geen' }
}

# ============================================================================
# 11. BUREAUBLAD
# ============================================================================
Invoke-Section 'Bureaublad' {
    $paths = @('C:\Users\Public\Desktop')
    if ($CustomerUser) { $paths += "C:\Users\$CustomerUser\Desktop" }
    $items = foreach ($p in $paths) {
        if (Test-Path $p) { Get-ChildItem $p -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object { $_.Name } }
    }
    Add-Check 'Bureaublad' "Pictogrammen ($(@($items).Count))" 'INFO' (($items | Sort-Object -Unique) -join ', ')
    if (-not ($items | Where-Object { $_ -match 'Helpdesk|Lipa' })) {
        Add-Check 'Bureaublad' "Snelkoppeling 'Helpdesk Lipa ICT'" 'WARN' 'Niet gevonden op bureaublad (stap 11)'
    }
    else { Add-Check 'Bureaublad' "Snelkoppeling 'Helpdesk Lipa ICT'" 'OK' 'Aanwezig' }
}

# ============================================================================
# RAPPORT OPBOUWEN
# ============================================================================
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$base = Join-Path $OutDir "Handover_${hostName}_$stamp"
$counts = $script:Results | Group-Object Status -AsHashTable -AsString
function Cnt($k) { if ($counts -and $counts.ContainsKey($k)) { $counts[$k].Count } else { 0 } }
$nFail = Cnt 'FAIL'; $nWarn = Cnt 'WARN'; $nOk = Cnt 'OK'

if ($nFail -gt 0) { $verdict = 'NIET KLAAR - er zijn FAIL-punten op te lossen' }
elseif ($nWarn -gt 0) { $verdict = 'KLAAR MET OPMERKINGEN - controleer de WARN-punten' }
else { $verdict = 'AUTOMATISCH OK - rond de handmatige punten af' }

$manual = @(
    'Toestel uitgepakt + op fabrieksfouten/beschadiging gecontroleerd (defect -> HR-bon via Leen)',
    'Windows-versie/taal/toetsenbord conform order (visueel getest)',
    'Wachtwoorden genoteerd in wachtwoordkluis/klantdossier (NIET in leesbaar in ticket)',
    'MS-account (indien Office/Windows) geregistreerd in klantdossier + ticket + afdruk klant',
    'Trend Micro: klant aangemaakt, Client ID gekoppeld aan Autotask + klantdossier',
    'Datto/Splashtop/Helpdesk-snelkoppeling werkt',
    'Webcam + microfoon + headset/speakers getest',
    'Data overgezet / backup ingesteld (indien afgesproken)',
    'Bureaublad en taakbalk ordelijk, pictogrammen geschikt',
    'Alle media van Lipa verwijderd en terug in LIPA-archief',
    'Lipa-sticker op toestel gekleefd',
    'Toestel gepoetst, volledig ingepakt (kabels, accessoires, monitor, keyboard hergebruik)',
    'Ticket volledig ingevuld + spelling gecontroleerd + serienummers genoteerd',
    'Ticket laten controleren door verantwoordelijke',
    'Klant verwittigd (datum + tijd telefoontje genoteerd)',
    'Toestel klaargezet voor afhaling + werkbon bij toestel'
)
if ($PcType -eq 'Gaming') {
    $manual += @(
        'Gaming: monitor op max Hz + 4K/gewenste resolutie ingesteld (Windows > Geavanceerde weergave)',
        'Gaming: GPU-driver recent, XMP/EXPO in BIOS gecontroleerd, temperaturen onder load OK',
        'Gaming: Steam/Epic aangemeld of klaar voor klant, headset getest'
    )
}

$symbol = @{ OK = '[ OK ]'; WARN = '[WARN]'; FAIL = '[FAIL]'; INFO = '[INFO]' }
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('OVERDRACHTSCONTROLE')
[void]$sb.AppendLine('===================')
[void]$sb.AppendLine("Ticket     : $TicketNr")
[void]$sb.AppendLine("Klant      : $CustomerName")
[void]$sb.AppendLine("Type       : $PcType-pc")
[void]$sb.AppendLine("Hostname   : $hostName")
[void]$sb.AppendLine("PN / SN    : $($cs.SystemSKUNumber) / $($bios.SerialNumber)")
[void]$sb.AppendLine("Controle   : $(Get-Date -Format 'dd/MM/yyyy HH:mm') door $env:USERNAME")
[void]$sb.AppendLine("Resultaat  : $verdict")
[void]$sb.AppendLine("Totaal     : $nOk OK | $nWarn WARN | $nFail FAIL")
[void]$sb.AppendLine('')

foreach ($grp in ($script:Results | Group-Object Section -NoElement | ForEach-Object { $_.Name })) {
    [void]$sb.AppendLine("--- $grp ---")
    foreach ($r in ($script:Results | Where-Object Section -eq $grp)) {
        [void]$sb.AppendLine("$($symbol[$r.Status]) $($r.Item)")
        if ($r.Detail) {
            foreach ($line in ($r.Detail -split "`r?`n")) { if ($line.Trim()) { [void]$sb.AppendLine("        $line") } }
        }
    }
    [void]$sb.AppendLine('')
}

[void]$sb.AppendLine('--- WACHTWOORDEN / TOEGANG (zelf invullen - script haalt GEEN wachtwoorden op) ---')
[void]$sb.AppendLine('Plaats wachtwoorden in de wachtwoordkluis en vermeld hier enkel WAAR ze staan.')
$accList = @($script:RealAccounts)
if (-not ($accList -contains $AdminUser)) { $accList = @($AdminUser) + $accList }
foreach ($a in ($accList | Sort-Object -Unique)) {
    [void]$sb.AppendLine("Account $a")
    [void]$sb.AppendLine('    Opgeslagen in : ____________________  (kluis / klantdossier)')
    [void]$sb.AppendLine('    Moet wijzigen bij 1e aanmelding : [ ] ja  [ ] nee')
}
[void]$sb.AppendLine('MS-account (e-mail)        : ____________________  Opgeslagen in: ____________________')
[void]$sb.AppendLine('Windows Hello / PIN          : [ ] ingesteld  [ ] niet')
[void]$sb.AppendLine('BIOS-wachtwoord              : [ ] geen  [ ] ja, opgeslagen in: ____________________')
[void]$sb.AppendLine('Trend Micro Client ID        : ____________________')
[void]$sb.AppendLine('Beveiligingsvragen (indien nodig): vermeld enkel dat ze in de kluis staan')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('--- HANDMATIGE CHECKLIST ---')
foreach ($m in $manual) { [void]$sb.AppendLine("[ ] $m") }
[void]$sb.AppendLine('')
[void]$sb.AppendLine('Extra software geinstalleerd op vraag van klant: ______________________________________')
[void]$sb.AppendLine('Opmerkingen: ______________________________________________________________________')

$txtPath = "$base.txt"
$sb.ToString() | Out-File -FilePath $txtPath -Encoding UTF8

# --- HTML -------------------------------------------------------------------
function HE($s) { [System.Net.WebUtility]::HtmlEncode([string]$s) }
$color = @{ OK = '#d9f2d9'; WARN = '#fff3cd'; FAIL = '#f8d7da'; INFO = '#eef2f7' }
$h = New-Object System.Text.StringBuilder
[void]$h.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"><title>Overdrachtscontrole</title>')
[void]$h.AppendLine('<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}table{border-collapse:collapse;width:100%;margin-bottom:20px}td,th{border:1px solid #ccc;padding:6px 8px;vertical-align:top;font-size:13px}th{background:#333;color:#fff;text-align:left}pre{margin:0;font-family:Consolas,monospace;white-space:pre-wrap}h2{margin-top:28px}.v{font-size:18px;font-weight:bold;padding:10px;border-radius:6px;background:#eef2f7}@media print{body{margin:8px}}</style></head><body>')
[void]$h.AppendLine("<h1>Overdrachtscontrole - $(HE $hostName)</h1>")
[void]$h.AppendLine("<p>Ticket: <b>$(HE $TicketNr)</b> | Klant: <b>$(HE $CustomerName)</b> | Type: <b>$PcType</b> | PN/SN: $(HE $cs.SystemSKUNumber) / $(HE $bios.SerialNumber) | $(Get-Date -Format 'dd/MM/yyyy HH:mm') door $(HE $env:USERNAME)</p>")
[void]$h.AppendLine("<div class='v'>$(HE $verdict) &mdash; $nOk OK | $nWarn WARN | $nFail FAIL</div>")
foreach ($grp in ($script:Results | Group-Object Section -NoElement | ForEach-Object { $_.Name })) {
    [void]$h.AppendLine("<h2>$(HE $grp)</h2><table><tr><th style='width:70px'>Status</th><th style='width:32%'>Controle</th><th>Details</th></tr>")
    foreach ($r in ($script:Results | Where-Object Section -eq $grp)) {
        [void]$h.AppendLine("<tr style='background:$($color[$r.Status])'><td><b>$($r.Status)</b></td><td>$(HE $r.Item)</td><td><pre>$(HE $r.Detail)</pre></td></tr>")
    }
    [void]$h.AppendLine('</table>')
}
[void]$h.AppendLine('<h2>Wachtwoorden / toegang (zelf invullen)</h2><p><i>Het script haalt geen wachtwoorden op. Bewaar ze in de wachtwoordkluis en noteer hier enkel waar.</i></p><table><tr><th>Account</th><th>Opgeslagen in</th><th>Wijzigen bij 1e login</th></tr>')
foreach ($a in ($accList | Sort-Object -Unique)) { [void]$h.AppendLine("<tr><td>$(HE $a)</td><td style='height:28px'></td><td>&#9744; ja &nbsp; &#9744; nee</td></tr>") }
[void]$h.AppendLine('<tr><td>MS-account (e-mail)</td><td></td><td></td></tr><tr><td>Trend Micro Client ID</td><td></td><td></td></tr></table>')
[void]$h.AppendLine('<h2>Handmatige checklist</h2><ul style="list-style:none;padding-left:0">')
foreach ($m in $manual) { [void]$h.AppendLine("<li>&#9744; $(HE $m)</li>") }
[void]$h.AppendLine('</ul></body></html>')
$htmlPath = "$base.html"
$h.ToString() | Out-File -FilePath $htmlPath -Encoding UTF8

if ($CopyToClipboard) { Get-Content $txtPath -Raw | Set-Clipboard; Write-Host 'Tekstrapport gekopieerd naar klembord.' -ForegroundColor Yellow }

Write-Host ''
Write-Host "RESULTAAT: $verdict" -ForegroundColor $(if ($nFail) { 'Red' } elseif ($nWarn) { 'Yellow' } else { 'Green' })
Write-Host "  $nOk OK | $nWarn WARN | $nFail FAIL"
Write-Host "  Tekst : $txtPath"
Write-Host "  HTML  : $htmlPath"
Start-Process $htmlPath -ErrorAction SilentlyContinue
