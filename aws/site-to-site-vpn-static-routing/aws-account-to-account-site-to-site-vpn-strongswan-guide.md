# AWS Account-to-Account Site-to-Site VPN with StrongSwan

## 1. Purpose

This document describes a site-to-site IPsec VPN between two separate AWS accounts/VPCs.

The recommended architecture is:

- **Account A** acts as the on-premises side.
- **Account A** runs **StrongSwan on an EC2 instance** as the Customer Gateway (CGW) device.
- **Account B** uses an **AWS Virtual Private Gateway (VGW)** and AWS Site-to-Site VPN.
- Routing is **static**, not BGP.
- Only the required private CIDRs are sent through the VPN.
- No NAT is performed for VPN traffic.

AWS officially supports a customer gateway as a physical or software appliance and supports static routing when BGP is not used. The AWS VPN connection provides two IPsec tunnels for redundancy.  
References:
- https://docs.aws.amazon.com/vpn/latest/s2svpn/SetUpVPNConnections.html
- https://docs.aws.amazon.com/vpn/latest/s2svpn/vpn-static-dynamic.html

---

# 2. VPC DESIGN

Network VPC Design:

| Network | CIDR |
|---|---|
| Account A VPC | `11.11.0.0/16` |
| Account A public subnet | `11.11.1.0/24` |
| Account A private subnet | `11.11.2.0/24` |
| Account B VPC | `12.12.0.0/16` |
| Account B public subnet | `12.12.1.0/24` |
| Account B private subnet | `12.12.2.0/24` |

Do not use overlapping CIDRs.

---

# 3. Final Recommended Architecture

```text
                         INTERNET
                             |
                +------------+------------+
                |                         |
             Account A                 AWS VPN
          "On-Premises"                  |
                |                         |
       Public IP on StrongSwan            |
                |                         |
      +---------+----------+              |                 +----------+-+----------+
      | Account A VPC      |              |                 | Account B             |
      | 11.11.0.0/16       |              |                 | 12.12.0.0/16          |
      |                    |              |                 |                       |
      | 11.11.1.0/24       |              |                 | Virtual Private       |
      | Public Subnet      |              |                 | Gateway (VGW)         |
      |                    |              |                 | 12.12.1.0/24          |
      |  A-VPN-EC2         |+=============|=============+   |                       |
      |  StrongSwan        |    IPsec Tunnel #1             | Public Subnet         |
      |                    |+=============|=============+   | B-Public-EC2          |
      |                    |    IPsec Tunnel #2             |                       |
      |                    |                                |                       |
      |  11.11.2.0/24      |                                | 12.12.2.0/24          |
      |  Private Subnet    |                                | Private Subnet        |
      |  A-Private-EC2     |                                | B-Private-EC2         |
      +--------------------+                                +-----------------------+
 
```

### Important

For this architecture, **do not install StrongSwan on Account B**.

Account B's AWS managed VPN endpoint is provided by AWS through the **Virtual Private Gateway**.

StrongSwan is installed only on the Account A VPN EC2 instance.

If StrongSwan is installed on both Account A and Account B, that becomes a different design: an EC2-to-EC2 IPsec VPN. It is not necessary for the AWS VGW design described here.

---

# 4. Components

## Account A

| Component | Value |
|---|---|
| VPC | `11.11.0.0/16` |
| Public subnet | `11.11.1.0/24` |
| Private subnet | `11.11.2.0/24` |
| Internet Gateway | `pub-igw` |
| Public route table | `a-pub-rtb` |
| Private route table | `a-pvt-rtb` |
| VPN instance | `a-pub-ec2` |
| VPN software | StrongSwan |
| Application instance | `a-pvt-ec2` |
| VPN instance role | Customer Gateway device |

## Account B

| Component | Value |
|---|---|
| VPC | `12.12.0.0/16` |
| Public subnet | `12.12.1.0/24` |
| Private subnet | `12.12.2.0/24` |
| Internet Gateway | `pub-igw` |
| Public route table | `b-pub-rtb` |
| Private route table | `b-pvt-rtb` |
| Public test instance | `b-pub-ec2` |
| Private application instance | `b-pvt-ec2` |
| VPN gateway | AWS VGW |
| VPN type | AWS Site-to-Site VPN |
| Routing | Static |

---

# 5. Traffic Flow

## Account A -> Account B

Example:

```text
A-Private-EC2
11.11.2.x
    |
    | destination = 12.12.2.x
    v
a-pvt-rtb
    |
    | 12.12.0.0/16 -> A-VPN-EC2
    v
StrongSwan
    |
    | IPsec
    v
AWS VGW
    |
    v
b-pvt-rtb
    |
    v
B-Private-EC2
12.12.2.x
```

## Account B -> Account A

```text
B-Private-EC2
12.12.2.x
    |
    | destination = 11.11.2.x
    v
b-pvt-rtb
    |
    | 11.11.0.0/16 -> VGW
    v
AWS VGW
    |
    | IPsec
    v
StrongSwan
    |
    v
a-pvt-rtb
    |
    v
A-Private-EC2
11.11.2.x
```

---

# 6. AWS Routing Model

This is the most important part of the configuration.

## Account A

The private subnet route table must send Account B traffic to the StrongSwan EC2 instance.

### `a-pvt-rtb`

```text
Destination       Target
-----------------------------------------
11.11.0.0/16     local
12.12.0.0/16      A-VPN-EC2 ENI
```

Do NOT point `12.12.0.0/16` directly to the Internet Gateway.

The VPN EC2 is the router.

AWS requires source/destination checking to be disabled when an EC2 instance is acting as a router, NAT device, or firewall.

Reference:
https://docs.aws.amazon.com/vpc/latest/userguide/work-with-nat-instances.html

---

# 7. Account A Public Route Table

### `a-pub-rtb`

```text
Destination       Target
-----------------------------------------
11.11.0.0/16     local
0.0.0.0/0        pub-igw
```

The StrongSwan EC2 needs Internet connectivity because the AWS VPN tunnel endpoints are public.

The StrongSwan instance should have:

- Private IP in `11.11.1.0/24`
- Elastic IP
- Public subnet
- Route to Internet Gateway

---

# 8. Account B Private Route Table

The AWS VGW is the endpoint for the VPN.

### `b-pvt-rtb`

```text
Destination       Target
-----------------------------------------
12.12.0.0/16     local
11.11.0.0/16     VGW
```

The target will be the VGW, for example:

```text
vgw-xxxxxxxx
```

You can either:

1. Enable VGW route propagation, or
2. Add the static route manually.

For a small lab, manual static routes are often easier to understand.

AWS documents both methods:
https://docs.aws.amazon.com/vpn/latest/s2svpn/SetUpVPNConnections.html

---

# 9. Account B Public Route Table

If `b-pub-ec2` must communicate with Account A private resources, add:

```text
Destination       Target
-----------------------------------------
12.12.0.0/16     local
11.11.0.0/16     VGW
0.0.0.0/0        pub-igw
```

If the public instance does not need VPN access, the `11.11.0.0/16 -> VGW` route is not required for that subnet.

---

# 10. Security Groups

Security groups are stateful, so return traffic for an allowed connection is automatically permitted.

## Account A VPN Security Group

Recommended minimum rules:

### Inbound

```text
SSH
TCP 22
Source: YOUR_ADMIN_IP/32

IKE
UDP 500
Source: 0.0.0.0/0

NAT-T
UDP 4500
Source: 0.0.0.0/0

ESP
Protocol 50
Source: 0.0.0.0/0
```

For AWS VPN with NAT traversal, UDP 4500 is particularly important.

Do not expose SSH to the whole Internet.

### Outbound

For initial testing:

```text
All traffic
0.0.0.0/0
```

After the tunnel works, tighten the policy according to your security requirements.

---

# 11. Account A Private Application Security Group

Example:

```text
Inbound:
TCP 22
Source: Account B application SG or 12.12.0.0/16

ICMP
Source: 12.12.0.0/16
```

For production, avoid allowing the entire `/16` if only one application subnet or security group is required.

---

# 12. Account B Private Application Security Group

Example:

```text
Inbound:
TCP 22
Source: 11.11.0.0/16

ICMP
Source: 11.11.0.0/16
```

Again, narrow this later to only the required subnet/SG.

---

# 13. Create Account A VPN EC2

Launch an Ubuntu LTS EC2 instance.

Recommended for a lab:

```text
OS: Ubuntu LTS
Subnet: a-pub-sub
Private IP: 11.11.1.x
Public IP: Elastic IP
Security Group: a-vpn-sg
```

Enable IP forwarding.

---

# 14. Disable Source/Destination Check

This is mandatory for the VPN EC2 because it forwards traffic between the private subnet and the VPN.

AWS CLI:

```bash
aws ec2 modify-instance-attribute \
  --instance-id <A_VPN_INSTANCE_ID> \
  --no-source-dest-check
```

Verify:

```bash
aws ec2 describe-instance-attribute \
  --instance-id <A_VPN_INSTANCE_ID> \
  --attribute sourceDestCheck
```

Expected:

```json
{
    "SourceDestCheck": {
        "Value": false
    }
}
```

AWS documentation:
https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_ModifyNetworkInterfaceAttribute.html

---

# 15. Configure Linux IP Forwarding

Edit:

```bash
sudo vim /etc/sysctl.conf
```

Ensure:

```text
net.ipv4.ip_forward = 1
```

Apply:

```bash
sudo sysctl -p
```

Verify:

```bash
sysctl net.ipv4.ip_forward
```

Expected:

```text
net.ipv4.ip_forward = 1
```

Also check:

```bash
cat /proc/sys/net/ipv4/ip_forward
```

Expected:

```text
1
```

---

# 16. Install StrongSwan

Update Ubuntu:

```bash
sudo apt update
sudo apt upgrade -y
```

Install:

```bash
sudo apt install -y \
  strongswan \
  strongswan-starter \
  strongswan-swanctl \
  libcharon-extra-plugins \
  iproute2 \
  iptables \
  tcpdump \
  net-tools
```

Check:

```bash
ipsec version
```

Check services:

```bash
systemctl list-units --type=service | grep -i strong
```

Depending on the Ubuntu/StrongSwan package version, the service may appear as:

```text
strongswan-starter.service
```

or the package may use another service arrangement.

Do not assume the service name until you verify it.

---

# 17. Do NOT Start by Writing a Custom AWS `ipsec.conf`

This is one of the main lessons from the previous troubleshooting.

The AWS Site-to-Site VPN configuration contains AWS-specific:

- tunnel endpoint addresses
- inside tunnel addresses
- encryption proposals
- DH groups
- lifetimes
- PSK
- traffic selectors
- tunnel-specific parameters

Therefore, after creating the AWS VPN connection, download the configuration provided by AWS for:

```text
Vendor: strongSwan
Platform: Ubuntu/Debian
Version: select the closest supported version
```

Use the AWS-generated configuration as the baseline.

AWS documentation:
https://docs.aws.amazon.com/vpn/latest/s2svpn/SetUpVPNConnections.html

---

# 18. Create the AWS VPN Objects in Account B

The order should be:

```text
1. Create VGW
2. Attach VGW to Account B VPC
3. Create Customer Gateway
4. Create Site-to-Site VPN connection
5. Select VGW as target
6. Select Customer Gateway
7. Select Static routing
8. Enter Account A network CIDR
9. Download StrongSwan configuration
```

---

# 19. Create Virtual Private Gateway

In Account B:

```text
VPC
  -> Virtual Private Gateways
  -> Create virtual private gateway
```

Example name:

```text
b-vgw
```

Attach it to:

```text
12.12.0.0/16
```

---

# 20. Create Customer Gateway

The Customer Gateway represents the StrongSwan VPN server in Account A.

Use:

```text
Routing:
Static

IP address:
<A-VPN-EC2-ELASTIC-IP>
```

Example:

```text
Customer Gateway:
a-strongswan-cgw

IP:
<ELASTIC_IP_OF_A_VPN_EC2>

Routing:
Static
```

AWS requires an internet-routable static IP for the customer gateway device. If the device is behind NAT, AWS uses the NAT public IP and UDP 500/4500 must be reachable.

Reference:
https://docs.aws.amazon.com/vpn/latest/s2svpn/cgw-options.html

---

# 21. Create Site-to-Site VPN Connection

In Account B:

```text
VPC
 -> Site-to-Site VPN Connections
 -> Create VPN connection
```

Use:

```text
Name:
a-to-b-vpn

Target gateway type:
Virtual Private Gateway

Virtual private gateway:
b-vgw

Customer gateway:
Existing

Customer gateway:
a-strongswan-cgw

Routing:
Static
```

Add the Account A network:

```text
11.11.0.0/16
```

This tells AWS:

```text
To reach 11.11.0.0/16,
send traffic through this VPN connection.
```

---

# 22. VPN Tunnel Options

AWS creates two tunnels.

Conceptually:

```text
StrongSwan
    |
    +---- Tunnel 1 ---- VGW
    |
    +---- Tunnel 2 ---- VGW
```

AWS provides separate tunnel endpoint and inside-IP information for each tunnel.

Do not invent the following values:

```text
AWS outside IP
169.254.x.x tunnel IP
PSK
proposal
DH group
```

Get them from the AWS-generated configuration.

---

# 23. Download the AWS StrongSwan Configuration

From Account B:

```text
VPC
 -> Site-to-Site VPN Connections
 -> select VPN
 -> Download configuration
```

Select:

```text
Vendor: strongSwan
Platform: Linux/Ubuntu/Debian
```

The exact available platform/version names depend on the AWS console.

Save the file on the Account A VPN server.

Example:

```bash
scp -i <key.pem> <aws-vpn-config> ubuntu@<A_VPN_PUBLIC_IP>:/home/ubuntu/
```

Then:

```bash
sudo cp <aws-vpn-config> /etc/
```

Do not blindly overwrite existing configuration before making a backup.

---

# 24. Back Up StrongSwan Configuration

Before every major change:

```bash
sudo cp /etc/ipsec.conf \
  /etc/ipsec.conf.backup-$(date +%F-%H%M%S)

sudo cp /etc/ipsec.secrets \
  /etc/ipsec.secrets.backup-$(date +%F-%H%M%S)
```

If a custom script exists:

```bash
sudo cp /etc/ipsec.d/aws-updown.sh \
  /etc/ipsec.d/aws-updown.sh.backup-$(date +%F-%H%M%S)
```

Only run the last command if the file exists.

---

# 25. Configure PSK Permissions

The AWS-generated configuration may reference `/etc/ipsec.secrets`.

Ensure:

```bash
sudo chmod 600 /etc/ipsec.secrets
sudo chown root:root /etc/ipsec.secrets
```

Check:

```bash
sudo ls -l /etc/ipsec.secrets
```

Expected permissions are approximately:

```text
-rw------- root root
```

---

# 26. StrongSwan Configuration Principles

The two VPN sides need matching traffic selectors:

```text
Account A:
Local subnet:
11.11.0.0/16

Remote subnet:
12.12.0.0/16
```

AWS side:

```text
AWS VPC:
12.12.0.0/16

Customer network:
11.11.0.0/16
```

Do not accidentally use:

```text
15.15.0.0/16
17.17.0.0/16
```

or old tunnel addresses from another environment.

Your previous troubleshooting history contains addresses such as:

```text
15.15.1.181
17.17.2.76
```

Those appear to belong to an older test environment. They must not be copied into this new `11.11.0.0/16 <-> 12.12.0.0/16` deployment.

---

# 27. VTI / `aws-updown.sh`

Your previous configuration attempted to create:

```text
Tunnel1
Tunnel2
```

with a custom:

```text
/etc/ipsec.d/aws-updown.sh
```

This can be useful with certain AWS StrongSwan configuration approaches, but it introduces additional moving parts:

- VTI interfaces
- XFRM policies
- marks
- routing tables
- iptables mangle rules
- MSS clamping
- policy/routing interaction
- rp_filter
- tunnel interface lifecycle

For the first deployment, use the AWS-generated StrongSwan configuration exactly as the baseline.

Only introduce custom VTI/updown logic if the generated configuration/version requires it or if you deliberately choose a VTI-based design.

Do not combine an old VTI script with a new AWS configuration without understanding the resulting XFRM/routing model.

---

# 28. Start StrongSwan

First validate configuration:

```bash
sudo ipsec status
```

Then:

```bash
sudo ipsec restart
```

Check:

```bash
sudo ipsec statusall
```

Also:

```bash
sudo systemctl status strongswan-starter
```

If the service name is different:

```bash
systemctl list-units --type=service | grep -i strong
```

---

# 29. Verify IKE/IPsec Status

Use:

```bash
sudo ipsec statusall
```

You want to see the VPN connection loaded and the tunnel established.

Also inspect:

```bash
sudo ip xfrm state
```

and:

```bash
sudo ip xfrm policy
```

For packet counters:

```bash
sudo ip -s xfrm state
```

A working tunnel should show increasing counters when traffic is sent.

---

# 30. AWS VPN Tunnel Status

In Account B:

```text
VPC
 -> Site-to-Site VPN Connections
 -> a-to-b-vpn
```

Check:

```text
Tunnel 1:
UP

Tunnel 2:
UP
```

At least one tunnel should be established for basic connectivity.

For production, configure both tunnels.

---

# 31. Account A Route

On the StrongSwan EC2 itself:

```bash
ip route
```

You need a valid route toward the Account B network.

Depending on whether you use policy-based IPsec, VTI, or the AWS-generated configuration, the exact route representation can differ.

Do not blindly add:

```bash
ip route add 12.12.0.0/16 via <old-gateway>
```

The route must match the actual StrongSwan configuration.

---

# 32. Account A Private Route Table

This route is mandatory:

```text
12.12.0.0/16 -> A-VPN-EC2 ENI
```

Example:

```text
Destination:
12.12.0.0/16

Target:
eni-xxxxxxxx
```

or use the EC2 instance target if supported by the route-table UI.

Using the ENI makes the routing relationship explicit.

---

# 33. Account B Route Table

This route is mandatory:

```text
11.11.0.0/16 -> VGW
```

You can use route propagation:

```text
b-pvt-rtb
 -> Route propagation
 -> Enable b-vgw
```

Or manually create:

```text
Destination:
11.11.0.0/16

Target:
vgw-xxxxxxxx
```

AWS documents that when route propagation is not enabled, the route must be added manually.

Reference:
https://docs.aws.amazon.com/vpn/latest/s2svpn/SetUpVPNConnections.html

---

# 34. Do Not Add NAT to VPN Traffic

For this design, traffic between:

```text
11.11.0.0/16
```

and:

```text
12.12.0.0/16
```

should remain private.

Do NOT add:

```bash
iptables -t nat -A POSTROUTING ...
```

just to make the VPN work.

The remote side needs to see the original source IP.

Example:

```text
A-private:
11.11.2.10

Destination:
12.12.2.10
```

Account B should receive:

```text
source = 11.11.2.10
destination = 12.12.2.10
```

not:

```text
source = 11.11.1.x
```

and not the public Elastic IP.

---

# 35. Optional: Restrict NAT to Internet Traffic

If the Account A VPN instance is also being used as a NAT instance for other purposes, make sure NAT does not apply to the VPN network.

For example, do not use a blanket rule such as:

```bash
iptables -t nat -A POSTROUTING -o ens5 -j MASQUERADE
```

without understanding its effect.

VPN traffic should remain un-NATed.

---

# 36. Linux Reverse Path Filtering

Reverse path filtering can interfere with advanced IPsec/VTI routing.

Check:

```bash
sysctl net.ipv4.conf.all.rp_filter
sysctl net.ipv4.conf.default.rp_filter
```

If AWS/StrongSwan's generated configuration requires relaxed reverse-path filtering, configure it consistently.

For a VTI-based setup, a common approach is:

```text
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
```

or per-interface settings appropriate to the selected StrongSwan design.

Do not change this simply because a guide says so; first determine whether you are using policy-based or VTI-based routing.

---

# 37. Verify Linux Firewall

Check:

```bash
sudo iptables -L -n -v
```

Check NAT:

```bash
sudo iptables -t nat -L -n -v
```

Check mangle:

```bash
sudo iptables -t mangle -L -n -v --line-numbers
```

If `ufw` is enabled:

```bash
sudo ufw status verbose
```

Make sure it is not blocking:

```text
UDP 500
UDP 4500
ESP
forwarded VPN traffic
```

---

# 38. Test in the Correct Order

Do not immediately test:

```bash
ping B-private
```

Use a layered troubleshooting process.

## Test 1 — Internet

From Account A VPN server:

```bash
ping -c 4 8.8.8.8
```

Test DNS:

```bash
ping -c 4 google.com
```

If this fails, fix the public subnet/IGW/EIP routing before touching IPsec.

---

# 39. Test 2 — AWS VPN Tunnel

Check:

```bash
sudo ipsec statusall
```

Then:

```bash
sudo ip xfrm state
```

Then:

```bash
sudo ip xfrm policy
```

Then:

```bash
sudo ip -s xfrm state
```

---

# 40. Test 3 — Tunnel Inside IP

AWS provides two tunnel inside addresses, typically from a `169.254.x.x` link-local network.

Do not use guessed addresses.

Example only:

```bash
ping -c 4 169.254.x.x
```

Use the exact AWS-provided tunnel inside address.

---

# 41. Test 4 — Account B Private Instance

From Account A VPN server:

```bash
ping -c 4 <B_PRIVATE_IP>
```

Then:

```bash
ssh ubuntu@<B_PRIVATE_IP>
```

From Account B private instance:

```bash
ping -c 4 <A_PRIVATE_IP>
```

Then:

```bash
ssh ubuntu@<A_PRIVATE_IP>
```

---

# 42. Test 5 — TCP Instead of Ping

Ping can fail because ICMP is disabled.

Use:

```bash
nc -vz <B_PRIVATE_IP> 22
```

or:

```bash
timeout 5 bash -c '</dev/tcp/<B_PRIVATE_IP>/22' && echo OK
```

If TCP works but ping does not, investigate ICMP security rules rather than IPsec.

---

# 43. Packet Capture

Packet capture is one of the most useful tools during troubleshooting.

On Account A VPN server:

```bash
sudo tcpdump -ni any host <B_PRIVATE_IP>
```

For IKE:

```bash
sudo tcpdump -ni any udp port 500
```

For NAT-T:

```bash
sudo tcpdump -ni any udp port 4500
```

For ESP:

```bash
sudo tcpdump -ni any proto 50
```

---

# 44. Capture Traffic From the Private Instance

On Account A VPN server:

```bash
sudo tcpdump -ni any host <A_PRIVATE_IP>
```

Then generate traffic from A-private-ec2.

You should see packets arriving at the VPN server.

If you see packets arriving but not leaving through IPsec, investigate:

```text
StrongSwan
XFRM policy
routing
traffic selectors
```

---

# 45. XFRM Troubleshooting

Check:

```bash
sudo ip xfrm state
```

Check:

```bash
sudo ip xfrm policy
```

Counters:

```bash
sudo ip -s xfrm state
```

The counters should change when traffic is generated.

If there is no matching XFRM policy for:

```text
11.11.x.x -> 12.12.x.x
```

the IPsec configuration/traffic selectors are likely wrong.

---

# 46. Routing Troubleshooting

From Account A VPN server:

```bash
ip route get <B_PRIVATE_IP>
```

From A-private-ec2:

```bash
ip route get <B_PRIVATE_IP>
```

The A private instance should send the packet toward the VPN instance.

From Account B:

```bash
ip route get <A_PRIVATE_IP>
```

The B instance should have:

```text
11.11.0.0/16 -> VGW
```

---

# 47. AWS VPC Route Verification

Account A:

```text
a-pvt-rtb

11.11.0.0/16 -> local
12.12.0.0/16 -> A-VPN-EC2
```

Account B:

```text
b-pvt-rtb

12.12.0.0/16 -> local
11.11.0.0/16 -> VGW
```

If either route is missing, the VPN can be perfectly established while application traffic still fails.

AWS route selection uses longest-prefix matching and static/propagated route priority.

Reference:
https://docs.aws.amazon.com/vpn/latest/s2svpn/vpn-route-priority.html

---

# 48. AWS Security Group Checklist

## A VPN EC2

Allow:

```text
UDP 500
UDP 4500
ESP
TCP 22 from administrator IP only
```

## A Private EC2

Allow:

```text
ICMP from 12.12.0.0/16
TCP 22 from 12.12.0.0/16
```

or, preferably, only the exact required B subnet/SG.

## B Private EC2

Allow:

```text
ICMP from 11.11.0.0/16
TCP 22 from 11.11.0.0/16
```

---

# 49. Network ACL Checklist

If custom NACLs are being used, verify both directions.

Remember that NACLs are stateless.

For initial testing, use a permissive NACL and tighten it after connectivity is confirmed.

---

# 50. AWS Reachability Analyzer

If traffic still fails, use AWS VPC Reachability Analyzer.

Check paths such as:

```text
A-private-ec2
       |
       v
A-VPN-EC2
       |
       v
VPN/VGW
       |
       v
B-private-ec2
```

It can identify issues such as:

- route mismatch
- security group restrictions
- NACL restrictions
- source/destination check
- higher-priority route

AWS documents source/destination-check failures as a specific reachability restriction.

Reference:
https://docs.aws.amazon.com/vpc/latest/reachability/explanation-codes.html

---

# 51. Common Problems From the Previous Attempt

## Problem 1 — Wrong CIDRs

Previous testing used:

```text
15.15.1.181
17.17.2.76
15.15.0.0/16
```

Those should not appear in the new deployment.

New environment:

```text
A = 11.11.0.0/16
B = 12.12.0.0/16
```

---

## Problem 2 — Manual Route Added Through Old Gateway

You previously used:

```bash
sudo ip route add 15.15.0.0/16 via 17.17.2.1
```

and later:

```bash
sudo ip route del 15.15.0.0/16 via 17.17.2.1 dev ens5
```

Do not carry this pattern into the new configuration.

The correct Account A VPC route is:

```text
12.12.0.0/16 -> StrongSwan EC2 ENI
```

---

## Problem 3 — Mixing VTI and Policy-Based IPsec

Your previous configuration created:

```text
Tunnel1
Tunnel2
```

and manipulated:

```text
ip rule
ip route table 200
ip xfrm policy
ip xfrm state
iptables mangle
rp_filter
```

This can work, but it creates a much more complicated system.

Start with the AWS-generated StrongSwan configuration.

Only add VTI/routing-table logic after the basic tunnel works.

---

## Problem 4 — Deleting `aws-updown.sh`

You previously did:

```bash
rm -rf /etc/ipsec.d/aws-updown.sh
```

while experimenting.

Avoid repeatedly creating/deleting scripts until you have identified exactly which configuration is invoking them.

---

## Problem 5 — Restarting Without Checking Logs

Do not rely only on:

```bash
sudo systemctl restart strongswan-starter
```

Immediately inspect:

```bash
sudo systemctl status strongswan-starter
```

and:

```bash
sudo journalctl -u strongswan-starter -n 100 --no-pager
```

Also:

```bash
sudo ipsec statusall
```

---

# 52. StrongSwan Logs

Use:

```bash
sudo journalctl -u strongswan-starter -f
```

In another terminal generate traffic.

For broader system logs:

```bash
sudo journalctl -f
```

Look for:

```text
IKE_SA established
CHILD_SA established
AUTHENTICATION_FAILED
NO_PROPOSAL_CHOSEN
TS_UNACCEPTABLE
peer not responding
no matching CHILD_SA config
```

---

# 53. Meaning of Common IPsec Errors

## `AUTHENTICATION_FAILED`

Usually investigate:

```text
PSK
customer gateway IP
identity
configuration mismatch
```

## `NO_PROPOSAL_CHOSEN`

Usually:

```text
IKE/ESP encryption proposal mismatch
DH group mismatch
```

Use the AWS-generated configuration.

## `TS_UNACCEPTABLE`

Usually:

```text
traffic selector/subnet mismatch
```

Check:

```text
A = 11.11.0.0/16
B = 12.12.0.0/16
```

## `peer not responding`

Check:

```text
Elastic IP
UDP 500
UDP 4500
Security Group
NACL
Internet Gateway
route
```

---

# 54. Verify the StrongSwan Public IP

On Account A:

```bash
curl -4 https://checkip.amazonaws.com
```

Compare the result with the Elastic IP registered in the AWS Customer Gateway.

They must correspond to the public address actually used by the VPN server.

---

# 55. Verify AWS Customer Gateway

Account B:

```text
Customer Gateway public IP
        =
Account A StrongSwan public IP
```

If the EC2 has:

```text
Private IP: 11.11.1.x
Elastic IP: EIP-A
```

then the AWS Customer Gateway should reference:

```text
EIP-A
```

not:

```text
11.11.1.x
```

---

# 56. Verify IP Forwarding

On A-VPN-EC2:

```bash
sysctl net.ipv4.ip_forward
```

Expected:

```text
net.ipv4.ip_forward = 1
```

---

# 57. Verify Source/Destination Check

AWS:

```bash
aws ec2 describe-instance-attribute \
  --instance-id <A_VPN_INSTANCE_ID> \
  --attribute sourceDestCheck
```

Expected:

```text
false
```

---

# 58. Verify the Route From A Private Instance

On A-private-ec2:

```bash
ip route get <B_PRIVATE_IP>
```

It should ultimately send the traffic toward the A VPN instance.

If it instead sends the packet somewhere else, fix:

```text
a-pvt-rtb
```

---

# 59. Verify the Route From B Private Instance

On B-private-ec2:

```bash
ip route get <A_PRIVATE_IP>
```

The route should use the AWS VGW.

In AWS route table:

```text
11.11.0.0/16 -> vgw-xxxxxxxx
```

---

# 60. Verify No NAT

On A VPN server:

```bash
sudo iptables -t nat -L -n -v
```

Check whether VPN traffic is being masqueraded.

The desired VPN flow is:

```text
11.11.2.10 -> 12.12.2.10
```

not:

```text
11.11.1.10 -> 12.12.2.10
```

and not:

```text
<A-VPN-EIP> -> 12.12.2.10
```

---

# 61. Two-Tunnel Design

AWS Site-to-Site VPN creates two tunnels.

You should configure both.

Conceptually:

```text
                 +----------------+
                 | Account A      |
                 | StrongSwan     |
                 +-------+--------+
                         |
              +----------+----------+
              |                     |
          Tunnel 1              Tunnel 2
              |                     |
              v                     v
        +--------------------------------+
        | Account B AWS VGW              |
        +--------------------------------+
```

The second tunnel provides redundancy.

AWS documentation recommends configuring the customer gateway device to use both tunnels.

Reference:
https://docs.aws.amazon.com/vpn/latest/s2svpn/your-cgw.html

---

# 62. Final Validation Checklist

## Account A

- [ ] VPC = `11.11.0.0/16`
- [ ] Public subnet = `11.11.1.0/24`
- [ ] Private subnet = `11.11.2.0/24`
- [ ] IGW attached
- [ ] VPN EC2 has Elastic IP
- [ ] VPN EC2 source/destination check disabled
- [ ] IP forwarding enabled
- [ ] UDP 500 allowed
- [ ] UDP 4500 allowed
- [ ] ESP allowed where required
- [ ] StrongSwan installed
- [ ] AWS-generated configuration used
- [ ] PSK permissions = `600`
- [ ] VPN route exists in `a-pvt-rtb`

## Account B

- [ ] VPC = `12.12.0.0/16`
- [ ] Public subnet = `12.12.1.0/24`
- [ ] Private subnet = `12.12.2.0/24`
- [ ] IGW attached
- [ ] VGW created
- [ ] VGW attached to VPC
- [ ] Customer Gateway created
- [ ] CGW uses Account A Elastic IP
- [ ] Site-to-Site VPN created
- [ ] Static routing selected
- [ ] Static prefix = `11.11.0.0/16`
- [ ] `11.11.0.0/16 -> VGW` route exists in required route tables
- [ ] Security groups allow required traffic
- [ ] NACLs allow required traffic

## StrongSwan

- [ ] `ipsec statusall` checked
- [ ] Tunnel 1 UP
- [ ] Tunnel 2 UP or configured for failover
- [ ] XFRM state exists
- [ ] XFRM policy exists
- [ ] XFRM counters increase during testing
- [ ] No accidental NAT of VPN traffic
- [ ] No stale routes from previous VPN deployment
- [ ] No stale VTI configuration unless deliberately required

---

# 63. Recommended Test Sequence

Perform tests in this exact order.

### Test A — VPN EC2 Internet

```bash
ping -c 4 8.8.8.8
```

### Test B — StrongSwan

```bash
sudo ipsec statusall
```

### Test C — XFRM

```bash
sudo ip xfrm state
sudo ip xfrm policy
```

### Test D — AWS Tunnel

Check AWS console:

```text
Tunnel 1 = UP
Tunnel 2 = UP
```

### Test E — A VPN -> B Private

```bash
ping -c 4 <B_PRIVATE_IP>
```

### Test F — A Private -> B Private

```bash
ping -c 4 <B_PRIVATE_IP>
```

### Test G — B Private -> A Private

```bash
ping -c 4 <A_PRIVATE_IP>
```

### Test H — SSH

```bash
ssh ubuntu@<REMOTE_PRIVATE_IP>
```

### Test I — Packet Capture

```bash
sudo tcpdump -ni any host <REMOTE_PRIVATE_IP>
```

Only proceed to the next layer after the previous layer works.

---

# 64. Useful Diagnostic Command Set

Keep this command set available on A-VPN-EC2:

```bash
# IP configuration
ip -br addr
ip route

# Routing decision
ip route get <B_PRIVATE_IP>

# Forwarding
sysctl net.ipv4.ip_forward

# StrongSwan
sudo ipsec status
sudo ipsec statusall

# XFRM
sudo ip xfrm state
sudo ip xfrm policy
sudo ip -s xfrm state

# Firewall
sudo iptables -L -n -v
sudo iptables -t nat -L -n -v
sudo iptables -t mangle -L -n -v --line-numbers

# Logs
sudo journalctl -u strongswan-starter -n 100 --no-pager

# Live logs
sudo journalctl -u strongswan-starter -f

# Packet capture
sudo tcpdump -ni any udp port 500
sudo tcpdump -ni any udp port 4500
sudo tcpdump -ni any proto 50
```

---

# 65. Important Design Decision

There are two possible architectures:

## Architecture A — Recommended for this document

```text
Account A
StrongSwan EC2
       |
       | AWS Site-to-Site VPN
       |
Account B
AWS VGW
```

This is the design documented above.

## Architecture B — Different design

```text
Account A
StrongSwan EC2
       |
       | IPsec
       |
Account B
StrongSwan EC2
```

This is an EC2-to-EC2 VPN.

If you choose Architecture B:

- You do not need an AWS VGW for the IPsec tunnel.
- You would configure StrongSwan on both sides.
- Both VPN EC2 instances require routing and source/destination-check changes.
- Both sides require public IP connectivity.
- You manage both ends of the IPsec tunnel yourself.

Do not mix the configuration of Architecture A and Architecture B.

---

# 66. Final Target Configuration

The clean target should be:

```text
ACCOUNT A
================================================

VPC:
11.11.0.0/16

Public:
11.11.1.0/24

Private:
11.11.2.0/24

A-VPN-EC2:
11.11.1.x
Elastic IP
StrongSwan
IP forwarding ON
Source/Destination Check OFF

A-PRIVATE-EC2:
11.11.2.x


ACCOUNT B
================================================

VPC:
12.12.0.0/16

Public:
12.12.1.0/24

Private:
12.12.2.0/24

VGW:
attached to 12.12.0.0/16

B-PUBLIC-EC2:
12.12.1.x

B-PRIVATE-EC2:
12.12.2.x


VPN
================================================

Customer Gateway:
Account A StrongSwan Elastic IP

VPN:
AWS Site-to-Site VPN

Routing:
Static

Account A prefix:
11.11.0.0/16

Account B prefix:
12.12.0.0/16


ROUTES
================================================

Account A private RT:
12.12.0.0/16 -> A-VPN-EC2

Account B private RT:
11.11.0.0/16 -> VGW
```

---

# 67. Key Lesson From the Previous Deployment

The previous troubleshooting became complicated because several layers were changed simultaneously:

```text
StrongSwan
VTI
XFRM
iptables
mangle
routing table 200
policy routing
static routes
custom aws-updown.sh
MSS clamping
rp_filter
```

For the new deployment, use this order:

```text
AWS VPC routing
        ↓
AWS VGW
        ↓
AWS VPN connection
        ↓
AWS-generated StrongSwan configuration
        ↓
StrongSwan tunnel
        ↓
XFRM verification
        ↓
private route testing
        ↓
packet capture
        ↓
only then custom VTI/policy routing if required
```

This keeps the troubleshooting deterministic.

---

# 68. AWS References

AWS Site-to-Site VPN setup:

https://docs.aws.amazon.com/vpn/latest/s2svpn/SetUpVPNConnections.html

Static and dynamic routing:

https://docs.aws.amazon.com/vpn/latest/s2svpn/vpn-static-dynamic.html

VPN route priority:

https://docs.aws.amazon.com/vpn/latest/s2svpn/vpn-route-priority.html

Customer gateway options:

https://docs.aws.amazon.com/vpn/latest/s2svpn/cgw-options.html

Customer gateway devices:

https://docs.aws.amazon.com/vpn/latest/s2svpn/your-cgw.html

AWS static routing example:

https://docs.aws.amazon.com/vpn/latest/s2svpn/cgw-static-routing-example-interface.html

EC2 source/destination checking:

https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_ModifyNetworkInterfaceAttribute.html

VPC routing/middlebox considerations:

https://docs.aws.amazon.com/vpc/latest/userguide/route-table-options.html
