# AWS — OpenVPN

Two ways to run OpenVPN on AWS — both produce the same working server + a `.ovpn` client profile:

- **[`iac/`](iac/)** — automated with **Terraform + Ansible** (SSM-first, break-glass SSH). Start here.
- **[`manual/`](manual/)** — 🚧 coming soon: step-by-step console + shell guide.

Full automated workflow: see **[`iac/README.md`](iac/README.md)**.

## Before You Begin

First time here? The IaC guide has the full onboarding hub — **AWS account prerequisites, required
tools, region selection, and deployment modes** — written for a brand-new user:
**[`iac/README.md` → Before You Begin](iac/README.md#before-you-begin)**. For beginner explanations of
VPC, Subnet, Route Table, Internet/NAT Gateway, Security Group, and CIDR, see
**[`../docs/README.md` → Recommended Knowledge](../docs/README.md#recommended-knowledge)**.

**Deployment modes:** **VPN Only** (default, `enable_private_networking = false`) builds a public VPC +
the OpenVPN server + an Elastic IP (cheapest, fastest). **Extended Networking**
(`enable_private_networking = true`) adds a private subnet + NAT Gateway + NAT EIP + private route table
to model a full public+private VPC (higher cost). Toggle it with one variable —
**[`iac/README.md` → Deployment Modes](iac/README.md#deployment-modes)**.

> Optional: the private subnet, NAT Gateway, NAT EIP, and private route table are only created when
> `enable_private_networking = true`.

**Costs:** pricing varies by region and usage, so no fixed monthly figure is quoted — see the single
authoritative breakdown in **[`iac/README.md` → Estimated AWS Costs](iac/README.md#estimated-aws-costs)**.

**Region:** the reference region is `ap-south-1`, but you can deploy to **any** AWS region — see
**[Supported AWS Regions](iac/README.md#supported-aws-regions)** and
**[Deploying To A Different AWS Region](iac/README.md#deploying-to-a-different-aws-region)**.
