# OpenVPN Full Setup Process — AWS EC2 (Secure Configuration)

Installer: [angristan/openvpn-install](https://github.com/angristan/openvpn-install)
Target: AWS EC2, Ubuntu

This doc walks through every interactive prompt the installer asks, with the recommended answer for a **strong, production-grade** setup, plus the hardening steps to do afterward.

---

## 0. Before You Start

```bash
sudo apt update && sudo apt upgrade -y
curl ifconfig.me   # confirm your public IP
```

**AWS Security Group — set this up before installing:**

| Type | Protocol | Port | Source |
|---|---|---|---|
| SSH | TCP | 22 | Your admin IP only (`/32`) |
| Custom UDP | UDP | 1194 (or your chosen port) | Client IP ranges, or `0.0.0.0/0` only if clients roam |

---

## 1. Download and Run the Installer

```bash
curl -O https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh
sudo bash openvpn-install.sh interactive
```

---

## 2. Interactive Prompts — Recommended Secure Answers

### Network setup

| Prompt | Recommended | Reasoning |
|---|---|---|
| Endpoint type (client connects via) | `1) IPv4` | Matches standard EC2 networking unless you have IPv6 configured |
| Client IP versions | `1) IPv4 only` | Simpler, matches your EC2 setup; use dual-stack only if you specifically need IPv6 egress |
| IPv4 VPN subnet | `1) Default 10.8.0.0/24` | Fine unless it conflicts with an existing network you connect to |

### Client access policy

| Prompt | Recommended | Reasoning |
|---|---|---|
| Route client internet traffic through VPN? | `y` | Standard full-tunnel VPN behavior |
| Allow clients to access each other? | `n` | Prevents lateral movement between clients — important if devices have different trust levels |
| Allow clients to access server's local network? | `n` (unless you specifically need it, e.g. home lab access) | Least privilege — only enable if you intend to reach LAN resources through the tunnel |

### Transport

| Prompt | Recommended | Reasoning |
|---|---|---|
| Port | `1) 1194` or `3) Random` | 1194 is fine behind a locked-down Security Group. Random reduces automated scanning noise if you're exposing the port broadly |
| Protocol | `1) UDP` | Lower latency, less overhead; only use TCP if UDP is blocked on your network |

### DNS

| Prompt | Recommended | Reasoning |
|---|---|---|
| DNS resolver | `2) Self-hosted (Unbound)` for privacy, or `3) Cloudflare` / `4) Quad9` for simplicity | Avoid leaking DNS queries to your ISP; avoid option 1 (system resolvers) if the server's resolv.conf isn't trustworthy |

### Client behavior

| Prompt | Recommended | Reasoning |
|---|---|---|
| Multiple devices per client profile | `n` | Keeping 1 profile = 1 device gives you persistent client IPs and cleaner auditing. Only say `y` if you specifically need to share one profile across devices |
| Custom MTU | `1) Default (1500)` | Only customize if you hit fragmentation issues on a specific network |

### Authentication mode

| Prompt | Recommended | Reasoning |
|---|---|---|
| Auth mode | `1) PKI (CA-based)` | More mature, supports revocation via CRL, works everywhere. Fingerprint mode is fine for very small/home setups but PKI is the safer default |

### Encryption — say `y` to customize, then:

| Prompt | Recommended | Reasoning |
|---|---|---|
| Data channel cipher | `3) AES-256-GCM` (not CBC) | AEAD cipher = authenticated encryption, enables Data Channel Offload, faster and more secure than CBC modes |
| Certificate type | `1) ECDSA` | Smaller keys, faster TLS handshakes, equivalent security to RSA-3072+. Use `2) RSA` with 4096-bit only if a client device requires RSA compatibility |
| RSA key size (if RSA chosen) | `3) 4096` | Strongest RSA option offered |
| Control channel cipher | `2) ECDHE-RSA-AES-256-GCM-SHA384` | Stronger than the 128-bit default, still widely supported |
| Minimum TLS version | `2) TLS 1.3` | Drop legacy TLS 1.2 entirely if all your clients support it (OpenVPN 2.5+) |
| TLS 1.3 cipher suite | `1) All secure ciphers` | Let OpenVPN negotiate the strongest mutually-supported option |
| TLS key exchange groups | `1) All modern curves` | Best balance of security and client compatibility |
| Digest / HMAC | `2) SHA-384` or `3) SHA-512` | Stronger than SHA-256 with negligible performance cost on modern hardware |
| Control channel security | `1) tls-crypt-v2` | Best option — unique key per client, so one leaked client key doesn't compromise the whole control channel (unlike shared `tls-crypt`) |

---

## 3. Creating the First Client

| Prompt | Recommended | Reasoning |
|---|---|---|
| Client name | Something identifying but not overly personal, e.g. `laptop-tn-lap-0564` | Makes auditing/revocation easier later |
| Certificate validity (days) | `365` – `730` | Shorter-lived certs limit exposure if a device is lost. Avoid the default 3650 (10 years) for anything beyond quick lab testing |
| Password-protect the config? | `2) Use a password` | Encrypts the private key at rest in the `.ovpn` file — protects it if the file itself is ever copied or leaked from a client device |

---

## 4. Retrieving the Client Config Safely

**Never** display or paste `.ovpn` contents in a terminal session that gets logged, screen-shared, or copy-pasted into chat tools/tickets — it contains a private key.

```bash
# From your local machine:
scp -i your-aws-key.pem root@<server-ip>:/root/<client-name>.ovpn ./

# Then remove the copy from the server:
ssh -i your-aws-key.pem root@<server-ip> "rm /root/<client-name>.ovpn"
```

---

## 5. Post-Install Hardening

### Host firewall (defense-in-depth alongside the Security Group)
```bash
sudo apt install -y ufw
sudo ufw allow OpenSSH
sudo ufw allow 1194/udp     # match your chosen port
sudo ufw enable
sudo ufw status verbose
```

### SSH hardening
Create a non-root sudo user with key-based auth, confirm you can log in as them, **then**:

`/etc/ssh/sshd_config`:
```
PermitRootLogin no
PasswordAuthentication no
```
```bash
sudo systemctl restart sshd
```

### Brute-force protection
```bash
sudo apt install -y fail2ban
sudo systemctl enable --now fail2ban
```

### Automatic security updates
```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

---

## 6. Ongoing Client Management

| Task | Command |
|---|---|
| Add a client | `sudo bash openvpn-install.sh client add --name <name>` |
| Revoke a client | `sudo bash openvpn-install.sh client revoke <name>` |
| List clients | `sudo bash openvpn-install.sh client list` |
| Server status | `sudo systemctl status openvpn-server@server` |
| Live logs | `sudo journalctl -u openvpn-server@server -f` |

**Rotation policy:** revoke and reissue any client cert that's lost, on a decommissioned device, or older than your chosen validity window.

---

## 7. PKI Backup (Critical)

Losing `/etc/openvpn/server/easy-rsa/pki` means reissuing every client certificate from scratch.

```bash
sudo tar czf openvpn-pki-backup-$(date +%F).tar.gz -C /etc/openvpn/server easy-rsa
gpg -c openvpn-pki-backup-$(date +%F).tar.gz     # encrypt before it leaves the server
rm openvpn-pki-backup-$(date +%F).tar.gz          # keep only the encrypted copy locally
```
Store the encrypted archive off-server (e.g. S3 with SSE, or your local machine) — separate from where you keep client `.ovpn` files.

---

## 8. Final Verification Checklist

- [ ] `sudo systemctl status openvpn-server@server` → active (running)
- [ ] Client connects and `curl ifconfig.me` from the client shows the VPN server's IP
- [ ] `sudo ufw status` shows only expected ports
- [ ] Non-root SSH login with keys confirmed working before disabling root SSH
- [ ] Client cert validity set to a reasonable window (not 10 years)
- [ ] Encrypted PKI backup stored off-server
- [ ] No `.ovpn`/key/cert content ever pasted into chat, tickets, or logs shared externally

---

*Reference setup guide — AWS EC2 OpenVPN, August 2026.*
