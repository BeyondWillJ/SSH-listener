# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 BeyondWillJ
# Switch an installed SSH-listener between explicit and background mode.
# The host key, configuration, authorized keys and firewall rule are kept.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Explicit','Background')][string]$Mode,
    [switch]$AutoStart,
    [switch]$NoStart
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run Windows PowerShell as administrator.'
}
. (Join-Path $PSScriptRoot 'Common.ps1')
if ($Mode -eq 'Explicit' -and ($AutoStart -or $NoStart)) { throw '-AutoStart and -NoStart apply only to -Mode Background.' }
$settings = Read-ListenerSettings $PSScriptRoot
$mutex = Enter-ListenerLock
try {
    Set-ListenerMode $PSScriptRoot $settings $Mode ([bool]$AutoStart) (!$NoStart)
} finally { Exit-ListenerLock $mutex }
if ($Mode -eq 'Background') {
    $status = (Get-Service -Name $ListenerServiceName).Status
    Write-Host "Background mode. Service $ListenerServiceName is $status; autostart at boot: $([bool]$AutoStart)." -ForegroundColor Green
    Write-Host "Manage it with the desktop shortcut: $($settings.DesktopShortcut)"
} else {
    Write-Host "Explicit mode. Background service removed; double-click $($settings.DesktopShortcut) to listen while its window is open." -ForegroundColor Green
}
