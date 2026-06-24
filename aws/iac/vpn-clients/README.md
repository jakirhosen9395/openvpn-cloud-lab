# vpn-clients/

Generated OpenVPN **client profiles** (`*.ovpn`) are downloaded here by Ansible.

- `playbook.yml` creates `admin_user.ovpn`.
- `ansible-playbook create-user.yml -e vpn_user=<name>` creates `<name>.ovpn`.

## How to use a profile

Import the file into **OpenVPN Connect** (Windows / macOS / Linux / iOS / Android), or on Linux:

```bash
sudo openvpn --config admin_user.ovpn
```

## ⚠️ These files are secrets

Each `.ovpn` embeds a **private key** and the `tls-crypt` key — anyone with the file can connect to
your VPN. So:

- **Never commit them** (the repo's root `.gitignore` ignores `*.ovpn`).
- Share them only over a secure channel (encrypted vault / one-time link), never email or chat.
- After a server **rebuild**, old profiles stop working (new certificate authority). Regenerate them
  by re-running the playbook / `create-user.yml`.

To revoke a leaked profile, recreate the server or revoke the client certificate on the server.

> Tip: `.gitkeep` keeps this folder in git while the real `.ovpn` files stay local-only.
