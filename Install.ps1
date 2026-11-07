# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 BeyondWillJ
# Run from an elevated Windows PowerShell 5.1 window.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_.-]+$')][string]$UserName,
    [Parameter(Mandatory)][string[]]$PublicKeyPath,
    [Parameter(Mandatory)][string[]]$AllowedClientAddress,
    [string]$ListenAddress,
    [ValidateRange(1024,65535)][int]$Port = 2223,
    [string]$DesktopPath = [Environment]::GetFolderPath('Desktop'),
    [switch]$InstallOpenSsh,
    [switch]$PlanOnly
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'src\Common.ps1')
$root = Join-Path $env:ProgramData 'SSH-listener'
$ruleName = 'SSH-listener-Tailscale'
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (!$PlanOnly -and !$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open Windows PowerShell as administrator and rerun this command.'
}
if (!(Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)) { throw 'UserName must be an existing local Windows account.' }
if (!(Get-Service Tailscale -ErrorAction SilentlyContinue)) { throw 'Install Tailscale and sign in before installing SSH-listener.' }
if (!$ListenAddress) {
    $ts = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (!(Test-Path -LiteralPath $ts)) { $ts = (Get-Command tailscale.exe -ErrorAction Stop).Source }
    $ListenAddress = ((& $ts ip -4) | Select-Object -First 1).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read Tailscale IPv4. Sign in to Tailscale first.' }
}
foreach ($address in @($ListenAddress) + $AllowedClientAddress) {
    if (!(Test-TailnetIPv4 $address)) { throw "Expected an individual Tailscale IPv4 address, got: $address" }
}
if (!(Get-NetIPAddress -IPAddress $ListenAddress -ErrorAction SilentlyContinue)) { throw 'ListenAddress is not assigned to this computer.' }
if (!(Test-Path -LiteralPath $DesktopPath -PathType Container)) { throw 'DesktopPath does not exist.' }
if (Test-Path -LiteralPath $root) { throw "An installation already exists at $root. Back it up and uninstall before reinstalling." }
$shortcut = Join-Path $DesktopPath 'Start SSH.lnk'
if (Test-Path -LiteralPath $shortcut) { throw 'Start SSH.lnk already exists on the selected desktop.' }
if (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) { throw 'An SSH-listener firewall rule already exists.' }
$keys = @()
foreach ($path in $PublicKeyPath) {
    $text = (Get-Content -LiteralPath $path -Raw).Trim()
    if ($text -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+=*( [^\r\n]*)?$') {
        throw 'Each PublicKeyPath must contain one OpenSSH public key, not a private key or authorized_keys options.'
    }
    $keys += $text
}
if ($keys.Count -eq 0) { throw 'At least one public key is required.' }
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { throw 'Selected port is already in use.' }
$plan = [ordered]@{ InstallDirectory=$root; UserName=$UserName; ListenAddress=$ListenAddress; Port=$Port;
    AllowedClientAddress=$AllowedClientAddress; PublicKeys=$keys.Count; DesktopShortcut=$shortcut;
    SystemSshdService='Unchanged'; InstallOpenSsh=[bool]$InstallOpenSsh }
if ($PlanOnly) { $plan | ConvertTo-Json; return }
$exe = Join-Path $env:WINDIR 'System32\OpenSSH\sshd.exe'
if (!(Test-Path -LiteralPath $exe)) {
    if (!$InstallOpenSsh) { throw 'OpenSSH Server is missing. Rerun with -InstallOpenSsh to install the Windows optional capability.' }
    $cap = Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
    if ($cap.RestartNeeded) { throw 'Windows requires a restart. Restart and rerun installation.' }
}
if (!(Test-Path -LiteralPath $exe)) { throw 'OpenSSH Server installation did not provide sshd.exe.' }
$keygen = Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe'
foreach ($path in $PublicKeyPath) {
    & $keygen -lf (Resolve-Path -LiteralPath $path).Path | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'ssh-keygen rejected a supplied public key.' }
}
$created = $false
$firewallCreated = $false
$shortcutCreated = $false
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $created = $true
    Set-ListenerAcl $root -UsersRead
    foreach ($name in @('Start-SSHListener.ps1','SshWindowLifetime.cs','Common.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "src\$name") -Destination $root
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Uninstall.ps1') -Destination $root
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'LICENSE') -Destination $root
    # Empty passphrase: host keys are used unattended by sshd and protected by ACLs.
    $keyDirectory = Join-Path $root 'keys'
    New-Item -ItemType Directory -Path $keyDirectory | Out-Null
    Set-ListenerAcl $keyDirectory
    $hostKey = Join-Path $keyDirectory 'ssh_host_ed25519_key'
    & $keygen -q -t ed25519 -f $hostKey -N '""'
    if ($LASTEXITCODE -ne 0) { throw 'Host key generation failed.' }
    Set-ListenerAcl $hostKey
    ($keys -join "`n") + "`n" | Set-Content -LiteralPath (Join-Path $root 'authorized_keys') -Encoding ascii
    Set-ListenerAcl (Join-Path $root 'authorized_keys')
    $configText = New-ListenerConfig $root $UserName $ListenAddress $Port $AllowedClientAddress
    [IO.File]::WriteAllText((Join-Path $root 'sshd_config'), $configText, (New-Object Text.UTF8Encoding($false)))
    # The marker identifies data owned by this application during uninstall.
    $settings = @{ Product='SSH-listener'; Version=1; UserName=$UserName; ListenAddress=$ListenAddress;
        Port=$Port; AllowedClientAddress=$AllowedClientAddress; DesktopShortcut=$shortcut }
    $settings | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'settings.json') -Encoding utf8
    & $exe -t -f (Join-Path $root 'sshd_config')
    if ($LASTEXITCODE -ne 0) { throw 'Generated OpenSSH configuration failed validation.' }
    # Also compile and validate the job object before exposing the listener port.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Start-SSHListener.ps1') -ValidateOnly
    if ($LASTEXITCODE -ne 0) { throw 'Launcher validation failed.' }
    New-NetFirewallRule -Name $ruleName -DisplayName 'SSH-listener: allowed Tailscale clients' -Direction Inbound -Action Allow -Enabled True -Profile Any -Protocol TCP -LocalPort $Port -LocalAddress $ListenAddress -RemoteAddress $AllowedClientAddress -Program $exe | Out-Null
    $firewallCreated = $true
    $link = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
    $link.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $link.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'Start-SSHListener.ps1') + '"'
    $link.WorkingDirectory = $root
    $link.IconLocation = (Join-Path $env:WINDIR 'System32\shell32.dll') + ',17'
    $link.WindowStyle = 1
    $link.Description = 'Open SSH over Tailscale; close the window to stop.'
    $link.Save()
    $shortcutCreated = $true
    Write-Host "Installed. Double-click $shortcut and accept UAC to start listening." -ForegroundColor Green
    Write-Host 'Verify this host-key fingerprint on the client before accepting the first connection:'
    & $keygen -lf ($hostKey + '.pub')
    Write-Host "Connect: ssh -p $Port -i <client-private-key> $UserName@$ListenAddress"
    Write-Host 'The existing Windows sshd service and its configuration were left unchanged.'
} catch {
    if ($shortcutCreated) { Remove-Item -LiteralPath $shortcut -Force }
    if ($firewallCreated) { Remove-NetFirewallRule -Name $ruleName }
    # The path is fixed and created by this invocation, never supplied by the caller.
    if ($created -and [IO.Path]::GetFullPath($root) -eq [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'SSH-listener'))) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
    throw
}
