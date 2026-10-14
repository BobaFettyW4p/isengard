# Server setup runbook

How the server was configured, in order. Fedora 43 (dnf5, systemd, firewalld, SELinux enforcing).
Commands that need `sudo` are marked; run them on the server, not on your laptop.
Placeholders: `<UUID>` is a partition UUID, `<tailscale-ip>` is the server's Tailscale address.

## 1. Network: Tailscale

- Install Tailscale on the server and your laptop. `tailscaled` is enabled at boot, so the server rejoins after a reboot.
- In the Tailscale admin console, **disable key expiry** for the server. Node keys expire (180 days by default), after which the machine drops off the tailnet until someone logs in.
- Access control is the tailnet itself: only devices you join can reach the server.

## 2. SSH

Two things can answer on port 22:

- **Tailscale SSH** (`tailscale set --ssh`) serves the tailnet address. Authentication is by tailnet identity, not keys or passwords, and `ssh -v` shows `Authenticated ... using "none"`. It may ask for a browser re-check on new connections ("check" mode).
- **OpenSSH** serves the LAN address. Harden it with a drop-in (first value wins in `sshd_config.d`, so name it `01-`):

```bash
sudo tee /etc/ssh/sshd_config.d/01-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
sudo sshd -t && sudo systemctl reload sshd
sudo sshd -T | grep -E 'passwordauthentication|kbdinteractiveauthentication|permitrootlogin'
```

Verify from the server itself: `ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password localhost true` must fail with `Permission denied (publickey...)`.

## 3. Always on

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

In the BIOS set **Restore on AC/Power Loss** to **Power On** (ASRock: Advanced, Chipset Configuration). Optionally enable Wake-on-LAN. Test once by powering off, cutting power for ~10 seconds, and restoring it.

## 4. Headless

```bash
sudo systemctl set-default multi-user.target     # takes effect on next boot
sudo loginctl enable-linger "$USER"              # user services, tmux, containers survive logout and start at boot
```

GNOME stays installed. To use the desktop at the keyboard: `sudo systemctl isolate graphical.target`.
Booting headless freed about 0.5 GB of VRAM (564 MiB down to 33 MiB) and about 2.5 GB of RAM.

## 5. Automatic security updates

```bash
sudo dnf install -y dnf5-plugin-automatic
sudo tee /etc/dnf/automatic.conf <<'EOF'
[commands]
upgrade_type = security
apply_updates = yes
reboot = never

[emitters]
emit_via = stdio
EOF
sudo systemctl enable --now dnf5-automatic.timer
```

Security only, so kernel and NVIDIA driver updates stay manual. Never reboots on its own; reboot when
`sudo dnf needs-restarting -r` says so. Logs: `journalctl -u dnf5-automatic`.

## 6. GPU in containers (rootless Podman)

```bash
curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
  | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo
sudo dnf install -y nvidia-container-toolkit
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
sudo setsebool -P container_use_devices on
podman run --rm --device nvidia.com/gpu=all docker.io/library/ubuntu nvidia-smi
```

Without the `container_use_devices` boolean, `nvidia-smi` in the container fails with `Insufficient Permissions`
because SELinux blocks the device nodes. The boolean is preferable to `--security-opt=label=disable`, which turns
SELinux confinement off for the whole container.

Regenerate `/etc/cdi/nvidia.yaml` after a driver update.

## 7. Firewall

Fedora Workstation's default zone opens **every port from 1025 up** to the LAN. For a server, switch it:

```bash
sudo firewall-cmd --permanent --zone=trusted --add-interface=tailscale0
sudo firewall-cmd --reload
sudo firewall-cmd --set-default-zone=FedoraServer      # immediate and permanent
firewall-cmd --get-active-zones
```

Expected: the Wi-Fi/Ethernet interface under `FedoraServer` (ssh, cockpit, dhcpv6-client only), `tailscale0` under `trusted`.
Tailnet traffic is then gated by Tailscale's access controls.

**Audit what listens first.** Anything bound to `0.0.0.0` was reachable from the LAN under the old zone:

```bash
ss -tlnp | grep -v '127.0.0.1\|\[::1\]'
```

Databases and caches (Redis, MariaDB) were found exposed this way. Bind them to loopback and require authentication.

## 8. Secondary storage and Samba

A 3.6 TB NTFS disk left over from Windows, mounted with the kernel `ntfs3` driver. Mount read-only first to check it isn't dirty (Windows Fast Startup or hibernation leaves it dirty):

```bash
sudo mkdir -p /mnt/data
sudo mount -t ntfs3 -o ro,uid=1000,gid=1000 /dev/sda2 /mnt/data && ls /mnt/data
sudo umount /mnt/data
echo 'UUID=<UUID> /mnt/data ntfs3 uid=1000,gid=1000,umask=022,nofail,context=system_u:object_r:samba_share_t:s0,x-systemd.device-timeout=10 0 0' | sudo tee -a /etc/fstab
sudo systemctl daemon-reload && sudo mount /mnt/data
```

- `nofail` and the device timeout keep a missing disk from blocking boot.
- NTFS can't hold SELinux labels, so `context=...samba_share_t` labels the whole mount for Samba. `ls -dZ` shows `?` for it; that is only how an unprivileged `ls` displays it.
- It is a spinning disk: good for bulk and cold data, poor for builds, databases or scratch space.

Samba, reachable only over the tailnet:

```bash
sudo dnf install -y samba
sudo tee /etc/samba/smb.conf <<'EOF'
[global]
   server string = perseus
   workgroup = WORKGROUP
   security = user
   map to guest = never
   server min protocol = SMB3
   server smb encrypt = desired
   disable netbios = yes
   smb ports = 445
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes

[data]
   path = /mnt/data
   valid users = <your-user>
   read only = no
   create mask = 0644
   directory mask = 0755
EOF
sudo smbpasswd -a "$USER"                          # separate Samba password
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="100.64.0.0/10" service name="samba" accept'
sudo firewall-cmd --reload
sudo testparm -s >/dev/null && sudo systemctl enable --now smb
```

With `tailscale0` in the `trusted` zone the rich rule is redundant but harmless.

**Gotcha:** `interfaces = lo tailscale0` and `bind interfaces only = yes` did not work. Samba skipped
`tailscale0` (a point-to-point link), and listing its IP addresses didn't help either, so smbd listened on
loopback only. The fix was to drop both settings and rely on the firewall to keep the LAN out.

On the Mac: Finder, Cmd-K, `smb://<server-name>/data`. macOS drops SMB mounts on sleep or network changes;
reconnect with `open smb://<user>@<server-name>/data`.

## 9. Gotchas

- **Non-interactive SSH has a minimal PATH** (`/usr/local/bin:/usr/bin:/bin`). With zsh as the login shell,
  `~/.zshrc` is read only for interactive shells, so `uv` and anything in `~/.local/bin` is missing for
  `ssh host 'cmd'`. Put `export PATH="$HOME/.local/bin:$PATH"` in `~/.zshenv`.
- **`sudo` prompts differ:** macOS shows `Password:`; Fedora shows `[sudo] password for <user>:`. A `Read-only file system` error on `/mnt` means the command ran on the Mac.
- **A new SSH host key must be verified once.** Compare `ssh-keyscan -t ed25519 <host> | ssh-keygen -lf -` with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the server before trusting it.
- **Claude Code login on the server can expire.** Symptom: `Login expired - Please run /login`. Fix: run `claude` on the server, then `/login`.

## 10. Verification checklist

```bash
uptime -p; systemctl get-default; loginctl show-user "$USER" -p Linger
systemctl is-enabled sshd tailscaled dnf5-automatic.timer
systemctl is-enabled sleep.target suspend.target hibernate.target hybrid-sleep.target   # all: masked
nvidia-smi --query-gpu=memory.used,memory.total --format=csv
getenforce; getsebool container_use_devices
firewall-cmd --get-active-zones
findmnt /mnt/data; systemctl is-active smb
```
