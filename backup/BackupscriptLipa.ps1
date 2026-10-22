
<#
.SYNOPSIS
 Geautomatiseerd back-upsysteem voor de Briljant-omgeving met uitgebreide statuscontrole en rapportage.
.DESCRIPTION
    Dit script voert de volgende hoofdtaken uit:
    1. Synchronisatie: Gebruikt Robocopy voor een efficiënte mirror-back-up naar een netwerklocatie.
    2. Bitmask Analyse: Decodeert de Robocopy exitcodes naar menselijke taal (o.a. OK, Mismatch, Extra of Fout).
    3. Foutafhandeling: Extraheert bij falen specifiek de foutmeldingen uit de hoofdlog voor snelle inspectie.
    4. Rapportage: Genereert een gedetailleerde mail-body met statistieken (aantal bestanden, grootte, snelheid).
    5. Logging & Historiek: Onderhoudt een lokaal logboek van alle runs en slaat gespecificeerde logs op per sessie.
    6. Notificatie: Verstuurt een e-mail via beveiligde SMTP (SSL), waarbij logs optioneel worden bijgevoegd op basis van het resultaat.
    
.NOTES
Auteur: Lore (Lipa ICT)
    Versie: V6.2 [Made robot copy status be less negative]
    Advise always welcome in how to improve.
#>

# =========================
# CONFIGURATIE (PROD)
# =========================
$Source          = "C:\Briljant"
$Destination     = "\\lipa-server02\backups\Briljant"
$LogRoot         = "C:\BackupBriljant"
$EmailFrom       = "noreply@itbeheer.be"
$EmailTo         = "backup@lipa.be"
$SmtpServer      = "smtp-auth.mailprotect.be"
$SmtpPort        = 587
$CredentialPath  = Join-Path $LogRoot "SmtpCredential.xml"
$AttachLogsOn    = "WarnOrFailure"
$RunServer       = $env:COMPUTERNAME

# =========================
# LOGGING PARAMS
# =========================
$RunStamp        = Get-Date -Format "yyyyMMdd_HHmmss"
$DateNow         = Get-Date -Format "dd-MM-yyyy HH:mm:ss"

$LogboekPath     = Join-Path $LogRoot "backuplog.txt"                   # timerke
$RoboLogPath     = Join-Path $LogRoot "Robocopy_$RunStamp.log"          # FULL robocopy log
$MailLogPath     = Join-Path $LogRoot "MailSummary_$RunStamp.txt"       # mail body (kort)
$ErrorLogPath    = Join-Path $LogRoot "Errors_$RunStamp.txt"            # extract errors (alleen bij FAILED)

Clear-Host

# --- LIPA LOGO (danku Niels) ---
$LipaLogo = @"
 ___       ___  ________  ________
|\  \     |\  \|\   __  \|\   __  \
\ \  \    \ \  \ \  \|\  \ \  \|\  \
 \ \  \    \ \  \ \   ____\ \   __  \
  \ \  \____\ \  \ \  \___|\ \  \ \  \
   \ \_______\ \__\ \__\    \ \__\ \__\
    \|_______|\|__|\|__|     \|__|\|__|
"@
Write-Host $LipaLogo -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Green
Write-Host "Briljant Back-up Script V6.2" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Green

# --- LOGS & DIRECTORIES ---
$null = New-Item -ItemType Directory -Path $LogRoot -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "LOG BESTANDEN:" -ForegroundColor Yellow
Write-Host "  Robocopy log : $RoboLogPath" -ForegroundColor DarkGray
Write-Host "  Mail summary : $MailLogPath" -ForegroundColor DarkGray
Write-Host "  Error extract: $ErrorLogPath" -ForegroundColor DarkGray
Write-Host "  Historiek    : $LogboekPath" -ForegroundColor DarkGray
Write-Host ""

# --- CREDENTIAL CHECK ---
if (-not (Test-Path $CredentialPath)) {
    Write-Host "FATALE FOUT: SMTP credentialbestand niet gevonden: $CredentialPath" -ForegroundColor Red
    Write-Host "De handleiding voor het aanmaken van SmtpCredential.xml bevindt zich in de sharepoint." -ForegroundColor Yellow
    return
}
$Credential = Import-Clixml -Path $CredentialPath
Write-Host "Beveiligde referenties geladen." -ForegroundColor DarkGreen


# =========================
# FUNCTIES
# =========================


function Get-ServerFromPath {
    param([Parameter(Mandatory)][string]$Path)

    # UNC: \\server\share\...
    if ($Path -match '^[\\]{2}([^\\]+)\\') {
        return $matches[1]
    }

    # lokaal pad
    return $env:COMPUTERNAME
    
}

$SourceServer = Get-ServerFromPath -Path $Source #Dynamish checken voor server name (nodig voor in Lipa cat te komen)
$DestServer   = Get-ServerFromPath -Path $Destination

function Get-RobocopyStatus {
    param([int]$Code)

    $flags = [ordered]@{
        1  = "Bestanden gekopieerd"
        2  = "Bestanden gekopieerd"
        4  = "Bestanden gekopieerd"
        8  = "Enkele bestanden overgeslagen (in gebruik/permission issues)"
        16 = "FATALE FOUT: Robocopy kon niet correct uitvoeren (bv. toegang/path)"
    }

    if ($Code -eq 0) {
        return [PSCustomObject]@{
            Level   = "SUCCESS"
            Code    = 0
            Summary = "Geen wijzigingen (nothing to copy)."
            Failed  = $false
            Warn    = $false
        }
    }

    $hit = @()
    foreach ($k in $flags.Keys) {
        if ($Code -band $k) { $hit += $flags[$k] }
    }

    $failed = ($Code -ge 16)
    $warn   = ($Code -ge 8 -and $Code -lt 16)

    $level =
        if ($failed) { "FAILED" }
        elseif ($warn) { "SUCCESS-WARN" }
        else { "SUCCESS" }

    [PSCustomObject]@{
        Level   = $level
        Code    = $Code
        Summary = ($hit -join " | ")
        Failed  = $failed
        Warn    = $warn
    }
}

function Get-RobocopySummaryFromLog {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return $null }
    $text = Get-Content $Path -ErrorAction SilentlyContinue

    [PSCustomObject]@{
        DirsLine  = ($text | Select-String -Pattern '^\s*Dirs\s*:\s*(.+)$'  | Select-Object -Last 1).Line
        FilesLine = ($text | Select-String -Pattern '^\s*Files\s*:\s*(.+)$' | Select-Object -Last 1).Line
        BytesLine = ($text | Select-String -Pattern '^\s*Bytes\s*:\s*(.+)$' | Select-Object -Last 1).Line
        TimesLine = ($text | Select-String -Pattern '^\s*Times\s*:\s*(.+)$' | Select-Object -Last 1).Line
        SpeedLine = ($text | Select-String -Pattern '^\s*Speed\s*:\s*(.+)$' | Select-Object -Last 1).Line
        EndedLine = ($text | Select-String -Pattern '^\s*Ended\s*:\s*(.+)$' | Select-Object -Last 1).Line
    }
}

function Get-AttachDecision {
    param(
        [string]$Policy,
        [bool]$IsFailed,
        [bool]$IsWarn
    )
    switch ($Policy) {
        "Never"         { $false }
        "Always"        { $true }
        "Failure"       { $IsFailed }
        "WarnOrFailure" { ($IsFailed -or $IsWarn) }
        default         { ($IsFailed -or $IsWarn) }
    }
}

# Functie om de exitcode leesbaar te maken
function Get-RoboLabel {
    param([int]$Code)

    if ($Code -eq 0) { return "NOCHANGE" }

    $parts = @()
    if ($Code -band 1)  { $parts += "Copied" }
    if ($Code -band 2)  { $parts += "Extra" }
    if ($Code -band 4)  { $parts += "Mismatch" }
    if ($Code -band 8)  { $parts += "Failed" }
    if ($Code -band 16) { $parts += "Fatal" }

    ($parts -join " + ")
}

# Uitleg per bit (0/1/2/4/8/16) — bitmask zoals robocopy documentatie (online)
function Get-RoboBitExplainLines {
    param([int]$Code)

    $bitMeaning = [ordered]@{
        0  = "0  = Geen fouten en niets gekopieerd (source en dest zijn gesynchroniseerd)."
        1  = "1  = OKCOPY: 1 of meer bestanden succesvol gekopieerd."
        2  = "2  = XTRA: extra bestanden/dirs in destination (niet in source)."
        4  = "4  = MISMATCHES: mismatches gedetecteerd (attributes/timestamps/verschillen)."
        8  = "8  = FAIL: copy errors (retries opgebruikt) — check log voor details."
        16 = "16 = FATAL: serious error (bv. syntax/rechten/path) — robocopy kon niet correct uitvoeren."
    }

    if ($Code -eq 0) { return @($bitMeaning[0]) }

    $lines = @()
    foreach ($bit in 1,2,4,8,16) {
        if ($Code -band $bit) { $lines += $bitMeaning[$bit] }
    }
    return $lines
}

# =========================
# START TIMER (logboek)
# =========================
"start $DateNow" | Add-Content -Path $LogboekPath -Encoding UTF8


# =========================
# BACKUP (ROBOCOPY)
# =========================
Write-Host "START BACK-UP" -ForegroundColor Yellow
Write-Host "-----------------" -ForegroundColor Yellow
Write-Host "Bron: $Source" -ForegroundColor DarkGray
Write-Host "Doel: $Destination" -ForegroundColor DarkGray
Write-Host "Robocopy log: $RoboLogPath" -ForegroundColor Cyan
Write-Host ""

& robocopy.exe "$Source" "$Destination" `
    /E /ZB /R:2 /W:5 `
    /LOG:"$RoboLogPath" /NP | Out-Null
    
$RobocopyExitCode = $LASTEXITCODE
$status = Get-RobocopyStatus -Code $RobocopyExitCode

$EndDate = Get-Date -Format "dd-MM-yyyy HH:mm:ss"


# =========================
# ERROR EXTRACT (alleen bij FAILED)
# =========================
if ($status.Failed) {
    $ErrorLines = Select-String -Path $RoboLogPath -Pattern "ERROR|FAILED" -ErrorAction SilentlyContinue |
                  Select-Object -ExpandProperty Line

    if ($ErrorLines) {
        $ErrorLines | Set-Content -Path $ErrorLogPath -Encoding UTF8
    } else {
        "Exitcode geeft FAILED aan (Code $($status.Code)), maar geen ERROR/FAILED lijnen gevonden. Check volledige log: $RoboLogPath" |
            Set-Content -Path $ErrorLogPath -Encoding UTF8
    }
} else {
    "" | Set-Content -Path $ErrorLogPath -Encoding UTF8
}


# =========================
# SUBJECT + STATUS LINE
# =========================
#needs lipa-server
$FinalSubject = "Briljant Backup: $($status.Level) (Code $($status.Code))"
$StatusLine   = "BACKUP STATUS: $($status.Level) - Code $($status.Code) - $($status.Summary)"

Write-Host "--- Status ---" -ForegroundColor Yellow
Write-Host $StatusLine -ForegroundColor White
Write-Host ""


# =========================
# MAIL BODY 
# =========================
$summary  = Get-RobocopySummaryFromLog -Path $RoboLogPath
$label    = Get-RoboLabel -Code $RobocopyExitCode
$bitLines = Get-RoboBitExplainLines -Code $RobocopyExitCode

#Opbouw van de email body
@(
    "Briljant Backup - Statusrapport"
    "========================================"
    ""
    "Status      : $($status.Level)"
    "Exitcode    : $($status.Code)"
    "Label       : $label"
    "Betekenis   : $($status.Summary)"
    ""
    "Exitcode decode (bits gezet):"
    ($bitLines | ForEach-Object { "  - $_" })
    ""
    "Start       : $DateNow"
    "Einde       : $EndDate"
    "Bron        : $Source"
    "Doel        : $Destination"
    ""
    "Run server  : $RunServer"
    "Source host : $SourceServer"
    "Target host : $DestServer"
    ""
    "Waar logs te vinden:"
    " - Opgeslagen op: $RunServer"
    " - Robocopy log : $RoboLogPath"
    " - Error extract: $ErrorLogPath"
    " - Historiek    : $LogboekPath"
    ""
    "Samenvatting (Robocopy):"
    $(if ($summary.DirsLine)  { $summary.DirsLine }  else { "Dirs  : (niet gevonden in log)" })
    $(if ($summary.FilesLine) { $summary.FilesLine } else { "Files : (niet gevonden in log)" })
    $(if ($summary.BytesLine) { $summary.BytesLine } else { "Bytes : (niet gevonden in log)" })
    $(if ($summary.TimesLine) { $summary.TimesLine })
    $(if ($summary.SpeedLine) { $summary.SpeedLine })
    ""
) | ForEach-Object { $_ } | Where-Object { $_ -ne $null } | Set-Content -Path $MailLogPath -Encoding UTF8

# Alleen bij FAILED: foutdetail preview
if ($status.Failed) {
    Add-Content -Path $MailLogPath -Encoding UTF8 -Value @(
        "----------------------------------------"
        "FOUTDETAIL (eerste 20 lijnen):"
        "----------------------------------------"
    )

    $ErrorPreview = Get-Content -Path $ErrorLogPath -ErrorAction SilentlyContinue | Select-Object -First 20
    if ($ErrorPreview) {
        $ErrorPreview | Add-Content -Path $MailLogPath -Encoding UTF8
        Add-Content -Path $MailLogPath -Encoding UTF8 -Value ""
        Add-Content -Path $MailLogPath -Encoding UTF8 -Value "Bekijk volledige details in: $RoboLogPath"
    } else {
        Add-Content -Path $MailLogPath -Encoding UTF8 -Value "Geen errorlijnen gevonden. Check volledige robocopy log: $RoboLogPath"
    }
}

# =========================
# END TIMER (logboek)
# =========================
"einde $EndDate" | Add-Content -Path $LogboekPath -Encoding UTF8
"Status Code: $RobocopyExitCode" | Add-Content -Path $LogboekPath -Encoding UTF8
"----------------------------------------" | Add-Content -Path $LogboekPath -Encoding UTF8


# =========================
# EMAIL VERZENDEN
# =========================
$MailBody = Get-Content -Path $MailLogPath -Raw

$doAttach = Get-AttachDecision -Policy $AttachLogsOn -IsFailed $status.Failed -IsWarn $status.Warn

$attachments = @()
if ($doAttach) {
    if (Test-Path $RoboLogPath) { $attachments += $RoboLogPath }
    if ($status.Failed -and (Test-Path $ErrorLogPath)) { $attachments += $ErrorLogPath }
}

Write-Host "Mail sturen naar $EmailTo..." -ForegroundColor Cyan
Write-Host "Attachments policy: $AttachLogsOn (attach = $doAttach)" -ForegroundColor DarkGray

try {
    $mailParams = @{
        From        = $EmailFrom
        To          = $EmailTo
        Subject     = $FinalSubject
        Body        = $MailBody
        SmtpServer  = $SmtpServer
        Port        = $SmtpPort
        UseSsl      = $true
        Credential  = $Credential
        ErrorAction = "Stop"
    }

    if ($attachments.Count -gt 0) {
        $mailParams["Attachments"] = $attachments
    }

    Send-MailMessage @mailParams
    Write-Host "E-mail succesvol verzonden." -ForegroundColor Green
}
catch {
    Write-Host "Fout bij versturen e-mail: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Tip: check SMTP settings + credential xml." -ForegroundColor DarkRed
}
