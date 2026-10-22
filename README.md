# Lipa ICT Automation Tools

![Status](https://img.shields.io/badge/Status-Active-success)
![Platforms](https://img.shields.io/badge/Platforms-Windows%20%7C%20macOS-blue)
![Languages](https://img.shields.io/badge/Languages-PowerShell%20%7C%20Bash-blue)

Automation scripts used by Lipa ICT for backup operations, endpoint
management, security, cloud administration, and device handover checks.

## Repository structure

Directories are grouped by capability rather than by a single customer,
product, or script name. This keeps the layout predictable as more scripts
and integrations are added.

```text
.
├── .vscode/
│   └── settings.json
├── backup/
│   └── BackupscriptLipa.ps1
├── checks/
│   ├── Lipa-Handover-Check.ps1
│   └── empty.txt
├── cloud-services/
│   └── AvepointAccount.ps1
├── endpoint-management/
│   └── macos/
│       └── datto/
│           ├── Datto_macos_update.sh
│           └── MacOSAutoPatching.sh
├── security/
│   └── LipaBackupCredentials.ps1
└── README.md
```

### Directory conventions

- `backup/` contains data backup and restore automation.
- `checks/` contains setup, handover, validation, and reporting checks.
- `cloud-services/` contains scripts for cloud platforms and SaaS providers.
- `endpoint-management/` contains operating-system and device-management
  integrations. Vendor-specific scripts belong in a subdirectory such as
  `macos/datto/`.
- `security/` contains credential and access-management tooling.
- Use lowercase, descriptive directory names for new categories. Add a
  provider or platform subdirectory when a category needs to support multiple
  integrations.

## Scripts

### Secure SMTP credential generator

[`security/LipaBackupCredentials.ps1`](security/LipaBackupCredentials.ps1)
creates a DPAPI-protected XML credential file for the backup mail account.
The file is encrypted for the Windows user who creates it and must not be
committed to this repository.

Run PowerShell as an administrator:

```powershell
irm "https://raw.githubusercontent.com/LoreGrymonprezPXL/Lipa-Automation-Tools/refs/heads/main/security/LipaBackupCredentials.ps1" | iex
```

### Briljant backup

[`backup/BackupscriptLipa.ps1`](backup/BackupscriptLipa.ps1) mirrors
`C:\Briljant` to the configured network share using Robocopy. It decodes
Robocopy exit codes, maintains run logs, and sends an SMTP summary. Logs are
attached when warnings or failures occur.

The script expects the generated credential file at
`C:\BackupBriljant\SmtpCredential.xml` by default.

```powershell
irm "https://raw.githubusercontent.com/LoreGrymonprezPXL/Lipa-Automation-Tools/refs/heads/main/backup/BackupscriptLipa.ps1" | iex
```

Review the source and environment-specific configuration before running this
script in production.

### AvePoint account setup

[`cloud-services/AvepointAccount.ps1`](cloud-services/AvepointAccount.ps1)
creates and documents the Microsoft 365 account and licensing setup used for
AvePoint backups. It installs or imports the required Microsoft Graph modules
when needed.

```powershell
irm "https://raw.githubusercontent.com/LoreGrymonprezPXL/Lipa-Automation-Tools/refs/heads/main/cloud-services/AvepointAccount.ps1" | iex
```

### Windows handover check

[`checks/Lipa-Handover-Check.ps1`](checks/Lipa-Handover-Check.ps1) provides an
administrator menu for preparing, validating, and documenting new Windows
devices. It can run individual actions or the complete workflow.

Run it from an elevated PowerShell session and review the requested actions
before selecting the full workflow.

### Datto macOS management

The scripts in
[`endpoint-management/macos/datto/`](endpoint-management/macos/datto/) are
Bash scripts for Datto RMM:

- `MacOSAutoPatching.sh` handles macOS update discovery, installation,
  restart prompts, logging, and Datto status reporting.
- `Datto_macos_update.sh` provides the Datto macOS update workflow and checks.

Deploy these scripts through Datto RMM with the required environment variables
and permissions for the target devices.

## Safety and contribution notes

- Inspect scripts and environment-specific settings before using `irm | iex`
  or deploying through an RMM platform.
- Never commit passwords, credential XML files, API tokens, or generated logs.
- Keep new scripts in the most specific existing category. Create a new
  lowercase category only when the capability does not fit an existing one.
- Update this README's structure and script list whenever files are added,
  moved, or renamed.
