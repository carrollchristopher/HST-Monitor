# HST eChart Monitor

Always-on availability monitor for the HST eChart sign-in endpoint, installed on a server at each site. It runs as a SYSTEM scheduled task, polls the endpoint through its redirects with curl, and emails when the site loses access, when it stays slow, when it comes back, and when the monitor itself was not running.

## What it does

- Polls the eChart URL every 10 seconds, follows the sign-in redirects, and checks that the page is populated.
- Declares an outage after 3 failed polls in a row, emails DOWN, STILL DOWN every 30 minutes, and RESOLVED with the outage length.
- Emails SLOW when at least half the polls in the last 5 minutes were slower than 3 seconds or failed, STILL SLOW every 30 minutes, and SLOW RESOLVED once 10 percent or fewer are. A single slow poll or timeout never emails.
- Sends a daily summary at 7 AM of slow polls, failed polls with their reasons, outages, the worst response, and the busiest hour. It is sent only when something went wrong.
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
| `Test-HSTMonitorHealth.ps1` | Checks an installed monitor: task, process, heartbeat, recorded polls, logs, mail secret, and a live probe. `-OutageDrill` simulates an outage end to end. |
| `Test-HSTMailSend.ps1` | One-shot diagnostic for the Graph mail path on an installed server. |
| `Stress-InstallHSTMonitor.ps1` | Static and functional checks for the installer and the generated monitor, including the wizard and the sign-in token path against a local mock. |
| `Stress-WindowsHSTMonitor.ps1` | Live checks on Windows PowerShell 5.1: DPAPI, ACLs, task objects, and the generated monitor running against local listeners and the real endpoint. |
| `Test-HSTMonitorInstallLocal.ps1` | End-to-end test that runs the real installer twice from an elevated console and verifies the result. |
| `PSScriptAnalyzerSettings.psd1` | Analyzer settings with the deliberate rule exclusions. |

## Checking a server

Copy `Test-HSTMonitorHealth.ps1` to the server and run it from an elevated Windows PowerShell console.

```powershell
.\Test-HSTMonitorHealth.ps1
```

It changes nothing and ends with WORKING or NOT WORKING CORRECTLY. It reports the task and process, the heartbeat age, the last poll, response times and failures over the last hour and 24 hours, gaps in recording, warnings in the monitor's own log, the mail secret, and a probe of the endpoint from the server.

```powershell
.\Test-HSTMonitorHealth.ps1 -OutageDrill
```

The drill makes only the monitor's own probes fail for about a minute, using a curl settings file in the profile of the account the monitor runs as. Browsers and other programs keep working. It confirms the monitor declares DOWN, sends the DOWN email, records RESOLVED, and sends the RESOLVED email. The drill leaves one short outage in the outage log. If the window is closed during the drill, run the script again and it removes the file.

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
