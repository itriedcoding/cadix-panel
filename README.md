# TooO Cadix Panel

A lightweight, high-performance VPS control panel alternative to Proxmox VE, built with Go (backend) and TypeScript (frontend).

## Tech Stack

| Component | Technology |
|-----------|------------|
| Backend | **Go (Golang)** - High-performance daemon |
| Frontend | **TypeScript + React** - Modern dashboard |
| Database | **SQL (SQLite)** - Lightweight & reliable |
| Scripting | **Bash** - System integration |

## Features

- **High Performance**: Go backend for fast API responses
- **Modern UI**: TypeScript/React dashboard with Bootstrap
- **SSL Ready**: Integrated Let's Encrypt support
- **Zero-Downtime**: Graceful systemd service management
- **Lightweight**: Minimal RAM/CPU footprint
- **Scalable**: Supports any server size from 512MB RAM

## Requirements

- Ubuntu 22.04 LTS, 24.04 LTS, Debian 11+, Debian 12+
- Root access
- 512MB+ RAM
- 1GB+ disk space
- Domain name (optional, for SSL)

## Quick Install

### Basic Installation

```bash
curl -sSL https://raw.githubusercontent.com/itriedcoding/tooocadix-panel/main/install.sh | bash -s
```

### With SSL/Domain

```bash
curl -sSL https://raw.githubusercontent.com/itriedcoding/tooocadix-panel/main/install.sh | bash -s -- -d panel.example.com -e admin@example.com
```

## Command Line Options

```bash
./install.sh [OPTIONS]

Options:
  -d, --domain DOMAIN    Domain for SSL certificate
  -e, --email EMAIL      Email for Let's Encrypt registration
  -h, --help             Show help message

Examples:
  ./install.sh
  ./install.sh -d vps.example.com -e admin@example.com
```

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
                     │  TooO Cadix Panel   │
                     │   (Go HTTP Server)  │
                     └──────────┬──────────┘
                               │
         ┌───────────────────────┼───────────────────────┐
         │   ┌───────────────┐ │ ┌─────────────────┐ │
         │   │   SQLite DB   │ │ │ System Tools    │ │
         │   │ (SQL Tables)  │ │ │ (Bash Scripts)  │ │
         │   └───────────────┘ │ └─────────────────┘ │
         └───────────────────────────────────────────┘
```

## What Gets Installed

1. **Go Backend**: High-performance HTTP server with SQLite database
2. **TypeScript Frontend**: Modern React-based dashboard
3. **Nginx**: Reverse proxy on ports 80/443
4. **Certbot**: Automatic SSL certificate management
5. **UFW Firewall**: Configured security with essential ports
6. **Systemd Service**: Auto-start on boot

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/` | GET | Web dashboard |
| `/api/status` | GET | Server status/response |
| `/api/servers` | GET | List all managed servers |
| `/api/system` | GET | System metrics (CPU, RAM, storage) |
| `/api/update` | POST | Trigger system update check |

## Installation Flow

```bash
# 1. Download installer
curl -sSL https://raw.githubusercontent.com/itriedcoding/tooocadix-panel/main/install.sh -o install.sh

# 2. Make executable
chmod +x install.sh

# 3. Run as root
sudo ./install.sh

# 4. (Optional) With SSL
sudo ./install.sh -d yourdomain.com -e admin@yourdomain.com
```

## Post-Installation

Access the panel:
- **Web Interface**: `http://YOUR_SERVER_IP`
- **API Status**: `http://YOUR_SERVER_IP/api/status`

Check service status:
```bash
systemctl status tooocadix-panel
journalctl -u tooocadix-panel -f
```

## Database Schema

```sql
-- Servers table
CREATE TABLE servers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    ip TEXT NOT NULL,
    status TEXT DEFAULT 'offline',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Settings table
CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT
);

-- Users table
CREATE TABLE users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

## Configuration

| Path | Description |
|------|-------------|
| `/opt/tooocadix-panel/app/` | Go backend source |
| `/opt/tooocadix-panel/data/` | SQLite database |
| `/opt/tooocadix-panel/frontend/` | TypeScript frontend |
| `/opt/tooocadix-panel/logs/` | Application logs |
| `/etc/systemd/system/tooocadix-panel.service` | Systemd unit file |

## Security

- UFW firewall enabled with essential ports only
- SSH (port 22) always allowed
- Let's Encrypt certificates auto-renew
- All traffic goes through Nginx reverse proxy

## Troubleshooting

### Panel not accessible?

```bash
# Check service
systemctl status tooocadix-panel

# Check logs
journalctl -u tooocadix-panel -f

# Check port
ss -tlnp | grep 5000

# Restart
systemctl restart tooocadix-panel
```

### SSL Issues?

```bash
# Check cert status
certbot certificates

# Force renewal
certbot renew

# Nginx test
nginx -t && systemctl reload nginx
```

## Development

```bash
# Clone
git clone https://github.com/itriedcoding/tooocadix-panel.git
cd tooocadix-panel

# Backend: Go
cd app && go build -o panel .

# Frontend: TypeScript
cd frontend && npm install && npm run build
```

## License

MIT License - Feel free to use and modify.

## Contributing

Pull requests welcome! Areas for contribution:
- Bug fixes
- New features
- Documentation
- Tests