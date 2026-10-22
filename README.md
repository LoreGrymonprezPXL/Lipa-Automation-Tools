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

- `Datto_macos_update.sh` is the single recommended Datto component. It
  handles macOS updates, major upgrades, unattended authentication, restart
  handling, logging, and Datto status reporting.
- `MacOSAutoPatching.sh` is an older alternative workflow. Do not deploy both
  scripts as scheduled jobs on the same device.

Deploy only `Datto_macos_update.sh` through Datto RMM with the required
environment variables and root permissions for the target devices. Keeping
the second file in the repository prevents accidental loss of the older
workflow, but it is not part of the recommended Datto policy.

#### Datto verification guide

Run the components as `root` on a test Mac first. The update commands can
restart the device.

Check the device before running an update:

```bash
id -u
sw_vers -productVersion
uname -m
pmset -g batt
df -h /
softwareupdate --list
```

`id -u` must return `0`, the Mac should be connected to AC power, and
`softwareupdate --list` should show available updates or report that no
updates are available.

Run the full update workflow:

```bash
chmod 700 ./Datto_macos_update.sh
sudo ./Datto_macos_update.sh
```

The full workflow checks power, disk space, Apple connectivity and Apple
Silicon credentials, then uses SUPER where available and falls back to
`softwareupdate` or `startosinstall`.

Important Datto variables include:

```text
ADMIN_USER=clientadmin
ADMIN_PASS=<masked-password>
MIN_FREE_GB=35
MAJOR_UPGRADES=true
MAX_TARGET_MAJOR=0
MAX_WAIT_MIN=90
JOB_MAX_MIN=240
```

Set `MAJOR_UPGRADES=false` to install minor updates only. On Apple Silicon,
`ADMIN_USER` must be a SecureToken/volume-owner account and `ADMIN_PASS` must
be configured as a masked Datto password variable.

The component is designed for an unattended Datto scheduled job. It must run
as `root`. Intel Macs do not require an update password; Apple Silicon Macs
require the credentials of a local SecureToken/volume-owner account. The
component does not fall back to asking the logged-in user for a password. If
the credentials are missing or invalid, it exits with `AUTH_FAILED` instead of
waiting for user input.

By default, a logged-in user receives a 120-second warning before a native
update or upgrade starts, but no button press is required. To suppress the
warning completely for a fully silent scheduled job, set:

```text
USER_WARN_SECONDS=0
```

Monitor the full workflow:

```bash
sudo ls -lt /var/log/DattoMacUpdate/
sudo tail -f /var/log/datto-macos-upgrade.log
sudo tail -f "$(ls -t /var/log/DattoMacUpdate/job-*.log | head -n 1)"
sudo grep -E "DATTO_RESULT|ERROR|WARN|UP_TO_DATE|UPDATE_STARTED|UPGRADE_STARTED|SUPER_" \
  /var/log/DattoMacUpdate/job-*.log
pgrep -alf "softwareupdate|startosinstall|super|mist"
```

The final `DATTO_RESULT` line and exit code are the main Datto indicators.
Successful results include `UP_TO_DATE`, `UPDATE_STARTED`, `UPGRADE_STARTED`,
`SUPER_COMPLETED`, and `SUPER_IN_PROGRESS`. Common failure codes are:

- `10`: no AC power
- `11`: insufficient disk space
- `12`: Apple update server/network failure
- `13`: Apple Silicon authentication failure
- `14`: unsupported macOS or not running as root
- `20`: timeout
- `21`: installer failure
- `22`: major-upgrade check failed
- `30`: SUPER error

After the Mac restarts, verify the result:

```bash
sw_vers -productVersion
softwareupdate --list
pgrep -alf "softwareupdate|startosinstall|super|mist"
test ! -e "/Library/Application Support/MSP-Patching/restart_pending.state" \
  && echo "Restart state cleared" \
  || echo "Restart still pending"
```

## Safety and contribution notes

- Inspect scripts and environment-specific settings before using `irm | iex`
  or deploying through an RMM platform.
- Never commit passwords, credential XML files, API tokens, or generated logs.
- Keep new scripts in the most specific existing category. Create a new
  lowercase category only when the capability does not fit an existing one.
- Update this README's structure and script list whenever files are added,
  moved, or renamed.
