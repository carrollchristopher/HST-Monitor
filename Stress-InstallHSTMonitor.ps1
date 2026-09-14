$ErrorActionPreference = 'Stop'
$script:pass=0; $script:fail=0; $script:failed=@()
function Check($n,$c){ if($c){$script:pass++} else {$script:fail++; $script:failed += $n; Write-Host "FAIL: $n"} }
function Section($n){ Write-Host ""; Write-Host "== $n ==" }

$installerPath = '/tmp/Install-HSTMonitor.ps1'
$src = Get-Content -Raw $installerPath
$T=$null;$E=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($installerPath,[ref]$T,[ref]$E)

Section "A. Installer parse and static checks"
Check "Installer parses with zero errors" ($E.Count -eq 0)
if ($E.Count){ $E | % { Write-Host ("  " + $_.Message + " @ " + $_.Extent.StartLineNumber) } }
Check "No em dashes anywhere" (-not ($src -match ([char]0x2014)))
Check "No PS7-only ?? operator" (-not ($src -match '\?\?'))
Check "No PS7-only && / || chain operators" (-not ($src -match '\s&&\s|\s\|\|\s'))
Check "No banner-style comment headers" (-not ($src -match '(?m)^\s*#\s*[-=#*]{5,}'))
Check "Remove-Variable * immediately after help (installer)" ($src -match '(?s)#>\s*\r?\n\s*\r?\nRemove-Variable \* -ErrorAction SilentlyContinue')
Check "Author name present" ($src -match 'Author:\s+Christopher Carroll')

# Approved verbs on every function in installer + template
$hereNodes = $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -eq 'SingleQuotedHereString'},$true)
Check "Exactly one embedded template" ($hereNodes.Count -eq 1)
$template = $hereNodes[0].Value
$tT=$null;$tE=$null
$tAst=[System.Management.Automation.Language.Parser]::ParseInput($template,[ref]$tT,[ref]$tE)
$approved = (Get-Verb).Verb
$allFuncs = @($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)) + @($tAst.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true))
$badVerbs = $allFuncs | Where-Object { ($_.Name -split '-')[0] -notin $approved } | Select-Object -ExpandProperty Name -Unique
Check "All function verbs approved ($($allFuncs.Count) functions)" ($badVerbs.Count -eq 0)
if ($badVerbs){ Write-Host "  bad: $($badVerbs -join ', ')" }

# Every Write-Log -Level literal is in the approved keyword set
$levels = @('ADDED','CREATED','ERROR','FAILED','FINISHED','FOUND','INFORMATIONAL','PROMPT','SANITY CHECK','STARTED','SUCCESS','TOTAL','WARNING')
$badLevels = @()
foreach ($a in @($ast,$tAst)) {
  foreach ($c in $a.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-Log'},$true)) {
    for ($i=0;$i -lt $c.CommandElements.Count;$i++) {
      $el=$c.CommandElements[$i]
      if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -eq 'Level') {
        $v=$c.CommandElements[$i+1]
        if ($v -is [System.Management.Automation.Language.StringConstantExpressionAst]) { if ($v.Value -notin $levels){ $badLevels += $v.Value } }
      }
    }
  }
}
Check "All Write-Log levels approved" ($badLevels.Count -eq 0)

# Every email subject literal starts with [HST
$subjects = [regex]::Matches($src,'"\[HST [A-Z ]+\][^"]*"') | % { $_.Value }
Check "Found subject literals ($($subjects.Count))" ($subjects.Count -ge 5)
$subjectTypes = $subjects | % { ([regex]::Match($_,'\[HST ([A-Z ]+)\]')).Groups[1].Value } | Sort-Object -Unique
Check "Subject set is exactly DOWN/STILL DOWN/RESOLVED/MONITOR TEST/MONITOR INSTALLED/MONITOR RESTARTED" ((($subjectTypes -join '|')) -eq 'DOWN|MONITOR INSTALLED|MONITOR RESTARTED|MONITOR TEST|RESOLVED|STILL DOWN')
Check "Every subject carries the site name variable" (($subjects | Where-Object { $_ -notmatch '\$SiteName|\$site' }).Count -eq 0)

Check "Single deliverable: only Install-HSTMonitor.ps1 among installer files" ((Get-ChildItem /mnt/user-data/outputs -Filter '*HSTMonitor*.ps1').Count -eq 1)
Check "No dedicatedit.com or DIT-specific addresses anywhere" (-not ($src -match 'dedicatedit'))
Check "Sender and recipients have no baked defaults" ($src -match '(?m)^\$MailFrom\s+=\s+""' -and $src -match '(?m)^\$MailTo\s+=\s+@\(\)')
Check "Policy group derived from sender domain" ($src -match '\$policyGroup = "\$GraphPolicyGroupAlias@" \+')
Check "No reference to a second script" (-not ($src -match 'New-HSTMonitorAppRegistration'))
Check "Tenant setup lives inside installer" ($src -match 'function New-TenantMailApp' -and $src -match 'function Test-RequiredModule')
Check "Graph wizard branch calls tenant setup" ($src -match [regex]::Escape('New-TenantMailApp -SenderAddress $from -SiteName $SiteName'))
Check "Access policy RestrictAccess applied" ($src -match 'New-ApplicationAccessPolicy' -and $src -match 'RestrictAccess')
Check "Mail.Send role looked up, not hardcoded" ($src -match "Value -eq 'Mail.Send'" -and -not ($src -match 'b633e1c5-b582-4048-a93e-9f11b44c7e96'))
Check "Secret never written to disk in plaintext" (-not ($src -match 'Set-Content[^\n]*\$secret\b') -and -not ($src -match 'Set-Content[^\n]*\$graphSecret'))
Check "Exchange module session disconnected in finally" ($src -match 'finally \{ if \(\$script:ExoMode -eq .module.\) \{ try \{ Disconnect-ExchangeOnline')
Check "Setup module removed automatically after setup" ($src -match 'function Remove-TenantSetupModules' -and $src.Contains('{ Remove-TenantSetupModules }'))
Check "No Microsoft.Graph module dependency" (-not ($src -match 'Microsoft\.Graph\.|Connect-MgGraph|Get-Mg|New-Mg|Add-Mg'))
Check "Only ExchangeOnlineManagement is installed" (([regex]::Matches($src,"Test-RequiredModule -Name '([^']+)'") | % { $_.Groups[1].Value } | Sort-Object -Unique) -join ',' -eq 'ExchangeOnlineManagement')
Check "Module install and removal have no Y/N prompts" (-not ($src -match 'Read-Choice -Prompt "Install') -and -not ($src -match 'Read-Choice -Prompt "Remove'))
Check "Browser auth-code sign-in for Graph, device code as fallback" ($src -match 'oauth2/v2\.0/authorize' -and $src -match 'code_challenge_method=S256' -and $src -match 'oauth2/v2\.0/devicecode')
Check "Graph setup uses REST endpoints" ($src.Contains('/addPassword') -and $src.Contains('appRoleAssignments'))
$rawReadHost = [regex]::Matches($src,'(?m)^\s*\$\w+\s*=\s*Read-Host\b(?![^\n]*-AsSecureString)') | ? { $_.Value -notmatch '\$entry\s*=' }
Check "All plain prompts route through Read-Setting/Read-Choice" ($rawReadHost.Count -eq 0)
Check "No plaintext-to-SecureString cmdlet anywhere" (-not ($src -match 'ConvertTo-SecureString -String') -and -not ($src -match '-AsPlainText'))
Check "ConvertTo-SecureText defined once in the installer and once in the monitor" (([regex]::Matches($src, '(?m)^function ConvertTo-SecureText \{')).Count -eq 2)
Check "Protect-Secret takes the prompt SecureString or in-memory text" ($src -match "ParameterSetName = 'Secure'\)\]\[securestring\]\`$Password" -and $src -match "ParameterSetName = 'Plain'\)\]\[string\]\`$PlainText")
Check "Drops log gets failed and slow polls, transitions, alerts, starts, restarts, never a healthy poll" ($template -match "Write-DropLog -Kind 'FAIL'" -and $template -match "Write-DropLog -Kind 'SLOW'" -and $template -match "Write-DropLog -Kind 'DOWN'" -and $template -match "Write-DropLog -Kind 'REMINDER'" -and $template -match "Write-DropLog -Kind 'RESOLVED'" -and $template -match "Write-DropLog -Kind 'RESTART'" -and $template -match "Write-DropLog -Kind 'CARRYOVER'" -and $template -match "Write-DropLog -Kind 'ALERT'" -and $template -match "Write-DropLog -Kind 'START'" -and $template -match "Write-DropLog -Kind 'STOP'" -and $template -match '(?m)^\s*else \{ Write-Log -Level SUCCESS -Message \$summary \}\s*$')
Check "Drops log is not pruned with the daily transcripts" ($template -match "Filter 'HST-eChart-Monitor_\*\.log'" -and $template -match "HST-eChart-Drops\.log" -and -not ($template -match "Filter 'HST-eChart-\*"))
Check "Stored secret offered only for the same Graph app" ($src -match "if \(\`$Saved -and \`$Saved\.MailMethod -eq 'Graph' -and \`$Saved\.CredentialFor -eq \`$client\) \{ Get-StoredSecret \}")
Check "Installer decrypts the stored secret in one place" (([regex]::Matches($src, 'ProtectedData\]::Unprotect')).Count -eq 2 -and $src -match 'function Get-StoredSecret')
Check "Analyzer settings file present and names only warning-level style rules" ((Test-Path 'C:\Workspaces\HST Monitor\PSScriptAnalyzerSettings.psd1') -and -not ((Get-Content 'C:\Workspaces\HST Monitor\PSScriptAnalyzerSettings.psd1' -Raw) -match 'SecureString|PlainText|Credential|Password'))
Check "No parameter shadows an automatic variable" (-not ($src -match '(?i)\[string\]\$(Sender|Event|Args|Input|Matches|Error|Host|PID|Profile)'))
Check "Non-interactive Graph refused (secret needs console)" ($src -match "Graph cannot be configured non-interactively")
Check "Probe follows redirects with a bounded hop count" ($template -match '-L --max-redirs \$MaxRedirects' -and $src -match '(?m)^\$MaxRedirects\s+=\s+5')
Check "Install-time preflight follows redirects too" ($src -match 'function Test-EndpointReachable[\s\S]*?-L --max-redirs \$MaxRedirects')
Check "Sign-in page marker is the default" ($src -match '(?m)^\$ExpectedContentMarker\s+=\s+"HST Federation Provider"')
Check "Task cmdlets stop on error and registration is verified" ($src -match 'Register-ScheduledTask[^\n]*-ErrorAction Stop' -and $src -match 'Get-ScheduledTask -TaskName \$TaskName -TaskPath \$TaskPath -ErrorAction Stop' -and $src -match 'Start-ScheduledTask -TaskName \$TaskName -TaskPath \$TaskPath -ErrorAction Stop')
Check "Existing task replaced in place, never unregistered first" (-not ($src -match 'Unregister-ScheduledTask') -and $src -match 'Register-ScheduledTask[^\n]*-Force')
Check "Monitor staged as .new and swapped in after verification" ($src -match '\$stagedPath = "\$monitorPath\.new"' -and $src -match 'Move-Item -Path \$stagedPath -Destination \$monitorPath -Force -ErrorAction Stop')
Check "InstalledAt recorded only after the task is running" ($src -match "(?s)if \(\`$taskState -eq 'Running'\) \{\s*\`$settings\['InstalledAt'\]")
Check "Monitor failure test includes the curl exit code" ($template -match '\$failed\s+=\s+\(\$result\.CurlExit -ne 0\) -or')
Check "Latency CSV written after alert dispatch" ($template -match "(?s)Send-AlertOrQueue -Subject \`$decision\.EmailSubject.*?Write-CsvRow -Path \(Get-LatencyCsvPath\) -Row \`$result")
Check "CSV write problems are logged, never rethrown" ($template -match "Could not append to")
Check "Graph JSON bodies declare UTF-8" ((([regex]::Matches($src, "application/json; charset=utf-8")).Count -ge 4) -and -not ($src -match "ContentType 'application/json'[^;]"))
Check "Graph send with no secret fails fast instead of falling through to SMTP" ($src -match 'No Graph client secret is available')
Check "Template substitution is a single pass" ($src -match "\[regex\]::Replace\(\`$Template_MonitorScript, '@@\(\[A-Z\]\+\)@@'" -and -not ($src -match "\.Replace\('@@SITENAME@@'"))
Check "Install ends non-zero when the task is not running" ($src -match "if \(\`$taskState -ne 'Running'\) \{[\s\S]*?exit 1")
$topReturns = @($ast.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] } | ForEach-Object { $_.FindAll({param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst]},$true) })
Check "Installer failure paths exit non-zero (no top-level return)" ($topReturns.Count -eq 0)
$tTopReturns = @($tAst.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] } | ForEach-Object { $_.FindAll({param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst]},$true) })
Check "Monitor failure paths exit non-zero (no top-level return)" ($tTopReturns.Count -eq 0)
Check "Windows PowerShell drops PowerShell 7 module paths before loading modules" ($src -match "if \(\`$PSVersionTable\.PSVersion\.Major -le 5\) \{\s*\`$env:PSModulePath = ")
Check "Probe body written under InstallDir, not the global temp folder" ($template -match "Join-Path \`$InstallDir 'probe-body\.tmp'" -and -not ($template -match 'GetTempFileName'))

Section "B. Load installer helpers and generate monitors across a value matrix"
# Define config vars from the installer's assignment statements (top-level scalar assigns only, before functions)
$firstFunc = ($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] } | Select-Object -First 1).Extent.StartLineNumber
$assigns = $ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Extent.StartLineNumber -lt $firstFunc }
foreach ($a in $assigns) { if ($a.Left.Extent.Text -ne '$Template_MonitorScript') { Invoke-Expression $a.Extent.Text } }
$Template_MonitorScript = $template
foreach ($f in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false) | Where-Object { $_.Name -in @('Write-Log','ConvertTo-SafeSiteName','Test-EmailAddress','ConvertTo-RecipientList','ConvertTo-DerivedDirectSendHost','New-MonitorContent','Read-Setting','Read-Choice','Read-PortSetting','Test-GuidLike','Test-DateInput','ConvertTo-GraphMailBody','New-AlertBody') }) { Invoke-Expression $f.Extent.Text }
function Write-Log { param($Level,$Message) }   # silence during tests

function Gen($site,$mail){ New-MonitorContent -SiteName $site -Mail $mail }
function ParseOk($text){ $x=$null;$y=$null; [void][System.Management.Automation.Language.Parser]::ParseInput($text,[ref]$x,[ref]$y); return ($y.Count -eq 0) }
function ConfigValue($text,$var){ $x=$null;$y=$null; $a=[System.Management.Automation.Language.Parser]::ParseInput($text,[ref]$x,[ref]$y); $n=$a.FindAll({param($k) $k -is [System.Management.Automation.Language.AssignmentStatementAst] -and $k.Left.Extent.Text -eq $var},$false) | Select-Object -First 1; Invoke-Expression $n.Right.Extent.Text }

$mDirect = @{ MailMethod='DirectSend'; SmtpServer='dedicatedit-com.mail.protection.outlook.com'; SmtpPort=25; SmtpUseSsl=$false; MailFrom='hst-monitor@dedicatedit.com'; MailTo=@('alerts@dedicatedit.com'); SmtpAuthUser=''; CipherText='' }
$mRelay  = @{ MailMethod='Relay'; SmtpServer='10.1.1.5'; SmtpPort=2525; SmtpUseSsl=$true; MailFrom='noc@dedicatedit.com'; MailTo=@('a@dedicatedit.com','b@dedicatedit.com','c@dedicatedit.com'); SmtpAuthUser=''; CipherText='' }
$mGraph  = @{ MailMethod='Graph'; SmtpServer='graph.microsoft.com'; SmtpPort=443; SmtpUseSsl=$true; MailFrom='hst-monitor@dedicatedit.com'; MailTo=@('alerts@dedicatedit.com','noc@dedicatedit.com'); SmtpAuthUser=''; CipherText='AAAA'; GraphTenantId='11111111-2222-3333-4444-555555555555'; GraphClientId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; GraphSecretExpires='2028-09-04' }
$mAuth   = @{ MailMethod='Authenticated'; SmtpServer='smtp.office365.com'; SmtpPort=587; SmtpUseSsl=$true; MailFrom="o'brien@dedicatedit.com"; MailTo=@("d'arcy@dedicatedit.com"); SmtpAuthUser="o'brien@dedicatedit.com"; CipherText='AAAA' }

$matrix = @(
  @{ site='CapCity'; mail=$mDirect; marker='' },
  @{ site='Jersey Shore'; mail=$mRelay; marker='HST eChart Login' },
  @{ site="O'Brien Site"; mail=$mAuth; marker="Bob's Login" },
  @{ site='  weird!!  name   '; mail=$mDirect; marker='' },
  @{ site='Café-Test_1'; mail=$mRelay; marker='<title>x</title>' },
  @{ site='X'; mail=$mAuth; marker='' },
  @{ site='GraphSite'; mail=$mGraph; marker='' }
)
$i=0
foreach ($m in $matrix) {
  $i++
  $ExpectedContentMarker = $m.marker
  $g = Gen $m.site $m.mail
  Check "M$i parses ($($m.site))" (ParseOk $g)
  Check "M$i no leftover tokens" (-not ($g -match '@@[A-Z]+@@'))
  Check "M$i site round-trips" ((ConfigValue $g '$SiteName') -eq (ConvertTo-SafeSiteName $m.site))
  Check "M$i marker round-trips" ((ConfigValue $g '$ExpectedContentMarker') -eq $m.marker)
  Check "M$i MailTo count" ((@(ConfigValue $g '$MailTo')).Count -eq $m.mail.MailTo.Count)
  Check "M$i MailFrom round-trips" ((ConfigValue $g '$MailFrom') -eq $m.mail.MailFrom)
  Check "M$i AuthUser round-trips" ((ConfigValue $g '$SmtpAuthUser') -eq $m.mail.SmtpAuthUser)
  Check "M$i SSL bool" ((ConfigValue $g '$SmtpUseSsl') -eq $m.mail.SmtpUseSsl)
  Check "M$i Port int" ((ConfigValue $g '$SmtpPort') -eq $m.mail.SmtpPort)
  if ($m.mail.MailMethod -eq 'Graph') {
    Check "M$i GraphTenant round-trips" ((ConfigValue $g '$GraphTenantId') -eq $m.mail.GraphTenantId)
    Check "M$i GraphClient round-trips" ((ConfigValue $g '$GraphClientId') -eq $m.mail.GraphClientId)
    Check "M$i Expiry round-trips"      ((ConfigValue $g '$GraphSecretExpires') -eq $m.mail.GraphSecretExpires)
    Check "M$i MailMethod Graph"        ((ConfigValue $g '$MailMethod') -eq 'Graph')
  }
}
$ExpectedContentMarker=''
# Config clamps
$DownThreshold=0; $IntervalSeconds=0; $TimeoutSeconds=-5
$g = Gen 'Clamp' $mDirect
Check "DownThreshold 0 clamps to 1" ((ConfigValue $g '$DownThreshold') -eq 1)
Check "Interval 0 clamps to 1"      ((ConfigValue $g '$IntervalSeconds') -eq 1)
Check "Timeout -5 clamps to 1"      ((ConfigValue $g '$TimeoutSeconds') -eq 1)
$DownThreshold=3; $IntervalSeconds=10; $TimeoutSeconds=15
$gen = Gen 'CapCity' $mDirect
Set-Content /tmp/generated_monitor.ps1 $gen
Check "Generated monitor: Remove-Variable * right after help" ($gen -match '(?s)#>\s*\r?\n\s*\r?\nRemove-Variable \* -ErrorAction SilentlyContinue')

Section "C. Site name, email, recipient, host helpers"
Check "Safe: strips punctuation" ((ConvertTo-SafeSiteName "O'Brien Site!!") -eq 'OBrien Site')
Check "Safe: collapses/trims spaces" ((ConvertTo-SafeSiteName '  a   b  ') -eq 'a b')
Check "Safe: keeps dash/underscore" ((ConvertTo-SafeSiteName 'Site_1-A') -eq 'Site_1-A')
Check "Safe: null -> empty" ((ConvertTo-SafeSiteName $null) -eq '')
Check "Safe: only junk -> empty" ((ConvertTo-SafeSiteName '!!!') -eq '')
Check "Email valid" (Test-EmailAddress 'a.b@c.io')
Check "Email invalid no @" (-not (Test-EmailAddress 'abc'))
Check "Email invalid no tld" (-not (Test-EmailAddress 'a@b'))
Check "Email invalid space" (-not (Test-EmailAddress 'a b@c.com'))
Check "Email null" (-not (Test-EmailAddress $null))
$r = ConvertTo-RecipientList 'a@x.com, B@x.com;a@X.COM  c@y.org bogus'
Check "Recipients: split, dedupe case-insensitive, drop invalid" (($r -join '|') -eq 'a@x.com|B@x.com|c@y.org')
Check "Recipients: empty -> 0" ((ConvertTo-RecipientList '').Count -eq 0)
Check "Recipients: single returns array" ((@(ConvertTo-RecipientList 'a@x.com')).Count -eq 1)
Check "DirectSend host derived" ((ConvertTo-DerivedDirectSendHost 'DedicatedIT.com') -eq 'dedicatedit-com.mail.protection.outlook.com')
Check "DirectSend subdomain" ((ConvertTo-DerivedDirectSendHost 'mail.foo.co.uk') -eq 'mail-foo-co-uk.mail.protection.outlook.com')
Check "Guid valid" (Test-GuidLike '11111111-2222-3333-4444-555555555555')
Check "Guid uppercase ok" (Test-GuidLike 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE')
Check "Guid invalid short" (-not (Test-GuidLike '1234'))
Check "Guid invalid braces" (-not (Test-GuidLike '{11111111-2222-3333-4444-555555555555}'))
Check "Date blank -> empty" ((Test-DateInput '') -eq '')
Check "Date valid" ((Test-DateInput ' 2028-09-04 ') -eq '2028-09-04')
Check "Date invalid -> null" ($null -eq (Test-DateInput '09/04/2028'))
Check "Date impossible -> null" ($null -eq (Test-DateInput '2028-13-40'))
$j = ConvertTo-GraphMailBody -Subject 'S' -Body "L1`nL2" -To @('a@x.com','b@x.com') | ConvertFrom-Json
Check "Graph body subject" ($j.message.subject -eq 'S')
Check "Graph body HTML type" ($j.message.body.contentType -eq 'HTML')
$ab = New-AlertBody -Heading "H <b>" -Details ([ordered]@{ 'Site' = "O'Brien & Co"; 'Server' = 'SRV1' })
Check "Alert body: HTML table, values encoded, footer names this server" ($ab -match '^<html>' -and $ab -match 'H &lt;b&gt;' -and $ab -match "O&#39;Brien &amp; Co" -and $ab -match '<td[^>]*>Server</td><td[^>]*>SRV1</td>' -and $ab -match [regex]::Escape("monitor on $env:COMPUTERNAME."))
Check "Both send paths deliver HTML" ((([regex]::Matches($src, 'BodyAsHtml = \$true')).Count -eq 2) -and -not ($src -match "contentType = 'Text'"))
Check "Graph body 2 recipients" ($j.message.toRecipients.Count -eq 2 -and $j.message.toRecipients[1].emailAddress.address -eq 'b@x.com')
Check "Graph body no sent items" ($j.saveToSentItems -eq $false)
$j1 = ConvertTo-GraphMailBody -Subject 'S' -Body 'B' -To @('a@x.com') | ConvertFrom-Json
Check "Graph body single recipient is array" (@($j1.message.toRecipients).Count -eq 1)
$NonInteractive=$true
Check "Read-Setting non-interactive returns default" ((Read-Setting -Prompt 'x' -Default 'dflt') -eq 'dflt')
Check "Read-Choice non-interactive returns default" ((Read-Choice -Prompt 'x' -Allowed @('Y','N') -Default 'N') -eq 'N')
$NonInteractive=$false

Section "D. Monitor functions: extract from generated monitor"
$gT=$null;$gE=$null
$gAst=[System.Management.Automation.Language.Parser]::ParseInput($gen,[ref]$gT,[ref]$gE)
foreach ($f in $gAst.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('ConvertTo-Ms','Format-Duration','Get-CurlReason','Get-LatencyCsvPath','Write-CsvRow','Get-TranscriptPath','Update-MonitorState','Get-HSTProbeResult','Get-SecretExpiryWarning','New-AlertBody','Write-Heartbeat','Read-Heartbeat','Get-RestartNotice','Send-AlertOrQueue','Send-PendingAlert','Wait-NetworkReady','Get-SmtpCredential','ConvertTo-SecureText','Write-DropLog')},$true)) { Invoke-Expression $f.Extent.Text }
$InstallDir = '/tmp/hstprobe_test'; if (Test-Path $InstallDir){Remove-Item $InstallDir -Recurse -Force}; New-Item $InstallDir -ItemType Directory | Out-Null

Check "Ms: 0.123456 -> 123" ((ConvertTo-Ms '0.123456') -eq 123)
Check "Ms: garbage -> null" ($null -eq (ConvertTo-Ms 'abc'))
Check "Ms: empty -> null"   ($null -eq (ConvertTo-Ms ''))
Check "Ms: comma decimal rejected (invariant)" ($null -eq (ConvertTo-Ms '0,5'))
Check "Duration negative -> 00m 00s" ((Format-Duration ([TimeSpan]::FromSeconds(-5))) -eq '00m 00s')
Check "Duration 2d" ((Format-Duration ([TimeSpan]::FromSeconds(172800+3661))) -eq '2d 1h 01m 01s')
Check "CurlReason 28" ((Get-CurlReason 28) -eq 'Timed out')
Check "CurlReason 7" ((Get-CurlReason 7) -eq 'Connection refused or unreachable')
Check "CurlReason unknown" ((Get-CurlReason 99) -eq 'curl exit 99')
Check "CurlReason 47" ((Get-CurlReason 47) -eq 'Too many redirects')
Check "CurlReason 18" ((Get-CurlReason 18) -eq 'Transfer ended early (partial body)')
Check "Latency path monthly" ((Get-LatencyCsvPath) -match 'HST-eChart-Latency_\d{6}\.csv$')
$today=[datetime]'2026-09-04'
Check "Expiry blank -> null" ($null -eq (Get-SecretExpiryWarning -ExpiresOn '' -Today $today))
Check "Expiry garbage -> null" ($null -eq (Get-SecretExpiryWarning -ExpiresOn 'soon' -Today $today))
Check "Expiry 31d -> null" ($null -eq (Get-SecretExpiryWarning -ExpiresOn '2026-10-05' -Today $today))
Check "Expiry 30d -> warn" ((Get-SecretExpiryWarning -ExpiresOn '2026-10-04' -Today $today) -match 'expires in 30 day')
Check "Expiry today -> warn 0" ((Get-SecretExpiryWarning -ExpiresOn '2026-09-04' -Today $today) -match 'expires in 0 day')
Check "Expiry yesterday -> EXPIRED" ((Get-SecretExpiryWarning -ExpiresOn '2026-09-03' -Today $today) -match 'EXPIRED')
Check "Transcript path daily"  ((Get-TranscriptPath) -match 'HST-eChart-Monitor_\d{8}\.log$')

# CSV schema mismatch handling
$csv = Join-Path $InstallDir 'schema.csv'
Write-CsvRow -Path $csv -Row ([PSCustomObject]@{A=1;B=2})
Write-CsvRow -Path $csv -Row ([PSCustomObject]@{A=3;B=4})
Check "CSV appends 2 rows" ((Import-Csv $csv).Count -eq 2)
Write-CsvRow -Path $csv -Row ([PSCustomObject]@{A=5;C=6})
$aside = Get-ChildItem $InstallDir -Filter 'schema_schema-*.csv'
Check "CSV mismatch moves old file aside" ($aside.Count -eq 1)
Check "CSV mismatch starts new file with 1 row" (@(Import-Csv $csv).Count -eq 1)
Check "CSV creates missing folder" ( (Write-CsvRow -Path (Join-Path $InstallDir 'sub/x.csv') -Row ([PSCustomObject]@{A=1})) -eq $null -and (Test-Path (Join-Path $InstallDir 'sub/x.csv')) )
# A locked file: the row is skipped with a warning, nothing is moved aside, nothing throws
$lockCsv = Join-Path $InstallDir 'locked.csv'
Write-CsvRow -Path $lockCsv -Row ([PSCustomObject]@{A=1;B=2})
$fsLock = [System.IO.File]::Open($lockCsv, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
function Write-Log { param($Level,$Message) $script:LastLog = "$Level|$Message" }
$script:LastLog = ''
$threw = $false
try { Write-CsvRow -Path $lockCsv -Row ([PSCustomObject]@{A=3;B=4}) } catch { $threw = $true }
$fsLock.Close()
Check "CSV locked: no throw, warning logged, file kept in place" (-not $threw -and $script:LastLog -match '^WARNING\|Could not append' -and (Test-Path $lockCsv) -and @(Get-ChildItem $InstallDir -Filter 'locked_schema-*.csv').Count -eq 0)
Check "CSV locked: earlier rows intact, skipped row absent" (@(Import-Csv $lockCsv).Count -eq 1)
# A value containing a token is inserted verbatim, not substituted again
$gTok = New-MonitorContent -SiteName 'T' -Mail @{ MailMethod='Relay'; SmtpServer='host-with-@@URL@@-inside'; SmtpPort=25; SmtpUseSsl=$false; MailFrom='m@x.invalid'; MailTo=@('a@x.invalid'); SmtpAuthUser=''; CipherText='' }
Check "Template: value containing a token survives unchanged" ($gTok -match "SmtpServer\s+=\s+'host-with-@@URL@@-inside'" -and (ParseOk $gTok))
# Drops log
$DropLog = Join-Path $InstallDir 'drops.log'
$script:DropLogWarned = $false
Write-DropLog -Kind 'FAIL' -Message 'Code=000 Reason=Timed out'
Write-DropLog -Kind 'CARRYOVER' -Message 'carried'
$dl = @(Get-Content $DropLog)
Check "Drops log: one line per event, timestamp, padded kind, message" ($dl.Count -eq 2 -and $dl[0] -match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \| FAIL      \| Code=000 Reason=Timed out$' -and $dl[1] -match '\| CARRYOVER \| carried$')
$fsDrop = [System.IO.File]::Open($DropLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
function Write-Log { param($Level,$Message) $script:LastLog = "$Level|$Message" }
$script:LastLog = ''; $threw = $false
try { Write-DropLog -Kind 'FAIL' -Message 'locked' } catch { $threw = $true }
Write-DropLog -Kind 'FAIL' -Message 'locked again'
$fsDrop.Close()
Check "Drops log locked: no throw, one warning, lost lines counted once writable" (-not $threw -and $script:LastLog -match '^WARNING\|Could not write the drops log' -and (& { Write-DropLog -Kind 'FAIL' -Message 'after unlock'; $dl2 = @(Get-Content $DropLog); $dl2.Count -eq 4 -and $dl2[2] -match '\| LOST      \| 2 line\(s\) were not recorded while this file was locked' -and $dl2[3] -match '\| FAIL      \| after unlock$' }))
function Write-Log { param($Level,$Message) }
$big = New-Object byte[] (10MB + 1); [System.IO.File]::WriteAllBytes($DropLog, $big)
Write-DropLog -Kind 'STOP' -Message 'rotated'
$asideDrops = @(Get-ChildItem $InstallDir -Filter 'drops_*.log')
Check "Drops log rotates aside past 10 MB and starts fresh" ($asideDrops.Count -eq 1 -and $asideDrops[0].Length -gt 10MB -and @(Get-Content $DropLog).Count -eq 1 -and (Get-Content $DropLog) -match '\| STOP      \| rotated$')
function Write-Log { param($Level,$Message) }

Section "E. State machine"
function NewState { @{ ConsecutiveFailures=0; IsDown=$false; LastAlertUtc=$null; OutageStartUtc=$null; OutageStartLocalStr=$null; OutageStartUtcStr=$null } }
function Res($code,$ok,$reason='Timed out') { [PSCustomObject]@{ Timestamp_Local='L'; Timestamp_UTC='U'; HttpCode=$code; ContentOk=$ok; RemoteIp='1.2.3.4'; Reason=$reason } }
$T0 = [datetime]::SpecifyKind([datetime]'2026-09-04T12:00:00','Utc')
function Step { param([hashtable]$State,[bool]$Failed,[datetime]$Now,[int]$Dt=3,[int]$Re=30,[bool]$Aor=$true,$Result=$null)
  if ($null -eq $Result){ $Result = Res '000' $false }
  Update-MonitorState -State $State -Failed $Failed -Result $Result -NowUtc $Now -DownThreshold $Dt -ReAlertMinutes $Re -AlertOnRecovery $Aor -SiteName 'CapCity' -Url 'http://x' -HostName 'HOST1' }

$st=NewState; $any=$false
for($i=0;$i -le 5;$i++){ $d=Step $st $false $T0.AddSeconds($i*10); $st=$d.State; if($d.EmailSubject){$any=$true} }
Check "S1 steady up no emails" (-not $any -and -not $st.IsDown -and $st.ConsecutiveFailures -eq 0)

$st=NewState; $d=Step $st $true $T0; $st=$d.State
Check "S2 blip CF=1 not down no email" ($st.ConsecutiveFailures -eq 1 -and -not $st.IsDown -and $null -eq $d.EmailSubject)
$d=Step $st $false $T0.AddSeconds(10); $st=$d.State
Check "S2 blip recover: no record, no email, reset" ($null -eq $d.OutageRecord -and $null -eq $d.EmailSubject -and $st.ConsecutiveFailures -eq 0)

$st=NewState; $orig = $st.Clone()
$d1=Step $st $true $T0; $st=$d1.State; $d2=Step $st $true $T0.AddSeconds(10); $st=$d2.State; $d3=Step $st $true $T0.AddSeconds(20); $st=$d3.State
Check "S3 no email before threshold" ($null -eq $d1.EmailSubject -and $null -eq $d2.EmailSubject)
Check "S3 DOWN at 3rd, subject names site and server" ($d3.EmailSubject -eq '[HST DOWN] CapCity (HOST1) - HST eChart unreachable')
Check "S3 DOWN body is HTML with server and reason rows" ($d3.EmailBody -match '^<html>' -and $d3.EmailBody -match '<td[^>]*>Server</td><td[^>]*>HOST1</td>' -and $d3.EmailBody -match '<td[^>]*>Reason</td><td[^>]*>Timed out</td>')
Check "S3 onset at first failure" ($st.OutageStartUtc -eq $T0)
Check "S3 input state not mutated" ($orig.ConsecutiveFailures -eq 0 -and -not $orig.IsDown)
$dr=Step $st $false $T0.AddSeconds(30) -Result (Res '200' $true 'OK'); $st=$dr.State
Check "S3 RESOLVED subject exact" ($dr.EmailSubject -eq '[HST RESOLVED] CapCity (HOST1) - outage lasted 00m 30s')
Check "S3 record fields" ($dr.OutageRecord.DurationSeconds -eq 30 -and $dr.OutageRecord.FailedPolls -eq 3 -and $dr.OutageRecord.RecoveryCode -eq '200' -and $dr.OutageRecord.Duration -eq '00m 30s')
Check "S3 state fully reset" (-not $st.IsDown -and $st.ConsecutiveFailures -eq 0 -and $null -eq $st.OutageStartUtc -and $null -eq $st.LastAlertUtc)

$st=NewState; for($i=0;$i -lt 3;$i++){ $d=Step $st $true $T0.AddSeconds($i*10); $st=$d.State }
$r1=Step $st $true $T0.AddSeconds(20).AddMinutes(29).AddSeconds(59); $st=$r1.State
Check "S4 no reminder at 29m59s" ($null -eq $r1.EmailSubject)
$r2=Step $st $true $T0.AddSeconds(20).AddMinutes(30); $st=$r2.State
Check "S4 reminder exactly at 30m" ($r2.EmailSubject -like '`[HST STILL DOWN`] CapCity (HOST1) - down for *')
Check "S4 reminder elapsed counts from onset (30m20s)" ($r2.EmailSubject -eq '[HST STILL DOWN] CapCity (HOST1) - down for 30m 20s')
$r3=Step $st $true $T0.AddSeconds(20).AddMinutes(31); $st=$r3.State
Check "S4 no premature second reminder" ($null -eq $r3.EmailSubject)
$r4=Step $st $true $T0.AddSeconds(20).AddMinutes(60); $st=$r4.State
Check "S4 second reminder at +60m" ($r4.EmailSubject -like '`[HST STILL DOWN`]*')
$fin=Step $st $false $T0.AddSeconds(20).AddMinutes(61) -Result (Res '200' $true 'OK'); $st=$fin.State
Check "S4 resolved 1h 01m 20s" ($fin.EmailSubject -eq '[HST RESOLVED] CapCity (HOST1) - outage lasted 1h 01m 20s')
Check "S4 failed polls counted through reminders (7)" ($fin.OutageRecord.FailedPolls -eq 7)

$st=NewState; for($i=0;$i -lt 3;$i++){ $d=Step $st $true $T0.AddSeconds($i*10) -Re 0; $st=$d.State }
$d=Step $st $true $T0.AddDays(3) -Re 0
Check "S5 ReAlert=0 never reminds" ($null -eq $d.EmailSubject)

$st=NewState; $d=Step $st $true $T0; $st=$d.State; $d=Step $st $false $T0.AddSeconds(5); $st=$d.State; $d=Step $st $true $T0.AddSeconds(10); $st=$d.State
Check "S6 flapping onset resets" ($st.OutageStartUtc -eq $T0.AddSeconds(10))

$d=Step (NewState) $true $T0 -Dt 1
Check "S7 threshold 1 immediate" ($d.EmailSubject -like '`[HST DOWN`]*')
$d=Step (NewState) $true $T0 -Dt 0
Check "S7 threshold 0 clamps to 1" ($d.EmailSubject -like '`[HST DOWN`]*')

$st=NewState; for($i=0;$i -lt 3;$i++){ $d=Step $st $true $T0.AddSeconds($i*10) -Aor $false; $st=$d.State }
$d=Step $st $false $T0.AddSeconds(30) -Aor $false
Check "S8 recovery alert off: record yes, email no" ($null -ne $d.OutageRecord -and $null -eq $d.EmailSubject)

$st=NewState; for($i=0;$i -lt 3;$i++){ $d=Step $st $true $T0.AddSeconds($i*10); $st=$d.State }
$d=Step $st $false $T0.AddDays(2).AddHours(3) -Result (Res '200' $true 'OK')
Check "S9 multi-day duration" ($d.EmailSubject -eq '[HST RESOLVED] CapCity (HOST1) - outage lasted 2d 3h 00m 00s')
Check "S9 multi-day seconds" ($d.OutageRecord.DurationSeconds -eq (2*86400+3*3600))

$corrupt = @{ ConsecutiveFailures=2; IsDown=$false; LastAlertUtc=$null; OutageStartUtc=$null; OutageStartLocalStr=$null; OutageStartUtcStr=$null }
$d=Step $corrupt $true $T0
Check "S10 corrupt state (CF>0, no onset) repairs onset" ($d.State.OutageStartUtc -eq $T0 -and $d.State.IsDown)

$d=Step (NewState) $true $T0 -Result ([PSCustomObject]@{Timestamp_Local='L';Timestamp_UTC='U';HttpCode='000';ContentOk=$false;RemoteIp=''})
Check "S11 result without Reason property tolerated" ($d.State.ConsecutiveFailures -eq 1)

$st=NewState; for($i=0;$i -lt 3;$i++){ $d=Step $st $true $T0.AddSeconds($i*10); $st=$d.State }
$d=Step $st $false $T0.AddSeconds(30).AddMilliseconds(600) -Result (Res '200' $true 'OK')
Check "S12 DurationSeconds truncates like the formatted duration (30.6 -> 30)" ($d.OutageRecord.DurationSeconds -eq 30)

# Long random soak: 20000 steps, invariants must always hold
$st=NewState; $rng=[Random]::new(42); $now=$T0; $emails=0; $records=0; $ok=$true
for($k=0;$k -lt 20000;$k++){
  $f = ($rng.NextDouble() -lt 0.3); $now=$now.AddSeconds(10)
  $d=Step $st $f $now; $st=$d.State
  if($d.EmailSubject){$emails++}; if($d.OutageRecord){$records++}
  if($st.IsDown -and $st.ConsecutiveFailures -lt 3){$ok=$false}
  if(-not $f -and $st.ConsecutiveFailures -ne 0){$ok=$false}
  if($st.ConsecutiveFailures -gt 0 -and $null -eq $st.OutageStartUtc){$ok=$false}
  if($d.OutageRecord -and $d.OutageRecord.FailedPolls -lt 3){$ok=$false}
  if($d.EmailSubject -and -not ($d.EmailSubject -match '^\[HST (DOWN|STILL DOWN|RESOLVED)\] CapCity \(HOST1\) - ')){$ok=$false}
}
Check "S13 20k-step random soak: invariants hold" $ok
Check "S13 soak produced outages and records" ($emails -gt 0 -and $records -gt 0)

Section "E2. Restart notice, heartbeat, delivery tracking, alert queue"
function Write-Log { param($Level,$Message) $script:LastLog = "$Level|$Message"; $script:Logs += "$Level|$Message" }
$script:Logs = @()
$HeartbeatFile = Join-Path $InstallDir 'monitor-heartbeat.json'
Check "R1 no previous heartbeat -> no notice" ($null -eq (Get-RestartNotice -Previous $null -NowUtc $T0 -GapThresholdSeconds 60 -IntervalSeconds 10 -SiteName 'CapCity' -HostName 'HOST1' -Url 'http://x'))
Check "R1 missing heartbeat file -> null" ($null -eq (Read-Heartbeat))
$downState = @{ ConsecutiveFailures=7; IsDown=$true; LastAlertUtc=$T0.AddMinutes(5); OutageStartUtc=$T0; OutageStartLocalStr='2026-09-04 08:00:00'; OutageStartUtcStr='2026-09-04 12:00:00'; AlertDelivered=$false }
Write-Heartbeat -State $downState -NowUtc $T0.AddMinutes(10)
$hb = Read-Heartbeat
Check "R2 heartbeat roundtrip keeps every field and UTC kind" ($hb -and $hb.BeatUtc -eq $T0.AddMinutes(10) -and $hb.BeatUtc.Kind -eq 'Utc' -and $hb.IsDown -and $hb.ConsecutiveFailures -eq 7 -and $hb.OutageStartUtc -eq $T0 -and $hb.OutageStartUtc.Kind -eq 'Utc' -and $hb.LastAlertUtc -eq $T0.AddMinutes(5) -and $hb.OutageStartLocalStr -eq '2026-09-04 08:00:00' -and $hb.AlertDelivered -eq $false)
Check "R2 heartbeat written atomically: no temp file left, rename into place" (-not (Test-Path "$HeartbeatFile.tmp") -and $template -match 'Move-Item -Path \$tmp -Destination \$HeartbeatFile -Force -ErrorAction Stop')
Check "R2 heartbeat is compact JSON with ISO dates" (((Get-Content $HeartbeatFile -Raw) -match '"Beat":"2026-09-04T12:10:00\.0000000Z"') -and -not ((Get-Content $HeartbeatFile -Raw) -match 'Date\('))
$upState = @{ ConsecutiveFailures=0; IsDown=$false; LastAlertUtc=$null; OutageStartUtc=$null; OutageStartLocalStr=$null; OutageStartUtcStr=$null; AlertDelivered=$null }
Write-Heartbeat -State $upState -NowUtc $T0.AddMinutes(10)
$hbUp = Read-Heartbeat
Check "R2 up-state heartbeat has null outage fields" ($hbUp -and -not $hbUp.IsDown -and $null -eq $hbUp.OutageStartUtc -and $null -eq $hbUp.LastAlertUtc -and $null -eq $hbUp.AlertDelivered)
$n = Get-RestartNotice -Previous $hb -NowUtc $T0.AddMinutes(10).AddSeconds(30) -BootTimeUtc $T0.AddHours(-5) -GapThresholdSeconds 60 -IntervalSeconds 10 -SiteName 'CapCity' -HostName 'HOST1' -Url 'http://x'
Check "R3 short gap -> no email but the outage is carried over" ($n -and $null -eq $n.Subject -and $n.GapSeconds -eq 30 -and $n.RestoredState -and $n.RestoredState.IsDown -and $n.RestoredState.OutageStartUtc -eq $T0 -and $n.RestoredState.ConsecutiveFailures -eq 7 -and $n.RestoredState.AlertDelivered -eq $false -and $n.RestoredState.LastAlertUtc -eq $T0.AddMinutes(5))
$n = Get-RestartNotice -Previous $hb -NowUtc $T0.AddMinutes(10).AddSeconds(3840) -BootTimeUtc $T0.AddMinutes(40) -GapThresholdSeconds 60 -IntervalSeconds 10 -SiteName 'CapCity' -HostName 'HOST1' -Url 'http://x'
Check "R4 long gap after a reboot -> subject names site, server, gap" ($n.Subject -eq '[HST MONITOR RESTARTED] CapCity (HOST1) - not running for 1h 04m 00s')
Check "R4 body says the server restarted after the heartbeat, outage carried, polls missed" ($n.Body -match '^<html>' -and $n.Body -match 'Server restarted at' -and $n.Body -match 'after the last heartbeat' -and $n.Body -match 'Yes\. HST eChart has been down since 2026-09-04 08:00:00 local' -and $n.Body -match '<td[^>]*>Polls missed</td><td[^>]*>384</td>' -and $n.Body -match '<td[^>]*>Server</td><td[^>]*>HOST1</td>' -and $n.RestoredState.IsDown)
$n = Get-RestartNotice -Previous $hbUp -NowUtc $T0.AddMinutes(10).AddSeconds(90) -BootTimeUtc $T0.AddHours(-5) -GapThresholdSeconds 60 -IntervalSeconds 10 -SiteName 'CapCity' -HostName 'HOST1' -Url 'http://x'
Check "R5 long gap without a reboot -> process stopped, nothing carried" ($n.Subject -eq '[HST MONITOR RESTARTED] CapCity (HOST1) - not running for 01m 30s' -and $n.Body -match 'Server did not restart' -and $n.Body -match 'None at the last heartbeat' -and $null -eq $n.RestoredState)
$n = Get-RestartNotice -Previous $hbUp -NowUtc $T0.AddMinutes(5) -BootTimeUtc $T0.AddHours(-5) -GapThresholdSeconds 60 -IntervalSeconds 10 -SiteName 'CapCity' -HostName 'HOST1' -Url 'http://x'
Check "R6 clock went backwards -> gap zero, no email" ($n -and $null -eq $n.Subject -and $n.GapSeconds -eq 0)
$n = Get-RestartNotice -Previous $hbUp -NowUtc $T0.AddMinutes(20) -GapThresholdSeconds 60 -IntervalSeconds 10 -SiteName 'CapCity' -HostName 'HOST1' -Url 'http://x'
Check "R7 unknown boot time is stated, not guessed" ($n.Subject -and $n.Body -match 'Could not read the server boot time')
Check "R7 threshold boundary: gap equal to threshold reports" ((Get-RestartNotice -Previous $hbUp -NowUtc $T0.AddMinutes(11) -GapThresholdSeconds 60 -IntervalSeconds 10 -SiteName 'C' -HostName 'H' -Url 'u').Subject -ne $null)
# Deliberate stop marked by the installer: no notice however long the gap, outage still carried over
Write-Heartbeat -State $downState -NowUtc $T0.AddMinutes(10)
$hbj = Get-Content $HeartbeatFile -Raw | ConvertFrom-Json
$hbj | Add-Member -NotePropertyName Stopped -NotePropertyValue $true -Force
$hbj | ConvertTo-Json -Compress | Set-Content -Path $HeartbeatFile -Encoding UTF8 -Force
$hbStopped = Read-Heartbeat
$n = Get-RestartNotice -Previous $hbStopped -NowUtc $T0.AddHours(30) -BootTimeUtc $T0.AddHours(-5) -GapThresholdSeconds 60 -IntervalSeconds 10 -SiteName 'CapCity' -HostName 'HOST1' -Url 'http://x'
Check "R7b deliberate stop: heartbeat flag read back, no notice after 30 h, outage carried" ($hbStopped.Stopped -and $n -and $null -eq $n.Subject -and $n.Stopped -and $n.RestoredState -and $n.RestoredState.OutageStartUtc -eq $T0 -and $n.GapSeconds -eq 107400)
Write-Heartbeat -State $downState -NowUtc $T0.AddMinutes(10)
Check "R7b the monitor's own heartbeat writes Stopped false" (-not (Read-Heartbeat).Stopped)
Set-Content $HeartbeatFile -Value '{ not json' -Encoding UTF8
Check "R8 corrupt heartbeat -> null with warning" ($null -eq (Read-Heartbeat) -and $script:LastLog -match '^WARNING\|Heartbeat file .* is unreadable')
Set-Content $HeartbeatFile -Value '{"IsDown":true}' -Encoding UTF8
Check "R8 heartbeat without Beat -> null" ($null -eq (Read-Heartbeat))
Remove-Item $HeartbeatFile -Force
# Restored state flows through the state machine: first up poll resolves from the original onset and names the undelivered DOWN
$n = Get-RestartNotice -Previous $hb -NowUtc $T0.AddMinutes(70) -BootTimeUtc $T0.AddMinutes(40) -GapThresholdSeconds 60 -IntervalSeconds 10 -SiteName 'CapCity' -HostName 'HOST1' -Url 'http://x'
$d = Step $n.RestoredState $false $T0.AddMinutes(70) -Result (Res '200' $true)
Check "R9 carried-over outage resolves with the true onset and duration" ($d.EmailKind -eq 'Resolved' -and $d.EmailSubject -eq '[HST RESOLVED] CapCity (HOST1) - outage lasted 1h 10m 00s' -and $d.OutageRecord.DurationSeconds -eq 4200 -and $d.OutageRecord.FailedPolls -eq 7 -and $d.OutageRecord.OutageStart_Local -eq '2026-09-04 08:00:00')
Check "R9 RESOLVED says the DOWN alert was never delivered" ($d.EmailBody -match '<td[^>]*>DOWN alert</td><td[^>]*>Not delivered\.' -and $null -eq $d.State.AlertDelivered)
$d = Step $n.RestoredState $true $T0.AddMinutes(70)
Check "R9 carried-over outage still down -> reminder from the old onset, first-notice row" ($d.EmailKind -eq 'Reminder' -and $d.EmailSubject -eq '[HST STILL DOWN] CapCity (HOST1) - down for 1h 10m 00s' -and $d.State.ConsecutiveFailures -eq 8 -and $d.EmailBody -match '<td[^>]*>Earlier alerts</td><td[^>]*>Not delivered\.')
$deliveredState = $n.RestoredState.Clone(); $deliveredState.AlertDelivered = $true
$d = Step $deliveredState $false $T0.AddMinutes(70) -Result (Res '200' $true)
Check "R9 RESOLVED after a delivered DOWN says so" ($d.EmailBody -match '<td[^>]*>DOWN alert</td><td[^>]*>Delivered</td>')
# Delivery tracking through DOWN
$st=NewState; $d=Step $st $true $T0; $st=$d.State; $d=Step $st $true $T0.AddSeconds(10); $st=$d.State; $d=Step $st $true $T0.AddSeconds(20)
Check "R10 DOWN decision carries kind and starts undelivered" ($d.EmailKind -eq 'Down' -and $d.State.AlertDelivered -eq $false)
$d2 = Step $d.State $false $T0.AddSeconds(30) -Result (Res '200' $true)
Check "R10 recovery clears delivery tracking" ($null -eq $d2.State.AlertDelivered -and $d2.EmailKind -eq 'Resolved')
# Alert queue with a stubbed sender
$script:PendingAlerts = New-Object System.Collections.ArrayList
$script:SendOk = $false; $script:Sent = @()
function Send-AlertEmail { param($Subject,$Body) $script:Sent += $Subject; return $script:SendOk }
$ok = Send-AlertOrQueue -Subject '[HST DOWN] x' -Body 'b' -Kind 'Down'
Check "Q1 failed send is queued and reported" (-not $ok -and $script:PendingAlerts.Count -eq 1 -and $script:LastLog -match 'will be retried every minute')
Check "Q1 retry within a minute does nothing" (@(Send-PendingAlert).Count -eq 0 -and $script:Sent.Count -eq 1)
$script:PendingAlerts[0].LastUtc = $script:PendingAlerts[0].LastUtc.AddSeconds(-61)
Check "Q1 retry after a minute while still failing keeps it queued" (@(Send-PendingAlert).Count -eq 0 -and $script:PendingAlerts.Count -eq 1 -and $script:Sent.Count -eq 2)
$script:PendingAlerts[0].LastUtc = $script:PendingAlerts[0].LastUtc.AddSeconds(-61); $script:SendOk = $true
$k = @(Send-PendingAlert)
Check "Q1 retry succeeds -> kind returned, queue empty" ($k.Count -eq 1 -and $k[0] -eq 'Down' -and $script:PendingAlerts.Count -eq 0 -and $script:LastLog -match 'Delivered on retry')
$script:SendOk = $false
Send-AlertOrQueue -Subject '[HST DOWN] x' -Body 'b' -Kind 'Down' | Out-Null
Send-AlertOrQueue -Subject '[HST MONITOR RESTARTED] x' -Body 'b' -Kind 'Restart' | Out-Null
Send-AlertOrQueue -Subject '[HST STILL DOWN] x' -Body 'b' -Kind 'Reminder' | Out-Null
Check "Q2 reminder supersedes the queued DOWN, restart notice kept" ($script:PendingAlerts.Count -eq 2 -and @($script:PendingAlerts | Where-Object { $_.Kind -eq 'Down' }).Count -eq 0 -and @($script:PendingAlerts | Where-Object { $_.Kind -eq 'Restart' }).Count -eq 1 -and ($script:Logs -join "`n") -match "Dropping undelivered '\[HST DOWN\] x', superseded by '\[HST STILL DOWN\] x'")
Send-AlertOrQueue -Subject '[HST RESOLVED] x' -Body 'b' -Kind 'Resolved' | Out-Null
Check "Q2 resolved supersedes the reminder, restart notice kept" ($script:PendingAlerts.Count -eq 2 -and @($script:PendingAlerts | Where-Object { $_.Kind -in @('Down','Reminder') }).Count -eq 0)
Send-AlertOrQueue -Subject '[HST MONITOR RESTARTED] y' -Body 'b' -Kind 'Restart' | Out-Null
Check "Q2 a newer restart notice replaces the older one" (@($script:PendingAlerts | Where-Object { $_.Kind -eq 'Restart' }).Count -eq 1 -and $script:PendingAlerts[-1].Subject -eq '[HST MONITOR RESTARTED] y')
foreach ($item in $script:PendingAlerts) { $item.FirstUtc = $item.FirstUtc.AddMinutes(-61); $item.LastUtc = $item.LastUtc.AddSeconds(-61) }
$k = @(Send-PendingAlert)
Check "Q3 gives up after an hour of failures" ($k.Count -eq 0 -and $script:PendingAlerts.Count -eq 0 -and ($script:Logs -join "`n") -match "Giving up on '\[HST RESOLVED\] x' after 60 minutes")
$script:SendOk = $false
1..7 | ForEach-Object { Send-AlertOrQueue -Subject "[HST DOWN] $_" -Body 'b' -Kind "K$_" | Out-Null }
Check "Q4 queue is capped at 5, oldest dropped" ($script:PendingAlerts.Count -eq 5 -and $script:PendingAlerts[0].Subject -eq '[HST DOWN] 3')
$script:PendingAlerts.Clear()
$script:SendOk = $true
Check "Q5 successful send is never queued" ((Send-AlertOrQueue -Subject 's' -Body 'b' -Kind 'Down') -and $script:PendingAlerts.Count -eq 0)
# SMTP credential rebuild never throws into the probe loop
function Get-ProtectedSecret { return $script:StoredSecret }
$SmtpAuthUser = 'svc@contoso.com'
$script:StoredSecret = ''
Check "C1 empty stored password -> null credential with a warning, no throw" ($null -eq (Get-SmtpCredential) -and $script:LastLog -match '^WARNING\|The stored SMTP password is empty')
$script:StoredSecret = $null
Check "C1 missing secret -> null credential" ($null -eq (Get-SmtpCredential))
$script:StoredSecret = "p@ss word'`u{00FC}"
$c1 = Get-SmtpCredential
Check "C1 stored password -> read-only credential with the exact password" ($c1 -and $c1.UserName -eq 'svc@contoso.com' -and $c1.GetNetworkCredential().Password -ceq $script:StoredSecret -and $c1.Password.IsReadOnly())
$SmtpAuthUser = ''
Check "C1 no auth user -> null credential" ($null -eq (Get-SmtpCredential))
Remove-Item function:Get-ProtectedSecret
Check "Monitor rebuilds the SMTP credential inside the send try block" ($template -match "(?s)try \{\s*\`$cred = Get-SmtpCredential\s*if \(\`$SmtpAuthUser -and -not \`$cred\)")
# Network wait
$sw = [Diagnostics.Stopwatch]::StartNew()
Check "N1 IP literal endpoint resolves instantly" ((Wait-NetworkReady -Url 'http://127.0.0.1:9/' -TimeoutSeconds 5) -and $sw.Elapsed.TotalSeconds -lt 3)
$sw.Restart()
Check "N1 unresolvable host gives up at the timeout with a warning" (-not (Wait-NetworkReady -Url 'http://nonexistent-host-zz.invalid/' -TimeoutSeconds 1) -and $sw.Elapsed.TotalSeconds -lt 40 -and $script:LastLog -match 'still fails after 1 s')
Check "N1 real endpoint resolves" (Wait-NetworkReady -Url 'https://prodasp09.hstpathways.com/p95_CSP/HSTeChart' -TimeoutSeconds 10)
# Static wiring
Check "Monitor writes a heartbeat before and after each poll" (([regex]::Matches($template, 'Write-Heartbeat -State \$state -NowUtc')).Count -eq 3)
Check "Monitor waits for name resolution before its first poll" ($template -match 'Wait-NetworkReady -Url \$Url')
Check "Monitor restart notice threshold is at least 60 s" ($template -match '\[math\]::Max\(60, 2 \* \(\$IntervalSeconds \+ \$TimeoutSeconds\)\)')
Check "Monitor Graph calls have a 30 s timeout" (([regex]::Matches($template, '-TimeoutSec 30')).Count -eq 2)
Check "Installer marks the heartbeat as a deliberate stop and logs STOP to the drops log" ($src -match "(?s)elseif \(\`$wasRunning\) \{.*?Add-Member -NotePropertyName Stopped -NotePropertyValue \`$true.*?HST-eChart-Drops\.log.*?'STOP'")
Check "Probe cycle errors reach the drops log" ($template.Contains("Write-DropLog -Kind 'ERROR' -Message `"Probe cycle error"))
Check "Install email skipped when the SMTP password cannot be read back" ($src -match '\$canSend -and \(Send-MailWithConfig')
Check "Stored secret gated on the credential recorded at the last successful install" ($src -match "\`$Saved\.CredentialFor -eq \`$client\) \{ Get-StoredSecret \}" -and $src -match "\`$settings\['CredentialFor'\] = switch")
function Write-Log { param($Level,$Message) }

Section "F. Live probe via curl.exe shim"
$SiteName='T'; $ExpectedContentMarker=''; $MinPopulatedBytes=100; $TimeoutSeconds=10
$Url='https://raw.githubusercontent.com/PowerShell/PowerShell/master/README.md'
$p=Get-HSTProbeResult
Check "Probe healthy 200"          ($p.HttpCode -eq '200')
Check "Probe healthy exit 0 / OK"  ($p.CurlExit -eq 0 -and $p.Reason -eq 'OK')
Check "Probe timings numeric"      ($null -ne $p.TotalMs -and $null -ne $p.TtfbMs -and $null -ne $p.DnsMs)
Check "Probe IP + size"            (-not [string]::IsNullOrWhiteSpace($p.RemoteIp) -and [int]$p.SizeBytes -gt 100)
Check "Probe populated"            ($p.ContentOk)
Check "Probe classified UP"        (-not (($p.CurlExit -ne 0) -or ($p.HttpCode -ne '200') -or (-not $p.ContentOk) -or ($null -eq $p.TotalMs)))
$Url='http://127.0.0.1:9/'; $TimeoutSeconds=3
$p=Get-HSTProbeResult
Check "Refused: code 000"          ($p.HttpCode -eq '000')
Check "Refused: exit 7 reason"     ($p.CurlExit -eq 7 -and $p.Reason -eq 'Connection refused or unreachable')
Check "Refused: classified DOWN"   (($p.CurlExit -ne 0) -or ($p.HttpCode -ne '200') -or (-not $p.ContentOk) -or ($null -eq $p.TotalMs))
$Url='http://nonexistent-host-zz.invalid/'
$p=Get-HSTProbeResult
Check "DNS fail: exit 6"           ($p.CurlExit -eq 6 -and $p.Reason -eq 'DNS resolution failed')
Check "DNS fail: code 000"         ($p.HttpCode -eq '000')
$Url='http://192.0.2.1/'; $TimeoutSeconds=2
$p=Get-HSTProbeResult
Check "Blackhole: non-zero curl exit" ($p.CurlExit -ne 0)
Check "Blackhole: classified DOWN" (($p.CurlExit -ne 0) -or ($p.HttpCode -ne '200') -or (-not $p.ContentOk) -or ($null -eq $p.TotalMs))
Check "No probe body file left behind" (-not (Test-Path (Join-Path $InstallDir 'probe-body.tmp')))
$Url='https://raw.githubusercontent.com/PowerShell/PowerShell/master/README.md'; $TimeoutSeconds=10
$ExpectedContentMarker='PowerShell'; $p=Get-HSTProbeResult
Check "Marker present -> populated" ($p.ContentOk)
$ExpectedContentMarker='zzz-not-in-page-zzz'; $p=Get-HSTProbeResult
Check "Marker absent -> not populated -> DOWN with a reason that says so" (-not $p.ContentOk -and $p.Reason -match '^Page not populated \(\d+ bytes, marker missing\)$')
$ExpectedContentMarker='PowerShell'; $MinPopulatedBytes=10000000; $p=Get-HSTProbeResult
Check "Marker present but body too small -> not populated, reason says marker found" (-not $p.ContentOk -and $p.Reason -match '^Page not populated \(\d+ bytes, marker found\)$')

# The real endpoint with the installer defaults: two redirects land on the federation sign-in page
$Url='https://prodasp09.hstpathways.com/p95_CSP/HSTeChart'; $TimeoutSeconds=15; $MaxRedirects=5; $MinPopulatedBytes=1000; $ExpectedContentMarker='HST Federation Provider'
$p=Get-HSTProbeResult
Check "Live HST: 200 after following redirects" ($p.HttpCode -eq '200' -and $p.CurlExit -eq 0 -and $p.Reason -eq 'OK')
Check "Live HST: exactly 2 redirects to the federation sign-in page" ($p.Redirects -eq '2' -and $p.FinalUrl -match '^https://prodasp09\.hstpathways\.com/p95_CSP/HSTFederationProvider/')
Check "Live HST: redirect time captured and below total" ($null -ne $p.RedirectMs -and $p.RedirectMs -gt 0 -and $p.RedirectMs -le $p.TotalMs)
Check "Live HST: sign-in page populated (marker and size)" ($p.ContentOk -and [int]$p.SizeBytes -ge 1000)
Check "Live HST: classified UP" (-not (($p.CurlExit -ne 0) -or ($p.HttpCode -ne '200') -or (-not $p.ContentOk) -or ($null -eq $p.TotalMs)))
$MaxRedirects=0; $p=Get-HSTProbeResult
Check "Redirect cap hit: exit 47, last code 302, classified DOWN" ($p.CurlExit -eq 47 -and $p.Reason -eq 'Too many redirects' -and $p.HttpCode -eq '302' -and (($p.HttpCode -ne '200') -or (-not $p.ContentOk)))
$MaxRedirects=0; $Url='https://prodasp09.hstpathways.com/p95_CSP/HSTeChart/'; $TimeoutSeconds=15
$p=Get-HSTProbeResult
$MaxRedirects=5
Check "Clean non-200 without a curl error names the HTTP code as the reason" ($p.CurlExit -eq 47 -or ($p.CurlExit -eq 0 -and $p.Reason -eq "HTTP $($p.HttpCode)"))
$MaxRedirects=5; $ExpectedContentMarker=''; $MinPopulatedBytes=100

# Install-time preflight uses the same redirect handling
foreach ($f in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-EndpointReachable'},$false)) { Invoke-Expression $f.Extent.Text }
$Url='https://prodasp09.hstpathways.com/p95_CSP/HSTeChart'; $TimeoutSeconds=15; $MaxRedirects=5
$r = Test-EndpointReachable
Check "Preflight: live HST reachable through 2 redirects" ($r.Reachable -and $r.HttpCode -eq '200' -and $r.Redirects -eq 2 -and $r.FinalUrl -match '^https://prodasp09\.hstpathways\.com/p95_CSP/HSTFederationProvider/')
$Url='http://127.0.0.1:9/'; $TimeoutSeconds=3
$r = Test-EndpointReachable
Check "Preflight: refused port -> not reachable, code 000" (-not $r.Reachable -and $r.HttpCode -eq '000')
$Url='https://raw.githubusercontent.com/PowerShell/PowerShell/master/README.md'; $TimeoutSeconds=10

Section "G. Wizard flows with scripted keystrokes"
foreach ($f in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false) | Where-Object { $_.Name -in @('Get-MailConfiguration','Get-SiteName') }) { Invoke-Expression $f.Extent.Text }
$script:Q = [System.Collections.Queue]::new(); $script:PromptCount = 0; $script:PromptLog = @()
function Push($answers){ $script:Q.Clear(); foreach($a in $answers){ $script:Q.Enqueue($a) }; $script:PromptCount=0; $script:PromptLog=@() }
function NextAnswer($prompt){ $script:PromptCount++; $script:PromptLog += $prompt; if ($script:Q.Count -eq 0) { throw "Wizard asked an unexpected extra prompt: $prompt" }; return $script:Q.Dequeue() }
function Read-Setting { param([string]$Prompt,[string]$Default="") if ($NonInteractive){return $Default}; $a = NextAnswer $Prompt; if ([string]::IsNullOrWhiteSpace($a)) { return $Default }; return $a.Trim() }
function Read-Choice { param([string]$Prompt,[string[]]$Allowed,[string]$Default) if ($NonInteractive){return $Default}; while ($true) { $a = NextAnswer $Prompt; if ([string]::IsNullOrWhiteSpace($a)) { return $Default }; $a=$a.Trim().ToUpper(); if ($Allowed -contains $a) { return $a } } }
function Read-Host { param([string]$Prompt,[switch]$AsSecureString) $a = NextAnswer $Prompt; if ($AsSecureString) { if ($a) { return (ConvertTo-SecureString $a -AsPlainText -Force) } else { return (New-Object System.Security.SecureString) } }; return $a }
function Get-DirectSendHost { param($FromAddress) [PSCustomObject]@{ Host='contoso-com.mail.protection.outlook.com'; Source='stub' } }
function Protect-Secret { param($Password,$PlainText) $script:LastPlainText = $PlainText; return 'CIPHER' }
$script:StoredSecretForWizard = $null
function Get-StoredSecret { return $script:StoredSecretForWizard }
$script:SavedMid = $null
function Save-InstallSettings { param($Settings) $script:SavedMid = $Settings }
function Get-Credential { param($UserName,$Message) New-Object System.Management.Automation.PSCredential($UserName,(ConvertTo-SecureString 'pw' -AsPlainText -Force)) }
$script:SendResult = $true; $script:SentSubjects=@()
function Send-MailWithConfig { param($Mail,$Subject,$Body,$Credential,$GraphSecret) $script:SentSubjects += $Subject; $script:LastGraphSecret=$GraphSecret; return $script:SendResult }
$script:CreateResult = @{ TenantId='11111111-2222-3333-4444-555555555555'; ClientId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; Secret='newsecret'; Expires='2028-09-04'; Sender='hst@contoso.com' }
function New-TenantMailApp { param($SenderAddress,$SiteName) return $script:CreateResult }
$NonInteractive=$false; $GraphAppDisplayName='HST Monitor'; $MailMethod='Graph'; $SmtpServer=''; $SmtpPort=25; $SmtpUseSsl=$false; $MailFrom=''; $MailTo=@(); $SmtpAuthUser=''; $GraphTenantId=''; $GraphClientId=''; $GraphSecretExpires=''
$T='11111111-2222-3333-4444-555555555555'; $C='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'

# W1 Graph, app exists, fresh box
Push @('1','hst@contoso.com','a@contoso.com','Y',$T,$C,'s3cret','2028-01-01','Y')
$m = Get-MailConfiguration -Saved $null -SiteName 'S'
Check "W1 Graph existing app returns config" ($m.MailMethod -eq 'Graph' -and $m.GraphTenantId -eq $T -and $m.GraphClientId -eq $C -and $m.GraphSecretExpires -eq '2028-01-01' -and $m.CipherText -eq 'CIPHER' -and $m.SmtpServer -eq 'graph.microsoft.com')
Check "W1 secret passed to test send" ($script:LastGraphSecret -eq 's3cret')
Check "W1 pasted secret reaches Protect-Secret as text" ($script:LastPlainText -eq 's3cret')
Check "W1 exactly 9 prompts" ($script:PromptCount -eq 9)
Check "W1 test subject names site and server" ($script:SentSubjects[-1] -eq "[HST MONITOR TEST] S ($env:COMPUTERNAME)")

# W2 Graph re-run with saved settings: all Enter except secret
$saved = [PSCustomObject]@{ MailMethod='Graph'; SmtpServer='graph.microsoft.com'; SmtpPort=443; SmtpUseSsl=$true; MailFrom='hst@contoso.com'; MailTo=@('a@contoso.com','b@contoso.com'); SmtpAuthUser=''; GraphTenantId=$T; GraphClientId=$C; GraphSecretExpires='2028-01-01'; CredentialFor=$C }
Push @('','','','','','','s3cret','','')
$m = Get-MailConfiguration -Saved $saved -SiteName 'S'
Check "W2 saved settings prefill everything" ($m.MailFrom -eq 'hst@contoso.com' -and $m.MailTo.Count -eq 2 -and $m.GraphTenantId -eq $T -and $m.GraphClientId -eq $C -and $m.GraphSecretExpires -eq '2028-01-01')
Check "W2 hasApp defaulted to Y when saved IDs exist" ($script:PromptLog[3] -match 'already been created' -and $m.GraphTenantId -eq $T)
Check "W2 9 prompts, all Enter except secret" ($script:PromptCount -eq 9)
Check "W2 no stored secret -> plain paste prompt" ($script:PromptLog[6] -eq 'Client secret (paste, input hidden)')

# W20 re-run with a stored secret for the same app: Enter keeps it, nothing needs pasting
$script:StoredSecretForWizard = 'stored~secret'
Push @('','','','','','','','','')
$m = Get-MailConfiguration -Saved $saved -SiteName 'S'
Check "W20 Enter keeps the stored secret" ($m.MailMethod -eq 'Graph' -and $script:LastGraphSecret -eq 'stored~secret' -and $script:LastPlainText -eq 'stored~secret' -and $script:PromptCount -eq 9 -and $script:PromptLog[6] -match '^Client secret \(Enter = keep')
# W21 a pasted secret wins over the stored one
Push @('','','','','','','fresh~secret','','')
$m = Get-MailConfiguration -Saved $saved -SiteName 'S'
Check "W21 pasted secret replaces the stored one" ($script:LastGraphSecret -eq 'fresh~secret' -and $script:LastPlainText -eq 'fresh~secret')
# W22 stored secret belongs to a different app: not offered, blank is refused
$savedOther = [PSCustomObject]@{ MailMethod='Graph'; SmtpServer='graph.microsoft.com'; SmtpPort=443; SmtpUseSsl=$true; MailFrom='hst@contoso.com'; MailTo=@('a@contoso.com'); SmtpAuthUser=''; GraphTenantId=$T; GraphClientId='ffffffff-ffff-ffff-ffff-ffffffffffff'; GraphSecretExpires=''; CredentialFor='ffffffff-ffff-ffff-ffff-ffffffffffff' }
Push @('','','','','',$C,'','s3cret','','Y')
$m = Get-MailConfiguration -Saved $savedOther -SiteName 'S'
Check "W22 stored secret for another app is not offered" ($m.GraphClientId -eq $C -and $script:LastGraphSecret -eq 's3cret' -and $script:PromptCount -eq 10 -and $script:PromptLog[6] -eq 'Client secret (paste, input hidden)')
# W23 saved settings were not Graph: stored file (from an SMTP password) is never offered as a Graph secret
$savedSmtp = [PSCustomObject]@{ MailMethod='Authenticated'; SmtpServer='smtp.office365.com'; SmtpPort=587; SmtpUseSsl=$true; MailFrom='hst@contoso.com'; MailTo=@('a@contoso.com'); SmtpAuthUser='hst@contoso.com'; GraphTenantId=''; GraphClientId=''; GraphSecretExpires=''; CredentialFor='hst@contoso.com' }
Push @('1','','','Y',$T,$C,'','s3cret','','Y')
$m = Get-MailConfiguration -Saved $savedSmtp -SiteName 'S'
Check "W23 an SMTP password on disk is never offered as a Graph secret" ($script:LastGraphSecret -eq 's3cret' -and $script:PromptCount -eq 10 -and $script:PromptLog[6] -eq 'Client secret (paste, input hidden)')
# W24 settings saved by an abandoned run (no CredentialFor yet): the file on disk is not trusted for this app
$savedAbandoned = [PSCustomObject]@{ MailMethod='Graph'; SmtpServer='graph.microsoft.com'; SmtpPort=443; SmtpUseSsl=$true; MailFrom='hst@contoso.com'; MailTo=@('a@contoso.com'); SmtpAuthUser=''; GraphTenantId=$T; GraphClientId=$C; GraphSecretExpires='' }
Push @('','','','','','','','s3cret','','Y')
$m = Get-MailConfiguration -Saved $savedAbandoned -SiteName 'S'
Check "W24 no CredentialFor in saved settings -> stored secret not offered" ($script:LastGraphSecret -eq 's3cret' -and $script:PromptCount -eq 10 -and $script:PromptLog[6] -eq 'Client secret (paste, input hidden)')
$script:StoredSecretForWizard = $null

# W3 Graph, create path (N): no Tenant/Client/expiry/secret prompts afterwards
Push @('1','hst@contoso.com','a@contoso.com','N','Y')
$m = Get-MailConfiguration -Saved $null -SiteName 'S'
Check "W3 create path uses created values" ($m.GraphTenantId -eq $T -and $m.GraphClientId -eq $C -and $m.GraphSecretExpires -eq '2028-09-04')
Check "W3 created secret used for test send" ($script:LastGraphSecret -eq 'newsecret')
Check "W3 exactly 5 prompts (method, from, to, create?, arrived?)" ($script:PromptCount -eq 5)
Check "W3 created IDs persisted immediately (abandoned runs prefill Y)" ($script:SavedMid -and $script:SavedMid.GraphClientId -eq $C -and $script:SavedMid.GraphTenantId -eq $T -and $script:SavedMid.MailMethod -eq 'Graph')

# W4 create fails then abort
$script:CreateResult = $null
Push @('1','hst@contoso.com','a@contoso.com','N','X')
$m = Get-MailConfiguration -Saved $null -SiteName 'S'
Check "W4 abort after failed tenant setup returns null" ($null -eq $m)
# W4b create fails, go back, choose Direct Send instead
Push @('1','hst@contoso.com','a@contoso.com','N','R','2','','','','Y')
$m = Get-MailConfiguration -Saved $null -SiteName 'S'
Check "W4b back to menu keeps from/to as defaults and lands on DirectSend" ($m.MailMethod -eq 'DirectSend' -and $m.MailFrom -eq 'hst@contoso.com' -and $m.SmtpServer -eq 'contoso-com.mail.protection.outlook.com' -and $m.SmtpPort -eq 25)
$script:CreateResult = @{ TenantId=$T; ClientId=$C; Secret='newsecret'; Expires='2028-09-04'; Sender='hst@contoso.com' }

# W5 Relay with bad inputs corrected, then N to change, then Y
Push @('3','notanemail','ok@contoso.com','','a@contoso.com, bad, b@contoso.com','','relay01','2525','y','N','','','','','','','Y')
$m = Get-MailConfiguration -Saved $null -SiteName 'S'
Check "W5 relay validation loops and defaults carry across N" ($m.MailMethod -eq 'Relay' -and $m.MailFrom -eq 'ok@contoso.com' -and $m.MailTo.Count -eq 2 -and $m.SmtpServer -eq 'relay01' -and $m.SmtpPort -eq 2525 -and $m.SmtpUseSsl)
Check "W5 second pass needed only Enters" ($script:PromptCount -eq 17)

# W6 Authenticated, skip on arrival prompt
Push @('4','ok@contoso.com','a@contoso.com','','','','','S')
$m = Get-MailConfiguration -Saved $null -SiteName 'S'
Check "W6 authenticated defaults: o365 587 TLS, user=from, cipher stored" ($m.MailMethod -eq 'Authenticated' -and $m.SmtpServer -eq 'smtp.office365.com' -and $m.SmtpPort -eq 587 -and $m.SmtpUseSsl -and $m.SmtpAuthUser -eq 'ok@contoso.com' -and $m.CipherText -eq 'CIPHER')

# W7 send failure: R retries with defaults, then success
$script:SendResult = $false
Push @('2','ok@contoso.com','a@contoso.com','','R')
try { $script:SendResult = $false; $m = $null
  # second pass will succeed: flip result when the retry prompt is consumed
  $orig = ${function:Send-MailWithConfig}
  function Send-MailWithConfig { param($Mail,$Subject,$Body,$Credential,$GraphSecret) $script:SentSubjects += $Subject; $script:SendCalls++; return ($script:SendCalls -ge 2) }
  $script:SendCalls=0
  Push @('2','ok@contoso.com','a@contoso.com','','R','','','','','Y')
  $m = Get-MailConfiguration -Saved $null -SiteName 'S'
  Check "W7 failed send -> retry -> success returns config" ($m.MailMethod -eq 'DirectSend' -and $script:SendCalls -eq 2)
} finally { ${function:Send-MailWithConfig} = $orig; $script:SendResult = $true }

# W8 skip after failed send
function Send-MailWithConfig { param($Mail,$Subject,$Body,$Credential,$GraphSecret) return $false }
Push @('2','ok@contoso.com','a@contoso.com','','S')
$m = Get-MailConfiguration -Saved $null -SiteName 'S'
Check "W8 skip after failed send still returns config" ($m.MailMethod -eq 'DirectSend')

# W10 first-site Graph: test send denied while the grant propagates, W waits and retries until it succeeds
$script:LastGraphSendError = 'AccessDenied'   # a stubbed send that fails stands for the Exchange grant not applied yet
function Start-Sleep { param($Seconds,$Milliseconds) $script:SleptSeconds += [int]$Seconds }
$script:SleptSeconds=0; $script:SendCalls=0; $script:SentSubjects=@()
function Send-MailWithConfig { param($Mail,$Subject,$Body,$Credential,$GraphSecret) $script:SentSubjects += $Subject; $script:SendCalls++; return ($script:SendCalls -ge 3) }
Push @('1','hst@contoso.com','a@contoso.com','N','W','Y')
$m = Get-MailConfiguration -Saved $null -SiteName 'S'
Check "W10 W waits, retries, succeeds on 3rd send, then asks arrived" ($m -and $m.MailMethod -eq 'Graph' -and $script:SendCalls -eq 3 -and $script:PromptCount -eq 6 -and $script:PromptLog[4] -match '^W = wait' -and $script:PromptLog[5] -match 'Did the test email arrive')
Check "W10 quiet 30 min first, then 10 min between retries" ($script:SleptSeconds -eq 2400)
Check "W10 returned the created app config" ($m.GraphClientId -eq $C -and $m.CipherText -eq 'CIPHER' -and $m.GraphSecretExpires -eq '2028-09-04')

# W11 W never propagates: gives up at the 40 minute deadline and finishes as S, no arrived prompt
$script:Clock = [datetime]'2026-09-04T12:00:00'
function Get-Date { param($Format) $script:Clock = $script:Clock.AddSeconds(30); if ($Format) { return $script:Clock.ToString($Format) }; return $script:Clock }
function Send-MailWithConfig { param($Mail,$Subject,$Body,$Credential,$GraphSecret) $script:SendCalls++; return $false }
$script:SendCalls=0
Push @('1','hst@contoso.com','a@contoso.com','N','W')
$m = Get-MailConfiguration -Saved $null -SiteName 'S'
Remove-Item function:Get-Date
Check "W11 gave up after the window and still returned config" ($m -and $m.MailMethod -eq 'Graph' -and $script:PromptCount -eq 5)
Check "W11 retried repeatedly before giving up" ($script:SendCalls -ge 10 -and $script:SendCalls -le 100)

# W12 first-site Graph denial, S finishes immediately without waiting
function Send-MailWithConfig { param($Mail,$Subject,$Body,$Credential,$GraphSecret) return $false }
$script:SleptSeconds=0
Push @('1','hst@contoso.com','a@contoso.com','N','S')
$m = Get-MailConfiguration -Saved $null -SiteName 'S'
Check "W12 S after propagation denial returns config without waiting" ($m -and $m.MailMethod -eq 'Graph' -and $script:PromptCount -eq 5 -and $script:SleptSeconds -eq 0)

# W25 first-site Graph, the secret itself is rejected: no propagation wait is offered, the plain retry prompt appears
$script:LastGraphSendError = 'InvalidSecret'
Push @('1','hst@contoso.com','a@contoso.com','N','S')
$m = Get-MailConfiguration -Saved $null -SiteName 'S'
Check "W25 rejected secret gets the plain retry prompt, not the propagation wait" ($m -and $m.MailMethod -eq 'Graph' -and $script:PromptCount -eq 5 -and $script:PromptLog[4] -match '^Test email failed\. R = change settings')
Check "W25 finishing after a failed test marks the install email to be skipped" ($script:MailTestSkipped -eq $true)
$script:MailTestSkipped = $false

# W26 a secret minted this run is rejected: R, then the app prompt defaults to N and the tenant setup runs again with a new secret
function New-TenantMailApp { param($SenderAddress,$SiteName) $script:CreateCalls++; return $script:CreateResult }
function Send-MailWithConfig { param($Mail,$Subject,$Body,$Credential,$GraphSecret,$MaxWaitSeconds) $script:SendCalls++; $script:LastGraphSecret=$GraphSecret; return ($script:SendCalls -ge 2) }
$script:SendCalls = 0; $script:CreateCalls = 0; $script:LastGraphSendError = 'InvalidSecret'
Push @('1','hst@contoso.com','a@contoso.com','N','R','','','','','Y')
$m = Get-MailConfiguration -Saved $null -SiteName 'S'
Check "W26 after a rejected minted secret the app prompt defaults to N and mints again" ($m -and $m.GraphClientId -eq $C -and $script:PromptCount -eq 10 -and $script:CreateCalls -eq 2 -and $script:PromptLog[8] -match 'already been created' -and $script:LastGraphSecret -eq 'newsecret' -and $script:MailTestSkipped -eq $false)
# W27 same start, but Y at the app prompt now asks for a pasted secret instead of silently reusing the rejected one
$script:SendCalls = 0; $script:CreateCalls = 0; $script:LastGraphSendError = 'InvalidSecret'
Push @('1','hst@contoso.com','a@contoso.com','N','R','','','','Y','','','pasted~secret','','Y')
$m = Get-MailConfiguration -Saved $null -SiteName 'S'
Check "W27 Y after a rejected minted secret prompts for a paste, rejected secret never reused" ($m -and $script:PromptCount -eq 14 -and $script:CreateCalls -eq 1 -and (@($script:PromptLog | Where-Object { $_ -match '^Client secret \(paste' }).Count -eq 1) -and $script:LastGraphSecret -eq 'pasted~secret')
# W28 a GUID pasted as the secret is refused and asked again
function Send-MailWithConfig { param($Mail,$Subject,$Body,$Credential,$GraphSecret,$MaxWaitSeconds) $script:LastGraphSecret=$GraphSecret; return $true }
$script:LastGraphSendError = ''
Push @('1','hst@contoso.com','a@contoso.com','Y',$T,$C,'11111111-2222-3333-4444-555555555555','s3cret','2028-01-01','Y')
$m = Get-MailConfiguration -Saved $null -SiteName 'S'
Check "W28 a GUID is refused as the secret and the real value is taken on the second prompt" ($m -and $script:PromptCount -eq 10 -and (@($script:PromptLog | Where-Object { $_ -match '^Client secret' }).Count -eq 2) -and $script:LastGraphSecret -eq 's3cret')
function Send-MailWithConfig { param($Mail,$Subject,$Body,$Credential,$GraphSecret,$MaxWaitSeconds) return $false }
$script:LastGraphSendError = 'AccessDenied'
Remove-Item function:Start-Sleep

# W13 port validation loops until a valid port is typed
$script:SendPlan = [System.Collections.Queue]::new()
function Send-MailWithConfig { param($Mail,$Subject,$Body,$Credential,$GraphSecret) $script:SentSubjects += $Subject; $script:LastGraphSecret=$GraphSecret; $script:SendCalls++; if ($script:SendPlan.Count -gt 0) { return $script:SendPlan.Dequeue() }; return $true }
Push @('3','ok@contoso.com','a@contoso.com','relay01','abc','70000','2525','N','Y')
$m = Get-MailConfiguration -Saved $null -SiteName 'S'
Check "W13 bad ports re-prompt, valid port accepted" ($m.MailMethod -eq 'Relay' -and $m.SmtpPort -eq 2525 -and $script:PromptCount -eq 9)

# W14 saved Authenticated with TLS off: all Enter keeps TLS off and port 25
$savedAuth = [PSCustomObject]@{ MailMethod='Authenticated'; SmtpServer='mail.internal.local'; SmtpPort=25; SmtpUseSsl=$false; MailFrom='svc@contoso.com'; MailTo=@('a@contoso.com'); SmtpAuthUser='svc@contoso.com' }
Push @('','','','','','','','Y')
$m = Get-MailConfiguration -Saved $savedAuth -SiteName 'S'
Check "W14 saved TLS off survives an all-Enter re-run" ($m.MailMethod -eq 'Authenticated' -and $m.SmtpServer -eq 'mail.internal.local' -and $m.SmtpPort -eq 25 -and -not $m.SmtpUseSsl -and $m.SmtpAuthUser -eq 'svc@contoso.com' -and $script:PromptCount -eq 8)

# W15 saved Graph IDs survive a failed Direct Send detour: the app prompt still defaults to Y and nothing is re-created
$script:CreateCalls = 0
function New-TenantMailApp { param($SenderAddress,$SiteName) $script:CreateCalls++; return $script:CreateResult }
$savedGraph = [PSCustomObject]@{ MailMethod='Graph'; SmtpServer='graph.microsoft.com'; SmtpPort=443; SmtpUseSsl=$true; MailFrom='hst@contoso.com'; MailTo=@('a@contoso.com'); SmtpAuthUser=''; GraphTenantId=$T; GraphClientId=$C; GraphSecretExpires='2027-01-01' }
$script:SendPlan.Clear(); $script:SendPlan.Enqueue($false)
Push @('2','','','','R','1','','','','','','s3cret','','Y')
$m = Get-MailConfiguration -Saved $savedGraph -SiteName 'S'
Check "W15 Graph IDs kept after a Direct Send detour, app not re-created" ($m.MailMethod -eq 'Graph' -and $m.GraphTenantId -eq $T -and $m.GraphClientId -eq $C -and $m.GraphSecretExpires -eq '2027-01-01' -and $script:CreateCalls -eq 0 -and $script:PromptCount -eq 14 -and $script:PromptLog[8] -match 'already been created')

# W16 a saved expiry can be cleared with '-'
Push @('1','','','','','','s3cret','-','Y')
$m = Get-MailConfiguration -Saved $savedGraph -SiteName 'S'
Check "W16 dash clears the saved expiry" ($m.MailMethod -eq 'Graph' -and $m.GraphSecretExpires -eq '')

# W17 cancelled credential dialog keeps the host, port, TLS, and user just typed
$script:CredCalls = 0
function Get-Credential { param($UserName,$Message) $script:CredCalls++; if ($script:CredCalls -eq 1) { return $null }; New-Object System.Management.Automation.PSCredential($UserName,(ConvertTo-SecureString 'pw' -AsPlainText -Force)) }
Push @('4','ok@contoso.com','a@contoso.com','smtp.custom.local','2587','N','me@contoso.com','','','','','','','','Y')
$m = Get-MailConfiguration -Saved $null -SiteName 'S'
Check "W17 typed values survive a cancelled credential dialog" ($m.MailMethod -eq 'Authenticated' -and $m.SmtpServer -eq 'smtp.custom.local' -and $m.SmtpPort -eq 2587 -and -not $m.SmtpUseSsl -and $m.SmtpAuthUser -eq 'me@contoso.com' -and $script:PromptCount -eq 15)
function Get-Credential { param($UserName,$Message) New-Object System.Management.Automation.PSCredential($UserName,(ConvertTo-SecureString 'pw' -AsPlainText -Force)) }

# W19 a blank password in the credential dialog is refused like a cancel, then a real one is accepted
function Write-Log { param($Level,$Message) $script:LastLog = "$Level|$Message"; $script:Logs += "$Level|$Message" }
$script:Logs = @(); $script:CredCalls = 0
function Get-Credential { param($UserName,$Message) $script:CredCalls++; if ($script:CredCalls -eq 1) { return (New-Object System.Management.Automation.PSCredential($UserName, (New-Object System.Security.SecureString))) }; New-Object System.Management.Automation.PSCredential($UserName,(ConvertTo-SecureString 'pw' -AsPlainText -Force)) }
Push @('4','ok@contoso.com','a@contoso.com','','','','','','','','','','','','Y')
$m = Get-MailConfiguration -Saved $null -SiteName 'S'
Check "W19 blank password refused, wizard restarts with defaults kept, real password accepted" ($m.MailMethod -eq 'Authenticated' -and $m.CipherText -eq 'CIPHER' -and $script:CredCalls -eq 2 -and $script:PromptCount -eq 15 -and (($script:Logs -join "`n") -match 'WARNING\|A password is required'))
function Write-Log { param($Level,$Message) }
function Get-Credential { param($UserName,$Message) New-Object System.Management.Automation.PSCredential($UserName,(ConvertTo-SecureString 'pw' -AsPlainText -Force)) }

# W18 after creating the app and choosing R at the propagation prompt, the next Graph pass reuses the new secret and needs no paste
$script:SendPlan.Clear(); $script:SendPlan.Enqueue($false); $script:SendPlan.Enqueue($true)
function Start-Sleep { param($Seconds,$Milliseconds) }
Push @('1','hst@contoso.com','a@contoso.com','N','R','','','','','','','','Y')
$m = Get-MailConfiguration -Saved $null -SiteName 'S'
Remove-Item function:Start-Sleep
Check "W18 second Graph pass reuses the secret created in this run" ($m.MailMethod -eq 'Graph' -and $m.GraphClientId -eq $C -and $script:LastGraphSecret -eq 'newsecret' -and $script:PromptCount -eq 13 -and (@($script:PromptLog | Where-Object { $_ -match 'Client secret' }).Count -eq 0) -and $script:PromptLog[4] -match '^W = wait')

# W9 Non-interactive: Graph refused, DirectSend proceeds with config block
$NonInteractive=$true; $MailMethod='Graph'; $MailFrom='x@contoso.com'; $MailTo=@('a@contoso.com')
Check "W9 non-interactive Graph refused" ($null -eq (Get-MailConfiguration -Saved $null -SiteName 'S'))
$MailMethod='DirectSend'
$m = Get-MailConfiguration -Saved $null -SiteName 'S'
Check "W9 non-interactive DirectSend proceeds" ($m.MailMethod -eq 'DirectSend' -and $m.MailFrom -eq 'x@contoso.com')
$NonInteractive=$false

# Site name prompts
$env:COMPUTERNAME='SRV01'; $SiteNameOverride=''
Push @('CapCity'); $n = Get-SiteName; Check "Site: clean input needs 1 prompt" ($n -eq 'CapCity' -and $script:PromptCount -eq 1)
Push @(''); $n = Get-SiteName; Check "Site: Enter takes machine name" ($n -eq 'SRV01' -and $script:PromptCount -eq 1)
Push @("O'Brien!!",'Y'); $n = Get-SiteName; Check "Site: dirty input asks once to confirm cleanup" ($n -eq 'OBrien' -and $script:PromptCount -eq 2)
Push @('!!!','Jersey Shore'); $n = Get-SiteName; Check "Site: empty-after-cleanup re-prompts" ($n -eq 'Jersey Shore' -and $script:PromptCount -eq 2)
Push @(''); $n = Get-SiteName -SavedDefault 'Saved Site'; Check "Site: saved default wins over machine name" ($n -eq 'Saved Site')
$SiteNameOverride='Override Site'; Push @(); $n = Get-SiteName; Check "Site: override skips prompt" ($n -eq 'Override Site' -and $script:PromptCount -eq 0); $SiteNameOverride=''

Section "H. Sign-in and setup flow static checks"
Check "One sign-in: offline_access requested" ($src -match 'offline_access')
Check "Device code copied to clipboard" ($src -match 'Set-Clipboard -Value \$dc\.user_code')
Check "Device fallback still has pre-filled URL" ($src -match [regex]::Escape('$signInUrl = "$($dc.verification_uri)?otc=$($dc.user_code)"'))
Check "One sign-in: Azure CLI client with .default scope only (no AADSTS65002)" ($src -match "clientId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'" -and $src -match "scope = 'https://graph\.microsoft\.com/\.default offline_access'" -and -not ($src -match 'graph\.microsoft\.com/Application\.ReadWrite'))
Check "Exchange token from the same sign-in's refresh token, same client" ($src -match "grant_type = 'refresh_token'; client_id = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'" -and $src -match 'outlook\.office365\.com/\.default offline_access')
Check "No second interactive sign-in for Exchange" ((([regex]::Matches($src,'Get-BrowserToken -ClientId')).Count) -eq 1)
Check "No embedded IE control, no other first-party client ids" (-not ($src -match 'WebBrowser|FEATURE_BROWSER_EMULATION|DoEvents|14d82eec|fb78d390'))
Check "Prompt text asks for Global Administrator" ($src -match "Sign in as a Global Administrator'" -and -not ($src -match 'Application Administrator'))
Check "Exchange work goes through admin REST endpoint" ($src -match 'outlook\.office365\.com/adminapi/beta/\$TenantId/InvokeCommand' -and $src -match 'CmdletInput')
Check "Module is fallback only, connects with -UserPrincipalName (all versions)" ($src -match 'Connect-ExchangeOnline -UserPrincipalName \$auth\.Upn' -and -not ($src -match 'Connect-ExchangeOnline -Device') -and -not ($src -match 'Connect-ExchangeOnline -AccessToken'))
Check "Module removed only if it was used" ($src.Contains("if (`$script:ExoMode -eq 'module') { Remove-TenantSetupModules }"))
Check "No background install job remains" (-not ($src -match 'Start-ModuleInstallJob|Start-Job'))
Check "Every Exchange cmdlet routed through the dispatcher" ((([regex]::Matches($src,"Invoke-ExoCmdlet -Name '([A-Za-z-]+)'") | % { $_.Groups[1].Value } | Sort-Object -Unique) -join ',') -eq 'Add-DistributionGroupMember,Enable-OrganizationCustomization,Get-ApplicationAccessPolicy,Get-DistributionGroup,Get-DistributionGroupMember,Get-Mailbox,Get-ManagementRoleAssignment,Get-ManagementScope,Get-OrganizationConfig,Get-ServicePrincipal,New-ApplicationAccessPolicy,New-DistributionGroup,New-Mailbox,New-ManagementRoleAssignment,New-ManagementScope,New-ServicePrincipal,Remove-ManagementRoleAssignment,Set-ManagementScope,Test-ApplicationAccessPolicy,Test-ServicePrincipalAuthorization')
Check "AppId sent as a string array (String[] parameter)" ($src -match '\bAppId = \[string\[\]\]@\(\$app\.appId\)')
Check "RBAC for Applications is the primary scoping" ($src -match "Role = 'Application Mail\.Send'" -and $src -match 'New-ManagementScope' -and $src -match 'Test-ServicePrincipalAuthorization')
Check "Legacy policy retained as fallback" ($src -match 'Falling back to the legacy application access policy')
Check "Tenant-wide consent removed when RBAC scope applies" ($src -match 'Method DELETE -Path "servicePrincipals/')
Check "Dehydrated tenant handled" ($src -match 'IsDehydrated' -and $src -match 'Enable-OrganizationCustomization')
Check "Secret minted only after Exchange configuration" ($src.IndexOf('/addPassword') -gt $src.IndexOf('Exchange configuration failed'))
Check "Raw REST error body preserved" ($src -match 'Full response')
Check "Web error bodies surfaced in installer and monitor" ((([regex]::Matches($src,'function Get-RestErrorDetail')).Count -eq 2) -and (([regex]::Matches($src,[regex]::Escape('Get-RestErrorDetail $_'))).Count -ge 4))
Check "Access-denied hint explains the propagation wait" ($src -match 'Wait at least 30 minutes without retrying')
Check "First-site Graph test send auto-waits only for an Exchange access denial" ($src -match "\`$method -eq 'Graph' -and \`$script:LastGraphSendError -eq 'AccessDenied' -and \(\`$created -or" -and $src -match 'wait and retry automatically')
Check "Ports validated through Read-PortSetting" ($src -match 'function Read-PortSetting' -and -not ($src -match '\[int\]\(Read-Setting -Prompt "Port"'))
Check "Install folder hardened before anything is written" ($src -match 'function Protect-InstallFolder' -and $src -match "Protect-InstallFolder -Path \`$InstallDir\s*\r?\n" -and $src -match "Protect-InstallFolder -Path \(Split-Path -Path \`$InstallDir -Parent\) -OwnerOnly")
Check "Credential file restricted before content is written, icacls checked" ($src -match "(?s)function Save-SmtpCredential \{.*?icacls\.exe.*?LASTEXITCODE.*?Set-Content.*?\n\}")
Check "Exchange not-found mapping is narrow and transient errors retried" ($src -match "couldn\.t be found\|could not be found" -and $src -match '429, 500, 502, 503, 504')
Check "Stale role assignment replaced instead of trusted by name" ($src -match "Remove-ManagementRoleAssignment")
Check "Created secret bypasses the transcript" (-not ($src -match 'Write-Host "  Client secret') -and $src -match '\[Console\]::Out\.WriteLine\("  Client secret')
Check "Device code honours slow_down" ($src -match "if \(\`$err -eq 'slow_down'\) \{ \`$interval \+= 5; continue \}")
Check "Browser sign-in checks state before rendering the page" ($src -match "if \(\`$code -and \`$gotState -ne \`$state\)")
Check "Policy retry can switch to the group directory id" ($src -match 'ExternalDirectoryObjectId')
Check "Scope filter quotes apostrophes in the sender" ($src -match [regex]::Escape('$SenderAddress.Replace("''", "''''")'))
Check "Created values skip re-prompts" ($src -match '\$tenant = \$created\.TenantId; \$client = \$created\.ClientId; \$expiry = \$created\.Expires')
Check "Site confirm only on cleanup change" ($src -match "Cleaned to '" -and -not ($src -match "Use site name '"))
$sw = $src.Substring($src.IndexOf('        switch ($method) {'), $src.IndexOf('        if ($restart) { continue }') - $src.IndexOf('        switch ($method) {'))
Check "No 'continue' inside the wizard switch (would exit switch, not loop)" (-not ($sw -match '\bcontinue\b'))
# W10 password branch: cancelled Get-Credential restarts cleanly with defaults kept
function Get-Credential { param($UserName,$Message) if ($script:CredCancelOnce) { $script:CredCancelOnce=$false; return $null }; New-Object System.Management.Automation.PSCredential($UserName,(ConvertTo-SecureString 'pw' -AsPlainText -Force)) }
function Send-MailWithConfig { param($Mail,$Subject,$Body,$Credential,$GraphSecret) return $true }
$script:CredCancelOnce=$true
Push @('4','ok@contoso.com','a@contoso.com','','','','',   '','','','','','','',   'Y')
$m = Get-MailConfiguration -Saved $null -SiteName 'S'
Check "W10 cancelled credential restarts wizard, defaults kept, completes" ($m.MailMethod -eq 'Authenticated' -and $m.MailFrom -eq 'ok@contoso.com' -and $m.CipherText -eq 'CIPHER' -and $script:PromptCount -eq 15)
Check "Install summary printed" ($src -match 'Write-Host "Install summary"')


Section "H2. Installer token path against a local sign-in mock (fresh secret replication)"
foreach ($f in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false) | Where-Object { $_.Name -in @('Get-RestErrorDetail','Get-InstallerGraphToken','Send-GraphMail') }) { Invoke-Expression $f.Extent.Text }
Check "H2 seams and state declared once each" ((([regex]::Matches($src,'(?m)^\$script:LoginBase = ''https://login\.microsoftonline\.com''')).Count -eq 1) -and (([regex]::Matches($src,'(?m)^\$script:GraphBase = ''https://graph\.microsoft\.com''')).Count -eq 1) -and $src -match '(?m)^\$script:FreshSecretRetrySeconds = 15$' -and $src -match '(?m)^\$script:PastedSecretRetrySeconds = 60$')
Check "H2 installer app-only token and send go through the seams" ($src -match '"\$script:LoginBase/\$TenantId/oauth2/v2\.0/token"' -and $src -match '"\$script:GraphBase/v1\.0/users/\$SenderAddress/sendMail"')
Check "H2 install email and test email share the helper (single Graph send path)" ((([regex]::Matches($src,'Get-InstallerGraphToken -TenantId')).Count -eq 2) -and (([regex]::Matches($src,'client_secret = \$Secret;')).Count -eq 1))
$h2WriteLog = ${function:Write-Log}
$script:H2Log = @()
function Write-Log { param($Level,$Message) $script:H2Log += "$Level|$Message" }
function Get-FreeTestPort { $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0); $l.Start(); $p = ($l.LocalEndpoint).Port; $l.Stop(); return $p }
$mockLog = Join-Path ([IO.Path]::GetTempPath()) "hst_mock_$PID.log"
function Start-MockGraph {
    # Minimal HTTP responder: the token route fails the first TokenFailures requests with FailCode, then issues tokens;
    # the sendMail route answers SendStatus with SendBody. Every request is appended to LogPath as path|status.
    param([int]$Port, [int]$TokenFailures = 0, [string]$FailCode = 'AADSTS7000215', [int]$FailStatus = 401, [int]$SendStatus = 202, [string]$SendBody = '', [string]$LogPath)
    if (Test-Path $LogPath) { Remove-Item $LogPath -Force }
    Start-Job -ScriptBlock {
        param($Port, $TokenFailures, $FailCode, $FailStatus, $SendStatus, $SendBody, $LogPath)
        $reasons = @{ 200 = 'OK'; 202 = 'Accepted'; 400 = 'Bad Request'; 401 = 'Unauthorized'; 403 = 'Forbidden'; 404 = 'Not Found' }
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        $deadline = (Get-Date).AddSeconds(45)
        $tokenHits = 0
        while ((Get-Date) -lt $deadline) {
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 30; continue }
            $client = $listener.AcceptTcpClient()
            $stream = $client.GetStream(); $stream.ReadTimeout = 3000
            $buf = New-Object byte[] 65536; $raw = New-Object System.IO.MemoryStream
            $headerEnd = -1; $bodyLen = 0
            try {
                while ($true) {
                    $n = $stream.Read($buf, 0, $buf.Length)
                    if ($n -le 0) { break }
                    $raw.Write($buf, 0, $n)
                    $text = [Text.Encoding]::ASCII.GetString($raw.ToArray())
                    if ($headerEnd -lt 0) {
                        $headerEnd = $text.IndexOf("`r`n`r`n")
                        if ($headerEnd -ge 0) { $m = [regex]::Match($text.Substring(0, $headerEnd), '(?im)^Content-Length:\s*(\d+)'); if ($m.Success) { $bodyLen = [int]$m.Groups[1].Value } }
                    }
                    if ($headerEnd -ge 0 -and $raw.Length -ge ($headerEnd + 4 + $bodyLen)) { break }
                }
            } catch { }
            $text = [Text.Encoding]::ASCII.GetString($raw.ToArray())
            $path = (($text -split "`r`n")[0] -split ' ')[1]
            if ($path -match '/oauth2/v2\.0/token$') {
                $tokenHits++
                if ($tokenHits -le $TokenFailures) { $status = $FailStatus; $body = '{"error":"invalid_client","error_description":"' + $FailCode + ': Invalid client secret provided. Ensure the secret being sent in the request is the client secret value, not the client secret ID","error_codes":[7000215]}' }
                else { $status = 200; $body = '{"token_type":"Bearer","expires_in":3599,"access_token":"tok' + $tokenHits + '"}' }
            }
            elseif ($path -match '/sendMail$') { $status = $SendStatus; $body = $SendBody }
            else { $status = 404; $body = '' }
            Add-Content -Path $LogPath -Value "$path|$status" -Encoding ASCII
            $resp = "HTTP/1.1 $status $($reasons[$status])`r`nContent-Type: application/json`r`nContent-Length: $([Text.Encoding]::UTF8.GetByteCount($body))`r`nConnection: close`r`n`r`n$body"
            $bytes = [Text.Encoding]::UTF8.GetBytes($resp)
            try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } catch { }
            $client.Close()
        }
        $listener.Stop()
    } -ArgumentList $Port, $TokenFailures, $FailCode, $FailStatus, $SendStatus, $SendBody, $LogPath
}
function Wait-MockGraph {
    param([int]$Port)
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline) {
        try {
            $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $Port); $s = $c.GetStream(); $s.ReadTimeout = 3000
            $req = [Text.Encoding]::ASCII.GetBytes("GET /ping HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n"); $s.Write($req, 0, $req.Length); $s.Flush()
            $b = New-Object byte[] 512; $n = $s.Read($b, 0, $b.Length); $c.Close()
            if ($n -gt 0) { return $true }
        } catch { Start-Sleep -Milliseconds 250 }
    }
    return $false
}
function Stop-MockGraph { param($Job) $Job | Stop-Job -ErrorAction SilentlyContinue; $Job | Remove-Job -Force -ErrorAction SilentlyContinue }
function Get-MockHits { param($Path, $Kind) if (-not (Test-Path $Path)) { return 0 }; return @(Get-Content $Path | Where-Object { $_ -match $Kind }).Count }
function Use-MockGraph { param([int]$Port) $script:LoginBase = "http://127.0.0.1:$Port"; $script:GraphBase = "http://127.0.0.1:$Port" }
function Show-H2Log { if ($script:fail -ne $script:H2FailBefore) { $script:H2Log | ForEach-Object { Write-Host "  log: $_" } }; $script:H2FailBefore = $script:fail }
$script:H2FailBefore = $script:fail
function Set-FreshSecret { param([int]$AgeMinutes = 0) $script:FreshSecretClientId = 'app-fresh'; $script:FreshSecretCreatedUtc = (Get-Date).ToUniversalTime().AddMinutes(-$AgeMinutes); $script:FreshSecretUntilUtc = $script:FreshSecretCreatedUtc.AddMinutes(20); $script:InstallerToken = $null; $script:H2Log = @() }
$script:FreshSecretRetrySeconds = 1; $script:PastedSecretRetrySeconds = 3; $script:FreshSecretNoteSeconds = 2; $script:QuietAccessDeniedHint = $false
Check "H2 static: install email honours the skip flag and caps its wait, wizard refuses a GUID as the secret" ($src -match 'if \(\$script:MailTestSkipped\) \{ Write-Log -Level WARNING' -and $src -match '-GraphSecret \$graphSecret -MaxWaitSeconds 120\)' -and $src -match 'Test-GuidLike \$graphSecret' -and $src -match "if \(\`$answer -eq 'S' -and -not \`$sent\) \{ \`$script:MailTestSkipped = \`$true \}")
$sendArgs = @{ TenantId = 'tid'; ClientId = 'app-fresh'; Secret = 'S1'; SenderAddress = 'hst@contoso.com'; To = @('a@contoso.com'); Subject = 'T'; Body = '<p>x</p>' }

# H2-1 fresh secret: two replicas answer 7000215, the third issues a token, the send goes through, one explanatory line
Set-FreshSecret
$port = Get-FreeTestPort; $job = Start-MockGraph -Port $port -TokenFailures 2 -LogPath $mockLog; $up = Wait-MockGraph -Port $port; Use-MockGraph -Port $port
Check "H2 mock sign-in listener answers" $up
$sw = [Diagnostics.Stopwatch]::StartNew(); $ok = Send-GraphMail @sendArgs; $sw.Stop()
Check "H2-1 fresh secret rejected twice then accepted: send succeeds" ($ok -eq $true -and (Get-MockHits $mockLog '/token\|401') -eq 2 -and (Get-MockHits $mockLog '/token\|200') -eq 1 -and (Get-MockHits $mockLog '/sendMail\|202') -eq 1)
Check "H2-1 waited the retry interval between attempts" ($sw.Elapsed.TotalSeconds -ge 1.8)
Check "H2-1 one replication line naming the code and the deadline, no failure class" (@($script:H2Log | Where-Object { $_ -match '^INFORMATIONAL\|The sign-in service has not accepted the new secret yet \(AADSTS7000215\)\. Usually a replication delay that clears within minutes\. Retrying every 1 s until \d\d:\d\d\.$' }).Count -eq 1 -and @($script:H2Log | Where-Object { $_ -match '^(FAILED|WARNING)\|' }).Count -eq 0 -and $script:LastGraphSendError -eq '')
Check "H2-1 bearer token cached with expiry" ($script:InstallerToken.AccessToken -eq 'tok3' -and $script:InstallerToken.ExpiresUtc -gt (Get-Date).ToUniversalTime().AddMinutes(50))
# H2-2 the token is reused: a second send makes no token request
$ok2 = Send-GraphMail @sendArgs
Check "H2-2 second send reuses the token" ($ok2 -eq $true -and (Get-MockHits $mockLog '/token\|') -eq 3 -and (Get-MockHits $mockLog '/sendMail\|202') -eq 2)
# H2-3 a different secret is a cache miss
$sa2 = $sendArgs.Clone(); $sa2['Secret'] = 'S2'
$ok3 = Send-GraphMail @sa2
Check "H2-3 a different secret requests a new token" ($ok3 -eq $true -and (Get-MockHits $mockLog '/token\|') -eq 4 -and $script:InstallerToken.Secret -eq 'S2')
# H2-3b an expired cached token is replaced
$script:InstallerToken.ExpiresUtc = (Get-Date).ToUniversalTime().AddMinutes(4)
$ok3b = Send-GraphMail @sa2
Check "H2-3b a token within 5 minutes of expiry is refreshed" ($ok3b -eq $true -and (Get-MockHits $mockLog '/token\|') -eq 5)
Show-H2Log; Stop-MockGraph $job

# H2-4 pasted secret always rejected: bounded retry, then InvalidSecret with the value-not-ID guidance, no send attempted
$script:FreshSecretClientId = ''; $script:InstallerToken = $null; $script:H2Log = @()
$port = Get-FreeTestPort; $job = Start-MockGraph -Port $port -TokenFailures 99 -LogPath $mockLog; $null = Wait-MockGraph -Port $port; Use-MockGraph -Port $port
$sw = [Diagnostics.Stopwatch]::StartNew(); $ok = Send-GraphMail @sendArgs; $sw.Stop()
$hits = Get-MockHits $mockLog '/token\|401'
Check "H2-4 pasted secret rejected: bounded retry then InvalidSecret, nothing sent" ($ok -eq $false -and $script:LastGraphSendError -eq 'InvalidSecret' -and $hits -ge 3 -and $hits -le 6 -and (Get-MockHits $mockLog '/sendMail') -eq 0 -and $sw.Elapsed.TotalSeconds -ge 2.5 -and $sw.Elapsed.TotalSeconds -lt 15)
Check "H2-4 pasted secret messages: retry notice, then value-not-ID guidance" ((($script:H2Log -join "`n") -match 'INFORMATIONAL\|The sign-in service rejected the client secret \(AADSTS7000215\)\. A secret created in the last few minutes can still be replicating, so this is retried every 1 s for 3 s\.') -and (($script:H2Log -join "`n") -match '(?m)^WARNING\|The sign-in service does not accept this client secret for app app-fresh in tenant tid\.$') -and (($script:H2Log -join "`n") -match 'FAILED\|Graph send failed as hst@contoso\.com\. .*AADSTS7000215'))
Show-H2Log; Stop-MockGraph $job

# H2-5 secret minted in this run but past its 20 minute window: short retry, then the past-replication message with the age
Set-FreshSecret -AgeMinutes 25
$port = Get-FreeTestPort; $job = Start-MockGraph -Port $port -TokenFailures 99 -LogPath $mockLog; $null = Wait-MockGraph -Port $port; Use-MockGraph -Port $port
$ok = Send-GraphMail @sendArgs
Check "H2-5 fresh secret past its window: one attempt, InvalidSecret, age reported, no advice about prompts" ($ok -eq $false -and $script:LastGraphSendError -eq 'InvalidSecret' -and (Get-MockHits $mockLog '/token\|401') -eq 1 -and (($script:H2Log -join "`n") -match '(?m)^WARNING\|The secret created in this run is still rejected 2[56] minutes after it was created, which is past any replication delay\.$') -and -not (($script:H2Log -join "`n") -match 'Choose R|retried'))
Show-H2Log; Stop-MockGraph $job

# H2-6 an unrelated sign-in error during the fresh window is not retried
Set-FreshSecret
$port = Get-FreeTestPort; $job = Start-MockGraph -Port $port -TokenFailures 99 -FailCode 'AADSTS90002' -FailStatus 400 -LogPath $mockLog; $null = Wait-MockGraph -Port $port; Use-MockGraph -Port $port
$sw = [Diagnostics.Stopwatch]::StartNew(); $ok = Send-GraphMail @sendArgs; $sw.Stop()
Check "H2-6 unrelated sign-in error: one attempt, class Other, no replication line" ($ok -eq $false -and $script:LastGraphSendError -eq 'Other' -and (Get-MockHits $mockLog '/token\|400') -eq 1 -and $sw.Elapsed.TotalSeconds -lt 2 -and (($script:H2Log -join "`n") -match 'FAILED\|Graph send failed as hst@contoso\.com\. .*AADSTS90002') -and -not (($script:H2Log -join "`n") -match 'replicating|retried'))
Show-H2Log; Stop-MockGraph $job

# H2-7 Graph refuses the send with ErrorAccessDenied: AccessDenied class, Exchange hint, cached token dropped
Set-FreshSecret
$port = Get-FreeTestPort; $job = Start-MockGraph -Port $port -SendStatus 403 -SendBody '{"error":{"code":"ErrorAccessDenied","message":"Access is denied. Check credentials and try again."}}' -LogPath $mockLog; $null = Wait-MockGraph -Port $port; Use-MockGraph -Port $port
$ok = Send-GraphMail @sendArgs
Check "H2-7 access denied from Graph: AccessDenied class, hint logged, token dropped" ($ok -eq $false -and $script:LastGraphSendError -eq 'AccessDenied' -and $null -eq $script:InstallerToken -and (($script:H2Log -join "`n") -match 'FAILED\|Graph send failed as hst@contoso\.com\. .*\[ErrorAccessDenied\] Access is denied') -and (($script:H2Log -join "`n") -match 'INFORMATIONAL\|Access denied right after tenant setup usually means the Exchange sending grant'))
$script:QuietAccessDeniedHint = $true; $script:H2Log = @()
$ok = Send-GraphMail @sendArgs
Check "H2-7 next send requests a fresh token, hint silenced during the quiet wait" ((Get-MockHits $mockLog '/token\|200') -eq 2 -and -not (($script:H2Log -join "`n") -match 'Access denied right after tenant setup'))
$script:QuietAccessDeniedHint = $false
Show-H2Log; Stop-MockGraph $job

# H2-8 a replica that does not know the app yet (AADSTS700016) is retried like a rejected secret
Set-FreshSecret
$port = Get-FreeTestPort; $job = Start-MockGraph -Port $port -TokenFailures 1 -FailCode 'AADSTS700016' -LogPath $mockLog; $null = Wait-MockGraph -Port $port; Use-MockGraph -Port $port
$ok = Send-GraphMail @sendArgs
Check "H2-8 app-not-found from a lagging replica is retried and the send succeeds" ($ok -eq $true -and (Get-MockHits $mockLog '/token\|401') -eq 1 -and (Get-MockHits $mockLog '/token\|200') -eq 1 -and (($script:H2Log -join "`n") -match 'has not accepted the new secret yet \(AADSTS700016\)'))
Show-H2Log; Stop-MockGraph $job

# H2-10 a transient 503 inside the fresh window is retried, then the send succeeds
Set-FreshSecret
$port = Get-FreeTestPort; $job = Start-MockGraph -Port $port -TokenFailures 1 -FailCode 'ServerError' -FailStatus 503 -LogPath $mockLog; $null = Wait-MockGraph -Port $port; Use-MockGraph -Port $port
$ok = Send-GraphMail @sendArgs
Check "H2-10 transient 503 during the fresh window is retried" ($ok -eq $true -and (Get-MockHits $mockLog '/token\|503') -eq 1 -and (Get-MockHits $mockLog '/token\|200') -eq 1 -and (($script:H2Log -join "`n") -match 'has not accepted the new secret yet \(HTTP 503\)'))
Show-H2Log; Stop-MockGraph $job

# H2-11 the same 503 for a pasted secret is not retried
$script:FreshSecretClientId = ''; $script:InstallerToken = $null; $script:H2Log = @()
$port = Get-FreeTestPort; $job = Start-MockGraph -Port $port -TokenFailures 99 -FailCode 'ServerError' -FailStatus 503 -LogPath $mockLog; $null = Wait-MockGraph -Port $port; Use-MockGraph -Port $port
$sw = [Diagnostics.Stopwatch]::StartNew(); $ok = Send-GraphMail @sendArgs; $sw.Stop()
Check "H2-11 transient error outside the fresh window: one attempt, class Other" ($ok -eq $false -and $script:LastGraphSendError -eq 'Other' -and (Get-MockHits $mockLog '/token\|503') -eq 1 -and $sw.Elapsed.TotalSeconds -lt 2)
Show-H2Log; Stop-MockGraph $job

# H2-12 MaxWaitSeconds caps the fresh window for a caller that must not block, and the waiting line appears
Set-FreshSecret
$port = Get-FreeTestPort; $job = Start-MockGraph -Port $port -TokenFailures 99 -LogPath $mockLog; $null = Wait-MockGraph -Port $port; Use-MockGraph -Port $port
$sw = [Diagnostics.Stopwatch]::StartNew(); $ok = Send-GraphMail @sendArgs -MaxWaitSeconds 4; $sw.Stop()
$hits = Get-MockHits $mockLog '/token\|401'
Check "H2-12 capped wait: gives up after about 4 s inside a 20 min window, still classed InvalidSecret" ($ok -eq $false -and $script:LastGraphSendError -eq 'InvalidSecret' -and $hits -ge 4 -and $hits -le 7 -and $sw.Elapsed.TotalSeconds -ge 3.5 -and $sw.Elapsed.TotalSeconds -lt 12)
Check "H2-12 a still-waiting line with the give-up time appears during the wait" (@($script:H2Log | Where-Object { $_ -match '^INFORMATIONAL\|Still waiting for the sign-in service to accept the secret \(AADSTS7000215\)\. Giving up at \d\d:\d\d\.$' }).Count -ge 1)
Show-H2Log; Stop-MockGraph $job

# H2-13 a tenant correction is a cache miss even with the same client and secret
Set-FreshSecret
$port = Get-FreeTestPort; $job = Start-MockGraph -Port $port -LogPath $mockLog; $null = Wait-MockGraph -Port $port; Use-MockGraph -Port $port
$null = Send-GraphMail @sendArgs                      # tid, S1: first token
$sa4 = $sendArgs.Clone(); $sa4['Secret'] = 's1'
$null = Send-GraphMail @sa4                           # same tenant and client, secret differs only by case: must miss
$sa3 = $sendArgs.Clone(); $sa3['TenantId'] = 'tid2'
$null = Send-GraphMail @sa3                           # tenant differs: must miss
$null = Send-GraphMail @sa3                           # identical: hit
Check "H2-13 secret case change and tenant change each request a new token, identical call reuses it" ((Get-MockHits $mockLog '/tid/oauth2') -eq 2 -and (Get-MockHits $mockLog '/tid2/oauth2') -eq 1 -and (Get-MockHits $mockLog '/token\|200') -eq 3 -and (Get-MockHits $mockLog '/sendMail\|202') -eq 4)
Show-H2Log; Stop-MockGraph $job

# H2-9 a listener that never answers: the token call times out and is reported, not hung
Set-FreshSecret
$deadPort = Get-FreeTestPort
Use-MockGraph -Port $deadPort
$sw = [Diagnostics.Stopwatch]::StartNew(); $ok = Send-GraphMail @sendArgs; $sw.Stop()
Check "H2-9 refused connection: class Other, no retry loop" ($ok -eq $false -and $script:LastGraphSendError -eq 'Other' -and $sw.Elapsed.TotalSeconds -lt 10)
Show-H2Log

if (Test-Path $mockLog) { Remove-Item $mockLog -Force }
${function:Write-Log} = $h2WriteLog
$script:LoginBase = 'https://login.microsoftonline.com'; $script:GraphBase = 'https://graph.microsoft.com'; $script:FreshSecretClientId = ''; $script:InstallerToken = $null

Section "I. Browser sign-in flow (listener, PKCE, state, redemption)"
foreach ($f in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false) | Where-Object { $_.Name -in @('ConvertTo-Base64Url','ConvertFrom-JwtClaims','Get-FreeTcpPort','Get-BrowserToken') }) { Invoke-Expression $f.Extent.Text }
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
# RFC 7636 test vector
$v='dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'
Check "PKCE S256 matches RFC 7636 vector" ((ConvertTo-Base64Url ([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::ASCII.GetBytes($v)))) -eq 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM')
Check "Free port is ephemeral" ((Get-FreeTcpPort) -gt 1024)
# fake JWT
function NewJwt($claims){ $h=ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes('{"alg":"none"}')); $p=ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes(($claims|ConvertTo-Json -Compress))); "$h.$p.sig" }
$jwt = NewJwt @{ tid='11111111-2222-3333-4444-555555555555'; upn='admin@contoso.com' }
Check "JWT claims decode (base64url padding)" ((ConvertFrom-JwtClaims $jwt).upn -eq 'admin@contoso.com')

# Browser simulation: Start-Process stub parses the authorize URL and calls back the redirect like a browser would
$script:AuthUrl=$null; $script:TokenBody=$null; $script:BrowserMode='ok'
function Start-Process { param($FilePath,$ArgumentList,[switch]$Wait) $script:AuthUrl=$FilePath
  $q=[System.Web.HttpUtility]::ParseQueryString(([uri]$FilePath).Query); $redir=$q['redirect_uri']; $state=$q['state']
  $cb = switch ($script:BrowserMode) { 'ok' { "$redir`?code=AUTHCODE123&state=$state" } 'badstate' { "$redir`?code=AUTHCODE123&state=wrong" } 'denied' { "$redir`?error=access_denied&error_description=User+cancelled" } }
  Start-Job -ScriptBlock { param($u,$r) Start-Sleep -Milliseconds 300; try { Invoke-WebRequest -Uri ($r + 'favicon.ico') -UseBasicParsing -TimeoutSec 5 | Out-Null } catch { }; try { (Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 10).Content } catch { "ERR $_" } } -ArgumentList $cb,$redir | Out-Null }
function Invoke-RestMethod { param($Method,$Uri,$Body,$ContentType,$Headers,$ErrorAction) $script:TokenBody=$Body; [PSCustomObject]@{ access_token=$jwt; refresh_token='RT'; expires_in=3600 } }
function Write-Log { param($Level,$Message) $script:LastLog="$Level|$Message" }
$cid='04b07795-8ddb-461a-bbee-02f9e1bf7b46'; $scope='https://graph.microsoft.com/.default offline_access'
$r = Get-BrowserToken -ClientId $cid -Scope $scope
Get-Job | Wait-Job -Timeout 5 | Out-Null; Get-Job | Remove-Job -Force
Check "Browser flow: token returned with tenant and upn" ($r -and $r.TenantId -eq '11111111-2222-3333-4444-555555555555' -and $r.Upn -eq 'admin@contoso.com' -and $r.RefreshToken -eq 'RT')
$aq=[System.Web.HttpUtility]::ParseQueryString(([uri]$script:AuthUrl).Query)
Check "Authorize URL: PKCE S256, select_account, localhost redirect, scope, state" ($aq['code_challenge_method'] -eq 'S256' -and $aq['prompt'] -eq 'select_account' -and $aq['redirect_uri'] -like 'http://localhost:*/' -and $aq['scope'] -eq $scope -and $aq['client_id'] -eq $cid -and $aq['response_type'] -eq 'code')
Check "Token request: authorization_code with verifier and matching redirect" ($script:TokenBody.grant_type -eq 'authorization_code' -and $script:TokenBody.code -eq 'AUTHCODE123' -and $script:TokenBody.code_verifier -and $script:TokenBody.redirect_uri -eq $aq['redirect_uri'])
Check "Verifier matches challenge" ((ConvertTo-Base64Url ([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::ASCII.GetBytes($script:TokenBody.code_verifier)))) -eq $aq['code_challenge'])
$script:BrowserMode='badstate'; $r = Get-BrowserToken -ClientId $cid -Scope $scope; Get-Job | Wait-Job -Timeout 5 | Out-Null; Get-Job | Remove-Job -Force
Check "Browser flow: state mismatch rejected" ($null -eq $r -and $script:LastLog -match 'did not match')
$script:BrowserMode='denied'; $r = Get-BrowserToken -ClientId $cid -Scope $scope; Get-Job | Wait-Job -Timeout 5 | Out-Null; Get-Job | Remove-Job -Force
Check "Browser flow: user cancel surfaces error and returns null" ($null -eq $r -and $script:LastLog -match 'access_denied')
Check "Stray favicon request ignored, real redirect still accepted" ($src -match "Not the redirect \(favicon or pre-connect probe\)" -and $src -match 'StatusCode = 204')
Check "Listener bind retried" ($src -match '\$bindTry -lt 5')
Check "No System.Web dependency" (-not ($src -match 'System\.Web'))
Check "Role assignment retried on fresh SP" ($src -match 'for \(\$i = 0; \$i -lt 6 -and -not \$granted')
Check "Fresh secret window opened at minting, token obtained before the test email" ($src -match '\$script:FreshSecretUntilUtc = \$script:FreshSecretCreatedUtc\.AddMinutes\(20\)' -and $src -match 'Get-InstallerGraphToken -TenantId \$tenantId -ClientId \$app\.appId -Secret \$secret' -and -not ($src -match 'Wait-GraphAppReady'))
Check "Listener released after each attempt (new listener binds)" ((Get-FreeTcpPort) -gt 0)
Check "Fallback order: window/browser then device code" ($src -match 'Get-BrowserToken -ClientId \$clientId -Scope \$scope -Title' -and $src -match 'Falling back to a device code\."; \$auth = Get-DeviceCodeToken')
$script:BrowserMode='ok'; $r = Get-BrowserToken -ClientId $cid -Scope $scope -Prompt ''; Get-Job | Wait-Job -Timeout 5 | Out-Null; Get-Job | Remove-Job -Force
$aq2=[System.Web.HttpUtility]::ParseQueryString(([uri]$script:AuthUrl).Query)
Check "Silent second sign-in omits prompt parameter" ($r -and $null -eq $aq2['prompt'])
Check "Normal path never mentions a device code" (-not ($src.Substring($src.IndexOf('function Get-BrowserToken'), $src.IndexOf('function Get-DeviceCodeToken') - $src.IndexOf('function Get-BrowserToken')) -match 'user_code'))


Section "J. Exchange REST transport"
foreach ($f in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false) | Where-Object { $_.Name -in @('Invoke-ExoCommand','Invoke-ExoCmdlet') }) { Invoke-Expression $f.Extent.Text }
$script:RestCalls=@()
function Invoke-RestMethod { param($Method,$Uri,$Headers,$Body,$ContentType,$ErrorAction) $script:RestCalls += [PSCustomObject]@{ Method=$Method; Uri=$Uri; Headers=$Headers; Body=($Body|ConvertFrom-Json) }
  if ($Body -match 'Get-Mailbox' -and $Body -match 'missing@') { throw "not found" }
  [PSCustomObject]@{ value = @([PSCustomObject]@{ PrimarySmtpAddress='hst@contoso.com'; AccessCheckResult='Granted' }) } }
$r = Invoke-ExoCommand -Token 'T' -TenantId 'tid' -Upn 'admin@contoso.com' -Cmdlet 'New-Mailbox' -Parameters @{ Shared=$true; Name='hst'; PrimarySmtpAddress='hst@contoso.com' }
$c = $script:RestCalls[-1]
Check "REST: endpoint and method" ($c.Method -eq 'Post' -and $c.Uri -eq 'https://outlook.office365.com/adminapi/beta/tid/InvokeCommand')
Check "REST: bearer + anchor mailbox headers" ($c.Headers.Authorization -eq 'Bearer T' -and $c.Headers['X-AnchorMailbox'] -eq 'UPN:admin@contoso.com')
Check "REST: CmdletInput payload carries cmdlet and params" ($c.Body.CmdletInput.CmdletName -eq 'New-Mailbox' -and $c.Body.CmdletInput.Parameters.Shared -eq $true -and $c.Body.CmdletInput.Parameters.PrimarySmtpAddress -eq 'hst@contoso.com')
Check "REST: returns value array" (@($r).Count -eq 1 -and $r[0].PrimarySmtpAddress -eq 'hst@contoso.com')
$script:ExoMode='rest'; $script:ExoToken='T'; $script:ExoTenantId='tid'; $script:ExoUpn='admin@contoso.com'
Check "Dispatch rest: NullOnNotFound swallows error" ($null -eq (Invoke-ExoCmdlet -Name 'Get-Mailbox' -Parameters @{ Identity='missing@contoso.com' } -NullOnNotFound))
$threw=$false; try { Invoke-ExoCmdlet -Name 'Get-Mailbox' -Parameters @{ Identity='missing@contoso.com' } | Out-Null } catch { $threw=$true }
Check "Dispatch rest: errors propagate without the switch" $threw
function Get-Mailbox { param($Identity,$ErrorAction) if ($Identity -like 'missing*') { throw "not found" }; [PSCustomObject]@{ PrimarySmtpAddress=$Identity; Via='module' } }
$script:ExoMode='module'
Check "Dispatch module: calls local cmdlet with splat" (((Invoke-ExoCmdlet -Name 'Get-Mailbox' -Parameters @{ Identity='x@contoso.com' })[0]).Via -eq 'module')
Check "Dispatch module: not-found swallowed" ($null -eq (Invoke-ExoCmdlet -Name 'Get-Mailbox' -Parameters @{ Identity='missing@contoso.com' } -NullOnNotFound))

Write-Host ""
Write-Host "TOTAL: $script:pass passed, $script:fail failed"
if ($script:fail){ Write-Host "Failed: $($script:failed -join '; ')"; exit 1 }
