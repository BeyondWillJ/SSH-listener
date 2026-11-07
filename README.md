# SSH-listener

[中文](#中文) · [English](#english)

## 中文

Windows 上按需开启的 SSH 监听器。双击桌面上的 **Start SSH.lnk**，接受管理员提权，窗口打开后即可通过 Tailscale 连接；关闭窗口后，监听器和它管理的 SSH 会话进程一起结束。

适合希望手动开启远程维护、用完就关的个人电脑。使用 Windows 自带的 OpenSSH，支持 SSH 终端和 SFTP 文件传输。远程操作具有所选 Windows 账号的权限，包括该账号可执行的程序和可读写的文件。

### 工作方式

- 只绑定安装时选定的 Tailscale IPv4，默认端口 `2223`。
- 使用公钥认证，禁用密码认证、TCP 转发和代理转发。
- 防火墙和 `AllowUsers 用户名@客户端IP` 双重限制指定的 Tailscale 客户端。
- 前台运行 `sshd -D -e`，窗口显示连接日志。
- Windows Job Object 管理进程树；子进程先以挂起状态创建，加入 Job 后再运行。关闭窗口或启动器异常退出时，Windows 结束 Job 中的进程。
- 应用文件安装到 `%ProgramData%\SSH-listener`，有独立配置、授权公钥和主机密钥。现有 Windows `sshd` 服务、系统 SSH 配置和其他 SSH 会话保持原状。
- 不创建开机启动项或计划任务。重启电脑后，需要再次打开快捷方式。

这里提供快捷方式的生成脚本。`.lnk` 内含本机绝对路径，因此在安装时生成，不把某台电脑的快捷方式直接复制给其他人。

### 1. 准备两台电脑

受控端是要被远程连接的 Windows 电脑，控制端是发起 SSH 连接的电脑。

1. 受控端使用 Windows 10/11、64 位 Windows PowerShell 5.1，并能以管理员身份运行安装脚本。使用已有的本地 Windows 账号；安装器不创建账号，暂不支持域账号或 Microsoft Entra 账号。
2. 两端安装 [Tailscale](https://tailscale.com/download)，登录同一 tailnet，或配置允许它们互通的共享/访问策略。
3. 在两端运行 `tailscale ip -4`，记下各自的 Tailscale IPv4。后面的 `100.64.0.10`、`100.64.0.20` 都是示例，请替换。
4. 控制端需要 OpenSSH 客户端；在 PowerShell/终端运行 `ssh -V` 检查。

若 Tailscale 的访问策略有端口限制，需要允许控制端到受控端的 TCP `2223`（或你指定的端口）。安装器只修改受控端 Windows 防火墙，不修改 tailnet 策略。

### 2. 在控制端生成专用 SSH 密钥

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\ssh-listener-client" -C "ssh-listener-client"
```

按提示设置密钥口令。把生成的 **`ssh-listener-client.pub` 公钥文件**复制到受控端，例如 `C:\Temp\ssh-listener-client.pub`。私钥 `ssh-listener-client` 保留在控制端。

### 3. 下载项目并安装到受控端

下载本仓库的 ZIP 并解压到永久或临时目录；也可以使用 Git：

```powershell
git clone https://github.com/BeyondWillJ/SSH-listener.git
cd SSH-listener
```

在受控端打开 **Windows PowerShell（管理员）**，进入解压/克隆目录，运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 `
  -UserName "your-local-user" `
  -PublicKeyPath "C:\Temp\ssh-listener-client.pub" `
  -AllowedClientAddress "100.64.0.20" `
  -InstallOpenSsh
```

- `UserName`：受控端现有的本地 Windows 登录用户名，可运行 `Get-LocalUser` 查看。
- `PublicKeyPath`：刚复制到受控端的控制端公钥路径。多个公钥可传 PowerShell 字符串数组。
- `AllowedClientAddress`：允许访问的控制端 Tailscale IPv4。多个地址可传字符串数组，不接受网段或公网 IP。
- `ListenAddress`：受控端 Tailscale IPv4；省略时从 `tailscale ip -4` 自动读取。
- `Port`：默认 `2223`，可选 `1024` 至 `65535`。
- `InstallOpenSsh`：缺少 Windows OpenSSH Server 时安装该可选组件；可能需要 Windows Update 和重启。已安装时直接复用。
- `DesktopPath`：快捷方式保存目录，默认是当前提权账号的 Windows 桌面，兼容重定向到 OneDrive 的桌面。如果用另一个管理员账号提权，显式指定受控用户的桌面路径。
- `PlanOnly`：只输出安装计划，不写文件、不开放端口；不检查全部运行时能力，正式安装仍会验证 OpenSSH 和 Job Object。

传多个公钥或客户端地址时，在当前管理员 PowerShell 中直接调用脚本，保留数组类型：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Install.ps1 -UserName "your-local-user" `
  -PublicKeyPath @("C:\Temp\client-a.pub", "C:\Temp\client-b.pub") `
  -AllowedClientAddress @("100.64.0.20", "100.64.0.21") `
  -ListenAddress "100.64.0.10" -Port 2223 -InstallOpenSsh
```

公钥列表与客户端 IP 列表分别适用于所选账号：任意已授权密钥可从任意允许的客户端 IP 登录，不按数组位置一一配对。

安装器生成独立的 Ed25519 主机密钥、配置和防火墙规则，验证后在桌面创建 **Start SSH.lnk**。安装完成后可以删除下载目录；桌面快捷方式指向已安装目录。安装本身不开始监听。

### 4. 打开桌面快捷方式并连接

1. 受控端双击桌面 **Start SSH.lnk**，接受 UAC 提示。
2. 保持显示 SSH 地址的窗口开启。启动器最多等待30秒，让已登录的 Tailscale 接口就绪。
3. 控制端运行：

```powershell
ssh -p 2223 -i "$env:USERPROFILE\.ssh\ssh-listener-client" your-local-user@100.64.0.10
```

首次连接时，把 SSH 显示的主机指纹与安装器输出进行核对，再接受。也可以在受控端管理员 PowerShell 查看：

```powershell
& "$env:WINDIR\System32\OpenSSH\ssh-keygen.exe" -lf "$env:ProgramData\SSH-listener\keys\ssh_host_ed25519_key.pub"
```

SFTP 使用相同账号和密钥：

```powershell
sftp -P 2223 -i "$env:USERPROFILE\.ssh\ssh-listener-client" your-local-user@100.64.0.10
```

使用结束后关闭受控端监听窗口，或在该窗口按 `Ctrl+C`。SSH 会话及其受 Job 管理的子进程会结束；通过另建服务、计划任务或其他系统管理机制启动的工作可能有独立生命周期。

### 现有系统 SSH 服务

本项目使用独立端口和配置，不自动停止或禁用已有 `sshd` 服务。因此，“关闭窗口停止 SSH”指本启动器管理的监听器。若电脑已有常驻 SSH 服务，它仍可继续提供连接。

如果你希望整台电脑只在打开窗口期间提供 SSH，请先确认没有需要保留的连接，再在受控端管理员 PowerShell 中自行停用系统服务：

```powershell
Stop-Service sshd -ErrorAction SilentlyContinue
Set-Service sshd -StartupType Disabled
```

### 诊断、卸载与更新

验证安装但不启动监听：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:ProgramData\SSH-listener\Start-SSHListener.ps1" -ValidateOnly
```

- **连接被拒绝**：检查监听窗口是否开启、端口是否一致、Tailscale 是否在线。
- **连接超时**：检查客户端 IP 白名单、两端 Tailscale 策略及 Windows 防火墙。
- **Permission denied (publickey)**：核对本地用户名、控制端 Tailscale IP 和公私钥配对；查看监听窗口日志。密码登录被禁用。
- **端口占用/重复窗口**：关闭原窗口，或重新安装时选择不同端口；启动器不会杀死其他监听器。
- **Tailscale IP 改变**：备份安装资料后重新安装，更新绑定地址和防火墙。
- **更新**：先关闭窗口并备份安装目录，再卸载、安装新版。重新生成的主机密钥会改变指纹；验证新指纹后再更新客户端 `known_hosts`。

卸载前关闭监听窗口。在受控端管理员 PowerShell 运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:ProgramData\SSH-listener\Uninstall.ps1"
```

确认后删除应用目录、专属主机密钥、配置、桌面快捷方式和本项目防火墙规则。保留 Windows OpenSSH 组件、Tailscale、控制端私钥和既有系统 SSH 设置。

### 开发与验证

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Listener.ps1
```

测试覆盖 PowerShell 语法、地址校验、配置约束，以及正常释放和启动器被强制终止后的子进程清理。测试不修改 SSH 服务或防火墙。完整安装和真实 SSH 登录还需要在已登录 Tailscale 的 Windows 机器上验证。

已安装 OpenSSH Server 的电脑还可在管理员 PowerShell 运行 `tests\Test-OpenSsh.ps1`，用临时配置、密钥和回环端口验证真实公钥登录及关停，不修改现有 SSH 服务或防火墙。

### 许可证

[GNU GPL v3.0](LICENSE)，SPDX：`GPL-3.0-only`。本仓库的启动器和脚本使用此许可证；OpenSSH 和 Tailscale 是独立安装的依赖，分别遵循自身许可证。

## English

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
