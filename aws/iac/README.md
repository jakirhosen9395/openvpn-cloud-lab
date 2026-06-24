# OpenVPN on AWS — Terraform + Ansible (SSM-first, SSH break-glass)

A beginner-friendly, reproducible OpenVPN lab on AWS.

- **Terraform** builds the AWS infrastructure.
- **Ansible** installs and configures OpenVPN — connecting **over AWS SSM** (no SSH/SCP).
- **SSH** exists only as a **break-glass** path, locked to *your* auto-detected public IP.

The result: client profiles (`admin_user.ovpn`, etc.) are generated on the server and downloaded to
`vpn-clients/` on your machine — no manual steps.

---

## Architecture

```
   Your machine (control node)                     AWS  (ap-south-1)
 ┌──────────────────────────┐              ┌─────────────────────────────────────--─┐
 │ terraform → builds infra │              │  VPC 10.0.0.0/16                       │
 │ ansible   → over SSM     │  HTTPS 443   │  ┌─────────────── public 10.0.1.0/24 ─┐│
 │ aws_ssm connection ──────┼──────────────┼─▶│ OpenVPN EC2 (Ubuntu 24.04)         ││
 │ vpn-clients/*.ovpn ◀─────┼─ S3 transfer ┼──│  EIP · UDP 1194 · SSM agent        ││
 │                          │              │  │  tun0 10.8.0.0/24 · MASQUERADE     ││
 │ ovpn-admin.pem (SSH)    ·┼·· TCP 22 ····┼··│  (break-glass, your IP only)       ││
 └──────────────────────────┘              │  └──────────────────┬─────────────────┘│
                                           │ IGW ◀─ public RT   │ NAT GW (private)  │
                                           │ ┌──────────── private 10.0.2.0/24 ─┐   │
                                           │ │ (future private resources)    ───┼─▶ │
                                           │ └──────────────────────────────────┘   │
                                           └──────  ────────────────────────────────┘
   VPN clients ── UDP 1194 ─▶ EIP ─▶ OpenVPN ─▶ tun 10.8.0.0/24 ─▶ internet / VPC
```

**Two ways in:** **SSM** (primary — works anywhere, no open ports) and **SSH** (break-glass — only
from your detected IP, only if your network allows outbound 22).

---

## Repository layout

```
ovpn/
├── README.md            ← you are here (start here)
├── ANSIBLE_HANDOFF.md   ← day-2 operations: SSM/SSH/user/key workflows + recovery
├── CLAUDE.md            ← notes/standards for the AI assistant
├── userdata.sh          ← STANDALONE EC2 "dashboard" learning script (not used by this VPN)
├── vpn-clients/         ← generated *.ovpn client profiles land here
│   └── README.md
├── terraform/           ← AWS infrastructure (see terraform/README.md)
│   ├── versions.tf providers.tf backend.tf variables.tf terraform.tfvars
│   ├── locals.tf main.tf outputs.tf README.md
│   └── (generates) ../ansible/inventory.ini
└── ansible/             ← OpenVPN install/config + user management
    ├── ansible.cfg playbook.yml create-user.yml inventory.ini (generated)
    ├── group_vars/all.yml
    └── roles/openvpn/{defaults,handlers,tasks,templates,files}
```

---

## Prerequisites (control node)

- **Terraform ≥ 1.10**, **AWS CLI v2** (`aws configure`, region `ap-south-1`).
- **Ansible** + for SSM: **`session-manager-plugin`**, **`boto3`**, collections **`community.aws`** + **`amazon.aws`**.
- Add the plugin to PATH when running Ansible: `export PATH="$HOME/.local/bin:$PATH"`.
- **No manual SSH key step** — Terraform *generates* the key pair and writes `ovpn-admin.pem` to the
  repo root (used by the `ssh_command` output). `*.pem` is git-ignored.

---

## Deployment workflow

```bash
# 1. Build the infrastructure
cd terraform
terraform init
terraform validate
terraform plan        # note: detected_admin_ip = your current public IP
terraform apply       # creates infra + writes ../ansible/inventory.ini

# 2. Install + configure OpenVPN and create the first client (over SSM)
cd ../ansible
export PATH="$HOME/.local/bin:$PATH"
ansible-playbook -i inventory.ini playbook.yml

# 3. Your profile is now at  vpn-clients/admin_user.ovpn
```

Get any value later with `terraform -chdir=terraform output` (e.g. `output -raw vpn_server_public_ip`).

---

## SSM access (primary)

No open ports, works from any network:

```bash
# interactive shell on the server
terraform -chdir=terraform output -raw ssm_command | bash
# or: aws ssm start-session --target <instance-id> --region ap-south-1

# run a one-off command over SSM
cd ansible && export PATH="$HOME/.local/bin:$PATH"
ansible -i inventory.ini openvpn -b -m shell -a 'systemctl status openvpn-server@server'
```

## SSH access (break-glass) and the dynamic IP

SSH is **secondary** — for emergencies/troubleshooting only. Terraform **auto-detects your current
public IP** (via `checkip.amazonaws.com`) and opens port 22 to **only that IP** (`detected_admin_ip`).

Terraform generates the key and saves `ovpn-admin.pem` in the repo root, so just:

```bash
terraform -chdir=terraform output -raw ssh_command   # ready-to-use, includes the .pem path
ssh -i ovpn-admin.pem ubuntu@$(terraform -chdir=terraform output -raw vpn_server_public_ip)
sudo -i
```

> **If your IP changes** (home ↔ office, mobile hotspot, ISP change, travel), SSH will stop working
> because the firewall still allows your *old* IP. **Fix it by re-running `terraform apply`** — it
> detects your new IP and updates the security group automatically. (SSM is unaffected and keeps
> working regardless.) Note: this control node's network blocks outbound 22, so SSH is validated by
> config (key + rule), not by a live login from here.

### SSH key lifecycle

- **Terraform generates** the key pair (`tls_private_key`) and writes the private key to
  **`ovpn-admin.pem`** in the repo root (chmod 600). AWS stores only the **public** key
  (`aws_key_pair.ovpn_admin`), which EC2 installs into the server's `authorized_keys`.
- **`ovpn-admin.pem` is git-ignored** (`*.pem`) — never commit or share it.
- **On `terraform destroy`:** the AWS key pair **and** the local `ovpn-admin.pem` are removed.
- **On each fresh `terraform apply`:** a **new** key is generated (new `ovpn-admin.pem`), so always
  use the freshly-generated `.pem` after a rebuild (and re-fetch any old client profiles).

---

## VPN user creation

```bash
cd ansible && export PATH="$HOME/.local/bin:$PATH"
ansible-playbook create-user.yml -e vpn_user=alice
ansible-playbook create-user.yml -e vpn_user=bob
```

Each run builds the client certificate, renders `<name>.ovpn`, and downloads it to
`vpn-clients/<name>.ovpn` — all over SSM. Import that file into **OpenVPN Connect** (or
`sudo openvpn --config vpn-clients/<name>.ovpn`).

> Re-deploying the server creates a **new** certificate authority, so profiles made against an old
> server stop working — just re-run the playbook / `create-user.yml` to regenerate them.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Ansible can't connect over SSM | `aws ssm describe-instance-information` must show `Online` (wait 1–3 min after apply); ensure `session-manager-plugin` is on PATH. |
| `boto3` import error | `python3 -m pip install --user boto3 botocore` for the Python that runs Ansible. |
| SSH times out | Your IP changed → `terraform apply` again; also your network must allow outbound 22 (use SSM instead). |
| VPN connects but no internet | On the server: `sysctl net.ipv4.ip_forward` = 1 and `iptables -t nat -S POSTROUTING` shows MASQUERADE. |
| OpenVPN down | `ansible openvpn -b -m shell -a 'journalctl -u openvpn-server@server -n 50'` (over SSM). |

---

## Cost considerations (ap-south-1, approx/month)

| Resource | Why it exists | ~Cost | Required? |
|---|---|---|---|
| **NAT Gateway + EIP** | Outbound internet for the **private** subnet | **~$41 + ~$3.6** | **No** for a VPN-only lab — see below |
| EC2 `t3.micro` | The OpenVPN server | ~$7.5 (free-tier eligible yr 1) | Yes |
| Elastic IP (server) | Stable VPN endpoint | ~$3.6 | Yes |
| EBS gp3 8 GB | Server disk | ~$0.64 | Yes |
| S3 transfer bucket | Ansible SSM file transfer | a few cents | Yes (tiny) |

**Total ≈ $56/mo, dominated by the NAT Gateway.** The NAT Gateway only serves the *private* subnet,
which currently has no instances. **Biggest saving (~$45/mo):** delete the NAT Gateway, its Elastic
IP, and the private route (the VPN host is in the public subnet and doesn't need it). It's kept here
to model a realistic "public + private" VPC. **Always `terraform destroy` when you finish learning.**

---

## Destroy procedure

```bash
cd terraform
terraform destroy          # removes ALL AWS resources (force-destroys the S3 bucket too)
```

Then confirm nothing lingers (especially Elastic IPs, which bill when idle):

```bash
aws ec2 describe-addresses --region ap-south-1 --query 'length(Addresses)'        # 0
aws ec2 describe-nat-gateways --region ap-south-1 \
  --filter Name=state,Values=available --query 'length(NatGateways)'              # 0
```

Your local `vpn-clients/*.ovpn` files remain; `ovpn-admin.pem` is removed by destroy and regenerated
on the next `apply`.
