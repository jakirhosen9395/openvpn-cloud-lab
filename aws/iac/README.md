# OpenVPN on AWS — Terraform + Ansible (SSM-first, SSH break-glass)

A beginner-friendly, reproducible OpenVPN lab on AWS.

- **Terraform** builds the AWS infrastructure.
- **Ansible** installs and configures OpenVPN — connecting **over AWS SSM** (no SSH/SCP).
- **SSH** exists only as a **break-glass** path, locked to *your* auto-detected public IP.

The result: client profiles (`admin_user.ovpn`, etc.) are generated on the server and downloaded to
`vpn-clients/` on your machine — no manual steps.

---

## Before You Begin

New here? Read this section first — it is the **single source of truth** for getting an AWS account
ready, installing the right tools, and choosing where (which region) and how (which deployment mode)
to deploy. Everything below is written for a **brand-new user** and works in **any AWS region**, not
just the reference region `ap-south-1`.

Work through it in order:

1. **[AWS Account Prerequisites](#aws-account-prerequisites)** — the account, access, and permissions you need.
2. **[Terraform Prerequisites](#terraform-prerequisites)** — the software to install on your machine (the *control node*).
3. **[Supported AWS Regions](#supported-aws-regions)** — how region selection works and what to change.
4. **[Deployment Modes](#deployment-modes)** — VPN-Only (default, cheapest) vs Extended Networking.
5. **[Deploying To A Different AWS Region](#deploying-to-a-different-aws-region)** — the region-migration checklist.

> New to cloud networking terms like *VPC*, *Subnet*, *Route Table*, *Internet Gateway*, *NAT Gateway*,
> *Security Group*, or *CIDR*? Start with the cloud-agnostic primer in
> **[`../../docs/README.md` → Recommended Knowledge](../../docs/README.md#recommended-knowledge)** —
> we explain each concept once there instead of repeating it per cloud.

---

## AWS Account Prerequisites

You need an AWS account and a way to make programmatic (CLI/Terraform) calls into it.

**Required**

- **An AWS account.** Sign up at [aws.amazon.com](https://aws.amazon.com/). A brand-new account
  includes the 12-month Free Tier, which covers a `t3.micro` for many hours/month — handy for this lab.
- **Billing enabled (a valid payment method).** Even Free-Tier accounts must have billing active, and
  some resources here (Elastic IP, optional NAT Gateway) are **not** free — without billing, `apply`
  fails or resources are blocked.
- **An IAM user or role you can authenticate as** — *not* the account root user. The root user should
  be locked away; day-to-day work uses a least-privilege identity. *Why:* if credentials leak, an IAM
  identity can be disabled/rotated without losing the whole account.
- **Programmatic access (access keys) or SSO.** Terraform and the AWS CLI authenticate using either an
  access key + secret (via `aws configure`) or AWS IAM Identity Center (SSO). *Why:* Terraform talks to
  AWS APIs directly; it never uses the web console.
- **Permissions to create the resources in this lab.** The simplest choice for a **sandbox lab** is the
  AWS-managed `AdministratorAccess` policy (this is what the reference operator uses). *Why:* the stack
  spans VPC, EC2, EIP, IAM, S3, and SSM — a narrow policy is easy to get wrong while learning. If you
  must scope down, the identity needs create/describe/delete on: **EC2/VPC** (VPC, subnets, route
  tables, internet/NAT gateways, security groups, instances, key pairs, Elastic IPs, AMI describe),
  **IAM** (role, instance profile, policy attach — required for the SSM role), **S3** (the transfer
  bucket), and **SSM** (Session Manager).

**Strongly recommended (do these before real use)**

- **Enable MFA** on your IAM user and the root user. *Why:* a password or access key alone is one leak
  away from full control; MFA blocks most credential-theft attacks.
- **Use a separate sandbox/learning account.** *Why:* this is a learning project, not production — an
  isolated account contains mistakes (and surprise charges) and makes teardown a clean `destroy`.
- **Create a budget + billing alarm** in AWS Budgets. *Why:* the optional NAT Gateway and any
  forgotten Elastic IP bill hourly — an alarm emails you before a small lab becomes a surprise bill.
- **Turn on Cost Explorer.** *Why:* it shows *which* resource is costing money, so you can confirm a
  `destroy` actually removed everything (see [Estimated AWS Costs](#estimated-aws-costs)).

**Verify your access** (after installing the AWS CLI — see the next section):

```bash
aws sts get-caller-identity   # prints your Account, UserId, and ARN → confirms you are authenticated
```

---

## Terraform Prerequisites

These tools run on your **control node** — your laptop/workstation, *not* in AWS. Install each, then
run its verify command.

| Tool | Why this repo needs it | Verify command (expected) |
|---|---|---|
| **Terraform ≥ 1.10** | Builds all AWS infrastructure from `terraform/`. **1.10+** is required because `backend.tf` uses S3-native state locking (`use_lockfile`). | `terraform version` (≥ `v1.10.0`) |
| **AWS CLI v2** | Authenticates you (`aws configure`), and is used by the verify/validation commands throughout these docs. | `aws --version` (shows `aws-cli/2.x`) · `aws sts get-caller-identity` |
| **Git** | Clones this repository and keeps secrets out (`.gitignore` excludes `*.pem`, `*.ovpn`, state, `inventory.ini`). | `git --version` |
| **An SSH client** (`ssh`) | Break-glass access only. Terraform generates the key and writes `ovpn-admin.pem`; SSM is the primary path. | `ssh -V` |
| **Ansible** | Installs/configures OpenVPN and issues client profiles **over SSM** (no SSH in the normal path). | `ansible --version` |
| **`session-manager-plugin`** | Lets Ansible's `community.aws.aws_ssm` connection open SSM sessions to the instance. Put it on `PATH`: `export PATH="$HOME/.local/bin:$PATH"`. | `session-manager-plugin --version` |
| **Python `boto3` + `botocore`** | The AWS SDK the `aws_ssm` connection plugin uses under the hood. | `python3 -c "import boto3, botocore; print(boto3.__version__)"` |
| **Ansible collections** `community.aws` + `amazon.aws` | Provide the `aws_ssm` connection and AWS modules. | `ansible-galaxy collection list \| grep -E 'community.aws\|amazon.aws'` |

> One-time installs for the SSM toolchain:
> `python3 -m pip install --user boto3 botocore` and
> `ansible-galaxy collection install community.aws amazon.aws`. Install `session-manager-plugin` from
> the [AWS docs](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).

---

## Supported AWS Regions

This lab is written against the **reference region `ap-south-1` (Mumbai)** but is **deployable to ANY
AWS region** — nothing about OpenVPN is region-specific.

**How region selection works**

- The region is the **`region`** input variable (`terraform/variables.tf`, default `ap-south-1`),
  consumed by the AWS provider (`providers.tf`) and written into the generated Ansible inventory as
  `ansible_aws_ssm_region`.
- You set it in **`terraform/terraform.tfvars`** (`region = "..."`). That one value drives every
  region-scoped resource in `main.tf`.

**Where it is configured / which files may need updates**

- **`terraform/terraform.tfvars`** — set `region` to your target. **Also update `availability_zone`**
  in the same file: AZ names are *region-prefixed* (e.g. `ap-south-1a`, `us-east-1a`, `eu-west-1b`), so
  a region change **requires** a matching AZ or the subnets fail to create.
- **`terraform/backend.tf`** — ⚠️ **special case.** Terraform backend blocks **cannot use variables**,
  so the `region` and `bucket` here are **hardcoded**. If you use the S3 remote backend, edit these by
  hand to your own state bucket and its region. (For solo learning you can ignore the backend entirely
  — local state is fine.)
- **No AMI change needed.** `data.aws_ami.ubuntu` is a **dynamic Canonical lookup** (owner
  `099720109477`, `most_recent = true`), so it resolves the right Ubuntu 24.04 AMI **in whatever region
  you pick** — there is no hardcoded AMI ID to update.

**Other facts that vary by region**

- **AZ naming differs per region** (see above).
- **Pricing differs per region** — EC2, Elastic IP, NAT Gateway, and data transfer all vary; see
  [Estimated AWS Costs](#estimated-aws-costs) and [Regional Considerations](#regional-considerations).

**Examples** (any of these work — set `region` + a matching `availability_zone`):

| `region` | Example `availability_zone` | Location |
|---|---|---|
| `ap-south-1` | `ap-south-1a` | Mumbai (reference) |
| `us-east-1` | `us-east-1a` | N. Virginia |
| `us-west-2` | `us-west-2a` | Oregon |
| `eu-west-1` | `eu-west-1a` | Ireland |

See **[Deploying To A Different AWS Region](#deploying-to-a-different-aws-region)** for the full
migration checklist.

---

## Deployment Modes

This lab ships **two modes**, controlled by one variable: **`enable_private_networking`**
(`terraform/variables.tf`, **default `false`**). Set it in `terraform/terraform.tfvars`.

### Mode 1 — VPN Only (Default · `enable_private_networking = false`)

**What it builds:** VPC + **public** subnet + Internet Gateway + public route table + the OpenVPN EC2
host + its **Elastic IP** (plus the SSM IAM role and S3 transfer bucket).

- **Use cases:** a personal VPN, learning the basics, low-cost short-lived labs.
- **Advantages:** **lower cost** (no NAT Gateway), **faster deploy**, **faster destroy**, **simpler**
  to reason about. This is the recommended starting point.

### Mode 2 — Extended Networking (`enable_private_networking = true`)

**What it adds (on top of Mode 1):** a **private** subnet, a **NAT Gateway** + its **NAT Elastic IP**,
a **private route table** (default route → NAT), and a **private Security Group** (reachable from the
VPC CIDR and from VPN clients). In `main.tf` these resources are gated by `count = var.enable_private_networking ? 1 : 0`.

- **Use cases:** hosting **private workloads** reachable only over the VPN, **internal services**,
  and **networking labs** that model a real public+private VPC.
- **Advantages:** mirrors **real-world VPC design** (public edge + private back-end).
- **Disadvantages:** **higher cost** (the NAT Gateway is the priciest piece — see
  [Estimated AWS Costs](#estimated-aws-costs)), **more resources**, and **more complex cleanup**.

```hcl
# terraform/terraform.tfvars
enable_private_networking = false   # Mode 1 (default): VPN-only, cheapest
# enable_private_networking = true  # Mode 2: add private subnet + NAT gateway
```

---

## Deploying To A Different AWS Region

Moving off `ap-south-1` is a small, well-defined change. Walk this list before you `apply`.

**What must be checked**

- **Region setting** — set `region` in `terraform/terraform.tfvars`. If (and only if) you use the S3
  remote backend, also update the **hardcoded `region` and `bucket` in `terraform/backend.tf`** (backend
  blocks can't read variables).
- **AZ references** — set `availability_zone` to an AZ that exists in the new region (e.g.
  `us-east-1a`). A mismatched AZ is the most common region-migration failure.
- **AMI lookup behaviour** — **nothing to change.** `data.aws_ami.ubuntu` is a dynamic Canonical
  lookup and resolves automatically in the new region.
- **Pricing differences** — re-check costs; EC2, Elastic IP, NAT Gateway, and data-transfer rates all
  vary by region (see [Estimated AWS Costs](#estimated-aws-costs)).
- **Quotas/limits** — confirm the new region allows your instance type and has spare Elastic IP /
  VPC quota (new accounts often start at **5 Elastic IPs** per region).

**Validation checklist**

- [ ] Selected AWS region (`region` set in `terraform.tfvars`; `backend.tf` updated if using S3 backend)
- [ ] Region supports the instance type (`aws ec2 describe-instance-type-offerings --region <r> --filters Name=instance-type,Values=t3.micro`)
- [ ] Region supports Elastic IPs (all standard commercial regions do; confirm quota below)
- [ ] Region has available quota (Elastic IP / VPC headroom — see Service Quotas console)
- [ ] AMI lookup succeeds (`aws ec2 describe-images --region <r> --owners 099720109477 --filters 'Name=name,Values=ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*' --query 'length(Images)'` returns ≥ 1)

After updating the variables, run the usual `terraform fmt -recursive && terraform init && terraform
validate && terraform plan` and confirm `plan` shows the new region/AZ before `apply`.

---

## Estimated AWS Costs

This lab is intentionally low-cost, but it is **not entirely free**. **No fixed monthly dollar amounts
are quoted here** because pricing is not a single number — estimate yours with the official
**[AWS Pricing Calculator](https://calculator.aws/)** and confirm against **Cost Explorer** after deploy.

**Pricing varies by**

- **Region** — every rate below differs per region.
- **Instance type** — `t3.micro` (the default) is the cheapest practical choice; larger types cost more.
- **NAT Gateway usage** — Extended mode only; billed both **per hour** *and* **per GB processed**.
- **Data transfer** — egress and inter-AZ transfer rates vary by region and volume.
- **Elastic IP usage** — an EIP attached to a running instance is low/no cost; an **idle** EIP bills
  hourly (this is why teardown matters).

**Cost by resource type — VPN Only vs Extended**

| Resource type | VPN Only (default) | Extended (`enable_private_networking = true`) |
|---|:---:|:---:|
| **EC2 instance** (`t3.micro`, Free-Tier eligible for the first 12 months) | ✅ | ✅ |
| **Elastic IP** (server endpoint) | ✅ | ✅ |
| **VPC networking** (subnet, IGW, route table, SG) | ✅ | ✅ |
| **EBS** (8 GB gp3 root) + near-zero **S3** | ✅ | ✅ |
| **NAT Gateway** (per-hour **+** per-GB processed — the dominant cost) | — | ✅ |
| **NAT Elastic IP** | — | ✅ |
| **Data processing / transfer** (through the NAT Gateway) | — | ✅ |

**VPN Only** bills only for the always-on EC2 instance, its Elastic IP, and the tiny EBS/VPC/S3
footprint. **Extended** adds the NAT Gateway, its NAT Elastic IP, and data-processing/transfer charges
on top — the NAT Gateway being by far the biggest line item.

**How to estimate**

1. Open the [AWS Pricing Calculator](https://calculator.aws/), pick **your region**, and add: 1×
   EC2 `t3.micro`, 1× Elastic IP, 8 GB gp3 EBS — and, for Extended mode, 1× NAT Gateway with an
   estimated GB/month.
2. After `apply`, watch **Cost Explorer** (grouped by service) for a day to see the real run-rate.

> The single biggest lever: **Extended mode's NAT Gateway**. If you only need a VPN, stay in **VPN
> Only mode**. Always `terraform destroy` when you finish — an idle Elastic IP or a forgotten NAT
> Gateway keeps billing.

---

## Regional Considerations

Things that genuinely differ from one region to another:

- **Instance-type availability** — not every region/AZ offers every instance type. Verify `t3.micro`
  (or your chosen type) is offered before deploying.
- **AZ naming differences** — AZ IDs are region-prefixed (`<region>a`, `<region>b`, …); your
  `availability_zone` must match the selected `region`.
- **Service quotas** — VPC, Elastic IP, and instance quotas are **per-region**; a fresh region starts
  at default limits even if another region has headroom.
- **Elastic IP quotas** — new accounts commonly allow **5 Elastic IPs per region**; Extended mode uses
  **two** EIPs (server + NAT), so plan accordingly.
- **NAT Gateway pricing differences** — both the hourly and per-GB rates vary by region.
- **Data-transfer pricing differences** — egress and inter-AZ transfer rates vary by region.

---

## Region-Specific Troubleshooting

| Issue | Symptoms | Root cause | Resolution |
|---|---|---|---|
| **AMI lookup fails** | `apply`/`plan` errors with "no AMI found" or an empty `data.aws_ami.ubuntu` | The Canonical Ubuntu 24.04 name filter matched nothing in this region (rare), or the `region` isn't actually set as expected | Re-run the describe-images check in the [region checklist](#deploying-to-a-different-aws-region); confirm `region` in `terraform.tfvars` and that your CLI region matches |
| **Instance type unavailable** | EC2 launch fails: "Unsupported" / "not available in this AZ" | `t3.micro` (or your type) isn't offered in the chosen region/AZ | Pick a supported type, or change `availability_zone`/`region`. Check with `aws ec2 describe-instance-type-offerings --region <r> --filters Name=instance-type,Values=t3.micro` |
| **Insufficient Elastic IP quota** | "AddressLimitExceeded" when creating the server or NAT EIP | The region's Elastic IP quota (often 5) is exhausted — Extended mode needs **2** EIPs | Release unused EIPs (`aws ec2 describe-addresses --region <r>`), or request a quota increase in **Service Quotas → EC2 → EC2-VPC Elastic IPs** |
| **AZ not found** | Subnet creation fails: "invalid availability zone" | `availability_zone` doesn't exist in the selected `region` (e.g. `ap-south-1a` left behind after switching to `us-east-1`) | Set `availability_zone` to a valid AZ for the new region (`aws ec2 describe-availability-zones --region <r>`) |
| **Service quota exceeded** | "VpcLimitExceeded", "AddressLimitExceeded", or similar limit errors | A per-region quota (VPC, EIP, instances) is at its cap | Delete unused resources, or raise the limit in the **Service Quotas** console for that region |

---

## Architecture

The diagram shows **both modes**. Solid boxes are the default (**VPN Only**, `enable_private_networking
= false`); the dashed **(optional)** block — private subnet, NAT Gateway, NAT EIP, private route table
— exists **only in Extended mode** (`enable_private_networking = true`).

```
   Your machine (control node)                     AWS  (any region)
 ┌──────────────────────────┐              ┌─────────────────────────────────────--─┐
 │ terraform → builds infra │              │  VPC 10.0.0.0/16                       │
 │ ansible   → over SSM     │  HTTPS 443   │  ┌─────────────── public 10.0.1.0/24 ─┐│
 │ aws_ssm connection ──────┼──────────────┼─▶│ OpenVPN EC2 (Ubuntu 24.04)         ││
 │ vpn-clients/*.ovpn ◀─────┼─ S3 transfer ┼──│  EIP · UDP 1194 · SSM agent        ││
 │                          │              │  │  tun0 10.8.0.0/24 · MASQUERADE     ││
 │ ovpn-admin.pem (SSH)    ·┼·· TCP 22 ····┼··│  (break-glass, your IP only)       ││
 └──────────────────────────┘              │  └──────────────────┬─────────────────┘│
                                           │ IGW ◀─ public RT   ┊ NAT GW (optional) ┊
                                           │ ┌┄┄┄┄┄┄┄┄┄┄┄ private 10.0.2.0/24 ┄┄┄┐  ┊
                                           │ ┊ (optional · enable_private_       ┊  ┊
                                           │ ┊  networking=true) NAT + priv RT ──┼─▶┊
                                           │ └┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┘  ┊
                                           └──────  ────────────────────────────────┘
   VPN clients ── UDP 1194 ─▶ EIP ─▶ OpenVPN ─▶ tun 10.8.0.0/24 ─▶ internet / VPC
```

> Optional: the private subnet, NAT Gateway, NAT EIP, and private route table are only created when
> `enable_private_networking = true` (Extended mode). The default VPN-Only build omits them.

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

## Cost considerations

See **[Estimated AWS Costs](#estimated-aws-costs)** — the single authoritative cost section. It breaks
costs down **by resource type** for **VPN Only** vs **Extended** mode, lists what *varies by* (region,
instance type, NAT Gateway usage, data transfer, Elastic IP usage), and points to the AWS Pricing
Calculator. The one-line summary: the **NAT Gateway** (Extended mode only) is the dominant cost, so a
VPN-only lab is the cheapest path. **Always `terraform destroy` when you finish learning.**

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
