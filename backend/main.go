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

type PanelStatus struct {
	Version     string `json:"version"`
	Uptime      string `json:"uptime"`
	ServerCount int    `json:"server_count"`
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
	routes := []map[string]string{
		{"/", "GET", "Dashboard"},
		{"/api/status", "GET", "Panel status"},
		{"/api/servers", "GET", "List servers"},
		{"/api/servers/add", "POST", "Add server"},
		{"/api/servers/remove", "POST", "Remove server"},
		{"/api/system", "GET", "Full system info"},
		{"/api/system/cpu", "GET", "CPU details"},
		{"/api/system/memory", "GET", "Memory details"},
		{"/api/system/disk", "GET", "Disk details"},
		{"/api/system/processes", "GET", "Process list"},
		{"/api/system/network", "GET", "Network connections"},
		{"/api/update", "POST", "Run update"},
		{"/api/update/check", "GET", "Check updates"},
		{"/api/firewall", "GET,POST", "Firewall management"},
	}
	writeJSON(w, 200, routes)
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
	);`
	for _, q := range strings.Split(schema, ";") {
		q = strings.TrimSpace(q)
		if q != "" {
			if _, err := db.Exec(q); err != nil {
				log.Printf("Schema error: %v", err)
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
		log.Printf("Query error: %v", err)
		return []Server{}
	}
	defer rows.Close()
	var servers []Server
	for rows.Next() {
		var s Server
		if err := rows.Scan(&s.ID, &s.Name, &s.IP, &s.Port, &s.Username, &s.Status, &s.Created); err != nil {
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

func apiStatus(w http.ResponseWriter, r *http.Request) {
	var count int
	db.QueryRow("SELECT COUNT(*) FROM servers").Scan(&count)
	writeJSON(w, 200, PanelStatus{
		Version:     "2.0.0",
		Uptime:      fmt.Sprintf("%.0f", time.Since(startTime).Seconds()),
		ServerCount: count,
	})
}

func apiServers(w http.ResponseWriter, r *http.Request) {
	s := queryServers()
	writeJSON(w, 200, s)
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
	_, err := db.Exec("INSERT INTO servers (name, ip, port, username) VALUES (?, ?, ?, ?)",
		s.Name, s.IP, s.Port, s.Username)
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
	writeJSON(w, 200, map[string]string{"status": "ok", "message": "removed"})
}

func apiServerStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		writeError(w, 405, "post required")
		return
	}
	var req struct{ ID int `json:"id"` }
	json.NewDecoder(r.Body).Decode(&req)
	db.Exec("UPDATE servers SET status = 'online' WHERE id = ?", req.ID)
	writeJSON(w, 200, map[string]string{"status": "ok", "message": "started"})
}

func apiServerStop(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		writeError(w, 405, "post required")
		return
	}
	var req struct{ ID int `json:"id"` }
	json.NewDecoder(r.Body).Decode(&req)
	db.Exec("UPDATE servers SET status = 'offline' WHERE id = ?", req.ID)
	writeJSON(w, 200, map[string]string{"status": "ok", "message": "stopped"})
}

func apiServerRestart(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		writeError(w, 405, "post required")
		return
	}
	exec.Command("systemctl", "restart", "cadix-panel").CombinedOutput()
	writeJSON(w, 200, map[string]string{"status": "ok", "message": "restarting"})
}

func apiSystem(w http.ResponseWriter, r *http.Request) {
	mu.RLock()
	info := SysInfo{
		Hostname:     getHostname(),
		Uptime:       readUptime(),
		CPU:          readCPUModel(),
		CPUCores:     countCPUCores(),
		RAMTotal:     "",
		RAMUsed:      "",
		RAMFree:      "",
		RAMPercent:   "",
		StorageTotal: "",
		StorageUsed:  "",
		StorageFree:  "",
		LoadAvg:      readLoadAvg(),
		Processes:    countProcesses(),
		OS:           readOS(),
		Kernel:       readKernel(),
	}
	mu.RUnlock()
	info.RAMTotal, info.RAMUsed, info.RAMFree, info.RAMPercent = readMemory()
	info.StorageTotal, info.StorageUsed, info.StorageFree = readDisk()
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
		"usage":  fmt.Sprintf("%.1f", usage),
		"cores":  countCPUCores(),
		"user":   user, "system": system, "idle": idle, "total": total,
	})
}

func apiSystemMemory(w http.ResponseWriter, r *http.Request) {
	t, u, f, p := readMemory()
	writeJSON(w, 200, map[string]string{"total": t, "used": u, "free": f, "percent": p})
}

func apiSystemDisk(w http.ResponseWriter, r *http.Request) {
	d, err := exec.Command("df", "-h").CombinedOutput()
	if err != nil {
		writeJSON(w, 200, []map[string]string{})
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
			ports = append(ports, map[string]string{
				"proto": f[0], "address": f[3], "state": f[1], "port": port,
			})
		}
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
		writeJSON(w, 200, map[string]string{"status": "ok"})
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
	writeJSON(w, 200, map[string]interface{}{"updates": updateCount, "available": updateCount > 0})
}

func getHostname() string {
	h, _ := os.Hostname()
	return h
}

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
		if len(c) > 35 {
			c = c[:35] + "..."
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
