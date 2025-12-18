
<#
.SYNOPSIS
  Voert een robuuste back-up uit met Robocopy en verstuurt een e-mail met een korte samenvatting.
  Robocopy-output komt NIET in de mail body, maar in een aparte log.

.NOTES
  Auteur: Lore (Lipa ICT)
  Versie: V3.3 - Summary mail + SUCCESS/WARN/FAILED + exitcode decode in mail
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
# INTERN (niet aanpassen)
# =========================
$RunStamp        = Get-Date -Format "yyyyMMdd_HHmmss"
$DateNow         = Get-Date -Format "dd-MM-yyyy HH:mm:ss"

$LogboekPath     = Join-Path $LogRoot "backuplog.txt"                  # historiek
$RoboLogPath     = Join-Path $LogRoot "Robocopy_$RunStamp.log"          # FULL robocopy log
$MailLogPath     = Join-Path $LogRoot "MailSummary_$RunStamp.txt"       # mail body (kort)
$ErrorLogPath    = Join-Path $LogRoot "Errors_$RunStamp.txt"            # extract errors (alleen bij FAILED)

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
Write-Host $LipaLogo -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Green
Write-Host "Briljant Back-up Script V4.0" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Green

# --- LOGS & DIRECTORIES ---
$null = New-Item -ItemType Directory -Path $LogRoot -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "LOG BESTANDEN (deze run):" -ForegroundColor Yellow
Write-Host "  Robocopy log : $RoboLogPath" -ForegroundColor DarkGray
Write-Host "  Mail summary : $MailLogPath" -ForegroundColor DarkGray
Write-Host "  Error extract: $ErrorLogPath" -ForegroundColor DarkGray
Write-Host "  Historiek    : $LogboekPath" -ForegroundColor DarkGray
Write-Host ""

# --- CREDENTIAL CHECK ---
if (-not (Test-Path $CredentialPath)) {
    Write-Host "FATALE FOUT: SMTP credentialbestand niet gevonden: $CredentialPath" -ForegroundColor Red
    Write-Host "Maak dit eenmalig aan met:" -ForegroundColor Yellow
    Write-Host '  Get-Credential | Export-Clixml -Path "C:\BackupBriljant\SmtpCredential.xml"' -ForegroundColor DarkGray
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

$SourceServer = Get-ServerFromPath -Path $Source
$DestServer   = Get-ServerFromPath -Path $Destination

function Get-RobocopyStatus {
    param([int]$Code)

    $flags = [ordered]@{
        1  = "Bestanden gekopieerd"
        2  = "Extra bestanden/dirs gedetecteerd (destination bevat meer dan source)"
        4  = "Mismatches gedetecteerd (verschillen in attributes/timestamps)"
        8  = "FOUTEN: 1 of meerdere bestanden konden niet gekopieerd worden"
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

    $failed = (($Code -band 8) -ne 0) -or (($Code -band 16) -ne 0)
    $warn   = (-not $failed) -and ( (($Code -band 2) -ne 0) -or (($Code -band 4) -ne 0) )

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

# Uitleg per bit (0/1/2/4/8/16) — bitmask zoals robocopy documentatie
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
# START HISTORIEK
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

# BELANGRIJK: exitcode direct na robocopy ophalen
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
# MAIL BODY (KORT + DECODE)
# =========================
$summary  = Get-RobocopySummaryFromLog -Path $RoboLogPath
$label    = Get-RoboLabel -Code $RobocopyExitCode
$bitLines = Get-RoboBitExplainLines -Code $RobocopyExitCode

# Opbouw: 1 keer Set-Content, daarna eventueel Add-Content

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
    " - Robocopy log : $RoboLogPath"
    " - Error extract: $ErrorLogPath"
    " - Historiek    : $LogboekPath"
    ""
    "Samenvatting (Robocopy):"
    ($summary.DirsLine  ? $summary.DirsLine  : "Dirs  : (niet gevonden in log)")
    ($summary.FilesLine ? $summary.FilesLine : "Files : (niet gevonden in log)")
    ($summary.BytesLine ? $summary.BytesLine : "Bytes : (niet gevonden in log)")
    ($summary.TimesLine ? $summary.TimesLine : $null)
    ($summary.SpeedLine ? $summary.SpeedLine : $null)
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
# HISTORIEK AFSLUITEN
# =========================
"einde $EndDate" | Add-Content -Path $LogboekPath -Encoding UTF8
"Status Code: $RobocopyExitCode" | Add-Content -Path $LogboekPath -Encoding UTF8
"----------------------------------------" | Add-Content -Path $LogboekPath -Encoding UTF8


# =========================
# MAIL VERZENDEN
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

