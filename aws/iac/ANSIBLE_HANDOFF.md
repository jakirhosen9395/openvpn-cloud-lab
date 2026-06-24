# Ansible Handoff — OpenVPN on AWS (SSM-first)

Day-2 operations guide. **Terraform builds the servers; Ansible configures them.** Ansible connects
**over AWS SSM** — there is no SSH or SCP in the normal workflow. This guide assumes you have never
used Ansible before.

> All values below come from `terraform output`, so they stay correct after every redeploy. Run
> commands from the repo unless noted. First, always: `export PATH="$HOME/.local/bin:$PATH"` (so
> Ansible can find `session-manager-plugin`).

---

## 1. Terraform outputs (your source of truth)

```bash
terraform -chdir=terraform output            # show everything
terraform -chdir=terraform output -raw vpn_server_public_ip
```

| Output | Meaning |
|---|---|
| `detected_admin_ip` | The public IP Terraform detected and allowed for SSH |
| `vpn_server_public_ip` | VPN server's public/Elastic IP (clients connect here) |
| `vpn_server_private_ip` | VPN server's private IP inside the VPC |
| `vpn_server_instance_id` | EC2 id — the SSM target and Ansible host |
| `ssm_command` | One-line command to open a shell over SSM |
| `ssh_command` | Break-glass SSH command |
| `ssh_private_key_path` / `ssh_public_key_path` | Your local SSH key files |
| `ssm_transfer_bucket` | S3 bucket Ansible uses to move files (no SCP) |

Terraform also **writes `ansible/inventory.ini`** for you (the SSM connection details). You never
edit it by hand.

---

## 2. SSM workflow (primary — how Ansible connects)

SSM is an AWS service that runs commands on the instance through the SSM agent (over HTTPS 443). No
open ports, works from any network.

```bash
cd ansible
export PATH="$HOME/.local/bin:$PATH"

ansible -i inventory.ini openvpn -m ping                 # "pong" = SSM works
ansible-playbook -i inventory.ini playbook.yml           # install + configure OpenVPN, make admin_user.ovpn
ansible -i inventory.ini openvpn -b -m shell \
  -a 'systemctl status openvpn-server@server'            # ad-hoc command (-b = become root)
```

Interactive shell (debugging): `aws ssm start-session --target <instance-id> --region ap-south-1`.

---

## 3. VPN user workflow

Create a user and download their profile (over SSM, no SSH):

```bash
cd ansible && export PATH="$HOME/.local/bin:$PATH"
ansible-playbook create-user.yml -e vpn_user=alice
# → builds certs on the server, then downloads vpn-clients/alice.ovpn locally
```

Import `vpn-clients/alice.ovpn` into **OpenVPN Connect**, or `sudo openvpn --config vpn-clients/alice.ovpn`.

---

## 4. SSH workflow (break-glass only)

For emergencies/troubleshooting when SSM is unavailable:

```bash
terraform -chdir=terraform output -raw ssh_command       # includes the generated .pem path
ssh -i ovpn-admin.pem ubuntu@$(terraform -chdir=terraform output -raw vpn_server_public_ip)
sudo -i                                                  # become root
```

SSH only allows your **detected public IP**. If your IP changed, see Recovery (§6).

---

## 5. Key management workflow

- **Terraform generates the key** — no `ssh-keygen` needed. On `apply` it creates the key pair and
  writes the private key to **`ovpn-admin.pem`** in the repo root (chmod 600). AWS stores only the
  public key; EC2 installs it into the server's `authorized_keys`.
- **`ovpn-admin.pem` is git-ignored** (`*.pem`) — keep it safe, never commit it.
- `terraform destroy` removes the **AWS key pair AND the local `ovpn-admin.pem`**. The next fresh
  `apply` generates a **new** key (new `.pem`), so use the new file after a rebuild.

---

## 6. Recovery procedures

| Problem | Recovery |
|---|---|
| **SSH stopped working after changing network/ISP/travel** | `cd terraform && terraform apply` — re-detects your new IP and updates the SSH rule. |
| **SSM shows not connected** | `aws ssm describe-instance-information --region ap-south-1` should list the instance as `Online`; wait 1–3 min after apply; confirm the IAM instance profile is attached. |
| **`session-manager-plugin not found`** | Install it and `export PATH="$HOME/.local/bin:$PATH"`. |
| **`boto3` import error** | `python3 -m pip install --user boto3 botocore`. |
| **Old `.ovpn` won't connect after a rebuild** | A rebuild creates a new CA; regenerate: `ansible-playbook -i inventory.ini playbook.yml` (admin_user) or `create-user.yml -e vpn_user=<name>`. |
| **Lost the whole environment** | `terraform apply` then `ansible-playbook -i inventory.ini playbook.yml` rebuilds everything; profiles are regenerated into `vpn-clients/`. |

---

## Quick reference (whole flow)

```bash
cd terraform && terraform apply
cd ../ansible && export PATH="$HOME/.local/bin:$PATH"
ansible-playbook -i inventory.ini playbook.yml          # server + admin_user.ovpn
ansible-playbook create-user.yml -e vpn_user=alice      # extra users
# profiles → ../vpn-clients/*.ovpn
cd ../terraform && terraform destroy                    # when finished (stops billing)
```
