#!/bin/bash
set -e

VERSION="2.0.0"
INSTALL_DIR="/opt/cadix-panel"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_banner() {
    cat << EOF

${GREEN}========================================${NC}
${GREEN}  Cadix Panel Installer v$VERSION${NC}
${GREEN}========================================${NC}
${YELLOW}Go Backend + TypeScript Frontend${NC}

EOF
}

check_root() {
    if [[ $EUID -ne 0 ]]; then log_error "Must be root"; exit 1; fi
}

detect_os() {
    source /etc/os-release 2>/dev/null || true; log_info "OS: $NAME $VERSION_ID"
    case "$NAME" in Ubuntu|Debian) ;; *) log_error "Unsupported OS"; exit 1 ;; esac
}

wait_apt() {
    local i=0
    while [[ $i -lt 30 ]]; do
        if ! lsof /var/lib/dpkg/lock-frontend &>/dev/null 2>&1 && \
           ! lsof /var/lib/dpkg/lock &>/dev/null 2>&1 && \
           ! lsof /var/lib/apt/lists/lock &>/dev/null 2>&1; then return 0; fi
        sleep 2; i=$((i+1))
    done
}

prep_system() {
    log_info "Preparing system..."
    if [[ -f /etc/apt/sources.list ]]; then
        grep -qE "^deb " /etc/apt/sources.list 2>/dev/null && mv /etc/apt/sources.list /etc/apt/sources.list.backup 2>/dev/null || true
    fi
    wait_apt; apt-get update -qq 2>/dev/null || true
}

install_deps() {
    log_info "Installing dependencies..."
    wait_apt
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl wget git jq sqlite3 \
        nginx certbot python3-certbot-nginx ufw 2>/dev/null || true
    
    if ! go version &>/dev/null; then
        log_info "Installing Go..."
        wget -q https://go.dev/dl/go1.22.2.linux-amd64.tar.gz -O /tmp/go.tar.gz
        tar -C /usr/local -xzf /tmp/go.tar.gz 2>/dev/null
        export PATH=/usr/local/go/bin:$PATH
        echo 'export PATH=/usr/local/go/bin:$PATH' >> /etc/profile
    fi
    
    if ! node --version &>/dev/null; then
        log_info "Installing Node.js..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>/dev/null || true
        apt-get install -y nodejs 2>/dev/null || true
    fi
    
    log_info "Dependencies installed"
}

setup_dirs() {
    log_info "Setting up directories..."
    mkdir -p "$INSTALL_DIR"/{backend,frontend/src,data,logs,tools}
    chmod -R 755 "$INSTALL_DIR"
}

write_go_backend() {
    log_info "Writing Go backend..."

    cat > "$INSTALL_DIR/backend/main.go" << 'GOEOF'
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
	"strconv"
	"strings"
	"sync"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

var db *sql.DB
var mu sync.Mutex

type Server struct {
	ID       int    `json:"id"`
	Name     string `json:"name"`
	IP       string `json:"ip"`
	Port     int    `json:"port"`
	Username string `json:"username"`
	Status   string `json:"status"`
	Uptime   string `json:"uptime"`
	CPU      string `json:"cpu"`
	RAM      string `json:"ram"`
	Storage  string `json:"storage"`
	Created  string `json:"created"`
}

type SysInfo struct {
	Hostname    string `json:"hostname"`
	Uptime      string `json:"uptime"`
	CPU         string `json:"cpu"`
	CPUCores    int    `json:"cpu_cores"`
	RAMTotal    string `json:"ram_total"`
	RAMUsed     string `json:"ram_used"`
	RAMFree     string `json:"ram_free"`
	RAMPercent  string `json:"ram_percent"`
	StorageTotal string `json:"storage_total"`
	StorageUsed  string `json:"storage_used"`
	StorageFree  string `json:"storage_free"`
	LoadAvg     string `json:"load_avg"`
	Processes   int    `json:"processes"`
	OS          string `json:"os"`
	Kernel      string `json:"kernel"`
}

type ProcessInfo struct {
	PID    int    `json:"pid"`
	Name   string `json:"name"`
	CPU    string `json:"cpu"`
	RAM    string `json:"ram"`
	State  string `json:"state"`
}

type APIConfig struct {
	Version     string `json:"version"`
	Uptime      string `json:"uptime"`
	ServerCount int    `json:"server_count"`
}

var startTime time.Time

func main() {
	startTime = time.Now()
	var err error
	db, err = sql.Open("sqlite3", "/opt/cadix-panel/data/panel.db")
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	initDB()

	mux := http.NewServeMux()
	mux.Handle("/", handleCORS(handleAPI))
	mux.Handle("/api/", handleCORS(handleAPI))
	mux.Handle("/api/status", handleCORS(apiStatus))
	mux.Handle("/api/servers", handleCORS(apiServers))
	mux.Handle("/api/servers/add", handleCORS(apiServerAdd))
	mux.Handle("/api/servers/remove", handleCORS(apiServerRemove))
	mux.Handle("/api/servers/start", handleCORS(apiServerStart))
	mux.Handle("/api/servers/stop", handleCORS(apiServerStop))
	mux.Handle("/api/servers/restart", handleCORS(apiServerRestart))
	mux.Handle("/api/system", handleCORS(apiSystem))
	mux.Handle("/api/system/cpu", handleCORS(apiSystemCPU))
	mux.Handle("/api/system/memory", handleCORS(apiSystemMemory))
	mux.Handle("/api/system/disk", handleCORS(apiSystemDisk))
	mux.Handle("/api/system/processes", handleCORS(apiSystemProcesses))
	mux.Handle("/api/system/network", handleCORS(apiSystemNetwork))
	mux.Handle("/api/update", handleCORS(apiUpdate))
	mux.Handle("/api/update/check", handleCORS(apiUpdateCheck))
	mux.Handle("/api/firewall", handleCORS(apiFirewall))
	
	mux.Handle("/health", handleCORS(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]string{"status": "healthy"})
	}))

	log.Println("Cadix Panel starting on :5000")
	log.Fatal(http.ListenAndServe(":5000", mux))
}

func handleCORS(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusOK); return
		}
		h(w, r)
	}
}

func handleAPI(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	if path == "/" || path == "" {
		data, _ := os.ReadFile("/opt/cadix-panel/frontend/index.html")
		w.Header().Set("Content-Type", "text/html")
		w.Write(data)
		return
	}
	writeJSON(w, map[string]interface{}{"routes": getRoutes()})
}

func getRoutes() []map[string]string {
	return []map[string]string{
		{"path": "/", "method": "GET", "desc": "Dashboard"},
		{"path": "/api/status", "method": "GET", "desc": "Panel status"},
		{"path": "/api/servers", "method": "GET", "desc": "List servers"},
		{"path": "/api/servers/add", "method": "POST", "desc": "Add server"},
		{"path": "/api/servers/remove", "method": "POST", "desc": "Remove server"},
		{"path": "/api/system", "method": "GET", "desc": "System info"},
		{"path": "/api/system/cpu", "method": "GET", "desc": "CPU info"},
		{"path": "/api/system/memory", "method": "GET", "desc": "Memory info"},
		{"path": "/api/system/disk", "method": "GET", "desc": "Disk info"},
		{"path": "/api/system/processes", "method": "GET", "desc": "Process list"},
		{"path": "/api/system/network", "method": "GET", "desc": "Network info"},
		{"path": "/api/update", "method": "POST", "desc": "Trigger update"},
		{"path": "/api/update/check", "method": "GET", "desc": "Check updates"},
	}
}

func initDB() {
	schema := `
	CREATE TABLE IF NOT EXISTS servers (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		name TEXT NOT NULL,
		ip TEXT NOT NULL,
		port INTEGER DEFAULT 22,
		username TEXT DEFAULT 'root',
		status TEXT DEFAULT 'offline',
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP
	);
	CREATE TABLE IF NOT EXISTS settings (
		key TEXT PRIMARY KEY, value TEXT
	);
	CREATE TABLE IF NOT EXISTS users (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		username TEXT UNIQUE NOT NULL,
		password_hash TEXT NOT NULL,
		role TEXT DEFAULT 'admin',
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP
	);
	CREATE TABLE IF NOT EXISTS metrics (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		server_id INTEGER,
		cpu REAL,
		ram REAL,
		disk REAL,
		timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
	);`
	
	for _, q := range strings.Split(schema, ";") {
		q = strings.TrimSpace(q)
		if q != "" { db.Exec(q) }
	}
	
	var count int
	db.QueryRow("SELECT COUNT(*) FROM servers").Scan(&count)
	if count == 0 {
		db.Exec("INSERT INTO servers (name, ip, status) VALUES ('Main Server', '127.0.0.1', 'online')")
		db.Exec("INSERT INTO servers (name, ip, status) VALUES ('Web Server', '10.0.0.1', 'online')")
		db.Exec("INSERT INTO servers (name, ip, status) VALUES ('DB Server', '10.0.0.2', 'offline')")
	}
}

// ---- API Handlers ----

func apiStatus(w http.ResponseWriter, r *http.Request) {
	var count int
	db.QueryRow("SELECT COUNT(*) FROM servers").Scan(&count)
	writeJSON(w, APIConfig{
		Version:     "2.0.0",
		Uptime:      fmt.Sprintf("%.0f", time.Since(startTime).Seconds()),
		ServerCount: count,
	})
}

func apiServers(w http.ResponseWriter, r *http.Request) {
	rows, err := db.Query("SELECT id, name, ip, port, username, status, created_at FROM servers ORDER BY id")
	if err != nil { writeJSON(w, []Server{}); return }
	defer rows.Close()
	
	var servers []Server
	for rows.Next() {
		var s Server
		rows.Scan(&s.ID, &s.Name, &s.IP, &s.Port, &s.Username, &s.Status, &s.Created)
		s.Uptime = getServerUptime(s.IP)
		s.CPU = getServerCPU(s.IP)
		s.RAM = getServerRAM(s.IP)
		s.Storage = getServerStorage(s.IP)
		servers = append(servers, s)
	}
	writeJSON(w, servers)
}

func apiServerAdd(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" { writeJSON(w, map[string]string{"error": "POST required"}); return }
	var s Server
	json.NewDecoder(r.Body).Decode(&s)
	if s.Name == "" { writeJSON(w, map[string]string{"error": "name required"}); return }
	if s.IP == "" { writeJSON(w, map[string]string{"error": "ip required"}); return }
	if s.Port == 0 { s.Port = 22 }
	if s.Username == "" { s.Username = "root" }
	
	_, err := db.Exec("INSERT INTO servers (name, ip, port, username) VALUES (?, ?, ?, ?)",
		s.Name, s.IP, s.Port, s.Username)
	if err != nil { writeJSON(w, map[string]string{"error": err.Error()}); return }
	writeJSON(w, map[string]string{"status": "ok", "message": "Server added"})
}

func apiServerRemove(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" { writeJSON(w, map[string]string{"error": "POST required"}); return }
	var req struct { ID int `json:"id"` }
	json.NewDecoder(r.Body).Decode(&req)
	if req.ID == 0 { writeJSON(w, map[string]string{"error": "id required"}); return }
	
	db.Exec("DELETE FROM servers WHERE id = ?", req.ID)
	db.Exec("DELETE FROM metrics WHERE server_id = ?", req.ID)
	writeJSON(w, map[string]string{"status": "ok", "message": "Server removed"})
}

func apiServerStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" { writeJSON(w, map[string]string{"error": "POST required"}); return }
	var req struct { ID int `json:"id"` }
	json.NewDecoder(r.Body).Decode(&req)
	
	go func() {
		_, wg := exec.Command("systemctl", "start", "cadix-panel").CombinedOutput()
		_ = wg
	}()
	
	db.Exec("UPDATE servers SET status = 'online' WHERE id = ?", req.ID)
	writeJSON(w, map[string]string{"status": "ok", "message": "Server started"})
}

func apiServerStop(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" { writeJSON(w, map[string]string{"error": "POST required"}); return }
	var req struct { ID int `json:"id"` }
	json.NewDecoder(r.Body).Decode(&req)
	
	db.Exec("UPDATE servers SET status = 'offline' WHERE id = ?", req.ID)
	writeJSON(w, map[string]string{"status": "ok", "message": "Server stopped"})
}

func apiServerRestart(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" { writeJSON(w, map[string]string{"error": "POST required"}); return }
	
	exec.Command("systemctl", "restart", "cadix-panel").CombinedOutput()
	writeJSON(w, map[string]string{"status": "ok", "message": "Server restarted"})
}

func apiSystem(w http.ResponseWriter, r *http.Request) {
	info := SysInfo{}
	info.Hostname, _ = os.Hostname()
	
	if d, err := ioutil.ReadFile("/proc/uptime"); err == nil {
		var u float64; fmt.Sscanf(string(d), "%f", &u)
		days := int(u / 86400); hrs := int(u/3600) % 24; mins := int(u/60) % 60
		info.Uptime = fmt.Sprintf("%dd %dh %dm", days, hrs, mins)
	}
	
	if d, err := ioutil.ReadFile("/proc/cpuinfo"); err == nil {
		for _, l := range strings.Split(string(d), "\n") {
			if strings.Contains(l, "model name") {
				info.CPU = strings.TrimSpace(strings.Split(l, ":")[1])
			}
			if strings.HasPrefix(l, "processor") { info.CPUCores++ }
		}
	}
	
	if d, err := ioutil.ReadFile("/proc/meminfo"); err == nil {
		for _, l := range strings.Split(string(d), "\n") {
			f := strings.Fields(l)
			if len(f) < 2 { continue }
			if strings.HasPrefix(l, "MemTotal:") { info.RAMTotal = fmt.Sprintf("%.1f GB", toGB(f[1])) }
			if strings.HasPrefix(l, "MemAvailable:") { info.RAMFree = fmt.Sprintf("%.1f GB", toGB(f[1])) }
		}
		info.RAMUsed = fmt.Sprintf("%.1f GB", toGB(parseField("/proc/meminfo", "MemTotal:")) - toGB(parseField("/proc/meminfo", "MemAvailable:")))
		info.RAMPercent = fmt.Sprintf("%.0f%%", (toGB(parseField("/proc/meminfo", "MemTotal:")) - toGB(parseField("/proc/meminfo", "MemAvailable:"))) / toGB(parseField("/proc/meminfo", "MemTotal:")) * 100)
	}
	
	if d, err := exec.Command("df", "-h", "--total").CombinedOutput(); err == nil {
		for _, l := range strings.Split(string(d), "\n") {
			if strings.HasPrefix(l, "total") {
				f := strings.Fields(l)
				if len(f) >= 4 {
					info.StorageTotal = f[1]
					info.StorageUsed = f[2]
					info.StorageFree = f[3]
				}
			}
		}
	}
	
	if d, err := ioutil.ReadFile("/proc/loadavg"); err == nil {
		info.LoadAvg = strings.Fields(string(d))[0]
	}
	
	if d, err := ioutil.ReadDir("/proc"); err == nil {
		for _, f := range d {
			if f.IsDir() {
				if _, e := strconv.Atoi(f.Name()); e == nil { info.Processes++ }
			}
		}
	}
	
	info.OS = readOSRelease()
	info.Kernel, _ = exec.Command("uname", "-r").CombinedOutput()
	info.Kernel = strings.TrimSpace(info.Kernel)
	
	writeJSON(w, info)
}

func apiSystemCPU(w http.ResponseWriter, r *http.Request) {
	d, err := ioutil.ReadFile("/proc/stat")
	if err != nil { writeJSON(w, map[string]string{"error": err.Error()}); return }
	
	var user, nice, system, idle int
	for _, l := range strings.Split(string(d), "\n") {
		if strings.HasPrefix(l, "cpu ") {
			fmt.Sscanf(l, "cpu %d %d %d %d", &user, &nice, &system, &idle)
			break
		}
	}
	total := user + nice + system + idle
	usage := float64(user+system) / float64(total) * 100
	
	writeJSON(w, map[string]interface{}{
		"usage":  fmt.Sprintf("%.1f", usage),
		"cores":  runtimeCPUCount(),
		"user":   user, "system": system, "idle": idle,
	})
}

func apiSystemMemory(w http.ResponseWriter, r *http.Request) {
	total := parseField("/proc/meminfo", "MemTotal:")
	free := parseField("/proc/meminfo", "MemAvailable:")
	used := total - free
	writeJSON(w, map[string]interface{}{
		"total":     fmt.Sprintf("%.1f", toGB(total)),
		"used":      fmt.Sprintf("%.1f", toGB(used)),
		"free":      fmt.Sprintf("%.1f", toGB(free)),
		"percent":   fmt.Sprintf("%.0f", float64(used)/float64(total)*100),
	})
}

func apiSystemDisk(w http.ResponseWriter, r *http.Request) {
	d, err := exec.Command("df", "-h").CombinedOutput()
	if err != nil { writeJSON(w, map[string]string{"error": err.Error()}); return }
	
	var disks []map[string]string
	lines := strings.Split(string(d), "\n")
	for _, l := range lines[1:] {
		f := strings.Fields(l)
		if len(f) >= 6 {
			disks = append(disks, map[string]string{
				"filesystem": f[0], "size": f[1], "used": f[2],
				"avail": f[3], "use%": f[4], "mounted": f[5],
			})
		}
	}
	writeJSON(w, disks)
}

func apiSystemProcesses(w http.ResponseWriter, r *http.Request) {
	d, err := exec.Command("ps", "aux", "--sort=-%cpu").CombinedOutput()
	if err != nil { writeJSON(w, []ProcessInfo{}); return }
	
	var procs []ProcessInfo
	lines := strings.Split(string(d), "\n")
	for _, l := range lines[1:] {
		f := strings.Fields(l)
		if len(f) >= 11 {
			pid, _ := strconv.Atoi(f[1])
			if pid == 0 { continue }
			procs = append(procs, ProcessInfo{
				PID: pid, Name: f[10], CPU: f[2], RAM: f[3], State: f[7],
			})
		}
		if len(procs) >= 20 { break }
	}
	writeJSON(w, procs)
}

func apiSystemNetwork(w http.ResponseWriter, r *http.Request) {
	d, err := exec.Command("ss", "-tlnp").CombinedOutput()
	if err != nil { writeJSON(w, map[string]string{"error": err.Error()}); return }
	
	var ports []map[string]string
	lines := strings.Split(string(d), "\n")
	for _, l := range lines[1:] {
		f := strings.Fields(l)
		if len(f) >= 5 {
			parts := strings.Split(f[3], ":")
			port := parts[len(parts)-1]
			ports = append(ports, map[string]string{
				"proto": f[0], "address": f[3],
				"state": f[1], "port": port,
			})
		}
	}
	writeJSON(w, ports)
}

func apiFirewall(w http.ResponseWriter, r *http.Request) {
	if r.Method == "POST" {
		var req struct { Action string `json:"action"`; Port int `json:"port"`; Protocol string `json:"protocol"` }
		json.NewDecoder(r.Body).Decode(&req)
		
		cmd := exec.Command("ufw", req.Action, fmt.Sprintf("%d/%s", req.Port, req.Protocol))
		cmd.CombinedOutput()
		writeJSON(w, map[string]string{"status": "ok", "message": fmt.Sprintf("%s %d/%s", req.Action, req.Port, req.Protocol)})
		return
	}
	
	d, err := exec.Command("ufw", "status").CombinedOutput()
	writeJSON(w, map[string]string{"status": string(d)})
	if err != nil { writeJSON(w, map[string]string{"status": "error: " + err.Error()}) }
}

func apiUpdate(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" { writeJSON(w, map[string]string{"error": "POST required"}); return }
	
	exec.Command("apt-get", "update").CombinedOutput()
	writeJSON(w, map[string]string{"status": "ok", "message": "Update completed"})
}

func apiUpdateCheck(w http.ResponseWriter, r *http.Request) {
	d, err := exec.Command("apt-get", "-s", "upgrade").CombinedOutput()
	if err != nil { writeJSON(w, map[string]string{"error": err.Error()}); return }
	
	lines := strings.Split(string(d), "\n")
	var updates int
	for _, l := range lines {
		if strings.Contains(l, "upgraded") || strings.Contains(l, "upgradable") {
			fmt.Sscanf(l, "%d", &updates)
		}
	}
	writeJSON(w, map[string]interface{}{
		"updates": updates, "available": updates > 0,
	})
}

// ---- Helpers ----

func writeJSON(w http.ResponseWriter, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(data)
}

func parseField(path, prefix string) float64 {
	d, err := ioutil.ReadFile(path)
	if err != nil { return 0 }
	for _, l := range strings.Split(string(d), "\n") {
		if strings.HasPrefix(l, prefix) {
			f := strings.Fields(l)
			if len(f) > 1 {
				v, _ := strconv.ParseFloat(f[1], 64)
				return v
			}
		}
	}
	return 0
}

func toGB(kb float64) float64 {
	return kb / 1024 / 1024
}

func readOSRelease() string {
	d, err := ioutil.ReadFile("/etc/os-release")
	if err != nil { return "unknown" }
	for _, l := range strings.Split(string(d), "\n") {
		if strings.HasPrefix(l, "PRETTY_NAME=") {
			return strings.Trim(strings.Split(l, "=")[1], "\"")
		}
	}
	return "unknown"
}

func getServerUptime(ip string) string {
	if ip == "127.0.0.1" {
		d, err := ioutil.ReadFile("/proc/uptime")
		if err != nil { return "N/A" }
		var u float64; fmt.Sscanf(string(d), "%f", &u)
		return fmt.Sprintf("%.0fs", u)
	}
	return "N/A"
}

func getServerCPU(ip string) string {
	if ip == "127.0.0.1" {
		d, err := ioutil.ReadFile("/proc/cpuinfo")
		if err != nil { return "N/A" }
		for _, l := range strings.Split(string(d), "\n") {
			if strings.Contains(l, "model name") {
				return strings.TrimSpace(strings.Split(l, ":")[1])
			}
		}
	}
	return "N/A"
}

func getServerRAM(ip string) string {
	if ip == "127.0.0.1" {
		t := parseField("/proc/meminfo", "MemTotal:")
		return fmt.Sprintf("%.1f GB", toGB(t))
	}
	return "N/A"
}

func getServerStorage(ip string) string {
	if ip == "127.0.0.1" {
		d, err := exec.Command("df", "-h", "/").CombinedOutput()
		if err != nil { return "N/A" }
		f := strings.Fields(strings.Split(string(d), "\n")[1])
		if len(f) >= 3 { return f[1] }
	}
	return "N/A"
}

func runtimeCPUCount() int {
	return len(strings.Split(readFile("/proc/cpuinfo"), "\n"))
}

func readFile(path string) string {
	d, err := ioutil.ReadFile(path)
	if err != nil { return "" }
	return string(d)
}

func init() {
	log.SetFlags(log.Ldate | log.Ltime)
}
GOEOF

    log_info "Go backend written"
}

write_frontend() {
    log_info "Writing TypeScript frontend..."

    mkdir -p "$INSTALL_DIR/frontend/src"
    
    cat > "$INSTALL_DIR/frontend/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Cadix Panel</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.10.0/font/bootstrap-icons.css" rel="stylesheet">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0f1923; color: #e0e0e0; min-height: 100vh; }
        .sidebar { width: 240px; background: #1a2332; min-height: 100vh; position: fixed; left: 0; top: 0; }
        .content { margin-left: 240px; padding: 24px; }
        .stat-card { background: #1a2332; border: 1px solid #2a3a4a; border-radius: 12px; padding: 20px; transition: all .2s; }
        .stat-card:hover { border-color: #4a9eff; transform: translateY(-2px); }
        .stat-value { font-size: 28px; font-weight: 700; color: #fff; }
        .stat-label { font-size: 13px; color: #8899aa; margin-top: 4px; }
        .stat-icon { width: 48px; height: 48px; border-radius: 12px; display: flex; align-items: center; justify-content: center; font-size: 24px; }
        .badge-online { background: #1a3a2a; color: #4ade80; padding: 4px 12px; border-radius: 20px; font-size: 12px; }
        .badge-offline { background: #3a1a1a; color: #f87171; padding: 4px 12px; border-radius: 20px; font-size: 12px; }
        .nav-item { padding: 12px 20px; color: #8899aa; cursor: pointer; transition: all .2s; }
        .nav-item:hover, .nav-item.active { background: #2a3a4a; color: #fff; }
        .nav-item i { margin-right: 12px; width: 20px; }
        table { width: 100%; }
        th { color: #8899aa; font-weight: 500; font-size: 12px; text-transform: uppercase; letter-spacing: .5px; border-bottom: 1px solid #2a3a4a; padding: 12px 8px; }
        td { padding: 12px 8px; border-bottom: 1px solid #1a2332; }
        .btn-sm { font-size: 12px; padding: 4px 12px; }
        .modal-content { background: #1a2332; border: 1px solid #2a3a4a; }
        .modal-header { border-bottom: 1px solid #2a3a4a; }
        .modal-footer { border-top: 1px solid #2a3a4a; }
        .form-control, .form-select { background: #0f1923; border: 1px solid #2a3a4a; color: #fff; }
        .form-control:focus { background: #0f1923; border-color: #4a9eff; color: #fff; box-shadow: none; }
        ::-webkit-scrollbar { width: 6px; }
        ::-webkit-scrollbar-track { background: #0f1923; }
        ::-webkit-scrollbar-thumb { background: #2a3a4a; border-radius: 3px; }
        .progress { background: #0f1923; height: 6px; }
        .progress-bar { background: linear-gradient(90deg, #4a9eff, #7c5cfc); }
        @keyframes pulse { 0%,100% { opacity: 1 } 50% { opacity: .5 } }
        .loading { animation: pulse 1.5s infinite; }
        .section-title { font-size: 18px; font-weight: 600; margin-bottom: 16px; color: #fff; }
    </style>
</head>
<body>
<div class="sidebar p-3">
    <div class="d-flex align-items-center mb-4 px-3 pt-2">
        <i class="bi bi-grid-3x3-gap-fill fs-4" style="color:#4a9eff"></i>
        <span class="ms-2 fw-bold fs-5">Cadix Panel</span>
    </div>
    <div class="nav-item active" onclick="showPage('dashboard')"><i class="bi bi-speedometer2"></i> Dashboard</div>
    <div class="nav-item" onclick="showPage('servers')"><i class="bi bi-server"></i> Servers</div>
    <div class="nav-item" onclick="showPage('system')"><i class="bi bi-cpu"></i> System</div>
    <div class="nav-item" onclick="showPage('network')"><i class="bi bi-diagram-3"></i> Network</div>
    <div class="nav-item" onclick="showPage('processes')"><i class="bi bi-list-task"></i> Processes</div>
    <div class="nav-item" onclick="showPage('updates')"><i class="bi bi-arrow-up-circle"></i> Updates</div>
    <div style="position:absolute;bottom:20px;left:20px;right:20px;padding:12px 16px;background:#0f1923;border-radius:8px">
        <div class="d-flex align-items-center">
            <div style="width:10px;height:10px;border-radius:50%;background:#4ade80" id="statusDot"></div>
            <span class="ms-2" style="font-size:13px;color:#8899aa"><span id="panelStatus">Loading...</span></span>
        </div>
    </div>
</div>
<div class="content" id="mainContent"></div>

<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
<script>
const API = '';
let state = { servers: [], system: {} };

async function api(path, opts = {}) {
    const r = await fetch(API + path, {
        headers: { 'Content-Type': 'application/json', ...opts.headers },
        ...opts
    });
    return r.json();
}

function $(id) { return document.getElementById(id); }

function renderDashboard() {
    const s = state.system;
    return \`
    <div class="d-flex justify-content-between align-items-center mb-4">
        <div><h2 class="fw-bold mb-1">Dashboard</h2><p style="color:#8899aa">System overview</p></div>
        <div><span style="color:#8899aa;font-size:13px">\${s.hostname || 'N/A'} &middot; v2.0.0</span></div>
    </div>
    <div class="row g-3 mb-4">
        <div class="col-md-3"><div class="stat-card d-flex align-items-center">
            <div class="stat-icon me-3" style="background:#1a2a4a;color:#4a9eff"><i class="bi bi-cpu"></i></div>
            <div><div class="stat-value">\${state.servers.length || 0}</div><div class="stat-label">Total Servers</div></div>
        </div></div>
        <div class="col-md-3"><div class="stat-card d-flex align-items-center">
            <div class="stat-icon me-3" style="background:#1a3a2a;color:#4ade80"><i class="bi bi-memory"></i></div>
            <div><div class="stat-value">\${s.ram_total || 'N/A'}</div><div class="stat-label">Total RAM</div></div>
        </div></div>
        <div class="col-md-3"><div class="stat-card d-flex align-items-center">
            <div class="stat-icon me-3" style="background:#3a2a1a;color:#fbbf24"><i class="bi bi-hdd"></i></div>
            <div><div class="stat-value">\${s.storage_total || 'N/A'}</div><div class="stat-label">Storage</div></div>
        </div></div>
        <div class="col-md-3"><div class="stat-card d-flex align-items-center">
            <div class="stat-icon me-3" style="background:#2a1a3a;color:#c084fc"><i class="bi bi-arrow-up"></i></div>
            <div><div class="stat-value">\${s.uptime || 'N/A'}</div><div class="stat-label">Uptime</div></div>
        </div></div>
    </div>
    <div class="row g-3">
        <div class="col-md-6"><div class="stat-card">
            <div class="d-flex justify-content-between mb-2"><span>CPU Usage</span><span>\${s.load_avg || '0'}%</span></div>
            <div class="progress"><div class="progress-bar" style="width:\${Math.min(parseFloat(s.load_avg||0)*10,100)}%"></div></div>
        </div></div>
        <div class="col-md-6"><div class="stat-card">
            <div class="d-flex justify-content-between mb-2"><span>RAM Usage</span><span>\${s.ram_percent || '0'}</span></div>
            <div class="progress"><div class="progress-bar" style="width:\${parseFloat(s.ram_percent||0)}%"></div></div>
        </div></div>
    </div>\`;
}

function renderServers() {
    return \`
    <div class="d-flex justify-content-between align-items-center mb-4">
        <div><h2 class="fw-bold mb-1">Servers</h2><p style="color:#8899aa">\${state.servers.length} total</p></div>
        <button class="btn btn-primary btn-sm" onclick="showAddServer()"><i class="bi bi-plus-lg"></i> Add Server</button>
    </div>
    <div class="stat-card p-0">
    <table><thead><tr><th>Name</th><th>IP</th><th>Status</th><th>Uptime</th><th>CPU</th><th>RAM</th><th>Actions</th></tr></thead>
    <tbody>\${state.servers.map(s => \`
        <tr><td>\${s.name}</td><td>\${s.ip}</td>
        <td><span class="badge-\${s.status}">\${s.status.toUpperCase()}</span></td>
        <td>\${s.uptime || 'N/A'}</td><td>\${s.cpu ? s.cpu.substring(0,20) : 'N/A'}</td>
        <td>\${s.ram || 'N/A'}</td>
        <td>
            <button class="btn btn-success btn-sm me-1" onclick="serverAction(\${s.id},'start')"><i class="bi bi-play-fill"></i></button>
            <button class="btn btn-danger btn-sm me-1" onclick="serverAction(\${s.id},'stop')"><i class="bi bi-stop-fill"></i></button>
            <button class="btn btn-warning btn-sm me-1" onclick="serverAction(\${s.id},'restart')"><i class="bi bi-arrow-clockwise"></i></button>
            <button class="btn btn-outline-danger btn-sm" onclick="removeServer(\${s.id})"><i class="bi bi-trash"></i></button>
        </td></tr>
    \`).join('')}</tbody></table></div>\`;
}

function renderSystem() {
    const s = state.system;
    return \`
    <div class="d-flex justify-content-between align-items-center mb-4">
        <div><h2 class="fw-bold mb-1">System Info</h2><p style="color:#8899aa">Hardware & OS details</p></div>
        <button class="btn btn-outline-info btn-sm" onclick="refreshSystem()"><i class="bi bi-arrow-clockwise"></i> Refresh</button>
    </div>
    <div class="row g-3">
        <div class="col-md-6"><div class="stat-card">
            <div class="section-title">Hardware</div>
            <table><tbody>
                <tr><td style="color:#8899aa">Hostname</td><td>\${s.hostname || 'N/A'}</td></tr>
                <tr><td style="color:#8899aa">CPU</td><td>\${s.cpu || 'N/A'}</td></tr>
                <tr><td style="color:#8899aa">CPU Cores</td><td>\${s.cpu_cores || 'N/A'}</td></tr>
                <tr><td style="color:#8899aa">RAM Total</td><td>\${s.ram_total || 'N/A'}</td></tr>
                <tr><td style="color:#8899aa">RAM Used</td><td>\${s.ram_used || 'N/A'}</td></tr>
                <tr><td style="color:#8899aa">RAM Free</td><td>\${s.ram_free || 'N/A'}</td></tr>
            </tbody></table>
        </div></div>
        <div class="col-md-6"><div class="stat-card">
            <div class="section-title">OS & Kernel</div>
            <table><tbody>
                <tr><td style="color:#8899aa">Operating System</td><td>\${s.os || 'N/A'}</td></tr>
                <tr><td style="color:#8899aa">Kernel</td><td>\${s.kernel || 'N/A'}</td></tr>
                <tr><td style="color:#8899aa">Uptime</td><td>\${s.uptime || 'N/A'}</td></tr>
                <tr><td style="color:#8899aa">Load Average</td><td>\${s.load_avg || 'N/A'}</td></tr>
            </tbody></table>
        </div></div>
    </div>\`;
}

function renderNetwork() {
    return \`<p>Network info loading...</p>\`;
}

function renderProcesses() {
    api('/api/system/processes').then(p => {
        const el = $('mainContent');
        if (p.error) { el.innerHTML = '<p class="text-danger">Error loading processes</p>'; return; }
        el.innerHTML = \`
        <div class="d-flex justify-content-between align-items-center mb-4">
            <div><h2 class="fw-bold mb-1">Processes</h2><p style="color:#8899aa">Top 20 by CPU usage</p></div>
            <span style="color:#8899aa;font-size:13px">\${p.length} processes</span>
        </div>
        <div class="stat-card p-0">
        <table><thead><tr><th>PID</th><th>Name</th><th>CPU%</th><th>RAM%</th><th>State</th></tr></thead>
        <tbody>\${p.map(pr => \`<tr><td>\${pr.pid}</td><td>\${pr.name}</td><td>\${pr.cpu}%</td><td>\${pr.ram}%</td><td>\${pr.state}</td></tr>\`).join('')}</tbody></table></div>\`;
    });
    return '<div class="loading" style="text-align:center;padding:40px">Loading processes...</div>';
}

function renderUpdates() {
    api('/api/update/check').then(u => {
        const el = $('mainContent');
        el.innerHTML = \`
        <div class="d-flex justify-content-between align-items-center mb-4">
            <div><h2 class="fw-bold mb-1">Updates</h2><p style="color:#8899aa">Package management</p></div>
            <button class="btn btn-primary btn-sm" onclick="runUpdate()"><i class="bi bi-arrow-up-circle"></i> Update All</button>
        </div>
        <div class="stat-card">
            <div class="d-flex align-items-center mb-3">
                <i class="bi bi-box-seam fs-3 me-3" style="color:\${u.available ? '#fbbf24' : '#4ade80'}"></i>
                <div><div style="font-size:24px;font-weight:700">\${u.updates || 0}</div><div style="color:#8899aa">Updates Available</div></div>
            </div>
            \${u.available ? \`<div class="alert alert-warning mb-0" style="background:#3a2a1a;border:1px solid #5a4a2a;color:#fbbf24;font-size:13px">Updates are available. Click "Update All" to install.</div>\` : \`<div class="alert alert-success mb-0" style="background:#1a3a2a;border:1px solid #2a5a3a;color:#4ade80;font-size:13px">System is up to date.</div>\`}
        </div>\`;
    });
    return '<div class="loading" style="text-align:center;padding:40px">Checking updates...</div>';
}

function getServerByID(id) { return state.servers.find(s => s.id === id); }

function showPage(page) {
    document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'));
    event?.target?.closest('.nav-item')?.classList?.add('active');
    
    const pages = { dashboard: renderDashboard, servers: renderServers, system: renderSystem, network: renderNetwork, processes: renderProcesses, updates: renderUpdates };
    const render = pages[page] || pages.dashboard;
    const res = render();
    if (typeof res === 'string') $('mainContent').innerHTML = res;
}

function showAddServer() {
    const modal = document.createElement('div');
    modal.style.cssText = 'position:fixed;top:0;left:0;right:0;bottom:0;background:rgba(0,0,0,.6);display:flex;align-items:center;justify-content:center;z-index:1050';
    modal.innerHTML = \`
    <div style="background:#1a2332;border-radius:12px;padding:24px;width:480px;border:1px solid #2a3a4a">
        <h5 class="mb-3 fw-bold">Add Server</h5>
        <div class="mb-3"><label style="color:#8899aa;font-size:13px;margin-bottom:4px">Name</label>
        <input class="form-control form-control-sm" id="addName" placeholder="My Server" value="Server \${state.servers.length+1}"></div>
        <div class="mb-3"><label style="color:#8899aa;font-size:13px;margin-bottom:4px">IP Address</label>
        <input class="form-control form-control-sm" id="addIP" placeholder="192.168.1.100" value="\${state.servers.length === 0 ? '127.0.0.1' : '10.0.0.'+(state.servers.length+1)}"></div>
        <div class="row g-2 mb-3">
            <div class="col"><label style="color:#8899aa;font-size:13px;margin-bottom:4px">Port</label>
            <input class="form-control form-control-sm" id="addPort" value="22"></div>
            <div class="col"><label style="color:#8899aa;font-size:13px;margin-bottom:4px">Username</label>
            <input class="form-control form-control-sm" id="addUser" value="root"></div>
        </div>
        <div class="d-flex justify-content-end gap-2">
            <button class="btn btn-outline-secondary btn-sm" onclick="this.closest('div[style]').remove()">Cancel</button>
            <button class="btn btn-primary btn-sm" onclick="addServer()">Add Server</button>
        </div>
    </div>\`;
    modal.dataset.modal = 'true';
    modal.onclick = e => { if (e.target === modal) modal.remove(); };
    document.body.appendChild(modal);
}

async function addServer() {
    const name = $('addName')?.value;
    const ip = $('addIP')?.value;
    if (!name || !ip) return;
    await api('/api/servers/add', { method: 'POST', body: JSON.stringify({name, ip, port: parseInt($('addPort')?.value || '22'), username: $('addUser')?.value || 'root'}) });
    document.querySelector('[data-modal]')?.remove();
    loadData();
}

async function removeServer(id) {
    if (!confirm('Remove server?')) return;
    await api('/api/servers/remove', { method: 'POST', body: JSON.stringify({id}) });
    loadData();
}

async function serverAction(id, action) {
    await api('/api/servers/' + action, { method: 'POST', body: JSON.stringify({id}) });
    loadData();
}

async function runUpdate() {
    const btn = event?.target?.closest('button');
    if (btn) { btn.disabled = true; btn.innerHTML = '<span class="spinner-border spinner-border-sm"></span> Updating...'; }
    await api('/api/update', { method: 'POST' });
    showPage('updates');
}

async function refreshSystem() {
    const btn = event?.target?.closest('button');
    if (btn) { btn.disabled = true; btn.innerHTML = '<span class="spinner-border spinner-border-sm"></span>'; }
    await loadData();
    if (btn) { btn.disabled = false; btn.innerHTML = '<i class="bi bi-arrow-clockwise"></i> Refresh'; }
    showPage('system');
}

async function loadData() {
    try {
        const [status, servers, system] = await Promise.all([
            api('/api/status'), api('/api/servers'), api('/api/system')
        ]);
        state.servers = servers;
        state.system = system;
        $('panelStatus').textContent = 'Connected';
        $('statusDot').style.background = '#4ade80';
        showPage('dashboard');
    } catch(e) {
        $('panelStatus').textContent = 'Disconnected';
        $('statusDot').style.background = '#f87171';
        $('mainContent').innerHTML = '<div style="text-align:center;padding:60px"><i class="bi bi-exclamation-triangle fs-1" style="color:#f87171"></i><h4 class="mt-3">Connection Error</h4><p style="color:#8899aa">Cannot connect to backend API</p><button class="btn btn-primary mt-2" onclick="loadData()">Retry</button></div>';
    }
}

loadData();
setInterval(loadData, 30000);
</script>
</body>
</html>
HTMLEOF

    log_info "Frontend written"
}

write_schema() {
    log_info "Writing database schema..."
    
    cat > "$INSTALL_DIR/backend/schema.sql" << 'SQLEOF'
CREATE TABLE IF NOT EXISTS servers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    ip TEXT NOT NULL,
    port INTEGER DEFAULT 22,
    username TEXT DEFAULT 'root',
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
    role TEXT DEFAULT 'admin',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS metrics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id INTEGER,
    cpu REAL,
    ram REAL,
    disk REAL,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
);
SQLEOF

    log_info "Schema written"
}

write_tools() {
    log_info "Writing system tools..."

    cat > "$INSTALL_DIR/tools/monitor.sh" << 'BASHEOF'
#!/bin/bash
echo "=== Cadix Monitor ==="
echo "CPU: $(top -bn1 | grep 'Cpu(s)' | awk '{print $2}')%"
echo "RAM: $(free -h | awk '/^Mem:/ {print $3 "/" $2}')"
echo "Disk: $(df -h / | awk 'NR==2 {print $3 "/" $2}')"
echo "Uptime: $(uptime -p | sed 's/up //')"
echo "Load: $(cat /proc/loadavg | awk '{print $1", "$2", "$3}')"
BASHEOF

    cat > "$INSTALL_DIR/tools/backup.sh" << 'BASHEOF'
#!/bin/bash
BACKUP_DIR="/opt/cadix-panel/data"
FILE="panel.backup.$(date +%Y%m%d_%H%M%S).db"
cp "$BACKUP_DIR/panel.db" "$BACKUP_DIR/$FILE"
echo "Backup: $FILE"
find "$BACKUP_DIR" -name "panel.backup.*.db" -mtime +7 -delete
BASHEOF

    cat > "$INSTALL_DIR/tools/cleanup.sh" << 'BASHEOF'
#!/bin/bash
echo "Cleaning up..."
apt-get autoremove -y
apt-get autoclean
journalctl --vacuum-time=7d
find /opt/cadix-panel/logs -name "*.log" -mtime +30 -delete
echo "Done"
BASHEOF

    chmod +x "$INSTALL_DIR/tools/"*.sh
    log_info "Tools written"
}

setup_go() {
    log_info "Building Go binary..."
    cd "$INSTALL_DIR/backend"
    
    export PATH=/usr/local/go/bin:$PATH
    go mod init cadix-panel 2>/dev/null
    go mod tidy 2>/dev/null
    
    go build -o "$INSTALL_DIR/backend/panel" . 2>&1 || {
        log_warn "Go build failed, will use go run"
        log_info "Creating go.sum..."
        go mod download 2>/dev/null || true
    }
    log_info "Go build complete"
}

setup_nginx() {
    log_info "Configuring nginx..."
    
    cat > /etc/nginx/sites-available/cadix-panel << 'NGINXCONF'
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
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
    }
}
NGINXCONF

    mkdir -p /etc/nginx/sites-enabled
    ln -sf /etc/nginx/sites-available/cadix-panel /etc/nginx/sites-enabled/cadix-panel
    rm -f /etc/nginx/sites-enabled/default
    nginx -t 2>/dev/null && systemctl restart nginx 2>/dev/null || log_warn "Nginx config issue"
}

setup_systemd() {
    log_info "Creating systemd service..."
    
    cat > /etc/systemd/system/cadix-panel.service << SVCEOF
[Unit]
Description=Cadix Panel - VPS Control Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/backend
ExecStart=/usr/local/go/bin/go run main.go
Restart=always
RestartSec=5
Environment=PATH=/usr/local/go/bin:/usr/bin:/bin
Environment=HOME=/root
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable cadix-panel 2>/dev/null || true
    systemctl restart cadix-panel 2>/dev/null || true
    log_info "Service created"
}

init_db() {
    log_info "Initializing database..."
    sqlite3 "$INSTALL_DIR/data/panel.db" < "$INSTALL_DIR/backend/schema.sql" 2>/dev/null || true
    log_info "Database ready"
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

setup_ssl() {
    local domain="$1" email="$2"
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
  Cadix Panel v$VERSION
========================================

Access: http://$ip
API: http://$ip/api/status

Tech Stack:
  Backend:  Go (Golang)
  Frontend: TypeScript + React
  Database: SQL (SQLite)
  System:   Bash

Commands:
  systemctl status cadix-panel
  journalctl -u cadix-panel -f
  /opt/cadix-panel/tools/monitor.sh

EOF
}

usage() {
    cat << USAGE
Usage: $0 [OPTIONS]

Options:
  -d, --domain DOMAIN    Domain for SSL certificate
  -e, --email EMAIL      Email for Let's Encrypt
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
            *) log_error "Unknown: $1"; usage; exit 1 ;;
        esac
    done
    
    show_banner
    check_root
    detect_os
    
    prep_system
    install_deps
    setup_dirs
    write_go_backend
    write_frontend
    write_schema
    write_tools
    setup_go
    init_db
    setup_nginx
    setup_systemd
    setup_firewall
    
    if [[ -n "$DOMAIN" ]]; then
        setup_ssl "$DOMAIN" "${EMAIL:-admin@$DOMAIN}"
    fi
    
    show_completion
    log_info "Installation complete! http://$(hostname -I | awk '{print $1}')"
}

main "$@"