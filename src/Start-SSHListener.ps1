# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 BeyondWillJ
# Explicit mode: listens only while this window stays open.
[CmdletBinding()]
param([switch]$ValidateOnly)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    if ($ValidateOnly) { $arguments += ' -ValidateOnly' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments
    exit
}
$lifetime = $null
$child = $null
$mutex = $null
try {
    . (Join-Path $PSScriptRoot 'Common.ps1')
    $settings = Read-ListenerSettings $PSScriptRoot
    $exe = Get-ListenerSshdPath
    $config = Join-Path $PSScriptRoot 'sshd_config'
    Add-Type -Path (Join-Path $PSScriptRoot 'SshWindowLifetime.cs')
    & $exe -t -f $config
    if ($LASTEXITCODE -ne 0) { throw 'OpenSSH configuration validation failed.' }
    if ($ValidateOnly) {
        $lifetime = New-Object SshListener.WindowLifetime
        Write-Output 'Configuration and Windows job object validated; no listener started.'
        return
    }
    if ($settings.Mode -ne 'Explicit') {
        throw ('SSH-listener is in background mode. Use the "SSH Listener" desktop shortcut, or switch back with: ' +
            (Join-Path $PSScriptRoot 'Set-SSHListenerMode.ps1') + ' -Mode Explicit')
    }
    $mutex = Enter-ListenerLock
    $host.UI.RawUI.WindowTitle = "SSH $($settings.ListenAddress):$($settings.Port) - CLOSE WINDOW TO STOP"
    $ts = Get-Service Tailscale -ErrorAction SilentlyContinue
    if ($ts -and $ts.Status -ne 'Running') { Start-Service Tailscale }
    $deadline = (Get-Date).AddSeconds(30)
    while (!(Get-NetIPAddress -IPAddress $settings.ListenAddress -ErrorAction SilentlyContinue)) {
        if ((Get-Date) -ge $deadline) { throw 'Configured Tailscale IP is unavailable. Sign in to Tailscale or reinstall with the current address.' }
        Start-Sleep -Seconds 1
    }
    if (Get-NetTCPConnection -LocalPort $settings.Port -State Listen -ErrorAction SilentlyContinue) {
        throw 'The configured port is already in use. Stop the other listener or choose a different port.'
    }
    Write-Host "SSH: $($settings.UserName)@$($settings.ListenAddress):$($settings.Port)" -ForegroundColor Green
    Write-Host 'Keep this window open. Closing it stops this listener and its SSH process tree.' -ForegroundColor Yellow
    Write-Host ('Allowed client IPs: ' + (@($settings.AllowedClientAddress) -join ', '))
    Write-Host 'Press Ctrl+C to stop. Live SSH logs follow.'
    # The system sshd service and other independently launched SSH servers are not started or stopped here.
    $lifetime = New-Object SshListener.WindowLifetime
    $child = $lifetime.Start($exe, ('-D -e -f "' + $config + '"'))
    while (!$child.WaitForExit(300)) { }
    if ($child.ExitCode -ne 0) { throw "OpenSSH exited with code $($child.ExitCode)." }
} catch {
    Write-Host ('SSH ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    if (!$ValidateOnly -and [Environment]::UserInteractive -and ![Console]::IsInputRedirected) { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
} finally {
    if ($lifetime) { $lifetime.Dispose() }
    if ($child) { $child.Dispose() }
    if ($mutex) { Exit-ListenerLock $mutex }
}
