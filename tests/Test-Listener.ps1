# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$count = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
    $script:count++
    Write-Host "PASS $Message"
}
foreach ($file in Get-ChildItem -LiteralPath $root -Filter *.ps1 -Recurse) {
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-True ($errors.Count -eq 0) ("PowerShell syntax: " + $file.Name)
}
. (Join-Path $root 'src\Common.ps1')
foreach ($ip in @('100.64.0.1','100.127.255.254')) { Assert-True (Test-TailnetIPv4 $ip) "Accept tailnet IPv4 $ip" }
foreach ($ip in @('100.63.255.255','100.128.0.1','127.0.0.1','0.0.0.0','::1','100.64.0.0/10','invalid')) {
    Assert-True (!(Test-TailnetIPv4 $ip)) "Reject address $ip"
}
$config = New-ListenerConfig 'C:\ProgramData\SSH-listener' 'ExampleUser' '100.64.0.10' 2223 @('100.64.0.20','100.64.0.21')
Assert-True ($config.Contains('AllowUsers exampleuser@100.64.0.20 exampleuser@100.64.0.21')) 'Bind user authentication to the permitted client IPs'
Assert-True ($config.Contains('PasswordAuthentication no')) 'Password authentication disabled'
Assert-True ($config.Contains('AllowTcpForwarding no')) 'TCP forwarding disabled'
Add-Type -Path (Join-Path $root 'src\SshWindowLifetime.cs')
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ssh-listener-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$job = $null; $process = $null; $owner = $null; $grandchild = $null
function Wait-Marker([string]$File) {
    $deadline = (Get-Date).AddSeconds(10)
    while (!(Test-Path -LiteralPath $File)) {
        if ((Get-Date) -ge $deadline) { throw 'Test child did not start.' }
        Start-Sleep -Milliseconds 50
    }
}
try {
    $marker = Join-Path $testRoot 'grandchild.txt'
    $worker = Join-Path $testRoot 'worker.ps1'
    @"
`$child = Start-Process '$powershell' -WindowStyle Hidden -ArgumentList '-NoProfile -Command Start-Sleep -Seconds 120' -PassThru
`$child.Id | Set-Content -LiteralPath '$marker'
Start-Sleep -Seconds 120
"@ | Set-Content -LiteralPath $worker
    $job = New-Object SshListener.WindowLifetime
    $process = $job.Start($powershell, ('-NoProfile -File "' + $worker + '"'))
    Wait-Marker $marker
    $grandchild = Get-Process -Id ([int](Get-Content -LiteralPath $marker))
    $job.Dispose()
    Assert-True ($process.WaitForExit(5000)) 'Disposing job terminates the listener process'
    Assert-True ($grandchild.WaitForExit(5000)) 'Disposing job terminates its descendant'
    Remove-Item -LiteralPath $marker
    $ownerScript = Join-Path $testRoot 'owner.ps1'
    @"
Add-Type -Path '$(Join-Path $root 'src\SshWindowLifetime.cs')'
`$job = New-Object SshListener.WindowLifetime
`$child = `$job.Start('$powershell', '-NoProfile -File "$worker"')
Start-Sleep -Seconds 120
"@ | Set-Content -LiteralPath $ownerScript
    $owner = Start-Process $powershell -WindowStyle Hidden -ArgumentList ('-NoProfile -File "' + $ownerScript + '"') -PassThru
    Wait-Marker $marker
    $nested = Get-Process -Id ([int](Get-Content -LiteralPath $marker))
    $owner.Kill()
    Assert-True ($owner.WaitForExit(5000)) 'Owner process forcibly terminated'
    Assert-True ($nested.WaitForExit(5000)) 'Abrupt owner exit still terminates descendants'
    $nested.Dispose()
} finally {
    if ($job) { $job.Dispose() }
    if ($process) { $process.Dispose() }
    if ($grandchild) { $grandchild.Dispose() }
    if ($owner) { if (!$owner.HasExited) { $owner.Kill() }; $owner.Dispose() }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\ssh-listener-test-'
    if ($resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host "$count checks passed. No SSH service or firewall settings were changed."
