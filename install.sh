#!/bin/bash
set -e

VERSION="1.0.0"
INSTALL_DIR="/opt/vps-panel"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_banner() {
    cat << EOF

${GREEN}========================================${NC}
${GREEN}  VPS Control Panel Installer v$VERSION${NC}
${GREEN}========================================${NC}

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
        python3 python3-pip python3-venv python3-dev python3-sqlite3 \
        python3-requests nginx certbot python3-certbot-nginx curl wget jq git \
        build-essential ufw sqlite3 2>/dev/null
    
    pip3 install flask flask-sqlalchemy requests werkzeug gunicorn -q 2>/dev/null || true
    
    log_info "Dependencies installed"
}

setup_panel_environment() {
    log_info "Setting up panel environment..."
    
    mkdir -p "$INSTALL_DIR/app" "$INSTALL_DIR/data" "$INSTALL_DIR/templates" \
        "$INSTALL_DIR/static/css" "$INSTALL_DIR/static/js" "$(dirname $INSTALL_DIR/logs)"
    
    chmod -R 755 "$INSTALL_DIR"
    
    python3 -m venv "$INSTALL_DIR/venv" 2>/dev/null || true
    
    source "$INSTALL_DIR/venv/bin/activate"
    pip3 install --upgrade pip -q 2>/dev/null
    pip3 install flask flask-sqlalchemy requests werkzeug gunicorn python-dotenv -q 2>/dev/null
    
    log_info "Environment ready"
}

write_app_files() {
    log_info "Writing application files..."
    
    cat > "$INSTALL_DIR/app/__init__.py" << 'PYEOF'
import os
import sys
sys.path.insert(0, '/opt/vps-panel')

from flask import Flask, render_template, jsonify
import json

def create_app():
    app = Flask(__name__)
    app.config['SECRET_KEY'] = os.environ.get('SECRET_KEY', 'vps-panel-secret-key-change-me')
    
    @app.route('/')
    def index():
        return render_template('index.html')
    
    @app.route('/api/status')
    def api_status():
        return jsonify({'status': 'ok', 'version': '1.0.0'})
    
    @app.route('/api/servers')
    def api_servers():
        try:
            with open('/opt/vps-panel/data/servers.json', 'r') as f:
                return jsonify(json.load(f))
        except:
            return jsonify([])
    
    @app.route('/api/system')
    def api_system():
        return jsonify({
            'hostname': os.uname().nodename,
            'uptime': get_uptime(),
            'cpu': get_cpu(),
            'ram_total': get_ram(),
            'storage': get_storage()
        })
    
    return app

def get_uptime():
    try:
        with open('/proc/uptime', 'r') as f:
            return str(int(float(f.read().split()[0])))
    except:
        return 'unknown'

def get_cpu():
    try:
        with open('/proc/cpuinfo', 'r') as f:
            for line in f:
                if 'model name' in line:
                    return line.split(':')[1].strip()
        return 'unknown'
    except:
        return 'unknown'

def get_ram():
    try:
        with open('/proc/meminfo', 'r') as f:
            for line in f:
                if line.startswith('MemTotal:'):
                    return str(int(line.split()[1]) // 1024) + ' MB'
        return 'unknown'
    except:
        return 'unknown'

def get_storage():
    try:
        return str(int(os.statvfs('/').f_blocks * os.statvfs('/').f_frsize / (1024*1024))) + ' MB'
    except:
        return 'unknown'
PYEOF

    log_info "Application files written"
}

write_templates() {
    log_info "Writing templates..."
    
    cat > "$INSTALL_DIR/templates/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>VPS Control Panel</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.10.0/font/bootstrap-icons.css" rel="stylesheet">
    <style>
        body { background: #f5f5f5; }
        .card { box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .status-online { color: #28a745; }
        .status-offline { color: #dc3545; }
    </style>
</head>
<body>
    <div class="container py-4">
        <div class="d-flex justify-content-between align-items-center mb-4">
            <h1>VPS Control Panel</h1>
            <span class="badge bg-primary">v1.0.0</span>
        </div>
        <div class="row mb-4">
            <div class="col-md-3"><div class="card"><div class="card-body">
                <i class="bi bi-server display-4 text-primary mb-2"></i>
                <h5 class="card-title">Total Servers</h5>
                <p class="card-text display-4" id="total-servers">0</p>
            </div></div></div>
            <div class="col-md-3"><div class="card"><div class="card-body">
                <i class="bi bi-cpu display-4 text-success mb-2"></i>
                <h5 class="card-title">CPU</h5>
                <p class="card-text" id="cpu-info">Loading...</p>
            </div></div></div>
            <div class="col-md-3"><div class="card"><div class="card-body">
                <i class="bi bi-memory display-4 text-warning mb-2"></i>
                <h5 class="card-title">RAM</h5>
                <p class="card-text" id="ram-info">Loading...</p>
            </div></div></div>
            <div class="col-md-3"><div class="card"><div class="card-body">
                <i class="bi bi-hdd display-4 text-danger mb-2"></i>
                <h5 class="card-title">Storage</h5>
                <p class="card-text" id="storage-info">Loading...</p>
            </div></div></div>
        </div>
        <div class="card"><div class="card-header"><h5 class="mb-0">Server Status</h5></div>
            <div class="card-body">
                <table class="table table-hover" id="servers-table">
                    <thead><tr><th>Name</th><th>IP</th><th>Status</th><th>Uptime</th></tr></thead>
                    <tbody></tbody>
                </table>
            </div>
        </div>
    </div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
    <script>
        async function loadData() {
            try {
                const [serversRes] = await Promise.all([fetch('/api/servers')]);
                const servers = await serversRes.json();
                document.getElementById('total-servers').textContent = servers.length;
                const tbody = document.querySelector('#servers-table tbody');
                tbody.innerHTML = servers.map(s => '<tr><td>'+s.name+'</td><td>'+s.ip+'</td><td><span class="status-'+s.status+'">'+s.status.toUpperCase()+'</span></td><td>'+s.uptime+'</td></tr>').join('');
            } catch(e) {}
        }
        async function loadSystemInfo() {
            try {
                const response = await fetch('/api/system');
                const data = await response.json();
                document.getElementById('cpu-info').textContent = data.cpu || 'N/A';
                document.getElementById('ram-info').textContent = data.ram_total || 'N/A';
            } catch(e) {}
        }
        loadData(); loadSystemInfo(); setInterval(loadData, 30000);
    </script>
</body>
</html>
HTMLEOF

    log_info "Templates written"
}

setup_nginx() {
    log_info "Configuring nginx..."
    
    cat > /etc/nginx/sites-available/vps-panel << 'NGINXCONF'
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
    ln -sf /etc/nginx/sites-available/vps-panel /etc/nginx/sites-enabled/vps-panel
    rm -f /etc/nginx/sites-enabled/default
    nginx -t 2>/dev/null && systemctl restart nginx 2>/dev/null || log_warn "Nginx config issue"
    log_info "Nginx configured"
}

setup_systemd() {
    log_info "Creating systemd service..."
    
    cat > /etc/systemd/system/vps-panel.service << 'SVCEOF'
[Unit]
Description=VPS Control Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/vps-panel
ExecStart=/opt/vps-panel/venv/bin/gunicorn -w 4 -b 127.0.0.1:5000 app:create_app()
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable vps-panel 2>/dev/null || true
    systemctl start vps-panel 2>/dev/null || true
    
    log_info "Service created"
}

init_data() {
    log_info "Initializing data..."
    echo '[]' > "$INSTALL_DIR/data/servers.json"
    log_info "Data initialized"
}

setup_firewall() {
    log_info "Configuring firewall..."
    
    ufw --force reset 2>/dev/null || true
    ufw default deny incoming 2>/dev/null || true
    ufw default allow outgoing 2>/dev/null || true
    ufw allow 22/tcp 2>/dev/null || true
    ufw allow 80/tcp 2>/dev/null || true
    ufw allow 443/tcp 2>/dev/null || true
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
  VPS Control Panel v$VERSION
========================================

Access: http://$ip
API: http://$ip/api/status

EOF
}

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options: -d DOMAIN, -e EMAIL, -h (help)"
    echo "Example: $0 -d vps.example.com -e admin@example.com"
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
    write_app_files
    write_templates
    init_data
    setup_nginx
    setup_systemd
    setup_firewall
    
    if [[ -n "$DOMAIN" ]]; then
        configure_ssl "$DOMAIN" "${EMAIL:-admin@$DOMAIN}"
    fi
    
    show_completion
    log_info "Installation complete!"
}

main "$@"