# --- LIPA LOGO ---
Clear-Host
$LipaLogo = @"
 ___        ___  ________  ________      
|\  \      |\  \|\   __  \|\   __  \    
\ \  \     \ \  \ \  \|\  \ \  \|\  \   
 \ \  \     \ \  \ \   ____\ \   __  \  
  \ \  \____\ \  \ \  \___|\ \  \ \  \ 
   \ \_______\ \__\ \__\    \ \__\ \__\
    \|_______|\|__|\|__|     \|__|\|__| 
                                        
"@ 
Write-Host $LipaLogo -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "      AvePoint Account Script V5.7" -ForegroundColor White
Write-Host "        (Cache Cleaner Edition)" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

# --- MODULE CHECK ---
if (-not (Get-Module -ListAvailable Microsoft.Graph.Groups)) {
    Write-Host "Module 'Microsoft.Graph.Groups' ontbreekt. Installeren..." -ForegroundColor Yellow
    Install-Module Microsoft.Graph.Groups -Scope CurrentUser -Force -AllowClobber
}

if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
    Write-Host "Module 'Microsoft.Graph.Authentication' ontbreekt. Installeren..." -ForegroundColor Yellow
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber
    Install-Module Microsoft.Graph.Users -Scope CurrentUser -Force -AllowClobber
    Install-Module Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser -Force -AllowClobber
}

Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Groups
Import-Module Microsoft.Graph.Users

# --- STAP 1: LOGIN & CACHE CLEANUP ---
$env:MSAL_USE_WAM = "false"

Write-Host "Vorige sessies verbreken..." -ForegroundColor Gray
Disconnect-MgGraph -ErrorAction SilentlyContinue


$CachePath = "$env:USERPROFILE\.Graph"
if (Test-Path $CachePath) {
    Write-Host "Oude login-cache wissen..." -ForegroundColor Gray
    Remove-Item $CachePath -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Login venster wordt geopend..." -ForegroundColor Yellow

try {
    Connect-MgGraph -Scopes "User.ReadWrite.All", "Group.ReadWrite.All", "RoleManagement.ReadWrite.Directory", "Domain.Read.All" -ErrorAction Stop
}
catch {
    Write-Host ""
    Write-Host "LOGIN MISLUKT (CRITICAL ERROR)" -ForegroundColor Red
    Write-Host "Foutmelding: $($_.Exception.Message)" -ForegroundColor Yellow
    return 
}

$Context = Get-MgContext
if (-not $Context) {
    Write-Host "GEEN SESSIE GEVONDEN." -ForegroundColor Red
    return
}

# --- VEILIGHEIDSCHECK ---
Clear-Host
Write-Host "--------------------------------------------------" -ForegroundColor Cyan
Write-Host "              CONTROLEER JE LOGIN" -ForegroundColor White
Write-Host "--------------------------------------------------" -ForegroundColor Cyan
Write-Host "Je bent nu ingelogd als:" -ForegroundColor Gray
Write-Host "$($Context.Account)" -ForegroundColor Yellow
Write-Host ""
Write-Host "CHECK: Is dit de juiste klant?" -ForegroundColor White
Write-Host "JA  -> Druk op ENTER om door te gaan." -ForegroundColor Green
Write-Host "NEE -> Sluit dit venster en begin opnieuw." -ForegroundColor Red
Write-Host "--------------------------------------------------" -ForegroundColor Cyan
$null = Read-Host "Druk op ENTER..."

# --- STAP 2: CONFIGURATIE VRAGEN ---
Write-Host ""
Write-Host "--- Account Instellingen ---" -ForegroundColor Cyan
$InputName = Read-Host "Hoe moet het account heten? (Bijv: AvePoint Backup) [Standaard: Avepoint Backup]"
if ([string]::IsNullOrWhiteSpace($InputName)) { $AccountNaam = "Avepoint Backup" } else { $AccountNaam = $InputName }
Write-Host "Gekozen Naam: $AccountNaam" -ForegroundColor Green
Write-Host ""

# B. Licentie Type
Write-Host "--- Licentie Type ---" -ForegroundColor Cyan
Write-Host "[1] POOL Licentie (Volledige Tenant - Geen Security Group)" -ForegroundColor White
Write-Host "[2] SINGLE Licentie (Selectief - Via Security Group)" -ForegroundColor White
$ScopeChoice = Read-Host "Maak uw keuze (1 of 2)"

$SecurityGroupName = $null
$LicenseLogStatus = "Pool License (Full Tenant)"

if ($ScopeChoice -eq "2") {
    $InputGroup = Read-Host "Naam Security Group? [Standaard: Avepoint Backup]"
    if ([string]::IsNullOrWhiteSpace($InputGroup)) { $SecurityGroupName = "Avepoint Backup" } else { $SecurityGroupName = $InputGroup }
    Write-Host "Er zal een Security Group gemaakt worden: '$SecurityGroupName'" -ForegroundColor Yellow
    $LicenseLogStatus = "Single License (Group: $SecurityGroupName)"
} else {
    Write-Host "Pool Licentie geselecteerd (Geen groep nodig)." -ForegroundColor Gray
}
Write-Host ""

# --- GEGEVENS SAMENSTELLEN ---
try {
    $InitialDomain = (Get-MgDomain | Where-Object { $_.IsInitial -eq $true }).Id
    $TenantName = $InitialDomain.Split(".")[0]
}
catch {
    Write-Error "Kan domein niet ophalen."
    return
}

$ShortName = $AccountNaam.Split(" ")[0]
$DisplayName = $AccountNaam
$UserPrincipalName = "$ShortName@$InitialDomain"
$MailNickname = $ShortName

# --- WACHTWOORD LOGICA ---
Write-Host "--- Beveiliging ---" -ForegroundColor Cyan
Write-Host "[1] Eigen wachtwoord invoeren" -ForegroundColor White
Write-Host "[2] Automatisch sterk wachtwoord genereren" -ForegroundColor White
$PwChoice = Read-Host "Maak uw keuze (1 of 2)"

$PlainPassword = ""
$PasswordTypeUsed = ""

if ($PwChoice -eq "2") {
    $CharSet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%"
    $Rnd = New-Object System.Random
    $PlainPassword = (-join (1..16 | ForEach-Object { $CharSet[$Rnd.Next($CharSet.Length)] }))
    $PasswordTypeUsed = "Generated (Random)"
    Write-Host "Wachtwoord gegenereerd." -ForegroundColor Green
}
else {
    $SecureInput = Read-Host -Prompt "Geef uw wachtwoord op" -AsSecureString
    $PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureInput))
    $PasswordTypeUsed = "Custom (User Input)"
}

$PasswordProfile = @{ Password = $PlainPassword; ForceChangePasswordNextSignIn = $false }

# --- GEBRUIKER AANMAKEN ---
$NewUser = $null

try {
    $NewUser = New-MgUser -DisplayName $DisplayName `
                          -UserPrincipalName $UserPrincipalName `
                          -MailNickname $MailNickname `
                          -PasswordProfile $PasswordProfile `
                          -AccountEnabled:$true `
                          -UsageLocation "BE" `
                          -ErrorAction Stop
                          
    Write-Host "Gebruiker '$ShortName' succesvol aangemaakt." -ForegroundColor Green
}
catch {
    $RawError = $_.Exception.Message
    if ($RawError -match "Password cannot contain username") {
        Write-Host "FOUT: WACHTWOORD MAG GEBRUIKERSNAAM NIET BEVATTEN." -ForegroundColor Red
        return
    }
    elseif ($RawError -match "Password") {
        Write-Host "FOUT: WACHTWOORD VOLDOET NIET AAN EISEN." -ForegroundColor Red
        return
    }
    
    Write-Host "Gebruiker bestaat waarschijnlijk al. Update modus..." -ForegroundColor Yellow
    try {
        $NewUser = Get-MgUser -UserId $UserPrincipalName -ErrorAction Stop
        Update-MgUser -UserId $NewUser.Id -PasswordProfile $PasswordProfile
        Write-Host "Bestaande gebruiker geüpdatet." -ForegroundColor Green
    }
    catch {
         Write-Error "CRITISCH: Kan gebruiker niet maken en niet vinden."
         return
    }
}

# --- SECURITY GROUP AANMAKEN (ALLEEN BIJ SINGLE LICENSE) ---
if ($SecurityGroupName) {
    try {
        $ExistingGroup = Get-MgGroup -Filter "displayName eq '$SecurityGroupName'" -ErrorAction SilentlyContinue
        
        if ($ExistingGroup) {
            Write-Host "Security Group '$SecurityGroupName' bestaat al." -ForegroundColor Yellow
        }
        else {
            $CleanNick = $SecurityGroupName.Replace(" ", "")
            New-MgGroup -DisplayName $SecurityGroupName -MailEnabled:$false -SecurityEnabled:$true -MailNickname $CleanNick -ErrorAction Stop
            Write-Host "Security Group '$SecurityGroupName' succesvol aangemaakt." -ForegroundColor Green
        }
    }
    catch {
        Write-Host "FOUT BIJ MAKEN GROEP: $($_.Exception.Message)" -ForegroundColor Red
        $LicenseLogStatus = "Single License (Failed to create group: $($_.Exception.Message))"
    }
}

# --- ROL TOEWIJZEN ---
$GlobalAdminTemplateId = "62e90394-69f5-4237-9190-012177145e10" 

try {
    $Role = Get-MgDirectoryRole -Filter "roleTemplateId eq '$GlobalAdminTemplateId'" -ErrorAction SilentlyContinue
    if ($null -eq $Role) {
        $RoleTemplate = Get-MgDirectoryRoleTemplate -Filter "id eq '$GlobalAdminTemplateId'"
        Enable-MgDirectoryRole -RoleTemplateId $RoleTemplate.Id
        $Role = Get-MgDirectoryRole -Filter "roleTemplateId eq '$GlobalAdminTemplateId'"
    }

    $Members = Get-MgDirectoryRoleMember -DirectoryRoleId $Role.Id
    if ($Members.Id -contains $NewUser.Id) {
        Write-Host "Rechten waren al correct." -ForegroundColor Yellow
    }
    else {
        New-MgDirectoryRoleMemberByRef -DirectoryRoleId $Role.Id -BodyParameter @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($NewUser.Id)" }
        Write-Host "Global Admin rechten toegewezen." -ForegroundColor Green
    }
}
catch {
    Write-Host "FOUT BIJ RECHTEN: $($_.Exception.Message)" -ForegroundColor Red
}

# --- SUMMARY FILE GENEREREN ---
$DesktopPath = [Environment]::GetFolderPath("Desktop")
$FileDate = Get-Date -Format "yyyyMMdd-HHmm"
$FileName = "$DesktopPath\AvePoint_Setup_${TenantName}_${ShortName}_${FileDate}.txt"
$DateLog = Get-Date -Format "yyyy-MM-dd HH:mm"

$FileContent = @"
[KEEPER]
Email: $UserPrincipalName
Password: $PlainPassword

[TICKET]
Ticket Info: AvePoint Service Account Created
---------------------------------------------
Date: $DateLog
Tenant: $InitialDomain
Account: $UserPrincipalName
Created by: Lipa Script V5.7
Settings:
 - DisplayName: $DisplayName
 - Role: Global Administrator
 - Location: BE (Belgium)
 - Password Type: $PasswordTypeUsed
 - License Type: $LicenseLogStatus

Log: Account successfully provisioned in Azure AD.
"@

$FileContent | Out-File -FilePath $FileName -Encoding UTF8

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "                KLAAR!" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Green
Write-Host "INFO IS OPGESLAGEN OP JE BUREAUBLAD:" -ForegroundColor Cyan
Write-Host "-> $FileName" -ForegroundColor Yellow
Write-Host ""

# --- ACTIE REMINDERS ---
if ($SecurityGroupName) {
    Write-Host "----------------- ACTIE VEREIST -----------------" -ForegroundColor Magenta
    Write-Host "Je hebt gekozen voor een SINGLE LICENTIE (via Groep)." -ForegroundColor Magenta
    Write-Host "De Security Group '$SecurityGroupName' is aangemaakt." -ForegroundColor White
    Write-Host "-> Voeg zelf de te back-uppen gebruikers toe in Admin Center!" -ForegroundColor Magenta
    Write-Host "---------------------------------------------------" -ForegroundColor Magenta
    Write-Host ""
}

Write-Host "Vergeet niet: Verwijder dit bestand na opslag in Keeper." -ForegroundColor Yellow
