# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param()
$ErrorActionPreference = 'Stop'
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run Windows PowerShell as administrator.' }
$root = [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'SSH-listener'))
. (Join-Path $root 'Common.ps1')
$settings = Read-ListenerSettings $root
$mutex = Enter-ListenerLock
try {
    if ($PSCmdlet.ShouldProcess($root, 'Remove SSH-listener, its background service, firewall rule, shortcuts, configuration and dedicated host key')) {
        Unregister-ListenerService (Join-Path $root 'sshd_config')
        Remove-NetFirewallRule -Name 'SSH-listener-Tailscale' -ErrorAction SilentlyContinue
        foreach ($name in $ListenerShortcutNames.Values) { Remove-ListenerShortcut (Join-Path $settings.DesktopPath $name) $root }
        # Fixed application directory, checked above; no user-controlled deletion target.
        if ($root -ne [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'SSH-listener'))) { throw 'Invalid removal path.' }
        # Leave the directory before deleting it; the dot-sourced helpers are already loaded.
        Set-Location -LiteralPath $env:SystemRoot
        Remove-Item -LiteralPath $root -Recurse -Force
        Write-Host 'SSH-listener removed. OpenSSH, Tailscale, and the system sshd service were left unchanged.'
    }
} finally {
    Exit-ListenerLock $mutex
}
