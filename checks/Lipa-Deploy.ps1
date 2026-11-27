<#
.SYNOPSIS
    Lipa ICT Windows 10/11 provisioning, audit en Autotask-handover.
.DESCRIPTION
    Werkt met Windows PowerShell 5.1 en PowerShell 7+, lokaal en via irm | iex.
    De audit-only module voert geen configuratiewijzigingen of installaties uit.
#>
[CmdletBinding()]
param(
    [string]$CustomerName,
    [string]$CustomerAbbreviation,
    [string]$TicketNumber,
    [string]$ComputerName
)

$ErrorActionPreference = 'Stop'
$script:Actions = New-Object 'System.Collections.Generic.List[object]'
$script:Warnings = New-Object 'System.Collections.Generic.List[string]'
$script:Credentials = New-Object 'System.Collections.Generic.List[object]'
$script:SelectedModules = @()
$script:IsAuditOnly = $false
$script:NeedReboot = $false
$script:UpdateNote = ''
$script:FormFactor = 'Onbekend'
$script:Edition = 'Onbekend'
$script:HelpdeskUrl = 'https://www.lipa.be' # Pas aan als Lipa een ander helpdeskadres gebruikt.
$script:OutputFile = 'C:\Temp\Lipa-Ticket-Output.txt'

function Write-Status {
    param([string]$Message, [string]$Level = 'INFO')

    $colour = switch ($Level) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'Cyan' }
    }
    Write-Host "[$Level] $Message" -ForegroundColor $colour
}

function Add-Action {
    param([string]$Title, [string[]]$Details)

    $script:Actions.Add([pscustomobject]@{
        Title   = $Title
        Details = @($Details | Where-Object { $_ })
    })
}

function Add-Warning {
    param([string]$Message)

    if ($Message) {
        $script:Warnings.Add($Message)
        Write-Status $Message 'WARN'
    }
}

function Invoke-DeployStep {
    param([string]$Name, [scriptblock]$Operation)

    try {
        $result = & $Operation
        if ($result) {
            Write-Status $Name 'OK'
        }
        return $result
    }
    catch {
        Add-Warning "$Name niet uitgevoerd: $($_.Exception.Message)"
        return $false
    }
}

function Read-Default {
    param([string]$Prompt, [string]$Default)

    $answer = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $Default
    }
    return $answer.Trim()
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $false)

    $hint = if ($Default) { 'J/n' } else { 'j/N' }
    while ($true) {
        $answer = (Read-Host "$Prompt [$hint]").Trim().ToLowerInvariant()
        if (-not $answer) { return $Default }
        if ($answer -in @('j', 'ja', 'y', 'yes')) { return $true }
        if ($answer -in @('n', 'nee', 'no')) { return $false }
        Write-Host 'Antwoord met j of n.' -ForegroundColor Yellow
    }
}

function Get-RandomIndex {
    param([int]$Maximum)

    if ($Maximum -le 0) {
        throw 'Maximum moet groter dan nul zijn.'
    }

    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = New-Object byte[] 4
        $range = [uint64]4294967296
        $limit = $range - ($range % [uint64]$Maximum)
        do {
            $rng.GetBytes($bytes)
            $value = [uint64][BitConverter]::ToUInt32($bytes, 0)
        } while ($value -ge $limit)

        return [int]($value % [uint64]$Maximum)
    }
    finally {
        $rng.Dispose()
    }
}

function New-SecureRandomPassword {
    $sets = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'abcdefghijkmnopqrstuvwxyz',
        '23456789',
        '!@#$%&*'
    )
    $all = $sets -join ''
    $characters = New-Object 'System.Collections.Generic.List[char]'

    foreach ($set in $sets) {
        $characters.Add($set[(Get-RandomIndex $set.Length)])
    }
    while ($characters.Count -lt 10) {
        $characters.Add($all[(Get-RandomIndex $all.Length)])
    }

    for ($i = $characters.Count - 1; $i -gt 0; $i--) {
        $j = Get-RandomIndex ($i + 1)
        $temporary = $characters[$i]
        $characters[$i] = $characters[$j]
        $characters[$j] = $temporary
    }
    return -join $characters.ToArray()
}

function Get-AccountPassword {
    param([string]$Account)

    while ($true) {
        $generated = New-SecureRandomPassword
        $answer = Read-Host "Wachtwoord voor ${Account}: Enter = gegenereerd, of typ een eigen wachtwoord"

        if ([string]::IsNullOrEmpty($answer)) {
            return [pscustomobject]@{
                Secure = ConvertTo-SecureString $generated -AsPlainText -Force
                Plain  = $generated
            }
        }

        $confirmation = Read-Host 'Bevestig het eigen wachtwoord'
        if ($answer -ne $confirmation) {
            Write-Status 'Wachtwoorden komen niet overeen; probeer opnieuw.' 'WARN'
            continue
        }
        if ($answer.Length -lt 10) {
            Write-Status 'Gebruik minstens 10 tekens.' 'WARN'
            continue
        }
        return [pscustomobject]@{
            Secure = ConvertTo-SecureString $answer -AsPlainText -Force
            Plain  = $answer
        }
    }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Start-ElevatedCopy {
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
        $source = "& '" + $PSCommandPath.Replace("'", "''") + "'"
    }
    else {
        $source = $MyInvocation.MyCommand.Definition
        if ([string]::IsNullOrWhiteSpace($source)) {
            throw 'Elevation via irm | iex kon niet gestart worden. Start PowerShell als administrator en voer het opnieuw uit.'
        }
        $sourceBytes = [Text.Encoding]::UTF8.GetBytes($source)
        $sourceBase64 = [Convert]::ToBase64String($sourceBytes)
        $source = '$s=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' +
            $sourceBase64 + ''')); Invoke-Expression $s'
    }

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($source))
    $hostPath = (Get-Process -Id $PID).Path
    if (-not $hostPath) {
        $hostPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }

    Start-Process -FilePath $hostPath -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded
    ) -Verb RunAs
    return $true
}

function Get-DeviceProfile {
    $system = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $battery = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    $chassisTypes = @(
        Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue |
            ForEach-Object { $_.ChassisTypes }
    )
    $portableTypes = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)

    if ($battery.Count -gt 0 -or @($chassisTypes | Where-Object { $_ -in $portableTypes }).Count -gt 0) {
        $script:FormFactor = 'Laptop/Tablet'
    }
    else {
        $script:FormFactor = 'Desktop'
    }

    if ($os.Caption -match 'Home') {
        $script:Edition = 'Home'
    }
    elseif ($os.Caption -match 'Pro') {
        $script:Edition = 'Pro'
    }
    else {
        $script:Edition = $os.Caption
    }

    return [pscustomobject]@{
        System  = $system
        OS      = $os
        Battery = $battery
    }
}

function Read-Intake {
    param($Profile)

    $script:CustomerName = Read-Default 'Klantnaam' 'Nieuwe klant'
    $script:CustomerAbbreviation = (Read-Default 'Klantafkorting' 'LIPA').ToUpperInvariant()
    $script:TicketNumber = Read-Default 'Ticketnummer' 'Geen ticketnummer opgegeven'

    if ($script:CustomerAbbreviation.Length -gt 8) {
        $nameDefault = $script:CustomerAbbreviation.Substring(0, 8) + '-PC01'
    }
    else {
        $nameDefault = $script:CustomerAbbreviation + '-PC01'
    }

    $suggestedName = if ($ComputerName) { $ComputerName } else { $nameDefault }
    while ($true) {
        $candidate = Read-Default 'Gewenste toestelnaam (max. 15 tekens)' $suggestedName
        if ($candidate.Length -le 15 -and
            $candidate -match '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,13}[A-Za-z0-9])?$') {
            $script:ComputerName = $candidate.ToUpperInvariant()
            break
        }
        Write-Status 'Ongeldige naam. Gebruik 1-15 letters, cijfers of koppeltekens; geen koppelteken vooraan of achteraan.' 'WARN'
    }

    $createUser = Read-YesNo 'Een lokale eindgebruiker aanmaken? Kies nee voor Entra ID/domein' $true
    $script:EndUser = $null
    $script:EndUserIsAdmin = $false

    if ($createUser) {
        while ($true) {
            $user = (Read-Host 'Voornaam/gebruikersnaam lokale eindgebruiker').Trim()
            if ($user -match '^[A-Za-z0-9._-]{1,20}$' -and $user -ine 'Clientadmin') {
                $script:EndUser = $user
                break
            }
            Write-Status 'Ongeldige gebruikersnaam; Clientadmin is gereserveerd.' 'WARN'
        }

        $rights = (Read-Host 'Rechten: [S] Standaardgebruiker (standaard) of [A] Administrator [S]').Trim()
        $script:EndUserIsAdmin = $rights -match '^(a|admin|administrator)$'
    }

    Write-Host ''
    Write-Host "Detectie: $($Profile.OS.Caption), editie $script:Edition, toesteltype $script:FormFactor"
    Write-Host 'Modules: [1] Basissoftware  [2] Microsoft 365 Apps  [3] Belgische e-ID'
    Write-Host '         [4] Bloatware verwijderen  [5] Domein/VPN  [6] Alleen audit'

    while ($true) {
        $selection = (Read-Host 'Kies nummers gescheiden door komma, bv. 1,2,5 (standaard 1,2)').Trim()
        if (-not $selection) { $selection = '1,2' }

        $items = @($selection -split '[,\s]+' | Where-Object { $_ })
        if (@($items | Where-Object { $_ -notmatch '^[1-6]$' }).Count -gt 0) {
            Write-Status 'Kies enkel nummers 1 tot en met 6.' 'WARN'
            continue
        }

        $items = @($items | Select-Object -Unique)
        if ($items -contains '6' -and $items.Count -gt 1) {
            Write-Status 'Audit-only kan niet samen met wijzigingsmodules gekozen worden.' 'WARN'
            continue
        }

        $script:SelectedModules = $items
        $script:IsAuditOnly = $items -contains '6'
        break
    }
}

function Ensure-GroupMembership {
    param([string]$User, [string]$GroupSid)

    $members = @(Get-LocalGroupMember -SID $GroupSid -ErrorAction Stop)
    $found = @($members | Where-Object {
        (($_.Name -split '\\')[-1]) -ieq $User
    }).Count -gt 0

    if (-not $found) {
        Add-LocalGroupMember -SID $GroupSid -Member $User -ErrorAction Stop
    }
}

function Set-OneLocalAccount {
    param(
        [string]$User,
        [Security.SecureString]$Password,
        [bool]$IsAdmin,
        [bool]$PasswordNeverExpires
    )

    $existing = Get-LocalUser -Name $User -ErrorAction SilentlyContinue
    if ($existing) {
        if (-not (Read-YesNo "Account $User bestaat al. Wachtwoord en rechten aanpassen?" $false)) {
            throw "Account $User bestaat al en werd niet aangepast."
        }
        Set-LocalUser -Name $User -Password $Password `
            -PasswordNeverExpires $PasswordNeverExpires -ErrorAction Stop
        Enable-LocalUser -Name $User -ErrorAction Stop
    }
    else {
        New-LocalUser -Name $User -Password $Password -AccountNeverExpires `
            -PasswordNeverExpires:$PasswordNeverExpires -ErrorAction Stop | Out-Null
    }

    if ($IsAdmin) {
        Ensure-GroupMembership $User 'S-1-5-32-544'
    }
    else {
        $admins = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)
        if (@($admins | Where-Object { (($_.Name -split '\\')[-1]) -ieq $User }).Count -gt 0) {
            Remove-LocalGroupMember -SID 'S-1-5-32-544' -Member $User -ErrorAction Stop
        }
        Ensure-GroupMembership $User 'S-1-5-32-545'
    }
}

function Set-LocalAccounts {
    if (-not (Get-Command Get-LocalUser -ErrorAction SilentlyContinue)) {
        throw 'De LocalAccounts-module ontbreekt. Start 64-bit PowerShell als administrator.'
    }

    $adminPassword = Get-AccountPassword 'Clientadmin'
    Set-OneLocalAccount 'Clientadmin' $adminPassword.Secure $true $true
    $script:Credentials.Add([pscustomobject]@{
        User = 'Clientadmin'
        Password = $adminPassword.Plain
    })
    Add-Action 'Lokaal beheerdersaccount ingesteld' @(
        'Clientadmin is actief en het wachtwoord verloopt niet.'
    )

    if ($script:EndUser) {
        $userPassword = Get-AccountPassword $script:EndUser
        Set-OneLocalAccount $script:EndUser $userPassword.Secure $script:EndUserIsAdmin $false
        $script:Credentials.Add([pscustomobject]@{
            User = $script:EndUser
            Password = $userPassword.Plain
        })
        $role = if ($script:EndUserIsAdmin) { 'Administrator' } else { 'Standaardgebruiker' }
        Add-Action 'Lokale eindgebruiker ingesteld' @("$($script:EndUser): $role.")
    }
}

function Set-PasswordPolicy {
    if ($script:Edition -eq 'Pro') {
        $config = Join-Path $env:TEMP ('Lipa-Policy-' + [guid]::NewGuid().ToString('N') + '.inf')
        $database = Join-Path $env:TEMP ('Lipa-Policy-' + [guid]::NewGuid().ToString('N') + '.sdb')

        try {
            & secedit.exe /export /cfg $config /areas SECURITYPOLICY | Out-Null
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $config)) {
                throw "secedit export gaf exitcode $LASTEXITCODE."
            }

            $content = Get-Content -LiteralPath $config -Raw
            if ($content -notmatch '(?m)^MinimumPasswordLength\s*=') {
                throw 'secedit-config bevat geen MinimumPasswordLength-instelling.'
            }
            if ($content -notmatch '(?m)^PasswordComplexity\s*=') {
                throw 'secedit-config bevat geen PasswordComplexity-instelling.'
            }

            $content = [regex]::Replace($content, '(?m)^MinimumPasswordLength\s*=.*$', 'MinimumPasswordLength = 10')
            $content = [regex]::Replace($content, '(?m)^PasswordComplexity\s*=.*$', 'PasswordComplexity = 1')
            Set-Content -LiteralPath $config -Value $content -Encoding Unicode

            & secedit.exe /configure /db $database /cfg $config /areas SECURITYPOLICY | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "secedit configure gaf exitcode $LASTEXITCODE."
            }

            Add-Action 'Lokaal wachtwoordbeleid ingesteld' @(
                'Minimumlengte 10 tekens en complexiteit ingeschakeld via lokaal beveiligingsbeleid.'
            )
        }
        finally {
            Remove-Item -LiteralPath $config, $database -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        & net.exe accounts /minpwlen:10 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "net accounts gaf exitcode $LASTEXITCODE."
        }
        Add-Action 'Lokaal wachtwoordbeleid ingesteld' @(
            'Minimumlengte 10 tekens via net accounts; Windows Home dwingt geen complexiteit af.'
        )
    }

    return $true
}

function Set-SystemBaseline {
    Invoke-DeployStep 'Lokale accounts instellen' {
        Set-LocalAccounts
        return $true
    } | Out-Null

    Invoke-DeployStep 'Wachtwoordbeleid instellen' {
        Set-PasswordPolicy
    } | Out-Null

    Invoke-DeployStep 'Computernaam instellen' {
        if ($env:COMPUTERNAME -ne $script:ComputerName) {
            Rename-Computer -NewName $script:ComputerName -Force -ErrorAction Stop
            $script:NeedReboot = $true
            Add-Action 'Toestelnaam ingesteld' @(
                "Nieuwe naam: $script:ComputerName; herstart vereist."
            )
        }
        else {
            Add-Action 'Toestelnaam gecontroleerd' @("Toestel heet al $script:ComputerName.")
        }
        return $true
    } | Out-Null

    Invoke-DeployStep 'Snel opstarten uitschakelen' {
        $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
        Set-ItemProperty -Path $path -Name HiberbootEnabled -Value 0 `
            -Type DWord -Force -ErrorAction Stop
        Add-Action 'Snel opstarten uitgeschakeld' @('HiberbootEnabled staat op 0.')
        return $true
    } | Out-Null

    Invoke-DeployStep 'Tijd en tijdzone synchroniseren' {
        Set-TimeZone -Id 'Romance Standard Time' -ErrorAction Stop
        Set-Service -Name w32time -StartupType Automatic -ErrorAction Stop
        Start-Service -Name w32time -ErrorAction Stop
        & w32tm.exe /resync | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "w32tm /resync gaf exitcode $LASTEXITCODE."
        }
        Add-Action 'Tijd en tijdzone ingesteld' @(
            'Tijdzone Brussel; Windows-tijdsynchronisatie uitgevoerd.'
        )
        return $true
    } | Out-Null

    Invoke-DeployStep 'Helpdesk-snelkoppeling maken' {
        $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
        if (-not $desktop) { $desktop = Join-Path $env:PUBLIC 'Desktop' }
        if (-not (Test-Path $desktop)) {
            New-Item -Path $desktop -ItemType Directory -Force | Out-Null
        }
        $path = Join-Path $desktop 'Helpdesk Lipa ICT.url'
        Set-Content -LiteralPath $path `
            -Value "[InternetShortcut]`r`nURL=$script:HelpdeskUrl" `
            -Encoding ASCII -ErrorAction Stop
        Add-Action 'Helpdesk-snelkoppeling aangemaakt' @(
            "Openbare bureaubladsnelkoppeling verwijst naar $script:HelpdeskUrl."
        )
        return $true
    } | Out-Null

    Invoke-DeployStep 'Promotie-snelkoppelingen opruimen' {
        $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
        $patterns = @(
            '*Xbox*.lnk', '*McAfee*.lnk', '*WildTangent*.lnk',
            '*TikTok*.lnk', '*Disney*.lnk', '*Candy Crush*.lnk'
        )
        $removed = New-Object 'System.Collections.Generic.List[string]'

        if ($desktop -and (Test-Path $desktop)) {
            foreach ($pattern in $patterns) {
                Get-ChildItem -LiteralPath $desktop -Filter $pattern -File `
                    -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                        $removed.Add($_.Name)
                    }
            }
        }

        if ($removed.Count -gt 0) {
            Add-Action 'Promotie-snelkoppelingen verwijderd' @($removed.ToArray())
        }
        else {
            Add-Action 'Openbaar bureaublad gecontroleerd' @(
                'Geen snelkoppelingen uit de beperkte promotielijst gevonden.'
            )
        }
        return $true
    } | Out-Null
}

function Install-WingetPackage {
    param([string]$Id, [string]$DisplayName)

    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        Add-Warning "winget ontbreekt; $DisplayName is niet geïnstalleerd."
        return $false
    }

    & winget.exe install --id $Id --exact --silent `
        --accept-package-agreements --accept-source-agreements `
        --disable-interactivity
    $code = $LASTEXITCODE

    if ($code -eq 0 -or $code -eq -1978335189) {
        Add-Action "$DisplayName geïnstalleerd" @("winget-pakket: $Id.")
        Write-Status "$DisplayName geïnstalleerd of was al aanwezig." 'OK'
        return $true
    }

    Add-Warning "$DisplayName niet geïnstalleerd (winget exitcode $code)."
    return $false
}

function Install-BasicSoftware {
    $packages = @(
        @{ Id = 'Google.Chrome'; Name = 'Google Chrome' },
        @{ Id = 'Mozilla.Firefox'; Name = 'Mozilla Firefox' },
        @{ Id = 'Adobe.Acrobat.Reader.64-bit'; Name = 'Adobe Acrobat Reader DC' }
    )

    foreach ($package in $packages) {
        Invoke-DeployStep "$($package.Name) installeren" {
            return (Install-WingetPackage $package.Id $package.Name)
        } | Out-Null
    }

    $optional = @(
        @{ Id = 'Foxit.FoxitReader'; Name = 'Foxit Reader' },
        @{ Id = '7zip.7zip'; Name = '7-Zip' },
        @{ Id = 'VideoLAN.VLC'; Name = 'VLC' }
    )
    foreach ($package in $optional) {
        if (Read-YesNo "$($package.Name) ook installeren?" $false) {
            Invoke-DeployStep "$($package.Name) installeren" {
                return (Install-WingetPackage $package.Id $package.Name)
            } | Out-Null
        }
    }
}

function Install-Office365 {
    $directory = 'C:\Temp\Office'

    Invoke-DeployStep 'Microsoft 365 Apps installeren' {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
        $setup = Join-Path $directory 'setup.exe'
        $config = Join-Path $directory 'config.xml'

        try {
            if ($PSVersionTable.PSVersion.Major -lt 6) {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            }

            Invoke-WebRequest `
                -Uri 'https://officecdn.microsoft.com/pr/wsus/setup.exe' `
                -OutFile $setup -UseBasicParsing -ErrorAction Stop

            if (-not (Test-Path $setup) -or (Get-Item $setup).Length -lt 100KB) {
                throw 'Gedownloade Office Setup ontbreekt of is onverwacht klein.'
            }

            $signature = Get-AuthenticodeSignature -FilePath $setup
            if ($signature.Status -ne 'Valid') {
                throw "Handtekening van Office Setup is niet geldig: $($signature.Status)."
            }

            $xml = @'
<Configuration>
  <Add OfficeClientEdition="64" Channel="Current">
    <Product ID="O365BusinessRetail">
      <Language ID="nl-nl" />
    </Product>
  </Add>
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="AUTOACTIVATE" Value="1" />
</Configuration>
'@
            Set-Content -LiteralPath $config -Value $xml -Encoding UTF8
            $process = Start-Process -FilePath $setup `
                -ArgumentList @('/configure', "`"$config`"") -Wait -PassThru

            if ($process.ExitCode -ne 0) {
                throw "Office Setup gaf exitcode $($process.ExitCode)."
            }

            Add-Action 'Microsoft 365 Apps geïnstalleerd' @(
                'O365BusinessRetail, 64-bit, Current-kanaal, taal nl-nl.'
            )
            return $true
        }
        finally {
            if (Test-Path $directory) {
                Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } | Out-Null
}

function Install-EidSoftware {
    Invoke-DeployStep 'Belgische e-ID software installeren' {
        $middleware = Install-WingetPackage `
            'BelgianGovernment.eIDmiddleware' 'Belgische e-ID middleware'
        $viewer = Install-WingetPackage `
            'BelgianGovernment.eIDViewer' 'Belgische e-ID Viewer'

        if (-not ($middleware -or $viewer)) {
            throw 'Geen e-ID-pakket werd geïnstalleerd.'
        }

        $service = Get-Service -Name SCardSvr -ErrorAction SilentlyContinue
        if ($service) {
            if ($service.Status -ne 'Running') {
                Start-Service -Name SCardSvr -ErrorAction Stop
            }
            Add-Action 'Kaartlezer-service gecontroleerd' @(
                'Smart Card-service (SCardSvr) draait.'
            )
        }
        else {
            Add-Warning 'Smart Card-service (SCardSvr) is niet beschikbaar.'
        }
        return $true
    } | Out-Null
}

function Remove-CuratedBloatware {
    $patterns = @(
        '*CandyCrush*', '*BubbleWitch*', '*FarmVille*',
        '*MarchofEmpires*', '*TikTok*', '*Disney*',
        '*McAfee*', '*WildTangent*'
    )
    $removed = New-Object 'System.Collections.Generic.List[string]'

    foreach ($pattern in $patterns) {
        $apps = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $pattern })

        foreach ($app in $apps) {
            try {
                Remove-AppxPackage -Package $app.PackageFullName -AllUsers -ErrorAction Stop
                $removed.Add($app.Name)
            }
            catch {
                Add-Warning "Appx-pakket $($app.Name) niet verwijderd: $($_.Exception.Message)"
            }
        }

        $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $pattern })

        foreach ($app in $provisioned) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $app.PackageName `
                    -ErrorAction Stop | Out-Null
                if (-not $removed.Contains($app.DisplayName)) {
                    $removed.Add($app.DisplayName)
                }
            }
            catch {
                Add-Warning "Voorzien pakket $($app.DisplayName) niet verwijderd: $($_.Exception.Message)"
            }
        }
    }

    if ($removed.Count -gt 0) {
        Add-Action 'Geselecteerde promotie-apps verwijderd' @($removed.ToArray())
    }
    else {
        Add-Action 'Bloatware gecontroleerd' @(
            'Geen verwijderbare pakketten uit de beperkte lijst gevonden.'
        )
    }
    return $true
}

function Invoke-VpnPreparation {
    if (Read-YesNo 'OpenVPN Connect installeren?' $false) {
        Invoke-DeployStep 'OpenVPN Connect installeren' {
            return (Install-WingetPackage `
                'OpenVPNTechnologies.OpenVPNConnect' 'OpenVPN Connect')
        } | Out-Null
    }
    else {
        Add-Action 'VPN-voorbereiding uitgevoerd' @(
            'Geen VPN-client geïnstalleerd; huidige domein- en netwerkstatus wordt gerapporteerd.'
        )
    }
}

function Invoke-WindowsUpdates {
    Invoke-DeployStep 'Windows Updates controleren en starten' {
        $module = Get-Module -ListAvailable -Name PSWindowsUpdate |
            Select-Object -First 1

        if ($module) {
            Import-Module PSWindowsUpdate -ErrorAction Stop
            $updates = @(Get-WindowsUpdate -ErrorAction Stop)

            if ($updates.Count -eq 0) {
                $script:UpdateNote = 'PSWindowsUpdate vond geen openstaande updates.'
                Add-Action 'Windows Updates gecontroleerd' @($script:UpdateNote)
            }
            else {
                Install-WindowsUpdate -AcceptAll -IgnoreReboot -Confirm:$false `
                    -ErrorAction Stop | Out-Null
                $script:UpdateNote = "$($updates.Count) openstaande update(s) via PSWindowsUpdate aangeboden."
                Add-Action 'Windows Updates gestart' @($script:UpdateNote)
            }
            return $true
        }

        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $search = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")

        if ($search.Updates.Count -eq 0) {
            $script:UpdateNote = 'Geen openstaande software-updates gevonden.'
            Add-Action 'Windows Updates gecontroleerd' @($script:UpdateNote)
            return $true
        }

        $collection = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($update in $search.Updates) {
            if (-not $update.EulaAccepted) { $update.AcceptEula() }
            [void]$collection.Add($update)
        }

        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $collection
        $downloadResult = $downloader.Download()
        if ($downloadResult.ResultCode -notin @(2, 3)) {
            throw "Windows Update-download gaf resultaatcode $($downloadResult.ResultCode)."
        }

        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $collection
        $installResult = $installer.Install()
        if ($installResult.ResultCode -notin @(2, 3)) {
            throw "Windows Update-installatie gaf resultaatcode $($installResult.ResultCode)."
        }

        if ($installResult.RebootRequired) { $script:NeedReboot = $true }
        $script:UpdateNote = "$($collection.Count) update(s) via de native Windows Update-API verwerkt."
        Add-Action 'Windows Updates gestart' @($script:UpdateNote)
        return $true
    } | Out-Null
}

function Start-VendorUpdateTools {
    $tools = @(
        @{
            Path = "$env:ProgramFiles\HP\HP Image Assistant\HPImageAssistant.exe"
            Args = '/Operation:Analyze /Category:All'
            Name = 'HP Image Assistant'
        },
        @{
            Path = "${env:ProgramFiles(x86)}\HP\HP Image Assistant\HPImageAssistant.exe"
            Args = '/Operation:Analyze /Category:All'
            Name = 'HP Image Assistant'
        },
        @{
            Path = "$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe"
            Args = '/scan'
            Name = 'Dell Command Update'
        },
        @{
            Path = "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe"
            Args = '/scan'
            Name = 'Dell Command Update'
        }
    )

    foreach ($tool in $tools) {
        if (Test-Path -LiteralPath $tool.Path) {
            try {
                Start-Process -FilePath $tool.Path -ArgumentList $tool.Args `
                    -Wait -ErrorAction Stop
                Add-Action 'Vendor-updatetool gestart' @("$($tool.Name): scan gestart.")
            }
            catch {
                Add-Warning "$($tool.Name) kon niet starten: $($_.Exception.Message)"
            }
        }
    }

    $hpRoots = @("$env:ProgramFiles\HP", "${env:ProgramFiles(x86)}\HP") |
        Where-Object { Test-Path $_ }
    if ($hpRoots.Count -gt 0) {
        $assistant = Get-ChildItem -Path $hpRoots -Filter 'HPSupportAssistant.exe' `
            -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($assistant) {
            try {
                Start-Process -FilePath $assistant.FullName -ErrorAction Stop
                Add-Action 'HP Support Assistant gestart' @('Toepassing geopend.')
            }
            catch {
                Add-Warning "HP Support Assistant kon niet starten: $($_.Exception.Message)"
            }
        }
    }
}

function Get-InstalledApplication {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($path in $paths) {
        Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName } |
            Select-Object -ExpandProperty DisplayName
    }
}

function Get-MonitorList {
    $monitors = @(Get-CimInstance -Namespace 'root\wmi' -ClassName WmiMonitorID `
        -ErrorAction SilentlyContinue | Where-Object { $_.Active })

    foreach ($monitor in $monitors) {
        $manufacturer = (-join @($monitor.ManufacturerName |
            Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ })).Trim()
        $model = (-join @($monitor.UserFriendlyName |
            Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ })).Trim()
        $serial = (-join @($monitor.SerialNumberID |
            Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ })).Trim()

        [pscustomobject]@{
            Manufacturer = $manufacturer
            Model        = $model
            Serial       = $serial
        }
    }
}

function Get-HardwareInventory {
    $system = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $os = Get-CimInstance Win32_OperatingSystem
    $processor = Get-CimInstance Win32_Processor | Select-Object -First 1
    $video = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
    $memory = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
    $memoryArray = Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' `
        -ErrorAction SilentlyContinue)
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
    $cameras = @(Get-PnpDevice -Class Camera, Image -Status OK -ErrorAction SilentlyContinue)
    $audio = @(Get-PnpDevice -Class AudioEndpoint -Status OK -ErrorAction SilentlyContinue)
    $monitors = @(Get-MonitorList)

    $ramGB = [math]::Round((($memory | Measure-Object Capacity -Sum).Sum / 1GB), 0)
    $slotCount = if ($memoryArray) { [int]$memoryArray.MemoryDevices } else { $memory.Count }
    $freeSlots = [math]::Max(0, $slotCount - $memory.Count)

    $displayVersion = ''
    try {
        $displayVersion = (Get-ItemProperty `
            'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
            -ErrorAction Stop).DisplayVersion
    }
    catch { }
    $build = "$($os.BuildNumber)$(if ($displayVersion) { " ($displayVersion)" })"

    $domain = if ($system.PartOfDomain) {
        "Domein: $($system.Domain)"
    }
    else {
        "Werkgroep: $($system.Workgroup)"
    }

    $entra = 'Status niet beschikbaar'
    $dsregPath = Join-Path $env:SystemRoot 'System32\dsregcmd.exe'
    if (Test-Path $dsregPath) {
        $dsregOutput = & $dsregPath /status 2>$null
        $azureLine = $dsregOutput |
            Where-Object { $_ -match '^\s*AzureAdJoined\s*:' } |
            Select-Object -First 1
        if ($azureLine) { $entra = $azureLine.Trim() }
    }

    $bitlocker = 'Status niet beschikbaar'
    try {
        $volume = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
        $bitlocker = "$($volume.ProtectionStatus) / $($volume.VolumeStatus)"
    }
    catch {
        $manageBde = Join-Path $env:SystemRoot 'System32\manage-bde.exe'
        if (Test-Path $manageBde) {
            $lines = & $manageBde -status C: 2>$null |
                Where-Object { $_ -match 'Protection Status|Conversion Status' }
            if ($lines) { $bitlocker = ($lines -join '; ').Trim() }
        }
    }

    $tpmStatus = 'Niet beschikbaar'
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        $tpmStatus = "Aanwezig=$($tpm.TpmPresent), klaar=$($tpm.TpmReady), versie=$($tpm.ManufacturerVersion)"
    }
    catch { }

    $batteryStatus = 'Niet van toepassing'
    if ($script:FormFactor -eq 'Laptop/Tablet') {
        $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($battery) {
            $batteryStatus = "Lading $($battery.EstimatedChargeRemaining)%; batterijgezondheid niet beschikbaar via standaard-WMI"
        }
        else {
            $batteryStatus = 'Batterij niet gedetecteerd'
        }
    }

    $apps = @(Get-InstalledApplication)
    $office = @($apps | Where-Object { $_ -match 'Microsoft 365|Microsoft Office|Office 16' })
    $dattoApps = @($apps | Where-Object { $_ -match 'Datto|CentraStage|Autotask Endpoint' })
    $trendApps = @($apps | Where-Object { $_ -match 'Trend Micro|Worry-Free|Security Agent|Apex One' })
    $services = @(Get-Service -ErrorAction SilentlyContinue)
    $dattoServices = @($services | Where-Object {
        $_.Name -match 'Datto|CentraStage|CagService' -or
        $_.DisplayName -match 'Datto|CentraStage'
    })
    $trendServices = @($services | Where-Object {
        $_.Name -match 'TMBMServer|NTRTScan|TmCCSF' -or
        $_.DisplayName -match 'Trend Micro|Worry-Free'
    })

    $fastStartup = (Get-ItemProperty `
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
        -ErrorAction SilentlyContinue).HiberbootEnabled
    $rebootPending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')

    $language = 'Niet beschikbaar'
    try {
        $language = (Get-WinUserLanguageList | ForEach-Object {
            "$($_.Language):$($_.InputMethodTips -join ',')"
        }) -join '; '
    }
    catch { }

    $network = @($adapters | ForEach-Object { "$($_.Name): $($_.Status)" })
    $microphones = @($audio | Where-Object {
        $_.FriendlyName -match 'Mic|Microfoon'
    } | ForEach-Object { $_.FriendlyName })
    $audioOutputs = @($audio | Where-Object {
        $_.FriendlyName -notmatch 'Mic|Microfoon'
    } | ForEach-Object { $_.FriendlyName })
    $diskDetails = @($disks | ForEach-Object {
        "$($_.DeviceID) $([math]::Round($_.FreeSpace / 1GB, 1)) GB vrij / $([math]::Round($_.Size / 1GB, 1)) GB"
    })

    return [pscustomobject]@{
        Manufacturer = $system.Manufacturer
        Model        = $system.Model
        ProductNumber = $system.SystemSKUNumber
        SerialNumber = $bios.SerialNumber
        CPU          = if ($processor) { $processor.Name.Trim() } else { 'Niet beschikbaar' }
        GPU          = (@($video | ForEach-Object { $_.Name } | Select-Object -Unique) -join ', ')
        RAM          = "$ramGB GB; $($memory.Count) bezette / $freeSlots vrije slots"
        Disks        = $diskDetails
        OS           = "$($os.Caption), versie $build"
        Hostname     = $env:COMPUTERNAME
        Monitors     = $monitors
        Network      = $network
        Cameras      = @($cameras | ForEach-Object { $_.FriendlyName })
        Microphones  = $microphones
        Audio        = $audioOutputs
        Battery      = $batteryStatus
        Domain       = $domain
        Entra        = $entra
        BitLocker    = $bitlocker
        TPM          = $tpmStatus
        DattoApps    = $dattoApps
        DattoServices = $dattoServices
        TrendApps    = $trendApps
        TrendServices = $trendServices
        Office       = $office
        FastStartupOff = ($fastStartup -eq 0)
        RebootPending = ($script:NeedReboot -or $rebootPending)
        Language     = $language
    }
}

function Get-ServiceCheck {
    param($InstalledApps, $ServiceList, [string]$AppPattern)

    $installed = @($InstalledApps | Where-Object { $_ -match $AppPattern }).Count -gt 0
    $active = @($ServiceList | Where-Object { $_.Status -eq 'Running' }).Count -gt 0

    if ($installed -and $active) { return 'OK' }
    if ($installed -or $ServiceList.Count -gt 0) { return 'ACTIE NODIG' }
    return 'Niet gevonden'
}

function Format-TicketBlock {
    param([string]$Title, [object[]]$Items)

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add($Title)
    foreach ($item in $Items) {
        $lines.Add("- $($item.Title)")
        foreach ($detail in $item.Details) {
            $lines.Add("    > $detail")
        }
    }
    return ($lines -join "`r`n")
}

function New-TicketOutput {
    param($Inventory)

    $customerItems = New-Object 'System.Collections.Generic.List[object]'
    $customerItems.Add([pscustomobject]@{
        Title = 'Ticketgegevens geregistreerd'
        Details = @(
            "Klant: $script:CustomerName; ticket: $script:TicketNumber."
        )
    })

    foreach ($action in $script:Actions) {
        if ($action.Title -match 'account|wachtwoord|BitLocker|TPM|Datto|Trend|domein|Entra|Snel opstarten|herstart|taal|toetsenbord|VPN|audit|bloatware|beleid') {
            continue
        }
        $customerItems.Add($action)
    }

    if ($Inventory.Monitors.Count -gt 0) {
        $screens = ($Inventory.Monitors | ForEach-Object {
            "$($_.Manufacturer) $($_.Model), SN $($_.Serial)"
        }) -join '; '
    }
    else {
        $screens = 'Geen EDID-schermen gedetecteerd'
    }

    $diskText = if ($Inventory.Disks.Count) {
        $Inventory.Disks -join '; '
    }
    else {
        'Geen lokale schijven gedetecteerd'
    }

    $customerItems.Add([pscustomobject]@{
        Title = 'Hardware-inventaris opgenomen'
        Details = @(
            "Model: $($Inventory.Manufacturer) $($Inventory.Model); productnummer: $($Inventory.ProductNumber); serienummer: $($Inventory.SerialNumber).",
            "CPU: $($Inventory.CPU); GPU: $($Inventory.GPU); RAM: $($Inventory.RAM).",
            "Schijven: $diskText.",
            "Windows: $($Inventory.OS); huidige toestelnaam: $($Inventory.Hostname).",
            "Schermen: $screens."
        )
    })

    $networkText = if ($Inventory.Network.Count) { $Inventory.Network -join '; ' } else { 'Geen fysieke adapters gedetecteerd' }
    $cameraText = if ($Inventory.Cameras.Count) { $Inventory.Cameras -join ', ' } else { 'Geen actieve webcam gedetecteerd' }
    $micText = if ($Inventory.Microphones.Count) { $Inventory.Microphones -join ', ' } else { 'Geen actieve microfoon gedetecteerd' }
    $audioText = if ($Inventory.Audio.Count) { $Inventory.Audio -join ', ' } else { 'Geen actief audio-uitvoerapparaat gedetecteerd' }

    $customerItems.Add([pscustomobject]@{
        Title = 'Randapparatuur en netwerk gecontroleerd'
        Details = @(
            "Netwerkadapters: $networkText.",
            "Webcams: $cameraText.",
            "Microfoons: $micText.",
            "Audio-uitvoer: $audioText.",
            "Batterij: $($Inventory.Battery)."
        )
    })

    if ($script:UpdateNote) {
        $customerItems.Add([pscustomobject]@{
            Title = 'Windows Updates gecontroleerd'
            Details = @($script:UpdateNote)
        })
    }

    $customerBlock = Format-TicketBlock `
        "[WERKINGSKLAAR MAKEN $script:ComputerName]" `
        $customerItems.ToArray()

    $internalItems = New-Object 'System.Collections.Generic.List[object]'
    $credentialDetails = @($script:Credentials | ForEach-Object {
        "$($_.User) -> $($_.Password)"
    })
    if ($credentialDetails.Count -eq 0) {
        $credentialDetails = @('Geen lokale accounts aangemaakt.')
    }

    $internalItems.Add([pscustomobject]@{
        Title = 'Lokale accounts'
        Details = $credentialDetails
    })
    $internalItems.Add([pscustomobject]@{
        Title = 'Aansluiting en beveiligingsstatus gecontroleerd'
        Details = @(
            "Domein/werkgroep: $($Inventory.Domain); Entra ID: $($Inventory.Entra).",
            "Datto RMM: $(Get-ServiceCheck $Inventory.DattoApps $Inventory.DattoServices 'Datto|CentraStage|Autotask Endpoint').",
            "Trend Micro Worry-Free: $(Get-ServiceCheck $Inventory.TrendApps $Inventory.TrendServices 'Trend Micro|Worry-Free|Security Agent|Apex One').",
            "BitLocker C:: $($Inventory.BitLocker); TPM 2.0: $($Inventory.TPM).",
            "Microsoft 365/Office geïnstalleerd: $(if ($Inventory.Office.Count) { 'ja' } else { 'nee' }).",
            "Snel opstarten uitgeschakeld: $(if ($Inventory.FastStartupOff) { 'ja' } else { 'nee' }).",
            "Herstart vereist: $(if ($Inventory.RebootPending) { 'ja' } else { 'nee' }).",
            "Windows-taal/invoermethode: $($Inventory.Language)."
        )
    })

    foreach ($warning in $script:Warnings) {
        $internalItems.Add([pscustomobject]@{
            Title = 'Technisch aandachtspunt'
            Details = @($warning)
        })
    }

    $internalBlock = Format-TicketBlock `
        "[TECHNISCHE NOTITIE $script:ComputerName]" `
        $internalItems.ToArray()

    return [pscustomobject]@{
        Customer = $customerBlock
        Internal = $internalBlock
    }
}

function Invoke-Deployment {
    if (-not $script:IsAuditOnly) {
        Set-SystemBaseline

        if ($script:SelectedModules -contains '1') { Install-BasicSoftware }
        if ($script:SelectedModules -contains '2') { Install-Office365 }
        if ($script:SelectedModules -contains '3') { Install-EidSoftware }
        if ($script:SelectedModules -contains '4') {
            Invoke-DeployStep 'Geselecteerde bloatware verwijderen' {
                Remove-CuratedBloatware
            } | Out-Null
        }
        if ($script:SelectedModules -contains '5') { Invoke-VpnPreparation }

        Invoke-WindowsUpdates
        Start-VendorUpdateTools
    }
    else {
        Add-Action 'Alleen audit uitgevoerd' @(
            'Er zijn geen installaties of configuratiewijzigingen gestart.'
        )
        $script:UpdateNote = 'Windows Updates niet gestart in audit-only modus.'
    }

    return Get-HardwareInventory
}

function Write-TicketOutput {
    param($Blocks)

    $combined = $Blocks.Customer + "`r`n`r`n" + $Blocks.Internal

    Write-Host ''
    Write-Host '========== KLANTBLOK ==========' -ForegroundColor Cyan
    Write-Host $Blocks.Customer
    Write-Host ''
    Write-Host '========== TECHNISCHE NOTITIE ==========' -ForegroundColor Yellow
    Write-Host $Blocks.Internal

    try {
        New-Item -Path (Split-Path -Parent $script:OutputFile) `
            -ItemType Directory -Force -ErrorAction Stop | Out-Null
        Set-Content -LiteralPath $script:OutputFile -Value $combined `
            -Encoding UTF8 -ErrorAction Stop
        Write-Status "Ticketblokken opgeslagen in $script:OutputFile" 'OK'
    }
    catch {
        Add-Warning "Ticketbestand kon niet worden opgeslagen: $($_.Exception.Message)"
    }

    if (Read-YesNo 'Beide blokken naar het klembord kopiëren?' $false) {
        try {
            Set-Clipboard -Value $combined -ErrorAction Stop
            Write-Status 'Beide blokken naar het klembord gekopieerd.' 'OK'
        }
        catch {
            Add-Warning "Klembord niet bijgewerkt: $($_.Exception.Message)"
        }
    }

    if (Read-YesNo 'Alleen C:\Temp\Lipa-Ticket-Output.txt opruimen?' $false) {
        try {
            Remove-Item -LiteralPath $script:OutputFile -Force -ErrorAction Stop
            Write-Status 'Ticketbestand verwijderd.' 'OK'
        }
        catch {
            Add-Warning "Ticketbestand kon niet verwijderd worden: $($_.Exception.Message)"
        }
    }
}


function Invoke-HandoverCheck {
    $handoverPath = $null
    $temporaryPath = $null
    $previousProtocol = $null

    try {
        if ($PSScriptRoot) {
            $candidatePath = Join-Path $PSScriptRoot 'Lipa-Handover-Check.ps1'
            if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
                $handoverPath = $candidatePath
            }
        }

        if (-not $handoverPath) {
            $temporaryPath = Join-Path $env:TEMP ("Lipa-Handover-Check-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
            $previousProtocol = [Net.ServicePointManager]::SecurityProtocol
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/LoreGrymonprezPXL/Lipa-Automation-Tools/refs/heads/main/checks/Lipa-Handover-Check.ps1' -OutFile $temporaryPath -UseBasicParsing -ErrorAction Stop
            }
            finally {
                [Net.ServicePointManager]::SecurityProtocol = $previousProtocol
            }

            if (-not (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
                throw 'De Handover Check kon niet naar een tijdelijk bestand worden gedownload.'
            }
            $handoverPath = $temporaryPath
        }

        & $handoverPath -CustomerName $script:CustomerName -TicketNr $script:TicketNumber -CustomerUser $script:EndUser -ExpectedHostname $script:ComputerName
    }
    finally {
        if ($temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
        }
    }
}

function Show-DeployDashboard {
    Clear-Host
    Write-Host '+----------------------------------------------------------+' -ForegroundColor Cyan
    Write-Host '| LIPA ICT - WINDOWS DEPLOY DASHBOARD                      |' -ForegroundColor Cyan
    Write-Host '+----------------------------------------------------------+' -ForegroundColor Cyan
    Write-Host '| 1  Volledige configuratie (baseline, modules en updates) |'
    Write-Host '| 2  Alleen de geselecteerde softwaremodules              |'
    Write-Host '| 3  Alleen systeem-baseline                               |'
    Write-Host '| 4  Alleen Windows- en fabrikantupdates                  |'
    Write-Host '| 5  Alleen controleren en ticketrapport maken             |'
    Write-Host '| 6  Handover Check openen (controle en gericht herstel)   |'
    Write-Host '| 7  Ticketrapport maken van de huidige toestand           |'
    Write-Host '| Q  Stoppen                                                |'
    Write-Host '+----------------------------------------------------------+' -ForegroundColor Cyan
    Write-Host 'M365-aanmelding en SOS Lipa rond je af in de eindgebruikerssessie.' -ForegroundColor Yellow
    Write-Host ''
}

function Confirm-DeployChanges {
    param([string]$ActionName)

    if (-not $script:IsAuditOnly) { return $true }
    return Read-YesNo "Audit-only was geselecteerd. Toch '$ActionName' uitvoeren?" $false
}

function Invoke-DashboardAction {
    param([string]$Choice)

    switch ($Choice) {
        '1' {
            if ($script:IsAuditOnly) {
                Write-Status 'Audit-only actief: er worden geen configuratiewijzigingen of installaties uitgevoerd.' 'INFO'
            }
            $inventory = Invoke-Deployment
            $blocks = New-TicketOutput $inventory
            Write-TicketOutput $blocks
        }
        '2' {
            $softwareModules = @($script:SelectedModules | Where-Object { $_ -in @('1', '2', '3', '4', '5') })
            if ($softwareModules.Count -eq 0) {
                Write-Status 'Geen softwaremodules geselecteerd. Kies bij de intake een of meer modules 1 tot en met 5.' 'WARN'
                return
            }
            if (-not (Confirm-DeployChanges 'de geselecteerde softwaremodules')) { return }

            if ($softwareModules -contains '1') { Install-BasicSoftware }
            if ($softwareModules -contains '2') { Install-Office365 }
            if ($softwareModules -contains '3') { Install-EidSoftware }
            if ($softwareModules -contains '4') {
                Invoke-DeployStep 'Geselecteerde bloatware verwijderen' {
                    Remove-CuratedBloatware
                } | Out-Null
            }
            if ($softwareModules -contains '5') { Invoke-VpnPreparation }
            [void](Get-HardwareInventory)
        }
        '3' {
            if (-not (Confirm-DeployChanges 'de systeem-baseline')) { return }
            Set-SystemBaseline
            [void](Get-HardwareInventory)
        }
        '4' {
            if (-not (Confirm-DeployChanges 'Windows- en fabrikantupdates')) { return }
            Invoke-WindowsUpdates
            Start-VendorUpdateTools
            [void](Get-HardwareInventory)
        }
        '5' {
            $previousAuditOnly = $script:IsAuditOnly
            $previousModules = $script:SelectedModules
            try {
                $script:IsAuditOnly = $true
                $script:SelectedModules = @()
                $inventory = Invoke-Deployment
                $blocks = New-TicketOutput $inventory
                Write-TicketOutput $blocks
            }
            finally {
                $script:IsAuditOnly = $previousAuditOnly
                $script:SelectedModules = $previousModules
            }
        }
        '6' {
            Invoke-HandoverCheck
        }
        '7' {
            $inventory = Get-HardwareInventory
            Add-Action 'Inventarisatie uitgevoerd' @('Huidige hardware- en softwaretoestand opgenomen in het ticketrapport.')
            $blocks = New-TicketOutput $inventory
            Write-TicketOutput $blocks
        }
        default {
            Write-Status "Onbekende keuze '$Choice'. Kies 1 tot en met 7 of Q." 'WARN'
        }
    }
}

try {
    if (-not (Test-Administrator)) {
        Write-Status 'Administratorrechten zijn vereist; er wordt om elevation gevraagd.' 'WARN'
        if (Start-ElevatedCopy) { exit }
    }

    Write-Host 'Lipa ICT - Windows toestel klaarzetten' -ForegroundColor Cyan
    $intakeReady = $false

    while ($true) {
        Show-DeployDashboard
        $choice = (Read-Host 'Keuze (1-7, Q = stoppen)').Trim().ToUpperInvariant()
        if ($choice -eq 'Q') { break }
        if (-not $choice) { continue }
        if ($choice -notin @('1', '2', '3', '4', '5', '6', '7')) {
            Write-Status "Onbekende keuze '$choice'. Kies 1 tot en met 7 of Q." 'WARN'
            [void](Read-Host 'Druk op Enter om terug te keren naar het dashboard')
            continue
        }

        try {
            if ($choice -eq '6') {
                Invoke-HandoverCheck
            }
            else {
                if (-not $intakeReady) {
                    $profile = Get-DeviceProfile
                    Write-Host "Detectie: $($profile.OS.Caption), editie $script:Edition, toesteltype $script:FormFactor"
                    Read-Intake $profile
                    $intakeReady = $true
                    if ($script:IsAuditOnly) {
                        Write-Status 'Audit-only geselecteerd. Configuratiewijzigingen vragen afzonderlijke bevestiging.' 'INFO'
                    }
                }
                Invoke-DashboardAction $choice
            }
        }
        catch {
            Write-Status "Actie '$choice' mislukt: $($_.Exception.Message)" 'FAIL'
            Write-Host 'De dashboard-sessie blijft open; controleer de fout voordat je verdergaat.' -ForegroundColor Yellow
        }

        [void](Read-Host 'Druk op Enter om terug te keren naar het dashboard')
    }

    Write-Host ''
    Write-Status 'Dashboard afgesloten. Bewaar de technische notitie beveiligd en verwijder ze na veilige opslag.' 'OK'
    if ($script:NeedReboot) {
        Write-Status 'Een herstart is vereist om wijzigingen volledig toe te passen.' 'WARN'
    }
}
catch {
    Write-Status "Fatale fout: $($_.Exception.Message)" 'FAIL'
    Write-Host 'Controleer de foutmelding; het resultaat is niet als volledig gevalideerd gemarkeerd.' -ForegroundColor Yellow
}
