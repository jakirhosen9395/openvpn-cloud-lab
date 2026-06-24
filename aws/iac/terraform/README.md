# terraform/

AWS infrastructure for the OpenVPN lab. **Start with the top-level [`../README.md`](../README.md)** —
it has the architecture, full workflow, cost, and destroy steps. This folder is just the Terraform.

## Files

| File | Purpose |
|------|---------|
| `versions.tf` | Terraform `>= 1.10` + provider pins (`aws`, `local`, `http`, `tls`) |
| `providers.tf` | AWS provider (region `ap-south-1`, default tags) |
| `backend.tf` | S3 remote state (`use_lockfile`, encrypted) |
| `variables.tf` | Inputs (region, CIDRs, `project_name`, `environment`, `ssh_key_name`, …) — **no** `admin_ip` |
| `terraform.tfvars` | Values for this lab |
| `locals.tf` | Names, tags, and the **auto-detected admin IP** |
| `main.tf` | All resources: VPC, subnets, IGW, NAT, route tables, security groups, IAM/SSM, S3 transfer bucket, generated SSH key pair, EC2, EIP; also writes `../ansible/inventory.ini` |
| `outputs.tf` | Beginner-friendly outputs (below) |

## Commands

```bash
terraform init
terraform validate
terraform plan      # detected_admin_ip = your current public IP
terraform apply     # builds infra + writes ../ovpn-admin.pem + ../ansible/inventory.ini
terraform destroy   # tears everything down (also removes ../ovpn-admin.pem)
```

## Key things to know

- **SSH key:** Terraform **generates** it (`tls_private_key`) and saves `../ovpn-admin.pem` (repo
  root, chmod 600) — no manual `ssh-keygen`. `*.pem` is git-ignored. A fresh `apply` makes a new key.
- **Admin IP:** auto-detected via the `http` provider (`checkip.amazonaws.com`) → SSH is locked to
  your `/32`. If your IP changes, re-run `terraform apply`. Output: `detected_admin_ip`.
- **Access:** SSM is primary (`ssm_command`); SSH (`ssh_command`, uses `ovpn-admin.pem`) is
  break-glass only, allowed from your detected IP.
- **Outputs:** `detected_admin_ip`, `vpn_server_public_ip`, `vpn_server_private_ip`,
  `vpn_server_instance_id`, `ssm_command`, `ssh_command`, `ssh_private_key_path`,
  `ssm_transfer_bucket`, `ansible_inventory_entry`.
