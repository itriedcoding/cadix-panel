# Proxmox VE All-in-One Installer

A single-command installer for Proxmox VE that supports Ubuntu 22.04, Ubuntu 24.04, and Debian 11+ with integrated SSL/certbot domain support.

## Features

- **One-Command Installation**: Install Proxmox VE with a single command
- **Multiple OS Support**: Ubuntu 22.04, Ubuntu 24.04, Debian 11, Debian 12+
- **Integrated SSL**: Automatic Let's Encrypt certificate setup via Certbot
- **Domain Integration**: Custom domain support with nginx proxy
- **Ready-to-use**: Fully configured Proxmox environment

## Requirements

- Ubuntu 22.04 LTS or 24.04 LTS
- Debian 11 or 12
- Root access
- Domain name (optional, for SSL)

## Quick Install

### Basic Install (no domain)

```bash
curl -sSL https://raw.githubusercontent.com/itriedcoding/proxmox-installer/main/install-proxmox.sh | bash -s
```

Or download and run:

```bash
wget https://raw.githubusercontent.com/itriedcoding/proxmox-installer/main/install-proxmox.sh
chmod +x install-proxmox.sh
sudo ./install-proxmox.sh
```

### With Domain and SSL

```bash
sudo ./install-proxmox.sh -d pve.yourdomain.com -e admin@yourdomain.com
```

## All Options

```bash
sudo ./install-proxmox.sh -d DOMAIN -e EMAIL [-u USERNAME] [-p PASSWORD]

Options:
  -d, --domain DOMAIN    Domain name for SSL/certbot
  -e, --email EMAIL      Email for certbot registration
  -u, --user USERNAME    Admin username (default: admin)
  -p, --pass PASSWORD    Admin password
  -h, --help             Show help message
```

## Examples

### Basic Installation
```bash
sudo ./install-proxmox.sh
```

### With Custom Admin User
```bash
sudo ./install-proxmox.sh -u proxmoadmin -p SecurePassword123
```

### Production Setup with SSL
```bash
sudo ./install-proxmox.sh -d pve.example.com -e admin@example.com
```

### Full Custom Setup
```bash
sudo ./install-proxmox.sh -d proxmox.example.com -e dev@example.com -u pveadmin -p MySecurePass123
```

## What Gets Installed

1. **Proxmox VE Packages**: Core virtualization platform
2. **Nginx**: Web server and reverse proxy
3. **Certbot**: Automatic SSL certificate management
4. **FUSE Support**: For storage connectivity
5. **Configured Services**: All services enabled and ready

## Post-Installation

### Access Web Interface
- **URL**: `https://YOUR_SERVER_IP:8006` or `https://yourdomain.com` (if configured)
- **Username**: `root`
- **Password**: Set by you during installation

### Change Admin Password
```bash
passwd admin
```

### Update Proxmox
```bash
apt update && apt upgrade -y
```

## Architecture

```
                    ┌─────────────────────┐
                    │   Internet/Users    │
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │      Nginx          │
                    │   (Reverse Proxy)   │
                    └─────┬─────────┬─────┘
                          │         │
           ┌──────────────┘         └──────────────┐
           │                                       │
┌──────────▼──────────┐               ┌────────────▼──────────┐
│   Let's Encrypt     │               │   Proxmox Web GUI     │
│      Certbot        │               │        (Port 8006)    │
└─────────────────────┘               └───────────────────────┘
           │                                       │
           │              ┌────────────────────────┘
           │              │
           │     ┌────────▼────────┐
           │     │  Proxmox VE     │
           │     │   Services      │
           │     │ pvedaemon,pveproxy,
           │     │ pvestatd, etc.  │
           │     └─────────────────┘
           │
    ┌──────▼──────┐
    │  Filesystem │
    │   (FUSE)    │
    └─────────────┘
```

## Security Notes

- Default no-subscription repository is used
- SSL certificates are automatically renewed by certbot
- Firewall configuration should be adjusted for your needs
- Change default passwords immediately after installation

## Troubleshooting

### Can't access web interface?
```bash
# Check if services are running
systemctl status pvedaemon pveproxy

# Check firewall
ufw status
```

### SSL certificate issues?
```bash
# Renew certificates manually
certbot renew

# Check certificate status
certbot certificates
```

### Domain not resolving?
```bash
# Ensure DNS points to your server IP
dig yourdomain.com
```

## Development

### Build Locally
```bash
git clone https://github.com/itriedcoding/proxmox-installer.git
cd proxmox-installer
chmod +x install-proxmox.sh
```

## Changelog

### v2.0.0
- Added full Ubuntu 22.04/24.04 support
- Added Debian 11+ support
- Integrated Let's Encrypt SSL with certbot
- Domain support for seamless HTTPS
- Nginx reverse proxy configuration
- Automated admin user creation
- UFW firewall integration

### v1.0.0
- Initial release with basic Proxmox installation

## License

MIT License - Feel free to use and modify.

## Contributing

Pull requests welcome!