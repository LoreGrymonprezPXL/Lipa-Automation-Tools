# Lipa ICT - System Automation Tools

![Status](https://img.shields.io/badge/Status-Active-success)
![Platform](https://img.shields.io/badge/Platform-Windows%20Server-blue)
![Language](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-blue)

## About this repo
This repository hosts essential automation scripts for Lipa ICT system administration. These tools are designed to standardize backup procedures, secure credential management, and automate reporting.

### Key Features
* **Security:** Securely store and retrieve credentials using DPAPI (XML) to avoid plaintext passwords in scripts.
* **Backups:** Automated Robocopy-based mirror backups with intelligent bitmask error decoding.
* **Reporting:** Automated SMTP email notifications with summary statistics and log attachments.

---

## Repository Structure

```text
.
├── Backups/              # Scripts for data archiving (Briljant Environment)
├── Security/             # Tools for credential encryption (XML)
└── README.md
```
# 1. Setup: SMTP Credential Generator
Before running the backup scripts, you must generate a secure credential file. The **LipaBackupCredentials.ps1** script creates an encrypted XML file for SMTP authentication (I use: noreply@itbeheer.be).
## How to Execute
Open PowerShell as an **administrator** and run:
```powershell
irm "https://raw.githubusercontent.com/LoreGrymonprezPXL/Lipa-Automation-Tools/refs/heads/main/Security/LipaBackupCredentials.ps1" | iex
```
# 2. Backup: Briljant Backup Script (V6)
The BackupscriptLipaV6.ps1 is designed to back up the Briljant environment **(C:\Briljant)** to a network share.
## Features
- **Robocopy Mirroring:** Efficiently syncs source and destination.
- **Bitmask Analysis:** Decodes Robocopy exit codes into human-readable status (OK, Mismatch, Extra, or Failure).
- **Automated Reporting:** Sends a detailed Text email summary to backup@lipa.be.
- **Smart Logging:** Automatically attaches logs to the email only if warnings or failures are detected.
## How to Execute
Open PowerShell as an **administrator** and run:
```powershell
irm "https://raw.githubusercontent.com/LoreGrymonprezPXL/Lipa-Automation-Tools/refs/heads/main/Backups/BackupscriptLipaV6.ps1" | iex
```
[IMPORTANT] The script is needs the Smtpcredential.xml to function!
