# 🔒 openvpn-cloud-lab

> Spin up your own **OpenVPN** server on any major cloud — the **manual** way *or* fully **automated**.

![Clouds](https://img.shields.io/badge/clouds-AWS%20%7C%20Azure%20%7C%20GCP-FF9900)
![VPN](https://img.shields.io/badge/VPN-OpenVPN%202.6-EA7E20)
![IaC](https://img.shields.io/badge/IaC-Terraform%20%2B%20Ansible-7B42BC)
![Setup](https://img.shields.io/badge/setup-manual%20%2B%20automated-2EA44F)
![Access](https://img.shields.io/badge/access-SSM--first%20%2B%20break--glass%20SSH-1D4ED8)
![License](https://img.shields.io/badge/license-MIT-blue)

## About this lab

**openvpn-cloud-lab** is a hands-on project for learning how a real VPN server is built and run in
the cloud. You stand up your own [OpenVPN](https://openvpn.net/) server, connect from your laptop or
phone, and route traffic through it — while learning the networking and automation underneath.

Every cloud offers **two paths to the same result**, so you choose how deep to go:

- **Manual** — do it by hand in the cloud console and a Linux shell. The *tutorial* path: create each
  piece yourself and see how it fits together.
- **Automated (IaC)** — reproduce the whole thing with **Terraform + Ansible** in a couple of
  commands. The *engineering* path: version-controlled, repeatable, disposable.

It's written for **beginners** — short steps, plain commands, heavy comments, *understanding over
cleverness* — with **low-cost** defaults and the expensive bits clearly flagged.

> ⚠️ **Learning project, not production.** Harden it (MFA, monitoring, HA, secrets management) before
> trusting it with anything real.

**What you'll learn:** cloud networking (VPC/VNet, subnets, internet & NAT gateways, routes) ·
firewalls / security groups · VPN internals (PKI, certs, IP forwarding, NAT, client profiles) ·
**Terraform** + **Ansible** · secure remote management without exposed SSH (e.g. **AWS SSM**) · cost
awareness and clean teardown.

## What's inside

| Cloud | Manual guide | Terraform + Ansible | Status |
|-------|:---:|:---:|--------|
| **[AWS](aws/)**   | 🚧 | ✅ | Stable |
| **[Azure](azure/)** | 🚧 | 🚧 | Planned |
| **[GCP](gcp/)**   | 🚧 | 🚧 | Planned |

```text
openvpn-cloud-lab/
├── aws/
│   ├── iac/        # Terraform + Ansible (stable)  →  terraform/  ansible/  vpn-clients/
│   ├── manual/     # step-by-step console + shell guide (planned)
│   └── extras/     # standalone scripts (e.g. EC2 dashboard) — not part of the VPN
├── azure/          # planned
├── gcp/            # planned
└── docs/           # shared, cloud-agnostic concepts (PKI, routing, NAT, clients)
```

## Prerequisites

**For everyone**

- A **cloud account** with permission to create networking + a small VM *(AWS today; Azure & GCP planned)*.
- A workstation with a **terminal** and **git**.
- An **OpenVPN client** to test: [OpenVPN Connect](https://openvpn.net/client/) or the `openvpn` CLI.
- Comfort with a Linux shell helps but isn't required — the manual guide explains each command.

**Manual path:** just the cloud **web console** + its browser shell (CloudShell / Cloud Shell) or SSH.

**Automated (IaC) path:**

- **Terraform ≥ 1.10**, the **cloud CLI** authenticated (`aws` / `az` / `gcloud`), and **Ansible**.
- **AWS only (SSH-free SSM management):** the **Session Manager plugin**, Python **`boto3`**, and the
  **`community.aws`** + **`amazon.aws`** Ansible collections (one-time install; see the AWS guide).

> 💸 **Cost heads-up:** a VPN needs a small **always-on VM** + a **stable public IP**; the AWS IaC
> path also creates a **NAT Gateway** (the priciest piece — optional, and flagged in the docs).
> Budget a few dollars a month and **always tear down when you're done**.

## Quick start (AWS, automated)

```bash
cd aws/iac/terraform && terraform init && terraform apply
cd ../ansible && export PATH="$HOME/.local/bin:$PATH"
ansible-playbook -i inventory.ini playbook.yml      # → your profile in aws/iac/vpn-clients/
```

Full details: **[`aws/iac/README.md`](aws/iac/README.md)** · day-2 ops: **[`aws/iac/ANSIBLE_HANDOFF.md`](aws/iac/ANSIBLE_HANDOFF.md)**.
Prefer to learn the internals first? **[`aws/manual/`](aws/manual/)** (coming soon).

## License

MIT — see `LICENSE`. *(Add a `LICENSE` file, or change this badge/section to your preference.)*
