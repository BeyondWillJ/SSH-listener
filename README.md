# SSH-listener


An on-demand SSH listener for Windows. Double-click **Start SSH.lnk** on the desktop and accept UAC. Keep the visible window open while using SSH over Tailscale. Closing the window terminates the listener and the SSH process tree it owns.

It uses Windows OpenSSH for terminal access and SFTP. Remote commands run with the selected Windows account's permissions, including its access to programs and files.

### How it works

- Binds only to the selected Tailscale IPv4; default TCP port `2223`.
- Uses public-key authentication. Password authentication, TCP forwarding and agent forwarding are disabled.
- Restricts clients through both a scoped Windows Firewall rule and `AllowUsers username@clientIP` entries.
- Runs `sshd -D -e` in the foreground with visible logs.
- Creates the child suspended, assigns it to a Windows Job Object, then resumes it. Closing the launcher, including abrupt termination, closes the job and terminates its processes.
- Installs into `%ProgramData%\SSH-listener` with a dedicated configuration, authorized-key file and host key. It leaves the existing Windows `sshd` service, system configuration and unrelated SSH sessions unchanged.
- Creates no startup task or scheduled task. Open the shortcut again after rebooting.

The shortcut is generated during installation because `.lnk` files contain machine-specific absolute paths.

### 1. Prepare the computers

The **host** is the Windows computer receiving connections. The **client** initiates SSH.

1. Use Windows 10/11 with 64-bit Windows PowerShell 5.1 on the host and administrator access for installation. Choose an existing local Windows account. Domain and Microsoft Entra accounts are not supported by this installer.
2. Install [Tailscale](https://tailscale.com/download) on both computers. Sign in to the same tailnet, or configure sharing and access policies that permit connectivity.
3. Run `tailscale ip -4` on each computer. Replace the example host address `100.64.0.10` and client address `100.64.0.20` below with their actual addresses.
4. Ensure the client has OpenSSH: run `ssh -V`.

If your tailnet policy restricts ports, allow the client to reach the host on TCP `2223`, or your selected port. The installer configures Windows Firewall, not your tailnet policy.

### 2. Create a client key

On the client:

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\ssh-listener-client" -C "ssh-listener-client"
```

Choose a passphrase when prompted. Copy only **`ssh-listener-client.pub`** to the host, for example to `C:\Temp\ssh-listener-client.pub`. Keep the private key on the client.

### 3. Install on the host

Download and extract this repository's ZIP, or clone it:

```powershell
git clone https://github.com/BeyondWillJ/SSH-listener.git
cd SSH-listener
```

Open **Windows PowerShell as administrator**, change to the extracted repository, and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 `
  -UserName "your-local-user" `
  -PublicKeyPath "C:\Temp\ssh-listener-client.pub" `
  -AllowedClientAddress "100.64.0.20" `
  -InstallOpenSsh
```

Parameters:

| Parameter | Meaning |
|---|---|
| `UserName` | Existing local host account. List accounts with `Get-LocalUser`. |
| `PublicKeyPath` | Path to a client public key on the host. Accepts an array. |
| `AllowedClientAddress` | Individual client Tailscale IPv4 addresses. Accepts an array; no subnets or public IPs. |
| `ListenAddress` | Host Tailscale IPv4. Automatically read from `tailscale ip -4` when omitted. |
| `Port` | `2223` by default; range `1024`–`65535`. |
| `InstallOpenSsh` | Install the Windows OpenSSH Server optional capability if missing. Windows Update access or a restart may be needed. |
| `DesktopPath` | Shortcut destination, defaulting to the elevated account's Windows desktop, including redirected desktops. Specify the intended user's desktop if elevating with a different admin account. |
| `PlanOnly` | Print the plan without creating files or opening a port. Final runtime validation still happens during installation. |

For arrays, invoke the script directly inside the administrator PowerShell session:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Install.ps1 -UserName "your-local-user" `
  -PublicKeyPath @("C:\Temp\client-a.pub", "C:\Temp\client-b.pub") `
  -AllowedClientAddress @("100.64.0.20", "100.64.0.21") `
  -ListenAddress "100.64.0.10" -Port 2223 -InstallOpenSsh
```

Every authorized key can authenticate from every allowed client address; the two arrays are not paired by position.

Installation generates a dedicated Ed25519 host key, configuration, firewall rule and **Start SSH.lnk** on the selected desktop. The downloaded repository can then be removed: the shortcut points to the installed files. Installation does not start listening.

### 4. Start and connect

1. Double-click **Start SSH.lnk** on the host and accept UAC.
2. Keep the window open. The launcher waits up to 30 seconds for the configured Tailscale interface.
3. Connect from the client:

```powershell
ssh -p 2223 -i "$env:USERPROFILE\.ssh\ssh-listener-client" your-local-user@100.64.0.10
```

On first connection, compare the displayed host-key fingerprint with the installer output before accepting it. Display it again on the host with:

```powershell
& "$env:WINDIR\System32\OpenSSH\ssh-keygen.exe" -lf "$env:ProgramData\SSH-listener\keys\ssh_host_ed25519_key.pub"
```

For SFTP:

```powershell
sftp -P 2223 -i "$env:USERPROFILE\.ssh\ssh-listener-client" your-local-user@100.64.0.10
```

Close the listener window or press `Ctrl+C` when finished. Processes owned by its Windows job terminate with it. Work launched through independent services, scheduled tasks or other system-management mechanisms may have a separate lifetime.

### Existing system SSH service

The launcher uses its own configuration and port. It does not automatically stop or disable an existing `sshd` service. Closing the window stops only this launcher's listener.

If you want SSH available only while this window is open, first ensure that existing service connections can be interrupted, then explicitly disable the system service in an administrator PowerShell:

```powershell
Stop-Service sshd -ErrorAction SilentlyContinue
Set-Service sshd -StartupType Disabled
```

### Diagnose, uninstall and update

Validate without opening a listener:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:ProgramData\SSH-listener\Start-SSHListener.ps1" -ValidateOnly
```

- **Connection refused:** open the listener window, check the port and Tailscale connectivity.
- **Timeout:** check the client IP allowlist, tailnet policy and Windows Firewall.
- **Permission denied (publickey):** verify the local username, client Tailscale IP and key pair. Read the listener window logs. Password login is disabled.
- **Port in use / duplicate window:** close the previous window or reinstall with a different port. The launcher does not terminate another listener.
- **Changed Tailscale address:** back up the installation and reinstall to update its bind address and firewall rule.
- **Update:** close the window, back up the installation, uninstall, then install the new version. Reinstallation creates a new host key; verify its fingerprint before updating client `known_hosts`.

Close the listener, then uninstall in an administrator PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:ProgramData\SSH-listener\Uninstall.ps1"
```

After confirmation, uninstall removes the application directory, dedicated host key, configuration, desktop shortcut and application firewall rule. Windows OpenSSH, Tailscale, the client private key and existing system SSH settings remain installed.

### Development checks

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Listener.ps1
```

Checks cover PowerShell syntax, address validation, configuration constraints, normal job disposal and descendant termination after forcibly killing the owner. They do not change SSH services or firewall rules. Full installation and authentication also need validation on a Windows host signed in to Tailscale.

On a host with OpenSSH Server installed, run `tests\Test-OpenSsh.ps1` as administrator for real public-key login and shutdown checks using temporary keys, configuration and a loopback listener. It does not change existing SSH services or firewall rules.

### License

[GNU GPL v3.0](LICENSE), SPDX identifier `GPL-3.0-only`. This license covers the launcher and scripts in this repository. OpenSSH and Tailscale are separately installed dependencies under their respective licenses.

References: [Microsoft Windows OpenSSH configuration](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration), [Windows Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects).
