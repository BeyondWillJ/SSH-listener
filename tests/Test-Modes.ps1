# SPDX-License-Identifier: GPL-3.0-only
# End-to-end test of explicit and background modes using the installed scripts.
# It creates %ProgramData%\SSH-listener, a Windows service and loopback-only
# listeners, then removes them with Uninstall.ps1. Intended for disposable CI
# machines; requires administrator rights and Windows OpenSSH Server.
[CmdletBinding()]
param([switch]$AllowSystemChanges, [ValidateRange(1024,65535)][int]$Port = 32224)
$ErrorActionPreference = 'Stop'
if (!$AllowSystemChanges) { throw 'This test installs a service under %ProgramData%. Rerun with -AllowSystemChanges on a disposable machine.' }
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'src\Common.ps1')
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run as administrator.' }
$sshd = Get-ListenerSshdPath
if (!(Test-Path -LiteralPath $sshd)) { throw 'Install Windows OpenSSH Server first.' }
$root = [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'SSH-listener'))
if (Test-Path -LiteralPath $root) { throw "$root already exists; refusing to touch a real installation." }
if (Get-Service -Name $ListenerServiceName -ErrorAction SilentlyContinue) { throw "Service $ListenerServiceName already exists." }
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { throw 'Test port is already in use.' }
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$work = Join-Path ([IO.Path]::GetTempPath()) ('ssh-listener-modes-' + [Guid]::NewGuid().ToString('N'))
$desktop = Join-Path $work 'Desktop'
$count = 0
$createdRoot = $false
$launcher = $null

function Assert-True([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw "FAIL $Message" }
    $script:count++
    Write-Host "PASS $Message"
}
function Invoke-Installed([string]$Script, [string[]]$Arguments) {
    & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root $Script) @Arguments | Out-Host
    return $LASTEXITCODE
}
function Test-Listening { return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) }
function Wait-Until([scriptblock]$Condition, [int]$Seconds = 15) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while (!(& $Condition)) { if ((Get-Date) -ge $deadline) { return $false }; Start-Sleep -Milliseconds 250 }
    return $true
}
function Test-Login {
    $out = Join-Path $work 'client-out.txt'
    $err = Join-Path $work 'client-err.txt'
    $arguments = "-p $Port -i `"$clientKey`" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new " +
        "-o `"UserKnownHostsFile=$(Join-Path $work 'known_hosts')`" -o ConnectTimeout=5 $($env:USERNAME)@127.0.0.1 `"echo SSH_LISTENER_AUTH_OK`""
    $client = Start-Process (Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe') -WindowStyle Hidden -ArgumentList $arguments -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
    try {
        $null = $client.Handle
        if (!$client.WaitForExit(20000)) { $client.Kill(); return $false }
        $ok = $client.ExitCode -eq 0 -and (Get-Content -LiteralPath $out -Raw) -match 'SSH_LISTENER_AUTH_OK'
        if (!$ok) { Write-Host ('ssh stderr: ' + (Get-Content -LiteralPath $err -Raw)) }
        return $ok
    } finally { $client.Dispose() }
}
function Get-Settings { return (Get-Content -LiteralPath (Join-Path $root 'settings.json') -Raw | ConvertFrom-Json) }
function Test-Link([string]$Name) { return (Test-ListenerShortcutOwned (Join-Path $desktop $Name) $root) }

try {
    New-Item -ItemType Directory -Path $desktop -Force | Out-Null
    # Reproduce what Install.ps1 lays down, minus the Tailscale-only validation and firewall rule.
    New-Item -ItemType Directory -Path $root | Out-Null
    $createdRoot = $true
    Set-ListenerAcl $root -UsersRead
    foreach ($name in @('Start-SSHListener.ps1','Manage-SSHListener.ps1','Set-SSHListenerMode.ps1','SshWindowLifetime.cs','Common.ps1')) {
        Copy-Item -LiteralPath (Join-Path $repo "src\$name") -Destination $root
    }
    Copy-Item -LiteralPath (Join-Path $repo 'Uninstall.ps1') -Destination $root
    $keyDir = Join-Path $root 'keys'
    New-Item -ItemType Directory -Path $keyDir | Out-Null
    Set-ListenerAcl $keyDir
    $keygen = Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe'
    & $keygen -q -t ed25519 -f (Join-Path $keyDir 'ssh_host_ed25519_key') -N '""'
    if ($LASTEXITCODE -ne 0) { throw 'Host key generation failed.' }
    Set-ListenerAcl (Join-Path $keyDir 'ssh_host_ed25519_key')
    $clientKey = Join-Path $keyDir 'test_client_key'
    & $keygen -q -t ed25519 -f $clientKey -N '""'
    if ($LASTEXITCODE -ne 0) { throw 'Client key generation failed.' }
    Set-ListenerAcl $clientKey
    Copy-Item -LiteralPath ($clientKey + '.pub') -Destination (Join-Path $root 'authorized_keys')
    Set-ListenerAcl (Join-Path $root 'authorized_keys')
    # Loopback is intentional for this isolated test; the installer only accepts tailnet IPv4s.
    $text = New-ListenerConfig $root $env:USERNAME '127.0.0.1' $Port @('127.0.0.1')
    [IO.File]::WriteAllText((Join-Path $root 'sshd_config'), $text, (New-Object Text.UTF8Encoding($false)))
    Save-ListenerSettings $root ([pscustomobject]@{ UserName=$env:USERNAME; ListenAddress='127.0.0.1'; Port=$Port
        AllowedClientAddress=@('127.0.0.1'); DesktopPath=$desktop; DesktopShortcut=$null; Mode='Explicit'; AutoStart=$false })
    $settings = Get-Settings
    Set-ListenerMode $root $settings 'Explicit' $false $false
    Assert-True (Test-Link $ListenerShortcutNames.Explicit) 'Explicit install creates Start SSH.lnk'
    Assert-True ((Invoke-Installed 'Start-SSHListener.ps1' @('-ValidateOnly')) -eq 0) 'Explicit launcher validates installation'

    # --- Explicit -> Background (Manual) ---
    Assert-True ((Invoke-Installed 'Set-SSHListenerMode.ps1' @('-Mode','Background')) -eq 0) 'Switch to background mode'
    $service = Get-ListenerService
    Assert-True ($null -ne $service) 'Background service registered'
    Assert-True ($service.PathName -eq (Get-ListenerServiceCommand (Join-Path $root 'sshd_config'))) 'Service runs the private sshd configuration'
    Assert-True ($service.StartName -eq 'LocalSystem') 'Service runs as LocalSystem'
    Assert-True ((Get-Service $ListenerServiceName).StartType -eq 'Manual') 'No autostart unless requested'
    Assert-True (Wait-Until { (Get-Service $ListenerServiceName).Status -eq 'Running' -and (Test-Listening) }) 'Service running and listening'
    Assert-True ((& sc.exe qfailure $ListenerServiceName | Out-String) -match 'RESTART') 'Service restarts on failure'
    Assert-True ((Test-Link $ListenerShortcutNames.Background) -and !(Test-Path -LiteralPath (Join-Path $desktop $ListenerShortcutNames.Explicit))) 'Shortcut swapped to SSH Listener.lnk'
    Assert-True ((Get-Settings).Mode -eq 'Background' -and !(Get-Settings).AutoStart) 'Settings record background mode, autostart off'
    Assert-True (Test-Login) 'Public-key login through background service'

    # --- The explicit launcher refuses while in background mode ---
    $empty = Join-Path $work 'empty.txt'; '' | Set-Content -LiteralPath $empty
    $refused = Start-Process $powershell -WindowStyle Hidden -RedirectStandardInput $empty -PassThru -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'Start-SSHListener.ps1') + '"')
    $null = $refused.Handle
    Assert-True ($refused.WaitForExit(60000) -and $refused.ExitCode -ne 0) 'Explicit launcher refuses in background mode'
    $refused.Dispose()

    # --- Control panel actions ---
    Assert-True ((Invoke-Installed 'Manage-SSHListener.ps1' @('-Action','EnableAutoStart')) -eq 0 -and (Get-Service $ListenerServiceName).StartType -eq 'Automatic' -and (Get-Settings).AutoStart) 'Enable autostart'
    Assert-True ((Invoke-Installed 'Manage-SSHListener.ps1' @('-Action','DisableAutoStart')) -eq 0 -and (Get-Service $ListenerServiceName).StartType -eq 'Manual' -and !(Get-Settings).AutoStart) 'Disable autostart'
    Assert-True ((Invoke-Installed 'Manage-SSHListener.ps1' @('-Action','Stop')) -eq 0 -and (Wait-Until { !(Test-Listening) })) 'Stop closes the port'
    Assert-True ((Invoke-Installed 'Manage-SSHListener.ps1' @('-Action','Start')) -eq 0 -and (Wait-Until { Test-Listening })) 'Start reopens the port'
    Assert-True ((Invoke-Installed 'Manage-SSHListener.ps1' @('-Action','Status')) -eq 0) 'Status action'
    Assert-True ((Invoke-Installed 'Set-SSHListenerMode.ps1' @('-Mode','Background','-AutoStart','-NoStart')) -eq 0 -and (Get-Service $ListenerServiceName).StartType -eq 'Automatic') 'Re-applying background mode updates autostart in place'

    # --- Background -> Explicit ---
    Assert-True ((Invoke-Installed 'Set-SSHListenerMode.ps1' @('-Mode','Explicit')) -eq 0) 'Switch to explicit mode'
    Assert-True (!(Get-ListenerService)) 'Background service removed'
    Assert-True (Wait-Until { !(Test-Listening) }) 'Port closed after leaving background mode'
    Assert-True ((Test-Link $ListenerShortcutNames.Explicit) -and !(Test-Path -LiteralPath (Join-Path $desktop $ListenerShortcutNames.Background))) 'Shortcut swapped back to Start SSH.lnk'
    Assert-True ((Get-Settings).Mode -eq 'Explicit') 'Settings record explicit mode'
    Assert-True ((Invoke-Installed 'Manage-SSHListener.ps1' @('-Action','Start')) -ne 0) 'Control panel refuses actions in explicit mode'

    # --- Explicit mode still behaves as before: window-bound lifetime ---
    $launcher = Start-Process $powershell -WindowStyle Hidden -PassThru -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'Start-SSHListener.ps1') + '"')
    Assert-True (Wait-Until { Test-Listening } 30) 'Explicit window listens'
    Assert-True (Test-Login) 'Public-key login through explicit window'
    Assert-True ((Invoke-Installed 'Set-SSHListenerMode.ps1' @('-Mode','Background')) -ne 0 -and !(Get-ListenerService)) 'Mode switch refused while the explicit window is open'
    $launcher.Kill()
    Assert-True (Wait-Until { !(Test-Listening) } 10) 'Killing the explicit window stops sshd'
    $launcher.Dispose(); $launcher = $null

    # --- Background with autostart, then uninstall ---
    Assert-True ((Invoke-Installed 'Set-SSHListenerMode.ps1' @('-Mode','Background','-AutoStart')) -eq 0 -and (Get-Service $ListenerServiceName).StartType -eq 'Automatic') 'Background mode with autostart'
    Assert-True ((Wait-Until { Test-Listening }) -and (Test-Login)) 'Login after switching back to background'
    # -File would pass '$false' as a string; -Command keeps it a real switch value.
    & $powershell -NoProfile -ExecutionPolicy Bypass -Command ("& '" + (Join-Path $root 'Uninstall.ps1') + "' -Confirm:`$false; exit `$LASTEXITCODE") | Out-Host
    Assert-True ($LASTEXITCODE -eq 0) 'Uninstall succeeds'
    Assert-True (!(Get-ListenerService) -and !(Test-Path -LiteralPath $root)) 'Uninstall removes service and application directory'
    Assert-True (!(Test-Path -LiteralPath (Join-Path $desktop $ListenerShortcutNames.Background)) -and !(Test-Path -LiteralPath (Join-Path $desktop $ListenerShortcutNames.Explicit))) 'Uninstall removes shortcuts'
    Assert-True (Wait-Until { !(Test-Listening) }) 'Port closed after uninstall'
    Write-Host "$count mode checks passed."
} finally {
    if ($launcher) { if (!$launcher.HasExited) { $launcher.Kill() }; $launcher.Dispose() }
    $service = Get-ListenerService
    if ($service -and $service.PathName -eq (Get-ListenerServiceCommand (Join-Path $root 'sshd_config'))) {
        Stop-Service -Name $ListenerServiceName -Force -ErrorAction SilentlyContinue
        & sc.exe delete $ListenerServiceName | Out-Null
    }
    if ($createdRoot -and (Test-Path -LiteralPath $root)) { Remove-Item -LiteralPath $root -Recurse -Force }
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\ssh-listener-modes-'
    if ([IO.Path]::GetFullPath($work).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $work)) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
