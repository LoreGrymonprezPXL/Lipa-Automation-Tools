# --- LIPA LOGO ---
Clear-Host
$LipaLogo = @"
 ___        ___  ________  ________      
|\  \      |\  \|\   __  \|\   __  \    
\ \  \     \ \  \ \  \|\  \ \  \|\  \   
 \ \  \     \ \  \ \   ____\ \   __  \  
  \ \  \____ \ \  \ \  \___|\ \  \ \  \ 
   \ \_______\\ \__\ \__\    \ \__\ \__\
    \|_______| \|__|\|__|     \|__|\|__| 
                                        
"@ 
Write-Host $LipaLogo -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "      AvePoint Account Script V4" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

# --- MODULE CHECK ---
if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
    Write-Host "Module installeren..." -ForegroundColor Yellow
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber
    Install-Module Microsoft.Graph.Users -Scope CurrentUser -Force -AllowClobber
    Install-Module Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser -Force -AllowClobber
    Import-Module Microsoft.Graph.Authentication
}

# --- STAP 1: LOGIN (MET ERROR DETAILS) ---
Write-Host "Vorige sessies verbreken..." -ForegroundColor Gray
Disconnect-MgGraph -ErrorAction SilentlyContinue

Write-Host "Login venster wordt geopend..." -ForegroundColor Yellow

try {
    Connect-MgGraph -Scopes "User.ReadWrite.All", "RoleManagement.ReadWrite.Directory", "Domain.Read.All"  -ErrorAction Stop
}
catch {
    Write-Host ""
    Write-Host "LOGIN MISLUKT (CRITICAL ERROR)" -ForegroundColor Red
    Write-Host "--------------------------------------------------------" -ForegroundColor Red
    Write-Host "Foutmelding: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "Type:        $($_.Exception.GetType().Name)" -ForegroundColor Gray
    Write-Host "Detail:      $($_)" -ForegroundColor Gray
    Write-Host "--------------------------------------------------------" -ForegroundColor Red
    return 
}

$Context = Get-MgContext
if (-not $Context) {
    Write-Host ""
    Write-Host "GEEN SESSIE GEVONDEN." -ForegroundColor Red
    Write-Host "Het venster is mogelijk weggeklikt of geblokkeerd." -ForegroundColor Yellow
    return
}

Write-Host "Ingelogd met: $($Context.Account)" -ForegroundColor Cyan
Write-Host ""

# --- STAP 2: CONFIGURATIE VRAGEN ---
Write-Host "----------------------------------------" -ForegroundColor Cyan
$InputName = Read-Host "Hoe moet het account heten? (Bijv: Test, AvePoint Backup) [Standaard: Avepoint Backup]"

if ([string]::IsNullOrWhiteSpace($InputName)) {
    $AccountNaam = "Avepoint Backup"
} else {
    $AccountNaam = $InputName
}
Write-Host "Gekozen DisplayNaam: $AccountNaam" -ForegroundColor Green

# --- GEGEVENS SAMENSTELLEN ---
try {
    $InitialDomain = (Get-MgDomain | Where-Object { $_.IsInitial -eq $true }).Id
    $TenantName = $InitialDomain.Split(".")[0]
}
catch {
    Write-Error "Kan domein niet ophalen. Login lijkt mislukt."
    return
}

# SLIMME NAAM LOGICA:
# 1. Email/Nickname 
$ShortName = $AccountNaam.Split(" ")[0]

# 2. DisplayName = De volledige naam 
$DisplayName = $AccountNaam

# Samenstellen
$UserPrincipalName = "$ShortName@$InitialDomain"
$MailNickname = $ShortName

Write-Host "Ingestelde Email:    $UserPrincipalName" -ForegroundColor Gray
Write-Host "----------------------------------------" -ForegroundColor Cyan
Write-Host ""

# --- WACHTWOORD LOGICA ---
Write-Host "Kies een wachtwoord methode:" -ForegroundColor Yellow
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

# Maak het wachtwoord object voor Graph
$PasswordProfile = @{
    Password = $PlainPassword
    ForceChangePasswordNextSignIn = $false
}

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
        Write-Host "Je koos '$ShortName', dus dat woord mag NIET in je wachtwoord zitten." -ForegroundColor Yellow
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
        Write-Host "Bestaande gebruiker gevonden & wachtwoord geüpdatet." -ForegroundColor Green
    }
    catch {
         Write-Error "CRITISCH: Kan gebruiker niet maken en niet vinden."
         return
    }
}

# --- ROL TOEWIJZEN ---
$GlobalAdminTemplateId = "62e90394-69f5-4237-9190-012177145e10" 
$Role = Get-MgDirectoryRole | Where-Object { $_.RoleTemplateId -eq $GlobalAdminTemplateId }

if ($null -eq $Role) {
    Enable-MgDirectoryRole -RoleTemplateId $GlobalAdminTemplateId
    $Role = Get-MgDirectoryRole | Where-Object { $_.RoleTemplateId -eq $GlobalAdminTemplateId }
}

try {
    New-MgDirectoryRoleMemberByRef -DirectoryRoleId $Role.Id -BodyParameter @{
        "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($NewUser.Id)"
    }
    Write-Host "Global Admin rechten toegewezen." -ForegroundColor Green
}
catch {
    Write-Host "Rechten waren al correct." -ForegroundColor Yellow
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
Created by: Lipa Script V4
Settings:
 - DisplayName: $DisplayName
 - Role: Global Administrator
 - Location: BE (Belgium)
 - Password Type: $PasswordTypeUsed
 - License: None (Service Account)

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
Write-Host "Je kunt dit bestand nu openen voor de documentatie." -ForegroundColor Gray
Write-Host "Verwijder dit bestand nadat je de gegevens in keeper hebt ingegeven!" -ForegroundColor Red