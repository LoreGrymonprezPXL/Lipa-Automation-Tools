param(
    # -CredPath param to change path
    [string]$CredPath = "C:\BackupBriljant\SmtpCredential.xml"
)

Clear-Host 

$LipaICT = @"
 ___       ___  ________  ________     
|\  \     |\  \|\   __  \|\   __  \    
\ \  \    \ \  \ \  \|\  \ \  \|\  \   
 \ \  \    \ \  \ \   ____\ \   __  \  
  \ \  \____\ \  \ \  \___|\ \  \ \  \ 
   \ \_______\ \__\ \__\    \ \__\ \__\
    \|_______|\|__|\|__|     \|__|\|__|                                     
"@

Write-Host $LipaICT -ForegroundColor Cyan
Write-Host "-------------------------------------------" -ForegroundColor Gray

$Username = "noreply@itbeheer.be"
Write-Host "Generating credentials for: $Username" -ForegroundColor Yellow

# 1. asking the user to give in the password (rn only for itbeheer)
$SecurePassword = Read-Host -Prompt "Enter SMTP password" -AsSecureString

Write-Host "Making the XML file..." -ForegroundColor Cyan

# 2. create file
$Credential = New-Object System.Management.Automation.PSCredential($Username, $SecurePassword)
$dir = Split-Path $CredPath -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$Credential | Export-Clixml -Path $CredPath -Force

Write-Host "[OK] Created $CredPath" -ForegroundColor Green

# 3. Guide for creating the correct security settings
$CurrentUser = "$env:USERDOMAIN\$env:USERNAME"

Write-Host "`n[!] SECURITY CHECK" -ForegroundColor Red
Write-Host "To prevent other users from deleting/copying this file,"
Write-Host "run this command in an Admin terminal:" -ForegroundColor Gray

$Command = "icacls `"$CredPath`" /inheritance:r /grant:r `"${CurrentUser}:F`" /grant:r `"SYSTEM:F`""

Write-Host "---------------------------------------------------" -ForegroundColor Gray
Write-Host $Command -ForegroundColor White -BackgroundColor DarkBlue
Write-Host "---------------------------------------------------" -ForegroundColor Gray