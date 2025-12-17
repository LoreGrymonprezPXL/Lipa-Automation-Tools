# 😃 Lipa ICT - System Automation Tools

![Status](https://img.shields.io/badge/Status-Active-success)
![Platform](https://img.shields.io/badge/Platform-Windows%20Server-blue)
![Language](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-blue)

## About this repo
This repository hosts essential automation scripts for Lipa ICT system administration. These tools are designed to standardize backup procedures, secure credential management, and automate reporting.

### Key Features
* **Security:** Securely store and retrieve credentials using DPAPI (XML) to avoid plaintext passwords in scripts.
* **Backups:** Back-up script fully in powershell.
* **Deployment:** One-line installation commands for quick setup.

---

## Repository Structure

```text
.
├── Backups/              # Scripts for data archiving
├── Security/             # Tools for credential encryption (XML)
└── README.md
```

## SMTP Credential Generator Script
The `LipaBackupCredentials.ps1` script automates the creation of a secure, encrypted XML file for SMTP authentication (`noreply@itbeheer.be`). It ensures passwords are never stored in plaintext.

### How to Execute
To execute the script directly from the web, open PowerShell as an **administrator** and run the following command:

```powershell
irm "https://raw.githubusercontent.com/LoreGrymonprezPXL/Lipa-Automation-Tools/refs/heads/main/Security/LipaBackupCredentials.ps1" | iex
