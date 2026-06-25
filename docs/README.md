# Shared concepts

Cloud-agnostic background that applies to every setup in this repo:

- **PKI & certificates** — CA, server/client certs, `tls-crypt`
- **OpenVPN server config** — `server.conf`, ciphers, pushed routes/DNS
- **Networking** — IP forwarding, NAT/MASQUERADE, routing, full vs split tunnel
- **Client profiles** — building `.ovpn` files and importing into OpenVPN Connect

> 🚧 Being filled in.

---

## Recommended Knowledge

A short, beginner-friendly primer on the cloud-networking building blocks this lab uses. These terms
are **cloud-agnostic** (AWS calls some of them slightly different names, but the ideas are the same).
Read this once; the per-cloud guides link here instead of re-explaining.

- **CIDR (e.g. `10.0.0.0/16`)** — a compact way to write a *range* of IP addresses. The number after
  the `/` says how many bits are fixed: a smaller number = a **bigger** range. `/16` ≈ 65,536
  addresses (a whole network); `/24` ≈ 256 (one subnet); `/32` = exactly **one** address (used here to
  lock SSH to your IP). You'll pick CIDRs for the VPC, each subnet, and the VPN tunnel.

- **VPC (Virtual Private Cloud)** — your own **private, isolated network** inside the cloud, defined by
  a CIDR (here `10.0.0.0/16`). Everything else (subnets, gateways, servers) lives **inside** the VPC.
  Think of it as the fenced plot of land on which you build.

- **Subnet** — a **slice** of the VPC's address range (a smaller CIDR like `10.0.1.0/24`). A **public**
  subnet can reach the internet directly (it routes to an Internet Gateway); a **private** subnet
  cannot, and reaches out only via a NAT Gateway. The OpenVPN server sits in the **public** subnet. The
  **private** subnet is **optional** — only created in Extended mode (`enable_private_networking = true`).

- **Route Table** — the **rulebook** that decides where network traffic goes. Each subnet is associated
  with a route table; a rule like "send `0.0.0.0/0` (everything) to the Internet Gateway" is what makes
  a subnet *public*. A **private route table** (routing `0.0.0.0/0` to a NAT Gateway) is **optional** —
  only created in Extended mode (`enable_private_networking = true`) alongside the private subnet.

- **Internet Gateway (IGW)** — the **doorway between your VPC and the public internet**. Attached to the
  VPC; the public route table points at it so public-subnet resources can send and receive internet
  traffic (and so VPN clients can reach the server's public IP).

- **NAT Gateway** — a **one-way door out** for private-subnet resources: it lets them make *outbound*
  internet connections (e.g. to download updates) **without** being reachable from the internet. It is
  the **most expensive** piece in this lab and is **only created in Extended mode** — a VPN-only setup
  doesn't need it.

- **Security Group** — a **virtual firewall** attached to a resource (like the EC2 instance). It lists
  the inbound/outbound traffic that is **allowed** (default-deny otherwise). Here it permits UDP 1194
  for VPN clients and SSH (port 22) **only from your detected IP**.

> Want to see how these map to real resources? The AWS guide builds each one:
> **[`../aws/iac/README.md`](../aws/iac/README.md)**.
