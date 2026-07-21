# VPS Control Panel

A lightweight, self-hosted VPS control panel - an alternative to Proxmox VE that runs on Ubuntu and Debian. Manage your servers through a modern web interface with full SSL support.

## Features

- Lightweight web-based control panel
- **One-Command Installation**: Single script installs everything
- **SSL Ready**: Integrated Let's Encrypt certificate setup
- **Domain Support**: Custom domain with automatic HTTPS
- **Resource Monitoring**: Real-time CPU, RAM, storage stats
- **Active Development**: Auto-update mechanism
- **Lightweight**: Minimal RAM/CPU overhead vs Proxmox

## Requirements

- Ubuntu 22.04 LTS, 24.04 LTS, Debian 11+, or Debian 12+
- Root access
- 512MB+ RAM
- 1GB+ disk space
- Domain name (optional, for SSL)

## Quick Install

### Basic Installation

```bash
curl -sSL https://raw.githubusercontent.com/itriedcoding/vps-panel/main/install.sh | bash -s
```

### With Custom Domain and SSL

```bash
curl -sSL https://raw.githubusercontent.com/itriedcoding/vps-panel/main/install.sh | bash -s -- -d vps.yourdomain.com -e admin@yourdomain.com
```

## All Options

```bash
./install.sh [OPTIONS]

Options:
  -d, --domain DOMAIN    Domain for SSL certificate
  -e, --email EMAIL      Email for Let's Encrypt registration
  -h, --help             Show help message
```

## Access

After installation, access the control panel at:
- **Web Interface**: `http://YOUR_SERVER_IP`
- **API Status**: `http://YOUR_SERVER_IP/api/status`

## Architecture

```
                    ┌─────────────────────┐
                    │   Internet/Users    │
                    └──────────┬──────────┘
                               │
                     ┌─────────▼──────────┐
                     │    Nginx (Port 80) │
                     │   Reverse Proxy    │
                     └─────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │   VPS Control Panel │
                    │    (Flask/Gunicorn) │
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │   Python Backend    │
                    │  System Monitoring  │
                    └─────────────────────┘
```

## What Gets Installed

1. **Flask Web Application**: Modern control panel with Bootstrap UI
2. **Gunicorn**: WSGI HTTP server
3. **Nginx**: Reverse proxy (port 80/443)
4. **Certbot**: Let's Encrypt SSL certificates
5. **UFW Firewall**: Configured with essential ports open
6. **Systemd Service**: Auto-start on boot

## Auto-Update

The panel includes an automatic update check. To manually update:

```bash
cd /opt/vps-panel
git pull origin main
systemctl restart vps-panel
```

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/` | GET | Web interface |
| `/api/status` | GET | Panel status |
| `/api/servers` | GET | List servers |
| `/api/servers` | POST | Add server |
| `/api/system` | GET | System metrics |

## Configuration

- Panel files: `/opt/vps-panel/`
- Data: `/opt/vps-panel/data/`
- Logs: `/opt/vps-panel/logs/`
- Service: `vps-panel`

## System Requirements Comparison

| Feature | Proxmox VE | VPS Panel |
|---------|-----------|-----------|
| RAM Minimum | 4GB | 512MB |
| CPU | 2+ cores | 1 core |
| Disk | 64GB+ | 1GB+ |
| Web Port | 8006 | 80 |
| Updates | Apt | Git |

## Security Notes

- Firewall enabled with UFW
- SSH access preserved
- Let's Encrypt certificates auto-renew
- Default credentials should be changed immediately

## Troubleshooting

### Panel not loading?

```bash
# Check service
systemctl status vps-panel

# Check logs
journalctl -u vps-panel -f

# Restart
systemctl restart vps-panel
```

### SSL Issues?

```bash
# Renew certificates
certbot renew

# Check certificates
certbot certificates

# Force reconfigure nginx
nginx -t && systemctl reload nginx
```

## Development

```bash
git clone https://github.com/itriedcoding/vps-panel.git
cd vps-panel
chmod +x install.sh
```

## License

MIT License - Feel free to use and modify.

## Contributing

Pull requests are welcome! Feel free to:
- Report bugs
- Add features
- Improve documentation
- Fix typos

## Sponsors

Support this project by starring the GitHub repo!