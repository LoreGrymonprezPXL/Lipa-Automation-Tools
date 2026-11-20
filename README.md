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

- `Datto_macos_update.sh` is the recommended Datto component. It starts a
  short-lived job, then runs the update in the background as a one-time
  LaunchDaemon. It handles major upgrades, regular updates, AC power,
  disk space and restart notifications.
- `MacOSAutoPatching.sh` is an older alternative workflow. Do not deploy both
  scripts as scheduled jobs on the same device.

Deploy only `Datto_macos_update.sh` through Datto RMM with the required
environment variables and root permissions for the target devices. Keeping
the second file in the repository prevents accidental loss of the older
workflow, but it is not part of the recommended Datto policy.

The supported Lipa ICT baseline is **macOS 13.3 Ventura and newer**. Older
macOS versions are stopped before the update starts.

#### Datto verification guide

Run the components as `root` on a test Mac first. The update commands can
restart the device.

Check the device before running an update:

```bash
id -u
sw_vers -productVersion
uname -m
pmset -g batt
df -Pk /System/Volumes/Data
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

The Datto job first checks macOS support, AC power and free disk space.
Apple Silicon also requires a valid volume-owner account. The background
worker then:

1. Downloads the newest full installer from Apple's update catalog.
2. Waits for AC power and asks the user to postpone the restart at most twice.
3. Starts `startosinstall`.
4. Falls back to normal `softwareupdate --install --all --restart` updates if
   no suitable major installer is available.

Important Datto variables include:

```text
ADMIN_USER=clientadmin
ADMIN_PASS=<masked-password>
MIN_FREE_GB=35
INSTALLER_VERSION=
RESTART_WARN_SEC=120
MAX_DEFERRALS=2
TEST_UI_ONLY=true
TEST_UI_TIMEOUT=15
TEST_LOW_DISK_MSG=true
TEST_NO_AC_MSG=true
TEST_NORMAL_RESTART_MSG=true
TEST_FORCED_RESTART_MSG=true
```

The script currently defaults `TEST_UI_ONLY` to `true`, so a QuickJob only
shows the UI messages and does not update or restart the Mac. Set
`TEST_UI_ONLY=false` as a Datto component variable to run the real update
workflow.

```bash
TEST_UI_ONLY=false
TEST_UI_TIMEOUT=120
```

As an extra force option from SSH or a QuickJob shell, run:

```bash
sudo ./Datto_macos_update.sh --test-ui
```

This test mode shows the low-storage, AC-power, normal restart and final
restart messages. It does not check for updates, download an installer, run
`startosinstall`, change the deferral counter or restart the Mac.

Set any individual `TEST_*_MSG` variable to `false` to hide that one test
message. All test variables are set directly in the script; no Datto command
line or SSH command is required.

Set `INSTALLER_VERSION` only when a fixed macOS version is required. On Apple
Silicon, `ADMIN_USER` must be a SecureToken/volume-owner account and
`ADMIN_PASS` must be configured as a masked Datto password variable.

The component is designed for an unattended Datto scheduled job. It must run
as `root`. Intel Macs do not require an update password; Apple Silicon Macs
require the credentials of a local SecureToken/volume-owner account. The
component does not fall back to asking the logged-in user for a password. If
the credentials are missing or invalid, it stops with exit code `2`.

Monitor the full workflow:

```bash
sudo tail -f /var/log/lipa-macos-upgrade.log
sudo pgrep -af "softwareupdate|startosinstall"
```

The main exit codes are:

- `0`: the background update was started or no action was required
- `1`: the LaunchDaemon could not be started
- `2`: a pre-flight check failed

Detailed download, installer and restart status is written to
`/var/log/lipa-macos-upgrade.log`.

After the Mac restarts, verify the result:

```bash
sw_vers -productVersion
softwareupdate --list
sudo pgrep -af "softwareupdate|startosinstall"
```

## Safety and contribution notes

- Inspect scripts and environment-specific settings before using `irm | iex`
  or deploying through an RMM platform.
- Never commit passwords, credential XML files, API tokens, or generated logs.
- Keep new scripts in the most specific existing category. Create a new
  lowercase category only when the capability does not fit an existing one.
- Update this README's structure and script list whenever files are added,
  moved, or renamed.
