# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param()
$ErrorActionPreference = 'Stop'
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run Windows PowerShell as administrator.' }
$root = [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'SSH-listener'))
$settings = Get-Content -LiteralPath (Join-Path $root 'settings.json') -Raw | ConvertFrom-Json
if ($settings.Product -ne 'SSH-listener' -or $settings.Version -ne 1) { throw 'Installation marker is invalid.' }
$mutex = New-Object Threading.Mutex($false, 'Global\SSH-listener')
$owns = $false
try {
    try { $owns = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owns = $true }
    if (!$owns) { throw 'Close the SSH-listener window before uninstalling.' }
    if ($PSCmdlet.ShouldProcess($root, 'Remove SSH-listener, its firewall rule, shortcut, configuration and dedicated host key')) {
        Remove-NetFirewallRule -Name 'SSH-listener-Tailscale' -ErrorAction SilentlyContinue
        $shortcut = $settings.DesktopShortcut
        if ($shortcut -and (Test-Path -LiteralPath $shortcut)) {
            $link = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
            if ($link.Arguments -like ('*' + (Join-Path $root 'Start-SSHListener.ps1') + '*')) {
                Remove-Item -LiteralPath $shortcut -Force
            }
        }
        # Fixed application directory, checked above; no user-controlled deletion target.
        if ($root -ne [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'SSH-listener'))) { throw 'Invalid removal path.' }
        Remove-Item -LiteralPath $root -Recurse -Force
        Write-Host 'SSH-listener removed. OpenSSH, Tailscale, and the system sshd service were left unchanged.'
    }
} finally {
    if ($owns) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
