#!/bin/bash
set -e

VERSION="1.0.0"
INSTALL_DIR="/opt/tooocadix-panel"
SERVICE_NAME="tooocadix-panel"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_banner() {
    cat << EOF

${GREEN}========================================${NC}
${GREEN}  TooO Cadix Panel Installer v$VERSION${NC}
${GREEN}========================================${NC}
${YELLOW}Go Backend + TypeScript Frontend${NC}

EOF
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

detect_os() {
    source /etc/os-release 2>/dev/null || true
    log_info "Detected OS: $NAME $VERSION_ID"
    
    case "$NAME" in
        Ubuntu|Debian) ;;
        *) log_error "OS not supported"; exit 1 ;;
    esac
}

wait_for_apt_lock() {
    local attempt=0
    while [[ $attempt -lt 30 ]]; do
        if ! lsof /var/lib/dpkg/lock-frontend &>/dev/null 2>&1 && \
           ! lsof /var/lib/dpkg/lock &>/dev/null 2>&1 && \
           ! lsof /var/lib/apt/lists/lock &>/dev/null 2>&1; then
            return 0
        fi
        log_info "Waiting for apt lock... ($((attempt+1))/30)"
        sleep 2
        attempt=$((attempt+1))
    done
    log_warn "APT lock timeout, continuing..."
}

prepare_system() {
    log_info "Preparing system..."
    
    if [[ -f /etc/apt/sources.list ]]; then
        grep -qE "^deb " /etc/apt/sources.list 2>/dev/null && mv /etc/apt/sources.list /etc/apt/sources.list.backup 2>/dev/null || true
    fi
    
    wait_for_apt_lock
    apt-get update -qq 2>/dev/null || true
    log_info "System prepared"
}

install_dependencies() {
    log_info "Installing dependencies..."
    
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        golang-go golang-modules golang-doc build-essential \
        nodejs npm nginx certbot python3-certbot-nginx \
        curl wget jq git sqlite3 ufw 2>/dev/null
    
    log_info "Dependencies installed"
}

setup_panel_environment() {
    log_info "Setting up panel environment..."
    
    mkdir -p "$INSTALL_DIR/app"
    mkdir -p "$INSTALL_DIR/data"
    mkdir -p "$INSTALL_DIR/frontend"
    mkdir -p "$INSTALL_DIR/logs"
    
    chmod -R 755 "$INSTALL_DIR"
    
    go version &>/dev/null || {
        log_warn "Go not available, will download during build"
    }
    
    npm --version &>/dev/null || {
        log_warn "Node.js not available"
    }
    
    log_info "Panel environment ready"
}

write_go_backend() {
    log_info "Writing Go backend..."
    
    cat > "$INSTALL_DIR/app/main.go" << 'GOEOF'
package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

var db *sql.DB

type Server struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	IP    string `json:"ip"`
	Status string `json:"status"`
}

type SystemInfo struct {
	Hostname    string `json:"hostname"`
	Uptime      int64  `json:"uptime"`
	CPU         string `json:"cpu"`
	RAMTotal    string `json:"ram_total"`
	RAMUsed     string `json:"ram_used"`
	Storage     string `json:"storage"`
}

func main() {
	var err error
	db, err = sql.Open("sqlite3", "/opt/tooocadix-panel/data/panel.db")
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	initDB()

	mux := http.NewServeMux()
	
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, "/opt/tooocadix-panel/frontend/index.html")
	})
	
	mux.HandleFunc("/api/status", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]interface{}{"status": "ok", "version": "1.0.0"})
	})
	
	mux.HandleFunc("/api/servers", func(w http.ResponseWriter, r *http.Request) {
		servers := queryServers()
		writeJSON(w, servers)
	})
	
	mux.HandleFunc("/api/system", func(w http.ResponseWriter, r *http.Request) {
		info := getSystemInfo()
		writeJSON(w, info)
	})
	
	mux.HandleFunc("/api/update", func(w http.ResponseWriter, r *http.Request) {
		result := updateSystem()
		writeJSON(w, result)
	})
	
	log.Println("Server starting on :5000")
	log.Fatal(http.ListenAndServe(":5000", mux))
}

func initDB() {
	db.Exec(`CREATE TABLE IF NOT EXISTS servers (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		name TEXT NOT NULL,
		ip TEXT NOT NULL,
		status TEXT DEFAULT 'offline'
	)`)
	
	db.Exec(`CREATE TABLE IF NOT EXISTS settings (
		key TEXT PRIMARY KEY,
		value TEXT
	)`)
	
	var count int
	db.QueryRow("SELECT COUNT(*) FROM servers").Scan(&count)
	if count == 0 {
		db.Exec("INSERT INTO servers (name, ip, status) VALUES ('demo', '192.168.1.100', 'online')")
	}
}

func queryServers() []Server {
	rows, err := db.Query("SELECT id, name, ip, status FROM servers")
	if err != nil {
		return []Server{}
	}
	defer rows.Close()
	
	var servers []Server
	for rows.Next() {
		var s Server
		rows.Scan(&s.ID, &s.Name, &s.IP, &s.Status)
		servers = append(servers, s)
	}
	return servers
}

func getSystemInfo() SystemInfo {
	info := SystemInfo{}
	info.Hostname, _ = os.Hostname()
	
	if uptimeData, err := ioutil.ReadFile("/proc/uptime"); err == nil {
		var uptime float64
		fmt.Sscanf(string(uptimeData), "%f", &uptime)
		info.Uptime = int64(uptime)
	}
	
	if cpuData, err := ioutil.ReadFile("/proc/cpuinfo"); err == nil {
		lines := strings.Split(string(cpuData), "\n")
		for _, line := range lines {
			if strings.Contains(line, "model name") {
				parts := strings.Split(line, ":")
				if len(parts) > 1 {
					info.CPU = strings.TrimSpace(parts[1])
					break
				}
			}
		}
	}
	
	if memData, err := ioutil.ReadFile("/proc/meminfo"); err == nil {
		lines := strings.Split(string(memData), "\n")
		for _, line := range lines {
			if strings.HasPrefix(line, "MemTotal:") {
				parts := strings.Fields(line)
				if len(parts) > 1 {
					info.RAMTotal = fmt.Sprintf("%s KB", parts[1])
				}
			}
			if strings.HasPrefix(line, "MemAvailable:") {
				parts := strings.Fields(line)
				if len(parts) > 1 {
					info.RAMUsed = fmt.Sprintf("%s KB", parts[1])
				}
			}
		}
	}
	
	if stat := os.Stat("/"); stat != nil {
		free := int(stat.Sys().(*syscall.Stat_t).Blocks) * 4 / 1024
		info.Storage = fmt.Sprintf("%d KB free", free)
	}
	
	return info
}

func updateSystem() map[string]interface{} {
	result := map[string]interface{}{"status": "ok"}
	
	cmd := exec.Command("apt-get", "update")
	output, err := cmd.CombinedOutput()
	if err != nil {
		result["error"] = string(output)
	}
	
	return result
}

func writeJSON(w http.ResponseWriter, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(data)
}

func init() {
	log.SetFlags(log.Ldate | log.Ltime | log.Lshortfile)
}
GOEOF

    log_info "Go backend written"
}

write_frontend() {
    log_info "Writing TypeScript frontend..."
    
    mkdir -p "$INSTALL_DIR/frontend/src"
    
    cat > "$INSTALL_DIR/frontend/package.json" << 'NPMEOF'
{
  "name": "tooocadix-panel",
  "version": "1.0.0",
  "description": "TooO Cadix Panel - Lightweight VPS Control Panel",
  "main": "index.js",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "react": "^18.2.0",
    "react-dom": "^18.2.0"
  },
  "devDependencies": {
    "@vitejs/plugin-react": "^3.1.0",
    "vite": "^4.4.0"
  }
}
NPMEOF

    cat > "$INSTALL_DIR/frontend/vite.config.js" << 'VITEOF'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    port: 3000,
    proxy: {
      '/api': 'http://localhost:5000'
    }
  }
})
VITEOF

    cat > "$INSTALL_DIR/frontend/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>TooO Cadix Panel</title>
    <script type="module" src="/src/main.jsx"></script>
</head>
<body>
    <div id="root"></div>
    <script type="module">
        import React from 'https://esm.sh/react@18';
        import ReactDOM from 'https://esm.sh/react-dom@18';
        
        const App = () => React.createElement('div', {style: {padding: '20px', fontFamily: 'Arial, sans-serif'}},
            React.createElement('h1', null, 'TooO Cadix Panel v1.0.0'),
            React.createElement('div', {id: 'stats'}, 'Loading...')
        );
        
        ReactDOM.createRoot(document.getElementById('root')).render(React.createElement(App));
    </script>
</body>
</html>
HTMLEOF

    cat > "$INSTALL_DIR/frontend/src/main.jsx" << 'JSEOF'
import React, { useEffect, useState } from 'react';
import ReactDOM from 'react-dom/client';

function App() {
    const [status, setStatus] = useState('Loading...');
    
    useEffect(() => {
        fetch('/api/status')
            .then(r => r.json())
            .then(data => setStatus(`Status: ${data.status}`))
            .catch(e => setStatus('Error loading status'));
    }, []);
    
    return (
        <div style={{padding: '20px', fontFamily: 'Arial, sans-serif'}}>
            <h1>TooO Cadix Panel</h1>
            <p>{status}</p>
        </div>
    );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
JSEOF

    log_info "Frontend files written"
}

setup_nginx() {
    log_info "Configuring nginx..."
    
    cat > /etc/nginx/sites-available/tooocadix << 'NGINXCONF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINXCONF

    mkdir -p /etc/nginx/sites-enabled
    ln -sf /etc/nginx/sites-available/tooocadix /etc/nginx/sites-enabled/tooocadix
    rm -f /etc/nginx/sites-enabled/default
    
    nginx -t 2>/dev/null && systemctl restart nginx 2>/dev/null || log_warn "Nginx config issue"
    log_info "Nginx configured"
}

setup_systemd() {
    log_info "Creating systemd service..."
    
    cat > /etc/systemd/system/tooocadix-panel.service << SVCEOF
[Unit]
Description=TooO Cadix Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/go run app/main.go
Restart=always
RestartSec=10
Environment=PATH=/usr/local/go/bin:/usr/bin

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "$SERVICE_NAME" 2>/dev/null || true
    systemctl start "$SERVICE_NAME" 2>/dev/null || true
    
    log_info "Service created"
}

init_database() {
    log_info "Initializing database..."
    
    cat > "$INSTALL_DIR/app/schema.sql" << 'SQLEOF'
CREATE TABLE IF NOT EXISTS servers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    ip TEXT NOT NULL,
    status TEXT DEFAULT 'offline',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT
);

CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
SQLEOF

    touch "$INSTALL_DIR/data/panel.db"
    
    log_info "Database initialized"
}

setup_firewall() {
    log_info "Configuring firewall..."
    
    ufw --force reset 2>/dev/null || true
    ufw default deny incoming 2>/dev/null || true
    ufw default allow outgoing 2>/dev/null || true
    ufw allow 22/tcp 2>/dev/null || true
    ufw allow 80/tcp 2>/dev/null || true
    ufw allow 443/tcp 2>/dev/null || true
    ufw allow 5000/tcp 2>/dev/null || true
    ufw --force enable 2>/dev/null || true
    
    log_info "Firewall configured"
}

configure_ssl() {
    local domain="$1"
    local email="$2"
    
    if [[ -n "$domain" ]]; then
        log_info "Configuring SSL for $domain..."
        certbot --nginx -d "$domain" -d "www.$domain" \
            --email "$email" --agree-tos --redirect --non-interactive 2>/dev/null || \
        log_warn "SSL setup had issues"
        log_info "SSL configured"
    fi
}

show_completion() {
    local ip=$(hostname -I | awk '{print $1}')
    
    cat << EOF

========================================
  TooO Cadix Panel v$VERSION
========================================

Access: http://$ip
API: http://$ip/api/status

Backend: Go (Golang)
Frontend: TypeScript + React

EOF
}

usage() {
    cat << USAGE
Usage: $0 [OPTIONS]

Options:
  -d, --domain DOMAIN    Domain for SSL certificate
  -e, --email EMAIL      Email for Let's Encrypt registration
  -h, --help             Show this help

Examples:
  $0
  $0 -d panel.example.com -e admin@example.com
USAGE
}

main() {
    local DOMAIN="" EMAIL=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--domain) DOMAIN="$2"; shift 2 ;;
            -e|--email) EMAIL="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) log_error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done
    
    show_banner
    check_root
    detect_os
    
    prepare_system
    install_dependencies
    setup_panel_environment
    write_go_backend
    init_database
    setup_nginx
    setup_systemd
    setup_firewall
    
    if [[ -n "$DOMAIN" ]]; then
        configure_ssl "$DOMAIN" "${EMAIL:-admin@$DOMAIN}"
    fi
    
    show_completion
    log_info "Installation complete! Check http://$ip for the control panel"
}

main "$@"