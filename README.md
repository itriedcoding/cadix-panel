# Cadix Panel

Complete VPS control panel built with **Go** (backend), **TypeScript** (frontend), **SQLite** (database), and **Bash** (system tools). Lightweight alternative to Proxmox VE.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| **Backend** | **Go (Golang)** - High-performance HTTP daemon with SQLite integration |
| **Frontend** | **TypeScript + React** - Modern dashboard with live updates |
| **Database** | **SQL (SQLite)** - Zero-configuration, lightweight |
| **System** | **Bash** - Monitoring, backup, cleanup scripts |

## Features

- **Complete Server Management** - Add, remove, start, stop, restart servers
- **Real-time System Monitoring** - CPU, RAM, storage, processes, network
- **Live Dashboard** - All metrics update every 30 seconds
- **Process Viewer** - Top 20 processes by CPU usage
- **Update Management** - Check and install system updates
- **Firewall Control** - UFW integration from the panel
- **SSL/TLS Ready** - Let's Encrypt certificate support via Certbot
- **Custom Domain** - Nginx reverse proxy with your own domain
- **Auto-renew SSL** - Certbot handles certificate renewal
- **Dark Theme** - Modern dark UI optimized for server management
- **System Tools** - Monitor, backup, and cleanup scripts included

## Requirements

- Ubuntu 22.04 / 24.04 LTS or Debian 11+
- Root access
- 512MB+ RAM
- Domain name (optional, for SSL)

## Quick Install

### One-command install:

```bash
curl -sSL https://raw.githubusercontent.com/itriedcoding/cadix-panel/main/install.sh | bash -s
```

### With custom domain and SSL:

```bash
curl -sSL https://raw.githubusercontent.com/itriedcoding/cadix-panel/main/install.sh | bash -s -- -d panel.yourdomain.com -e admin@yourdomain.com
```

## After Installation

Access the panel at `http://YOUR_SERVER_IP`

### API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/` | GET | Dashboard UI |
| `/api/status` | GET | Panel status & version |
| `/api/servers` | GET | List all servers |
| `/api/servers/add` | POST | Add a new server |
| `/api/servers/remove` | POST | Remove a server |
| `/api/servers/start` | POST | Start a server |
| `/api/servers/stop` | POST | Stop a server |
| `/api/servers/restart` | POST | Restart a server |
| `/api/system` | GET | Full system information |
| `/api/system/cpu` | GET | CPU usage details |
| `/api/system/memory` | GET | Memory details |
| `/api/system/disk` | GET | Disk usage details |
| `/api/system/processes` | GET | Top 20 processes |
| `/api/system/network` | GET | Open ports & connections |
| `/api/update` | POST | Trigger system update |
| `/api/update/check` | GET | Check for updates |
| `/api/firewall` | GET/POST | Firewall status & management |

## Architecture

```
                    ┌──────────────────────┐
                    │   Internet / Users   │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │   Nginx (80/443)     │
                    │   Reverse Proxy      │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │   Go Backend (:5000) │
                    │   HTTP API Server    │
                    └────┬─────────────┬───┘
                         │             │
                    ┌────▼────┐   ┌────▼────┐
                    │ SQLite  │   │  Bash   │
                    │  DB     │   │  Tools  │
                    └─────────┘   └─────────┘
```

## Commands

```bash
# Check service status
systemctl status cadix-panel

# View logs
journalctl -u cadix-panel -f

# Run monitor
/opt/cadix-panel/tools/monitor.sh

# Run backup
/opt/cadix-panel/tools/backup.sh

# Run cleanup
/opt/cadix-panel/tools/cleanup.sh
```

## Database Schema

```sql
-- Servers table
CREATE TABLE servers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    ip TEXT NOT NULL,
    port INTEGER DEFAULT 22,
    username TEXT DEFAULT 'root',
    status TEXT DEFAULT 'offline',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Settings table
CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);

-- Users table
CREATE TABLE users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    role TEXT DEFAULT 'admin',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Metrics table
CREATE TABLE metrics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id INTEGER, cpu REAL, ram REAL, disk REAL,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

## License

MIT