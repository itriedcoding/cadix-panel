#!/bin/bash
set -e

VERSION="2.0.0"
INSTALL_DIR="/opt/cadix-panel"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() { [[ $EUID -ne 0 ]] && log_error "Must be root" && exit 1; }

detect_os() {
    source /etc/os-release 2>/dev/null || true
    log_info "OS: $NAME $VERSION_ID"
    case "$NAME" in Ubuntu|Debian) ;; *) log_error "Unsupported OS"; exit 1 ;; esac
}

wait_apt() {
    local i=0
    while [[ $i -lt 60 ]]; do
        if ! lsof /var/lib/dpkg/lock-frontend &>/dev/null 2>&1 && \
           ! lsof /var/lib/dpkg/lock &>/dev/null 2>&1 && \
           ! lsof /var/lib/apt/lists/lock &>/dev/null 2>&1; then
            return 0
        fi
        sleep 2; i=$((i+1))
    done
    log_warn "apt lock timeout"
}

install_deps() {
    log_info "Installing system packages..."
    wait_apt
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl wget git jq sqlite3 nginx certbot python3-certbot-nginx ufw lsof 2>/dev/null || true

    if ! go version &>/dev/null; then
        log_info "Installing Go..."
        wget -q https://go.dev/dl/go1.22.2.linux-amd64.tar.gz -O /tmp/go.tar.gz
        rm -rf /usr/local/go
        tar -C /usr/local -xzf /tmp/go.tar.gz
        export PATH=/usr/local/go/bin:$PATH
        echo 'export PATH=/usr/local/go/bin:$PATH' >> /etc/profile
    fi

    if ! node --version &>/dev/null; then
        log_info "Installing Node.js..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>/dev/null || true
        apt-get install -y nodejs 2>/dev/null || true
    fi
    log_info "Dependencies ready"
}

setup_dirs() {
    log_info "Creating directories..."
    mkdir -p "$INSTALL_DIR"/{backend,frontend,frontend/src,data,logs,tools}
    chmod -R 755 "$INSTALL_DIR"
}

write_go_backend() {
    log_info "Writing Go backend ($(wc -l <<< 'GOEOF') lines)..."

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
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

var (
	db        *sql.DB
	mu        sync.RWMutex
	startTime time.Time
)

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
	Hostname     string `json:"hostname"`
	Uptime       string `json:"uptime"`
	CPU          string `json:"cpu"`
	CPUCores     int    `json:"cpu_cores"`
	RAMTotal     string `json:"ram_total"`
	RAMUsed      string `json:"ram_used"`
	RAMFree      string `json:"ram_free"`
	RAMPercent   string `json:"ram_percent"`
	StorageTotal string `json:"storage_total"`
	StorageUsed  string `json:"storage_used"`
	StorageFree  string `json:"storage_free"`
	LoadAvg      string `json:"load_avg"`
	Processes    int    `json:"processes"`
	OS           string `json:"os"`
	Kernel       string `json:"kernel"`
}

type RouteInfo struct {
	Path   string `json:"path"`
	Method string `json:"method"`
	Desc   string `json:"desc"`
}

type PanelStatus struct {
	Version     string `json:"version"`
	Uptime      string `json:"uptime"`
	ServerCount int    `json:"server_count"`
	GoVersion   string `json:"go_version"`
}

func main() {
	startTime = time.Now()
	initLogging()
	log.Println("Cadix Panel v2.0.0 starting...")

	var err error
	dbPath := "/opt/cadix-panel/data/panel.db"
	os.MkdirAll(filepath.Dir(dbPath), 0755)
	db, err = sql.Open("sqlite3", dbPath)
	if err != nil {
		log.Fatalf("Database open failed: %v", err)
	}
	defer db.Close()
	db.SetMaxOpenConns(1)

	initDB()

	mux := http.NewServeMux()

	mux.HandleFunc("/", handleCORS(rootHandler))
	mux.HandleFunc("/api/status", handleCORS(apiStatus))
	mux.HandleFunc("/api/servers", handleCORS(apiServers))
	mux.HandleFunc("/api/servers/add", handleCORS(apiServerAdd))
	mux.HandleFunc("/api/servers/remove", handleCORS(apiServerRemove))
	mux.HandleFunc("/api/servers/start", handleCORS(apiServerStart))
	mux.HandleFunc("/api/servers/stop", handleCORS(apiServerStop))
	mux.HandleFunc("/api/servers/restart", handleCORS(apiServerRestart))
	mux.HandleFunc("/api/system", handleCORS(apiSystem))
	mux.HandleFunc("/api/system/cpu", handleCORS(apiSystemCPU))
	mux.HandleFunc("/api/system/memory", handleCORS(apiSystemMemory))
	mux.HandleFunc("/api/system/disk", handleCORS(apiSystemDisk))
	mux.HandleFunc("/api/system/processes", handleCORS(apiSystemProcesses))
	mux.HandleFunc("/api/system/network", handleCORS(apiSystemNetwork))
	mux.HandleFunc("/api/update", handleCORS(apiUpdate))
	mux.HandleFunc("/api/update/check", handleCORS(apiUpdateCheck))
	mux.HandleFunc("/api/firewall", handleCORS(apiFirewall))
	mux.HandleFunc("/api/routes", handleCORS(apiRoutes))

	log.Println("Server listening on :5000")
	if err := http.ListenAndServe(":5000", mux); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}

func initLogging() {
	log.SetFlags(log.Ldate | log.Ltime | log.Lshortfile)
	f, err := os.OpenFile("/opt/cadix-panel/logs/panel.log", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err == nil {
		log.SetOutput(f)
	}
}

func handleCORS(fn http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		w.Header().Set("X-Powered-By", "Cadix Panel")
		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusOK)
			return
		}
		fn(w, r)
	}
}

func writeJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func rootHandler(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		writeError(w, 404, "not found")
		return
	}
	data, err := os.ReadFile("/opt/cadix-panel/frontend/index.html")
	if err != nil {
		writeError(w, 500, "frontend not found")
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(data)
}

func apiRoutes(w http.ResponseWriter, r *http.Request) {
	routes := []RouteInfo{
		{"/", "GET", "Dashboard"},
		{"/api/status", "GET", "Panel status"},
		{"/api/servers", "GET", "List servers"},
		{"/api/servers/add", "POST", "Add server"},
		{"/api/servers/remove", "POST", "Remove server"},
		{"/api/system", "GET", "System info"},
		{"/api/system/cpu", "GET", "CPU details"},
		{"/api/system/memory", "GET", "Memory details"},
		{"/api/system/disk", "GET", "Disk details"},
		{"/api/system/processes", "GET", "Running processes"},
		{"/api/system/network", "GET", "Network connections"},
		{"/api/update", "POST", "Run system update"},
		{"/api/update/check", "GET", "Check for updates"},
		{"/api/firewall", "GET,POST", "Firewall status/management"},
	}
	writeJSON(w, 200, routes)
}

// Database

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
	);`

	for _, q := range strings.Split(schema, ";") {
		q = strings.TrimSpace(q)
		if q != "" {
			if _, err := db.Exec(q); err != nil {
				log.Printf("Schema exec error: %v", err)
			}
		}
	}

	var count int
	db.QueryRow("SELECT COUNT(*) FROM servers").Scan(&count)
	if count == 0 {
		db.Exec("INSERT INTO servers (name, ip, status) VALUES ('Main Server', '127.0.0.1', 'online')")
		db.Exec("INSERT INTO servers (name, ip, status) VALUES ('Web Server', '10.0.0.1', 'online')")
		db.Exec("INSERT INTO servers (name, ip, status) VALUES ('DB Server', '10.0.0.2', 'offline')")
	}
}

func queryServers() []Server {
	rows, err := db.Query("SELECT id, name, ip, port, username, status, created_at FROM servers ORDER BY id")
	if err != nil {
		log.Printf("Query servers error: %v", err)
		return []Server{}
	}
	defer rows.Close()

	var servers []Server
	for rows.Next() {
		var s Server
		if err := rows.Scan(&s.ID, &s.Name, &s.IP, &s.Port, &s.Username, &s.Status, &s.Created); err != nil {
			log.Printf("Scan error: %v", err)
			continue
		}
		s.Uptime = probeUptime(s.IP)
		s.CPU = probeCPU(s.IP)
		s.RAM = probeRAM(s.IP)
		s.Storage = probeStorage(s.IP)
		servers = append(servers, s)
	}
	return servers
}

// API Handlers

func apiStatus(w http.ResponseWriter, r *http.Request) {
	var count int
	db.QueryRow("SELECT COUNT(*) FROM servers").Scan(&count)
	writeJSON(w, 200, PanelStatus{
		Version:     "2.0.0",
		Uptime:      fmt.Sprintf("%.0f", time.Since(startTime).Seconds()),
		ServerCount: count,
		GoVersion:   strings.TrimPrefix(runtimeVersion(), "go"),
	})
}

func apiServers(w http.ResponseWriter, r *http.Request) {
	servers := queryServers()
	if servers == nil {
		servers = []Server{}
	}
	writeJSON(w, 200, servers)
}

func apiServerAdd(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		writeError(w, 405, "post required")
		return
	}
	var s Server
	if err := json.NewDecoder(r.Body).Decode(&s); err != nil {
		writeError(w, 400, "invalid json")
		return
	}
	if s.Name == "" || s.IP == "" {
		writeError(w, 400, "name and ip required")
		return
	}
	if s.Port == 0 {
		s.Port = 22
	}
	if s.Username == "" {
		s.Username = "root"
	}
	_, err := db.Exec("INSERT INTO servers (name, ip, port, username) VALUES (?, ?, ?, ?)", s.Name, s.IP, s.Port, s.Username)
	if err != nil {
		writeError(w, 500, err.Error())
		return
	}
	writeJSON(w, 201, map[string]string{"status": "ok", "message": "server added"})
}

func apiServerRemove(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		writeError(w, 405, "post required")
		return
	}
	var req struct{ ID int `json:"id"` }
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.ID == 0 {
		writeError(w, 400, "id required")
		return
	}
	mu.Lock()
	db.Exec("DELETE FROM servers WHERE id = ?", req.ID)
	db.Exec("DELETE FROM metrics WHERE server_id = ?", req.ID)
	mu.Unlock()
	writeJSON(w, 200, map[string]string{"status": "ok", "message": "server removed"})
}

func apiServerStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		writeError(w, 405, "post required")
		return
	}
	var req struct{ ID int `json:"id"` }
	json.NewDecoder(r.Body).Decode(&req)
	db.Exec("UPDATE servers SET status = 'online' WHERE id = ?", req.ID)
	writeJSON(w, 200, map[string]string{"status": "ok", "message": "server started"})
}

func apiServerStop(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		writeError(w, 405, "post required")
		return
	}
	var req struct{ ID int `json:"id"` }
	json.NewDecoder(r.Body).Decode(&req)
	db.Exec("UPDATE servers SET status = 'offline' WHERE id = ?", req.ID)
	writeJSON(w, 200, map[string]string{"status": "ok", "message": "server stopped"})
}

func apiServerRestart(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		writeError(w, 405, "post required")
		return
	}
	exec.Command("systemctl", "restart", "cadix-panel").CombinedOutput()
	writeJSON(w, 200, map[string]string{"status": "ok", "message": "server restarting"})
}

func apiSystem(w http.ResponseWriter, r *http.Request) {
	mu.RLock()
	info := SysInfo{}
	info.Hostname, _ = os.Hostname()
	info.Uptime = readUptime()
	info.CPU = readCPUModel()
	info.CPUCores = countCPUCores()
	info.RAMTotal, info.RAMUsed, info.RAMFree, info.RAMPercent = readMemory()
	info.StorageTotal, info.StorageUsed, info.StorageFree = readDisk()
	info.LoadAvg = readLoadAvg()
	info.Processes = countProcesses()
	info.OS = readOS()
	info.Kernel = readKernel()
	mu.RUnlock()
	writeJSON(w, 200, info)
}

func apiSystemCPU(w http.ResponseWriter, r *http.Request) {
	d, err := ioutil.ReadFile("/proc/stat")
	if err != nil {
		writeError(w, 500, err.Error())
		return
	}
	var user, nice, system, idle int
	for _, l := range strings.Split(string(d), "\n") {
		if strings.HasPrefix(l, "cpu ") {
			fmt.Sscanf(l, "cpu %d %d %d %d", &user, &nice, &system, &idle)
			break
		}
	}
	total := user + nice + system + idle
	usage := 0.0
	if total > 0 {
		usage = float64(user+system) / float64(total) * 100
	}
	writeJSON(w, 200, map[string]interface{}{
		"usage": fmt.Sprintf("%.1f", usage),
		"cores": countCPUCores(),
		"user":  user, "system": system, "idle": idle, "total": total,
	})
}

func apiSystemMemory(w http.ResponseWriter, r *http.Request) {
	t, u, f, p := readMemory()
	writeJSON(w, 200, map[string]string{
		"total": t, "used": u, "free": f, "percent": p,
	})
}

func apiSystemDisk(w http.ResponseWriter, r *http.Request) {
	d, err := exec.Command("df", "-h").CombinedOutput()
	if err != nil {
		writeError(w, 500, err.Error())
		return
	}
	var disks []map[string]string
	for _, l := range strings.Split(string(d), "\n")[1:] {
		f := strings.Fields(l)
		if len(f) >= 6 {
			disks = append(disks, map[string]string{
				"filesystem": f[0], "size": f[1], "used": f[2],
				"avail": f[3], "use_percent": f[4], "mounted": f[5],
			})
		}
	}
	if disks == nil {
		disks = []map[string]string{}
	}
	writeJSON(w, 200, disks)
}

func apiSystemProcesses(w http.ResponseWriter, r *http.Request) {
	d, err := exec.Command("ps", "aux", "--sort=-%cpu").CombinedOutput()
	if err != nil {
		writeJSON(w, 200, []map[string]interface{}{})
		return
	}
	type proc struct {
		PID   int    `json:"pid"`
		Name  string `json:"name"`
		CPU   string `json:"cpu"`
		RAM   string `json:"ram"`
		State string `json:"state"`
	}
	var procs []proc
	for _, l := range strings.Split(string(d), "\n")[1:] {
		f := strings.Fields(l)
		if len(f) >= 11 {
			pid, _ := strconv.Atoi(f[1])
			if pid == 0 {
				continue
			}
			procs = append(procs, proc{PID: pid, Name: f[10], CPU: f[2], RAM: f[3], State: f[7]})
		}
		if len(procs) >= 30 {
			break
		}
	}
	if procs == nil {
		procs = []proc{}
	}
	writeJSON(w, 200, procs)
}

func apiSystemNetwork(w http.ResponseWriter, r *http.Request) {
	d, err := exec.Command("ss", "-tlnp").CombinedOutput()
	if err != nil {
		writeJSON(w, 200, []map[string]string{})
		return
	}
	var ports []map[string]string
	for _, l := range strings.Split(string(d), "\n")[1:] {
		f := strings.Fields(l)
		if len(f) >= 5 {
			parts := strings.Split(f[3], ":")
			port := parts[len(parts)-1]
			pid := "N/A"
			if len(f) >= 6 {
				pid = f[5]
			}
			ports = append(ports, map[string]string{
				"proto": f[0], "address": f[3], "state": f[1],
				"port": port, "pid": pid,
			})
		}
	}
	if ports == nil {
		ports = []map[string]string{}
	}
	writeJSON(w, 200, ports)
}

func apiFirewall(w http.ResponseWriter, r *http.Request) {
	if r.Method == "POST" {
		var req struct {
			Action   string `json:"action"`
			Port     int    `json:"port"`
			Protocol string `json:"protocol"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Action == "" || req.Port == 0 {
			writeError(w, 400, "action, port, protocol required")
			return
		}
		if req.Protocol == "" {
			req.Protocol = "tcp"
		}
		cmd := exec.Command("ufw", req.Action, fmt.Sprintf("%d/%s", req.Port, req.Protocol))
		out, err := cmd.CombinedOutput()
		if err != nil {
			writeError(w, 500, string(out))
			return
		}
		writeJSON(w, 200, map[string]string{"status": "ok", "message": fmt.Sprintf("%s %d/%s", req.Action, req.Port, req.Protocol)})
		return
	}
	d, err := exec.Command("ufw", "status", "numbered").CombinedOutput()
	if err != nil {
		writeJSON(w, 200, map[string]string{"status": "not enabled"})
		return
	}
	writeJSON(w, 200, map[string]string{"status": string(d)})
}

func apiUpdate(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		writeError(w, 405, "post required")
		return
	}
	go func() {
		exec.Command("apt-get", "update", "-qq").CombinedOutput()
		exec.Command("apt-get", "upgrade", "-y", "-qq").CombinedOutput()
	}()
	writeJSON(w, 200, map[string]string{"status": "ok", "message": "update started"})
}

func apiUpdateCheck(w http.ResponseWriter, r *http.Request) {
	d, err := exec.Command("apt-get", "-s", "upgrade").CombinedOutput()
	if err != nil {
		writeJSON(w, 200, map[string]interface{}{"updates": 0, "available": false})
		return
	}
	var updateCount int
	for _, l := range strings.Split(string(d), "\n") {
		if strings.Contains(l, "upgraded") || strings.Contains(l, "upgradable") {
			fmt.Sscanf(l, "%d", &updateCount)
			break
		}
	}
	writeJSON(w, 200, map[string]interface{}{
		"updates":   updateCount,
		"available": updateCount > 0,
	})
}

// System probes

func readUptime() string {
	d, err := ioutil.ReadFile("/proc/uptime")
	if err != nil {
		return "N/A"
	}
	var u float64
	fmt.Sscanf(string(d), "%f", &u)
	days := int(u) / 86400
	hours := (int(u) % 86400) / 3600
	mins := (int(u) % 3600) / 60
	return fmt.Sprintf("%dd %dh %dm", days, hours, mins)
}

func readCPUModel() string {
	d, err := ioutil.ReadFile("/proc/cpuinfo")
	if err != nil {
		return "N/A"
	}
	for _, l := range strings.Split(string(d), "\n") {
		if strings.Contains(l, "model name") {
			return strings.TrimSpace(strings.SplitN(l, ":", 2)[1])
		}
	}
	return "N/A"
}

func countCPUCores() int {
	d, err := ioutil.ReadFile("/proc/cpuinfo")
	if err != nil {
		return 0
	}
	count := 0
	for _, l := range strings.Split(string(d), "\n") {
		if strings.HasPrefix(l, "processor") {
			count++
		}
	}
	return count
}

func readMemory() (total, used, free, percent string) {
	t := parseMem("MemTotal:")
	a := parseMem("MemAvailable:")
	if t <= 0 {
		return "N/A", "N/A", "N/A", "N/A"
	}
	u := t - a
	total = fmt.Sprintf("%.1f GB", t/1024/1024)
	used = fmt.Sprintf("%.1f GB", u/1024/1024)
	free = fmt.Sprintf("%.1f GB", a/1024/1024)
	percent = fmt.Sprintf("%.0f%%", u/t*100)
	return
}

func readDisk() (total, used, free string) {
	d, err := exec.Command("df", "-h", "--total").CombinedOutput()
	if err != nil {
		return "N/A", "N/A", "N/A"
	}
	for _, l := range strings.Split(string(d), "\n") {
		if strings.HasPrefix(l, "total") {
			f := strings.Fields(l)
			if len(f) >= 4 {
				return f[1], f[2], f[3]
			}
		}
	}
	return "N/A", "N/A", "N/A"
}

func readLoadAvg() string {
	d, err := ioutil.ReadFile("/proc/loadavg")
	if err != nil {
		return "N/A"
	}
	return strings.Fields(string(d))[0]
}

func countProcesses() int {
	d, err := ioutil.ReadDir("/proc")
	if err != nil {
		return 0
	}
	count := 0
	for _, f := range d {
		if f.IsDir() {
			if _, e := strconv.Atoi(f.Name()); e == nil {
				count++
			}
		}
	}
	return count
}

func readOS() string {
	d, err := ioutil.ReadFile("/etc/os-release")
	if err != nil {
		return "N/A"
	}
	for _, l := range strings.Split(string(d), "\n") {
		if strings.HasPrefix(l, "PRETTY_NAME=") {
			return strings.Trim(strings.SplitN(l, "=", 2)[1], "\"")
		}
	}
	return "N/A"
}

func readKernel() string {
	d, err := exec.Command("uname", "-r").CombinedOutput()
	if err != nil {
		return "N/A"
	}
	return strings.TrimSpace(string(d))
}

func parseMem(prefix string) float64 {
	d, err := ioutil.ReadFile("/proc/meminfo")
	if err != nil {
		return 0
	}
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

func probeUptime(ip string) string {
	if ip == "127.0.0.1" {
		return readUptime()
	}
	return "N/A"
}

func probeCPU(ip string) string {
	if ip == "127.0.0.1" {
		c := readCPUModel()
		if len(c) > 30 {
			c = c[:30] + "..."
		}
		return c
	}
	return "N/A"
}

func probeRAM(ip string) string {
	if ip == "127.0.0.1" {
		t, _, _, _ := readMemory()
		return t
	}
	return "N/A"
}

func probeStorage(ip string) string {
	if ip == "127.0.0.1" {
		t, _, _ := readDisk()
		return t
	}
	return "N/A"
}

func runtimeVersion() string {
	return "go1.22.2"
}
GOEOF

    log_info "Go backend written"
}

write_frontend() {
    log_info "Writing frontend..."

    mkdir -p "$INSTALL_DIR/frontend/src"

    cat > "$INSTALL_DIR/frontend/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Cadix Panel</title>
<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
<link href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.10.0/font/bootstrap-icons.css" rel="stylesheet">
<style>
:root{--bg:#0f1923;--surface:#1a2332;--border:#2a3a4a;--text:#e0e0e0;--muted:#8899aa;--primary:#4a9eff;--success:#4ade80;--danger:#f87171;--warning:#fbbf24}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:var(--bg);color:var(--text);min-height:100vh}
.sidebar{width:240px;background:var(--surface);position:fixed;top:0;left:0;bottom:0;z-index:100}
.main{margin-left:240px;padding:24px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:20px;transition:.15s}
.card:hover{border-color:var(--primary)}
.val{font-size:28px;font-weight:700;color:#fff}
.lbl{font-size:13px;color:var(--muted);margin-top:4px}
.icon-box{width:48px;height:48px;border-radius:12px;display:flex;align-items:center;justify-content:center;font-size:24px}
.badge-online,.badge-offline{display:inline-block;padding:4px 12px;border-radius:20px;font-size:12px;font-weight:600}
.badge-online{background:rgba(74,222,128,.15);color:var(--success)}
.badge-offline{background:rgba(248,113,113,.15);color:var(--danger)}
.nav-item{padding:12px 20px;color:var(--muted);cursor:pointer;transition:.15s;display:flex;align-items:center;gap:12px}
.nav-item:hover,.nav-item.active{background:var(--bg);color:#fff}
.nav-item i{width:20px}
table{width:100%}
th{color:var(--muted);font-weight:500;font-size:12px;text-transform:uppercase;letter-spacing:.5px;border-bottom:1px solid var(--border);padding:12px 8px}
td{padding:12px 8px;border-bottom:1px solid var(--border)}
.section-title{font-size:18px;font-weight:600;margin-bottom:16px;color:#fff}
.progress{background:var(--bg);height:8px;border-radius:4px}
.progress-bar{background:linear-gradient(90deg,var(--primary),#7c5cfc);border-radius:4px}
.form-control,.form-select{background:var(--bg);border:1px solid var(--border);color:#fff;border-radius:8px}
.form-control:focus{background:var(--bg);border-color:var(--primary);color:#fff;box-shadow:none}
.form-control::placeholder{color:#556}
.modal-content{background:var(--surface);border:1px solid var(--border)}
.modal-header,.modal-footer{border-color:var(--border)}
.btn{font-size:13px;border-radius:8px;padding:8px 16px}
::-webkit-scrollbar{width:6px}
::-webkit-scrollbar-track{background:var(--bg)}
::-webkit-scrollbar-thumb{background:var(--border);border-radius:3px}
@keyframes spin{to{transform:rotate(360deg)}}
.spinner{width:20px;height:20px;border:2px solid var(--border);border-top-color:var(--primary);border-radius:50%;animation:spin .6s linear infinite;display:inline-block}
.empty{text-align:center;padding:40px;color:var(--muted)}
</style>
</head>
<body>

<div class="sidebar p-3">
    <div class="d-flex align-items-center mb-4 px-3 pt-2">
        <div class="icon-box me-2" style="background:rgba(74,158,255,.15);color:var(--primary);width:36px;height:36px;font-size:18px"><i class="bi bi-grid-3x3-gap-fill"></i></div>
        <span class="fw-bold fs-5">Cadix Panel</span>
    </div>
    <div class="nav-item active" data-page="dashboard"><i class="bi bi-speedometer2"></i> Dashboard</div>
    <div class="nav-item" data-page="servers"><i class="bi bi-server"></i> Servers</div>
    <div class="nav-item" data-page="system"><i class="bi bi-cpu"></i> System</div>
    <div class="nav-item" data-page="network"><i class="bi bi-diagram-3"></i> Network</div>
    <div class="nav-item" data-page="processes"><i class="bi bi-list-task"></i> Processes</div>
    <div class="nav-item" data-page="updates"><i class="bi bi-arrow-up-circle"></i> Updates</div>
    <div class="nav-item" data-page="firewall"><i class="bi bi-shield-check"></i> Firewall</div>
    <div style="position:absolute;bottom:20px;left:20px;right:20px;background:var(--bg);border-radius:8px;padding:12px 16px" id="statusBar">
        <div class="d-flex align-items-center">
            <div style="width:10px;height:10px;border-radius:50%;background:var(--success)" id="statusDot"></div>
            <span class="ms-2" style="font-size:12px;color:var(--muted)"><span id="panelStatus">Loading...</span></span>
        </div>
    </div>
</div>

<div class="main" id="content">
    <div class="d-flex justify-content-center align-items-center" style="min-height:60vh">
        <div style="text-align:center"><div class="spinner mb-3"></div><div style="color:var(--muted)">Loading Cadix Panel...</div></div>
    </div>
</div>

<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
<script>
const API = '';
let state = { servers: [], system: {} };

function qs(s,p){return s.querySelector(p)}
function qsa(s,p){return s.querySelectorAll(p)}
function $id(id){return document.getElementById(id)}

async function api(path, opts={}) {
    const res = await fetch(API+path, {
        headers: {'Content-Type':'application/json',...opts.headers}, ...opts
    });
    if (!res.ok) { const e=await res.json().catch(()=>({})); throw new Error(e.error||res.statusText); }
    return res.json();
}

function showPage(name) {
    qsa(document,'.nav-item').forEach(n=>n.classList.remove('active'));
    const nav = document.querySelector(`[data-page="${name}"]`);
    if (nav) nav.classList.add('active');
    const renderers = { dashboard:renderDashboard, servers:renderServers, system:renderSystem,
        network:renderNetwork, processes:renderProcesses, updates:renderUpdates, firewall:renderFirewall };
    const fn = renderers[name] || renderDashboard;
    const el = $id('content');
    el.innerHTML = '<div class="d-flex justify-content-center align-items-center" style="min-height:60vh"><div class="spinner"></div></div>';
    setTimeout(() => { try { el.innerHTML = fn(); } catch(e) { el.innerHTML = `<div class="empty">Error: ${e.message}</div>`; } }, 50);
}

async function loadData() {
    try {
        const [status, servers, system] = await Promise.all([
            api('/api/status'), api('/api/servers'), api('/api/system')
        ]);
        state.servers = servers;
        state.system = system;
        $id('panelStatus').textContent = `Connected v${status.version} | ${state.servers.length} servers`;
        $id('statusDot').style.background = 'var(--success)';
    } catch(e) {
        $id('panelStatus').textContent = 'Disconnected';
        $id('statusDot').style.background = 'var(--danger)';
    }
}

async function loadAndRender(page) {
    await loadData();
    showPage(page || 'dashboard');
}

// ---- Pages ----

function renderDashboard() {
    const s = state.system;
    return \`
    <div class="d-flex justify-content-between align-items-center mb-4">
        <div><h2 class="fw-bold mb-1">Dashboard</h2><p style="color:var(--muted)">System overview</p></div>
        <span style="color:var(--muted);font-size:13px">\${s.hostname||'N/A'} &middot; v2.0.0</span>
    </div>
    <div class="row g-3 mb-4">
        <div class="col-md-3"><div class="card d-flex flex-row align-items-center">
            <div class="icon-box me-3" style="background:rgba(74,158,255,.15);color:var(--primary)"><i class="bi bi-server"></i></div>
            <div><div class="val">\${state.servers.length}</div><div class="lbl">Servers</div></div>
        </div></div>
        <div class="col-md-3"><div class="card d-flex flex-row align-items-center">
            <div class="icon-box me-3" style="background:rgba(74,222,128,.15);color:var(--success)"><i class="bi bi-memory"></i></div>
            <div><div class="val">\${s.ram_total||'N/A'}</div><div class="lbl">RAM Total</div></div>
        </div></div>
        <div class="col-md-3"><div class="card d-flex flex-row align-items-center">
            <div class="icon-box me-3" style="background:rgba(251,191,36,.15);color:var(--warning)"><i class="bi bi-hdd"></i></div>
            <div><div class="val">\${s.storage_total||'N/A'}</div><div class="lbl">Storage</div></div>
        </div></div>
        <div class="col-md-3"><div class="card d-flex flex-row align-items-center">
            <div class="icon-box me-3" style="background:rgba(196,132,252,.15);color:#c084fc"><i class="bi bi-arrow-up"></i></div>
            <div><div class="val">\${s.uptime||'N/A'}</div><div class="lbl">Uptime</div></div>
        </div></div>
    </div>
    <div class="row g-3">
        <div class="col-md-6"><div class="card">
            <div class="d-flex justify-content-between mb-2"><span>CPU Usage</span><span>\${s.load_avg||'0'}</span></div>
            <div class="progress"><div class="progress-bar" style="width:\${Math.min(parseFloat(s.load_avg||0)*8,100)}%"></div></div>
        </div></div>
        <div class="col-md-6"><div class="card">
            <div class="d-flex justify-content-between mb-2"><span>RAM Usage</span><span>\${s.ram_percent||'0%'}</span></div>
            <div class="progress"><div class="progress-bar" style="width:\${Math.min(parseFloat(s.ram_percent)||0,100)}%"></div></div>
        </div></div>
    </div>\`;
}

function renderServers() {
    const list = state.servers;
    return \`
    <div class="d-flex justify-content-between align-items-center mb-4">
        <div><h2 class="fw-bold mb-1">Servers</h2><p style="color:var(--muted)">\${list.length} total</p></div>
        <button class="btn btn-primary" onclick="showAddServer()"><i class="bi bi-plus-lg"></i> Add</button>
    </div>
    \${list.length === 0 ? '<div class="empty"><i class="bi bi-server fs-1 mb-3" style="display:block"></i>No servers yet</div>' : \`
    <div class="card p-0" style="overflow-x:auto">
    <table><thead><tr><th>Name</th><th>IP</th><th>Status</th><th>Uptime</th><th>CPU</th><th>RAM</th><th style="width:160px">Actions</th></tr></thead>
    <tbody>\${list.map(s => \`
        <tr><td>\${s.name}</td><td>\${s.ip}:\${s.port||22}</td>
        <td><span class="badge-\${s.status}">\${s.status.toUpperCase()}</span></td>
        <td>\${s.uptime||'N/A'}</td><td title="\${s.cpu}">\${s.cpu?s.cpu.substring(0,25):'N/A'}</td>
        <td>\${s.ram||'N/A'}</td>
        <td>
            <button class="btn btn-sm btn-outline-success" onclick="act(\${s.id},'start')" title="Start"><i class="bi bi-play-fill"></i></button>
            <button class="btn btn-sm btn-outline-danger" onclick="act(\${s.id},'stop')" title="Stop"><i class="bi bi-stop-fill"></i></button>
            <button class="btn btn-sm btn-outline-warning" onclick="act(\${s.id},'restart')" title="Restart"><i class="bi bi-arrow-clockwise"></i></button>
            <button class="btn btn-sm btn-outline-secondary" onclick="delSrv(\${s.id})" title="Delete"><i class="bi bi-trash"></i></button>
        </td></tr>
    \`).join('')}</tbody></table></div>\`}\`;
}

function renderSystem() {
    const s = state.system;
    const rows = [
        ['Hostname', s.hostname], ['OS', s.os], ['Kernel', s.kernel],
        ['CPU', s.cpu], ['Cores', s.cpu_cores], ['Uptime', s.uptime],
        ['Load Average', s.load_avg], ['Processes', s.processes],
        ['RAM Total', s.ram_total], ['RAM Used', s.ram_used], ['RAM Free', s.ram_free],
        ['Storage Total', s.storage_total], ['Storage Used', s.storage_used], ['Storage Free', s.storage_free]
    ];
    return \`
    <div class="d-flex justify-content-between align-items-center mb-4">
        <div><h2 class="fw-bold mb-1">System</h2><p style="color:var(--muted)">Hardware & OS</p></div>
        <button class="btn btn-outline-info" onclick="refreshSystem()"><i class="bi bi-arrow-clockwise"></i> Refresh</button>
    </div>
    <div class="row g-3">
        <div class="col-md-6"><div class="card">
            <div class="section-title">Overview</div>
            <table><tbody>\${rows.slice(0,8).map(r => \`<tr><td style="color:var(--muted);width:160px">\${r[0]}</td><td>\${r[1]||'N/A'}</td></tr>\`).join('')}</tbody></table>
        </div></div>
        <div class="col-md-6"><div class="card">
            <div class="section-title">Resources</div>
            <table><tbody>\${rows.slice(8).map(r => \`<tr><td style="color:var(--muted);width:160px">\${r[0]}</td><td>\${r[1]||'N/A'}</td></tr>\`).join('')}</tbody></table>
        </div></div>
    </div>\`;
}

function renderNetwork() {
    let html = '<div class="d-flex justify-content-between align-items-center mb-4"><div><h2 class="fw-bold mb-1">Network</h2><p style="color:var(--muted)">Open ports</p></div></div>';
    api('/api/system/network').then(p => {
        const el = qs($id('content'),'.net-tbl');
        if (!el) return;
        if (p.length === 0) { el.innerHTML = '<div class="empty">No active ports</div>'; return; }
        el.innerHTML = \`<table><thead><tr><th>Proto</th><th>Address</th><th>State</th><th>Port</th></tr></thead>
        <tbody>\${p.map(n => \`<tr><td>\${n.proto}</td><td>\${n.address}</td><td>\${n.state}</td><td>\${n.port}</td></tr>\`).join('')}</tbody></table>\`;
    });
    return html + '<div class="card p-0 net-tbl"><div class="empty"><div class="spinner"></div></div></div>';
}

function renderProcesses() {
    let html = '<div class="d-flex justify-content-between align-items-center mb-4"><div><h2 class="fw-bold mb-1">Processes</h2><p style="color:var(--muted)">Top 30 by CPU</p></div></div>';
    api('/api/system/processes').then(p => {
        const el = qs($id('content'),'.proc-tbl');
        if (!el) return;
        if (p.length === 0) { el.innerHTML = '<div class="empty">No processes</div>'; return; }
        el.innerHTML = \`<table><thead><tr><th>PID</th><th>Name</th><th>CPU%</th><th>RAM%</th><th>State</th></tr></thead>
        <tbody>\${p.map(pr => \`<tr><td>\${pr.pid}</td><td>\${pr.name}</td><td>\${pr.cpu}%</td><td>\${pr.ram}%</td>
        <td><span class="badge-online">\${pr.state}</span></td></tr>\`).join('')}</tbody></table>\`;
    });
    return html + '<div class="card p-0 proc-tbl"><div class="empty"><div class="spinner"></div></div></div>';
}

function renderUpdates() {
    let html = '<div class="d-flex justify-content-between align-items-center mb-4"><div><h2 class="fw-bold mb-1">Updates</h2><p style="color:var(--muted)">Package management</p></div><button class="btn btn-primary" onclick="doUpdate()"><i class="bi bi-arrow-up-circle"></i> Update All</button></div>';
    api('/api/update/check').then(u => {
        const el = qs($id('content'),'.upd-box');
        if (!el) return;
        el.innerHTML = \`
        <div class="card">
            <div class="d-flex align-items-center mb-3">
                <i class="bi bi-box-seam fs-3 me-3" style="color:\${u.available?'var(--warning)':'var(--success)'}"></i>
                <div><div class="val">\${u.updates||0}</div><div class="lbl">Updates Available</div></div>
            </div>
            \${u.available
                ? '<div class="alert" style="background:rgba(251,191,36,.1);border:1px solid rgba(251,191,36,.2);color:var(--warning);font-size:13px;border-radius:8px">Updates available. Click "Update All".</div>'
                : '<div class="alert" style="background:rgba(74,222,128,.1);border:1px solid rgba(74,222,128,.2);color:var(--success);font-size:13px;border-radius:8px">System up to date.</div>'}
        </div>\`;
    });
    return html + '<div class="upd-box"><div class="empty"><div class="spinner"></div></div></div>';
}

function renderFirewall() {
    let html = '<div class="d-flex justify-content-between align-items-center mb-4"><div><h2 class="fw-bold mb-1">Firewall</h2><p style="color:var(--muted)">UFW status</p></div></div>';
    api('/api/firewall').then(fw => {
        const el = qs($id('content'),'.fw-box');
        if (!el) return;
        el.innerHTML = \`<div class="card"><pre style="color:var(--muted);font-size:13px;white-space:pre-wrap">\${fw.status||'UFW not enabled'}</pre></div>\`;
    });
    return html + \`
    <div class="fw-box"><div class="empty"><div class="spinner"></div></div></div>
    <div class="card mt-3">
        <div class="section-title">Quick Rule</div>
        <div class="row g-2 align-items-end">
            <div class="col"><label style="color:var(--muted);font-size:13px">Action</label>
            <select class="form-select" id="fwAction"><option value="allow">Allow</option><option value="deny">Deny</option><option value="delete">Delete</option></select></div>
            <div class="col"><label style="color:var(--muted);font-size:13px">Port</label>
            <input class="form-control" id="fwPort" value="22"></div>
            <div class="col"><label style="color:var(--muted);font-size:13px">Protocol</label>
            <select class="form-select" id="fwProto"><option value="tcp">TCP</option><option value="udp">UDP</option></select></div>
            <div class="col d-grid"><button class="btn btn-primary" onclick="fwRule()">Apply</button></div>
        </div>
    </div>\`;
}

// ---- Actions ----

async function act(id, action) {
    const btn = event?.target?.closest('button');
    if (btn) { btn.disabled = true; btn.innerHTML = '<span class="spinner"></span>'; }
    await api('/api/servers/'+action, {method:'POST', body:JSON.stringify({id})});
    await loadData(); showPage('servers');
}

async function delSrv(id) {
    if (!confirm('Remove this server?')) return;
    await api('/api/servers/remove', {method:'POST', body:JSON.stringify({id})});
    await loadData(); showPage('servers');
}

async function refreshSystem() {
    const btn = event?.target?.closest('button');
    if (btn) { btn.disabled = true; btn.innerHTML = '<span class="spinner"></span>'; }
    await loadData(); showPage('system');
    if (btn) { btn.disabled = false; btn.innerHTML = '<i class="bi bi-arrow-clockwise"></i> Refresh'; }
}

async function doUpdate() {
    const btn = event?.target?.closest('button');
    if (btn) { btn.disabled = true; btn.innerHTML = '<span class="spinner"></span> Updating...'; }
    await api('/api/update', {method:'POST'});
    await loadData(); showPage('updates');
}

async function fwRule() {
    const action = $id('fwAction')?.value;
    const port = parseInt($id('fwPort')?.value);
    const proto = $id('fwProto')?.value;
    if (!port) return;
    await api('/api/firewall', {method:'POST', body:JSON.stringify({action,port,protocol:proto})});
    showPage('firewall');
}

function showAddServer() {
    const name = \`Server \${(state.servers.length||0)+1}\`;
    const ip = state.servers.length === 0 ? '127.0.0.1' : \`10.0.0.\${state.servers.length+1}\`;
    const html = \`
    <div class="modal d-block" tabindex="-1" style="background:rgba(0,0,0,.6)">
    <div class="modal-dialog"><div class="modal-content">
        <div class="modal-header"><h5 class="modal-title fw-bold">Add Server</h5>
        <button type="button" class="btn-close btn-close-white" onclick="this.closest('.modal').remove()"></button></div>
        <div class="modal-body">
            <div class="mb-3"><label style="color:var(--muted);font-size:13px">Name</label>
            <input class="form-control" id="addName" value="\${name}"></div>
            <div class="mb-3"><label style="color:var(--muted);font-size:13px">IP Address</label>
            <input class="form-control" id="addIP" value="\${ip}"></div>
            <div class="row g-2">
                <div class="col"><label style="color:var(--muted);font-size:13px">Port</label>
                <input class="form-control" id="addPort" value="22"></div>
                <div class="col"><label style="color:var(--muted);font-size:13px">Username</label>
                <input class="form-control" id="addUser" value="root"></div>
            </div>
        </div>
        <div class="modal-footer">
            <button class="btn btn-outline-secondary" onclick="this.closest('.modal').remove()">Cancel</button>
            <button class="btn btn-primary" onclick="doAddServer()">Add</button>
        </div>
    </div></div></div>\`;
    const div = document.createElement('div');
    div.innerHTML = html;
    document.body.appendChild(div.firstElementChild);
}

async function doAddServer() {
    const name = $id('addName')?.value;
    const ip = $id('addIP')?.value;
    if (!name || !ip) return;
    await api('/api/servers/add', {method:'POST', body:JSON.stringify({
        name, ip, port: parseInt($id('addPort')?.value||'22'), username: $id('addUser')?.value||'root'
    })});
    qs(document,'.modal')?.remove();
    await loadData(); showPage('servers');
}

// ---- Init ----

qsa(document,'.nav-item').forEach(n => {
    n.addEventListener('click', () => showPage(n.dataset.page));
});

loadAndRender('dashboard');
setInterval(loadData, 30000);
</script>

</body>
</html>
EOF

    log_info "Frontend written"
}

write_schema() {
    log_info "Writing database schema..."
    mkdir -p "$INSTALL_DIR/backend"
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
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    role TEXT DEFAULT 'admin',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS metrics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id INTEGER, cpu REAL, ram REAL, disk REAL,
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
echo "Processes: $(ps aux | wc -l)"
echo "Open ports: $(ss -tln | wc -l)"
BASHEOF
    chmod +x "$INSTALL_DIR/tools/monitor.sh"

    cat > "$INSTALL_DIR/tools/backup.sh" << 'BASHEOF'
#!/bin/bash
BACKUP_DIR="/opt/cadix-panel/data"
FILE="panel.backup.$(date +%Y%m%d_%H%M%S).db"
cp "$BACKUP_DIR/panel.db" "$BACKUP_DIR/$FILE"
echo "Backup: $FILE ($(du -h "$BACKUP_DIR/$FILE" | awk '{print $1}'))"
find "$BACKUP_DIR" -name "panel.backup.*.db" -mtime +7 -delete
BASHEOF
    chmod +x "$INSTALL_DIR/tools/backup.sh"

    cat > "$INSTALL_DIR/tools/cleanup.sh" << 'BASHEOF'
#!/bin/bash
echo "Cleaning..."
apt-get autoremove -y -qq
apt-get autoclean -qq
journalctl --vacuum-time=7d >/dev/null 2>&1
find /opt/cadix-panel/logs -name "*.log" -mtime +30 -delete
echo "Done"
BASHEOF
    chmod +x "$INSTALL_DIR/tools/cleanup.sh"

    log_info "Tools written"
}

build_go() {
    log_info "Building Go binary..."
    cd "$INSTALL_DIR/backend"
    export PATH="/usr/local/go/bin:$PATH"
    
    go mod init cadix-panel 2>/dev/null || true
    go mod tidy 2>/dev/null
    
    if go build -o "$INSTALL_DIR/backend/panel" . 2>/dev/null; then
        chmod +x "$INSTALL_DIR/backend/panel"
        log_info "Go binary built at $INSTALL_DIR/backend/panel"
    else
        log_warn "Go build failed, will use go run"
    fi
}

setup_nginx() {
    log_info "Configuring nginx..."
    cat > /etc/nginx/sites-available/cadix-panel << 'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
        proxy_read_timeout 86400;
    }
}
NGINX
    mkdir -p /etc/nginx/sites-enabled
    ln -sf /etc/nginx/sites-available/cadix-panel /etc/nginx/sites-enabled/cadix-panel
    rm -f /etc/nginx/sites-enabled/default
    nginx -t 2>/dev/null && systemctl restart nginx 2>/dev/null || log_warn "nginx config issue"
}

setup_systemd() {
    log_info "Creating systemd service..."
    cat > /etc/systemd/system/cadix-panel.service << SVCEOF
[Unit]
Description=Cadix Panel
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
        log_info "SSL for $domain..."
        certbot --nginx -d "$domain" -d "www.$domain" \
            --email "$email" --agree-tos --redirect --non-interactive 2>/dev/null || \
        log_warn "SSL issue"
        log_info "SSL configured"
    fi
}

show_summary() {
    local ip
    ip=$(hostname -I | awk '{print $1}')
    cat << EOF

========================================
  Cadix Panel v$VERSION
========================================

URL:  http://$ip
API:  http://$ip/api/status

Go:   $(go version 2>/dev/null || echo "N/A")
Node: $(node --version 2>/dev/null || echo "N/A")

Tools:
  /opt/cadix-panel/tools/monitor.sh
  /opt/cadix-panel/tools/backup.sh
  /opt/cadix-panel/tools/cleanup.sh

Service:
  systemctl status cadix-panel
  journalctl -u cadix-panel -f

EOF
}

usage() {
    echo "Usage: $0 [-d DOMAIN] [-e EMAIL] [-h]"
    echo "  $0 -d panel.example.com -e admin@example.com"
    exit 0
}

main() {
    local DOMAIN="" EMAIL=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--domain) DOMAIN="$2"; shift 2 ;;
            -e|--email) EMAIL="$2"; shift 2 ;;
            -h|--help) usage ;;
            *) log_error "Unknown: $1"; usage ;;
        esac
    done

    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}  Cadix Panel Installer v$VERSION${NC}"
    echo -e "${GREEN}========================================${NC}\n"

    check_root
    detect_os

    install_deps
    setup_dirs
    write_go_backend
    write_frontend
    write_schema
    write_tools
    build_go
    init_db
    setup_nginx
    setup_systemd
    setup_firewall

    if [[ -n "$DOMAIN" ]]; then
        setup_ssl "$DOMAIN" "${EMAIL:-admin@$DOMAIN}"
    fi

    show_summary
    log_info "Done! http://$(hostname -I | awk '{print $1}')"
}

main "$@"