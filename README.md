# HST eChart Monitor

Always-on availability monitor for the HST eChart sign-in endpoint, installed on a server at each site. It runs as a SYSTEM scheduled task, polls the endpoint through its redirects with curl, and emails when the site loses access, when it comes back, and when the monitor itself was not running.

## What it does

- Polls the eChart URL every 30 seconds, follows the sign-in redirects, and checks that the page is populated.
- Declares an outage after consecutive failures, emails DOWN, periodic STILL DOWN reminders, and RESOLVED with the outage length.
- Writes a monthly latency CSV, an outages CSV, and `HST-eChart-Drops.log` with only the failures, slow polls, outage transitions, and alert delivery outcomes. Healthy polls never appear in the drops log.
- Keeps a heartbeat so a restart after a reboot, a stopped task, or a killed process sends a MONITOR RESTARTED notice with the gap and the cause. An outage in progress at the last heartbeat is carried over.
- Queues alerts that cannot be sent and retries them every minute for an hour.
- Sends mail through Microsoft Graph with an app registration scoped to one shared mailbox (RBAC for Applications), or through Microsoft 365 direct send, an internal relay, or authenticated SMTP.

## Install

Run `Install-HSTMonitor.ps1` from an elevated Windows PowerShell 5.1 console on the site server. It prompts for the site name and mail settings, sends a test email, writes the monitor script and settings under `C:\ProgramData\DIT\HSTProbe`, registers the scheduled task, and sends an install confirmation.

The first site in a tenant can create the Graph app registration, the shared sender mailbox, and the Exchange send scope during the install. It prints the tenant ID, client ID, and client secret once. Later sites paste those three values.

Re-running the installer on a server replaces the settings cleanly. Every prompt defaults to the saved value, and Enter keeps the client secret already stored on the server.

Requirements: Windows Server or Windows 10/11 with Windows PowerShell 5.1, curl.exe (built in since Windows 10 1803), administrator rights for the install, and outbound HTTPS.

## Files

| File | Purpose |
|---|---|
| `Install-HSTMonitor.ps1` | The installer. Contains the monitor script as an embedded template. |
| `Test-HSTMailSend.ps1` | One-shot diagnostic for the Graph mail path on an installed server. |
| `Stress-InstallHSTMonitor.ps1` | Static and functional checks for the installer and the generated monitor, including the wizard and the sign-in token path against a local mock. |
| `Stress-WindowsHSTMonitor.ps1` | Live checks on Windows PowerShell 5.1: DPAPI, ACLs, task objects, and the generated monitor running against local listeners and the real endpoint. |
| `Test-HSTMonitorInstallLocal.ps1` | End-to-end test that runs the real installer twice from an elevated console and verifies the result. |
| `PSScriptAnalyzerSettings.psd1` | Analyzer settings with the deliberate rule exclusions. |

## Testing

`Stress-InstallHSTMonitor.ps1` expects a copy of the installer at `C:\tmp\Install-HSTMonitor.ps1` and a copy under `C:\mnt\user-data\outputs\`. It runs under pwsh 7 or Windows PowerShell 5.1. `Stress-WindowsHSTMonitor.ps1` runs under Windows PowerShell 5.1 and does not need administrator rights. Run the live harness on its own; its timing checks are sensitive to CPU load.

```powershell
Invoke-ScriptAnalyzer -Path .\Install-HSTMonitor.ps1 -Settings .\PSScriptAnalyzerSettings.psd1
```

## Data written on the server

All under `C:\ProgramData\DIT\HSTProbe`, locked to SYSTEM and Administrators with read access for Users:

- `Watch-HSTeChartUptime.ps1`, the generated monitor
- `install-settings.json` and `smtp-credential.bin` (DPAPI, machine scope)
- `HST-eChart-Latency_yyyyMM.csv`, `HST-eChart-Outages.csv`, `HST-eChart-Drops.log`
- `HST-eChart-Monitor_yyyyMMdd.log` daily transcripts, pruned after 30 days
- `monitor-heartbeat.json`
