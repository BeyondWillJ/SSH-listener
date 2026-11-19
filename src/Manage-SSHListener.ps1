# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 BeyondWillJ
# Background mode control panel. Without -Action it shows an interactive menu.
[CmdletBinding()]
param([ValidateSet('Status','Start','Stop','EnableAutoStart','DisableAutoStart')][string]$Action)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($Action) { throw 'Run Windows PowerShell as administrator.' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"')
    exit
}
. (Join-Path $PSScriptRoot 'Common.ps1')

function Show-ListenerStatus($Settings) {
    $service = Get-Service -Name $ListenerServiceName -ErrorAction SilentlyContinue
    $listening = [bool](Get-NetTCPConnection -LocalAddress $Settings.ListenAddress -LocalPort $Settings.Port -State Listen -ErrorAction SilentlyContinue)
    Write-Host ''
    Write-Host 'SSH-listener - background mode' -ForegroundColor Cyan
    if ($service) {
        $color = 'Yellow'
        if ($service.Status -eq 'Running') { $color = 'Green' }
        Write-Host ('  Service    : ' + $service.Status) -ForegroundColor $color
        Write-Host ('  Autostart  : ' + $(if ($service.StartType -eq 'Automatic') { 'On (starts at boot)' } else { 'Off (manual start)' }))
    } else { Write-Host '  Service    : not registered (run Set-SSHListenerMode.ps1 -Mode Background)' -ForegroundColor Red }
    Write-Host ('  Listening  : ' + $(if ($listening) { 'yes' } else { 'no' }))
    Write-Host "  Address    : $($Settings.UserName)@$($Settings.ListenAddress):$($Settings.Port)"
    Write-Host ('  Clients    : ' + (@($Settings.AllowedClientAddress) -join ', '))
    Write-Host '  Logs       : Event Viewer > Applications and Services Logs > OpenSSH > Operational'
}

function Invoke-ListenerAction([string]$Name, $Settings) {
    switch ($Name) {
        'Status' { Show-ListenerStatus $Settings }
        'Start' {
            Start-Service -Name $ListenerServiceName
            Write-Host 'Started.' -ForegroundColor Green
        }
        'Stop' {
            Stop-Service -Name $ListenerServiceName -Force
            Write-Host 'Stopped. Sessions already open may continue until they disconnect.' -ForegroundColor Yellow
        }
        'EnableAutoStart' { Set-ListenerAutoStart $PSScriptRoot $Settings $true; Write-Host 'Autostart on.' -ForegroundColor Green }
        'DisableAutoStart' { Set-ListenerAutoStart $PSScriptRoot $Settings $false; Write-Host 'Autostart off.' -ForegroundColor Yellow }
    }
}

$settings = Read-ListenerSettings $PSScriptRoot
if ($Action) {
    if ($settings.Mode -ne 'Background' -and $Action -ne 'Status') { throw 'SSH-listener is in explicit mode.' }
    Invoke-ListenerAction $Action $settings
    return
}
try {
    $host.UI.RawUI.WindowTitle = 'SSH-listener (background)'
    if ($settings.Mode -ne 'Background') {
        throw 'SSH-listener is in explicit mode. Use the "Start SSH" desktop shortcut instead.'
    }
    while ($true) {
        Show-ListenerStatus $settings
        Write-Host ''
        Write-Host '  [1] Start   [2] Stop   [3] Toggle autostart   [4] Switch to explicit mode   [R] Refresh   [Q] Quit'
        $choice = (Read-Host '  Choose').Trim().ToUpperInvariant()
        try {
            switch ($choice) {
                '1' { Invoke-ListenerAction 'Start' $settings }
                '2' { Invoke-ListenerAction 'Stop' $settings }
                '3' {
                    if ((Get-Service -Name $ListenerServiceName).StartType -eq 'Automatic') { Invoke-ListenerAction 'DisableAutoStart' $settings }
                    else { Invoke-ListenerAction 'EnableAutoStart' $settings }
                }
                '4' {
                    if ((Read-Host '  Stop and remove the background service, then use the "Start SSH" window? (y/N)') -notmatch '^[yY]') { break }
                    $mutex = Enter-ListenerLock
                    try { Set-ListenerMode $PSScriptRoot $settings 'Explicit' $false $false } finally { Exit-ListenerLock $mutex }
                    Write-Host "Explicit mode. Double-click $($settings.DesktopShortcut) to listen while its window is open." -ForegroundColor Green
                    Read-Host 'Press Enter to close' | Out-Null
                    return
                }
                'Q' { return }
                default { }
            }
        } catch { Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red }
    }
} catch {
    Write-Host ('SSH ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    Read-Host 'Press Enter to close' | Out-Null
    exit 1
}
