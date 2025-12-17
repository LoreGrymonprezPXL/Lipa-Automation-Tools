<#
.SYNOPSIS
  Voert een robuuste back-up uit van de Briljant applicatiedata naar de centrale fileserver,
  inclusief logging en statusrapportage via e-mail.

.NOTES
  Auteur: Lore (Lipa ICT)
  Versie: 3.1 (Security Fix & Clixml implementation)
#>

# --- CONFIGURATIE (TO DO: Aanpassen voor Productie) ---
$LogboekPath = "C:\TestBriljantDest\backuplog.txt"
$TempLogPath = "C:\BackupBriljant\BackupBriljantLog.txt"
$Source      = "C:\TestBriljantSource" 
$Destination = "C:\TestBriljantDest" 
$EmailFrom      = "noreply@itbeheer.be"
$EmailTo        = "backup@lipa.be"
$SmtpServer     = "smtp-auth.mailprotect.be"
$SmtpPort       = 587
$ErrorLogPath   = "C:\BackupBriljant\BackupBriljantErrors.txt" 
$DateNow        = Get-Date -Format "dd-MM-yyyy HH:mm:ss"
$CredentialPath = "C:\BackupBriljant\SmtpCredential.xml"

Clear-Host

# --- LIPA LOGO ---

$LipaLogo = @"
 ___       ___  ________  ________     
|\  \     |\  \|\   __  \|\   __  \    
\ \  \    \ \  \ \  \|\  \ \  \|\  \   
 \ \  \    \ \  \ \   ____\ \   __  \  
  \ \  \____\ \  \ \  \___|\ \  \ \  \ 
   \ \_______\ \__\ \__\    \ \__\ \__\
    \|_______|\|__|\|__|     \|__|\|__| 
                                        
"@ 
Write-Host $LipaLogo -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Briljant Back-up Script V3.1" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Green


# --- VOORBEREIDING & DIRECTORY CHECKS ---
if (-not (Test-Path (Split-Path $LogboekPath -Parent))) {
    New-Item -ItemType Directory -Path (Split-Path $LogboekPath -Parent) -Force | Out-Null
}
if (-not (Test-Path (Split-Path $TempLogPath -Parent))) {
    New-Item -ItemType Directory -Path (Split-Path $TempLogPath -Parent) -Force | Out-Null
}

# --- REFERENTIES (SECURE XML CHECK) ---
if (-not (Test-Path $CredentialPath)) {
    Write-Host "FATALE FOUT: Bestand $CredentialPath niet gevonden." -ForegroundColor Red
    Write-Host "Voer eerst de eenmalige setup uit om het wachtwoord op te slaan." -ForegroundColor Red
    return # Stopt het script hier omdat we niet kunnen mailen zonder wachtwoord
} else {
    # Laadt de volledige credential (User + Pass)
    $Credential = Import-Clixml -Path $CredentialPath
    Write-Host "Beveiligde referenties geladen." -ForegroundColor DarkGreen
}

# --- START LOGGEN & E-MAIL HEADER ---
"start $DateNow" | Add-Content -Path $LogboekPath

"Briljant Backup - LIPA-SERVER02"               | Set-Content -Path $TempLogPath 
""                                              | Add-Content -Path $TempLogPath
"From Location: $Source"                        | Add-Content -Path $TempLogPath
"To Location: $Destination"                     | Add-Content -Path $TempLogPath
"Started on $DateNow"                           | Add-Content -Path $TempLogPath
"----------------------------------------"      | Add-Content -Path $TempLogPath
"--- Robocopy Log ---"                          | Add-Content -Path $TempLogPath 
"-----------------------------------"           | Add-Content -Path $TempLogPath 


# --- DE BACK-UP (ROBOCOPY) ---
Write-Host ""
Write-Host "START BACK-UP" -ForegroundColor Yellow
Write-Host "-----------------" -ForegroundColor Yellow
Write-Host "Bron: $Source" -ForegroundColor DarkGray
Write-Host "Doel: $Destination" -ForegroundColor DarkGray
Write-Host "Starten van Robocopy..." -ForegroundColor Cyan

# CRUCIAAL: Robocopy output toevoegen aan $TempLogPath
& robocopy.exe "$Source" "$Destination" /E /ZB /R:2 /W:5 /LOG+:"$TempLogPath" | Out-Host

# --- STATUSCHECK ---
$RobocopyExitCode = $LASTEXITCODE

if ($RobocopyExitCode -le 7) {
    $MailBodyStatusLine = "BACKUP STATUS: SUCCES/VOLTOOID (Code: $RobocopyExitCode). Geen fatale fouten."
    $FinalSubject = "Briljant Backup - LIPA-SERVER02: backup successful "
} else {
    $MailBodyStatusLine = "BACKUP STATUS: FOUT (Code: $RobocopyExitCode). FATALE FOUT opgetreden!"
    $FinalSubject = "Briljant Backup - LIPA-SERVER02: Failed"
}

Select-String -Path $TempLogPath -Pattern "FAILED" | Select-Object -ExpandProperty Line | Out-File $ErrorLogPath -Encoding ASCII

# --- EINDE LOGGEN & E-MAIL FOOTER ---
$EndDate = Get-Date -Format "dd-MM-yyyy HH:mm:ss"

# --- EMAIL BODY FOUT LOG (ALS NODIG) ---
$ErrorContent = Get-Content -Path $ErrorLogPath -ErrorAction SilentlyContinue | Out-String

if ($ErrorContent) {
    "`n========================================" | Add-Content -Path $TempLogPath
    "NOK OVERZICHT: MISLUKTE BESTANDEN (FAILED)" | Add-Content -Path $TempLogPath
    "========================================" | Add-Content -Path $TempLogPath
    $ErrorContent | Add-Content -Path $TempLogPath
    "----------------------------------------" | Add-Content -Path $TempLogPath
} else {
    "`n OK GEEN FOUTEN: Er zijn geen mislukte bestanden gedetecteerd." | Add-Content -Path $TempLogPath
}

# Hoofdlogboek Afsluiting
"einde $EndDate" | Add-Content -Path $LogboekPath
"Status Code: $RobocopyExitCode" | Add-Content -Path $LogboekPath
"----------------------------------------" | Add-Content -Path $LogboekPath

# E-mail Footer
$MailBodyStatusLine                          | Add-Content -Path $TempLogPath
"Ended on $EndDate"                          | Add-Content -Path $TempLogPath
"----------------------------------------"   | Add-Content -Path $TempLogPath

# --- E-MAIL VERZENDING ---
Write-Host ""
Write-Host "--- Status & Notificatie ---" -ForegroundColor Yellow
Write-Host "Status: $MailBodyStatusLine" -ForegroundColor White
Write-Host "Logboek versturen per mail naar $EmailTo..." -ForegroundColor Cyan
$MailBody = Get-Content -Path $TempLogPath | Out-String

try {
    Send-MailMessage -From $EmailFrom `
                     -To $EmailTo `
                     -Subject $FinalSubject `
                     -Body $MailBody `
                     -SmtpServer $SmtpServer `
                     -Port $SmtpPort `
                     -UseSsl `
                     -Credential $Credential `
                     -ErrorAction Stop
                      
    Write-Host "E-mail succesvol verzonden." -ForegroundColor Green
}
catch {
    Write-Host "Fout bij versturen e-mail: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Check of de SMTP user/pass correct zijn opgeslagen in de XML." -ForegroundColor DarkRed

}
