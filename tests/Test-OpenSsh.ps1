# SPDX-License-Identifier: GPL-3.0-only
# Optional integration test. Run as administrator on Windows with OpenSSH Server.
# Uses a temporary application directory and loopback only. No firewall/service changes.
[CmdletBinding()]
param([ValidateRange(1024,65535)][int]$Port=32223)
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Common.ps1')
$exe=Join-Path $env:WINDIR 'System32\OpenSSH\sshd.exe'
if (!(Test-Path -LiteralPath $exe)) { throw 'Install Windows OpenSSH Server before running this integration test.' }
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { throw 'Test port is already in use.' }
$fixture=Join-Path $env:ProgramData ('ssh-listener-test-'+[Guid]::NewGuid().ToString('N'))
$job=$null; $server=$null; $client=$null
try {
    New-Item -ItemType Directory -Path $fixture | Out-Null
    Set-ListenerAcl $fixture -UsersRead
    $keyDir=Join-Path $fixture 'keys'
    New-Item -ItemType Directory -Path $keyDir | Out-Null
    Set-ListenerAcl $keyDir
    $key=Join-Path $keyDir 'ssh_host_ed25519_key'
    & (Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe') -q -t ed25519 -f $key -N '""'
    if ($LASTEXITCODE -ne 0) { throw 'Test key generation failed.' }
    Set-ListenerAcl $key
    Copy-Item -LiteralPath ($key+'.pub') -Destination (Join-Path $fixture 'authorized_keys')
    Set-ListenerAcl (Join-Path $fixture 'authorized_keys')
    $config=Join-Path $fixture 'sshd_config'
    # Loopback is intentional for this isolated test; installer only accepts tailnet IPv4s.
    $text=New-ListenerConfig $fixture $env:USERNAME '127.0.0.1' $Port @('127.0.0.1')
    [IO.File]::WriteAllText($config,$text,(New-Object Text.UTF8Encoding($false)))
    & $exe -t -f $config
    if ($LASTEXITCODE -ne 0) { throw 'OpenSSH rejected generated configuration.' }
    Write-Host 'PASS generated configuration accepted by Windows OpenSSH'
    Add-Type -Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\SshWindowLifetime.cs')
    $job=New-Object SshListener.WindowLifetime
    $server=$job.Start($exe,('-D -E "'+(Join-Path $fixture 'sshd.log')+'" -f "'+$config+'"'))
    Start-Sleep -Milliseconds 700
    if ($server.HasExited) { throw 'Isolated listener exited.' }
    $known=Join-Path $fixture 'known_hosts'
    $clientExe=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
    $arguments="-p $Port -i `"$key`" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o `"UserKnownHostsFile=$known`" -o ConnectTimeout=5 $($env:USERNAME)@127.0.0.1 `"echo SSH_LISTENER_AUTH_OK`""
    $out=Join-Path $fixture 'client-out.txt'
    $err=Join-Path $fixture 'client-err.txt'
    $client=Start-Process $clientExe -WindowStyle Hidden -ArgumentList $arguments -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
    $null=$client.Handle
    if (!$client.WaitForExit(15000)) { $client.Kill(); throw 'SSH client timed out.' }
    if ($client.ExitCode -ne 0 -or (Get-Content -LiteralPath $out -Raw) -notmatch 'SSH_LISTENER_AUTH_OK') {
        throw ('Public-key command failed: '+(Get-Content -LiteralPath $err -Raw))
    }
    Write-Host 'PASS real public-key SSH authentication and remote command'
    $job.Dispose()
    if (!$server.WaitForExit(5000)) { throw 'sshd survived job disposal.' }
    if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { throw 'Test port remained open.' }
    Write-Host 'PASS SSH listener stopped and port closed with its job'
} catch {
    Write-Host ('FAIL '+$_.Exception.Message)
    throw
} finally {
    if ($job) { $job.Dispose() }
    if ($server) { $server.Dispose() }
    if ($client) { if (!$client.HasExited) { $client.Kill() }; $client.Dispose() }
    $prefix=[IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\')+'\ssh-listener-test-'
    $resolved=[IO.Path]::GetFullPath($fixture)
    if ($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
