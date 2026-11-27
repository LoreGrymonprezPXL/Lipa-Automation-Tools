### Deploy dashboard

On launch, the framed dashboard appears before deployment intake and stays open until you choose `Q`. No deployment action runs until you select it. Choose `6` to open the Handover Check directly without first completing deployment intake.

| Choice | Action |
| --- | --- |
| 1 | Full setup: system baseline, selected modules, Windows Update and detected vendor update tools |
| 2 | Run only the software modules selected during intake |
| 3 | Run only the system baseline |
| 4 | Run only Windows and vendor updates |
| 5 | Read-only audit and ticket report; no installation or configuration changes |
| 6 | Open the separate Handover Check for device validation and selective repairs |
| 7 | Create a ticket report from the current inventory |
| Q | Close the dashboard |

The Handover Check remains separate. Its `F` action offers repairable warnings and failures; choose the specific items to change rather than applying every fix. If the check script is not beside Lipa-Deploy, the dashboard downloads it to a temporary file and removes it after use. If audit-only was selected during intake, baseline and update actions require explicit confirmation before making changes.

### Finish the end-user profile
