import { useState, useEffect, useCallback } from 'react'

interface Server {
  id: number; name: string; ip: string; port: number; username: string
  status: string; uptime: string; cpu: string; ram: string; storage: string; created: string
}

interface SysInfo {
  hostname: string; uptime: string; cpu: string; cpu_cores: number
  ram_total: string; ram_used: string; ram_free: string; ram_percent: string
  storage_total: string; storage_used: string; storage_free: string
  load_avg: string; processes: number; os: string; kernel: string
}

interface PanelStatus {
  version: string; uptime: string; server_count: number
}

const base = ''
const api = async <T,>(path: string, opts?: RequestInit): Promise<T> => {
  const r = await fetch(base + path, { headers: { 'Content-Type': 'application/json' }, ...opts })
  if (!r.ok) { const e = await r.json().catch(() => ({})); throw new Error((e as Record<string, string>).error || r.statusText) }
  return r.json()
}

const pages = ['dashboard', 'servers', 'system', 'network', 'processes', 'updates', 'firewall'] as const
type Page = typeof pages[number]

export default function App() {
  const [page, setPage] = useState<Page>('dashboard')
  const [servers, setServers] = useState<Server[]>([])
  const [system, setSystem] = useState<SysInfo>({} as SysInfo)
  const [status, setStatus] = useState<PanelStatus>({} as PanelStatus)
  const [connected, setConnected] = useState(false)

  const load = useCallback(async () => {
    try {
      const [s, sv, sy] = await Promise.all([
        api<PanelStatus>('/api/status'),
        api<Server[]>('/api/servers'),
        api<SysInfo>('/api/system')
      ])
      setStatus(s); setServers(sv); setSystem(sy); setConnected(true)
    } catch { setConnected(false) }
  }, [])

  useEffect(() => { load(); const i = setInterval(load, 30000); return () => clearInterval(i) }, [load])

  const act = async (id: number, action: string) => {
    await api(`/api/servers/${action}`, { method: 'POST', body: JSON.stringify({ id }) })
    load()
  }

  const del = async (id: number) => {
    if (!confirm('Remove this server?')) return
    await api('/api/servers/remove', { method: 'POST', body: JSON.stringify({ id }) })
    load()
  }

  const addServer = async () => {
    const el = document.getElementById('add-name') as HTMLInputElement
    const ip = document.getElementById('add-ip') as HTMLInputElement
    const port = document.getElementById('add-port') as HTMLInputElement
    const user = document.getElementById('add-user') as HTMLInputElement
    if (!el?.value || !ip?.value) return
    await api('/api/servers/add', {
      method: 'POST',
      body: JSON.stringify({ name: el.value, ip: ip.value, port: parseInt(port?.value || '22'), username: user?.value || 'root' })
    })
    ;(document.querySelector('.modal') as HTMLElement)?.remove()
    load()
  }

  const runUpdate = async () => { await api('/api/update', { method: 'POST' }) }
  const fwRule = async () => {
    const action = (document.getElementById('fw-action') as HTMLSelectElement)?.value
    const port = parseInt((document.getElementById('fw-port') as HTMLInputElement)?.value)
    const proto = (document.getElementById('fw-proto') as HTMLSelectElement)?.value
    if (!port) return
    await api('/api/firewall', { method: 'POST', body: JSON.stringify({ action, port, protocol: proto }) })
  }

  const Nav = () => (
    <div className="sidebar">
      <div className="d-flex align-items-center mb-4 px-3 pt-3">
        <div className="icon-box me-2" style={{ background: 'rgba(74,158,255,.15)', color: '#4a9eff', width: 36, height: 36, fontSize: 18 }}>
          <i className="bi bi-grid-3x3-gap-fill"></i>
        </div>
        <span className="fw-bold fs-5">Cadix Panel</span>
      </div>
      {pages.map(p => (
        <div key={p} className={`nav-item ${page === p ? 'active' : ''}`} onClick={() => setPage(p)}>
          <i className={`bi ${navIcon(p)}`}></i> {p.charAt(0).toUpperCase() + p.slice(1)}
        </div>
      ))}
      <div className="sidebar-status">
        <div style={{ width: 10, height: 10, borderRadius: '50%', background: connected ? '#4ade80' : '#f87171' }}></div>
        <span className="ms-2">{connected ? `Connected v${status.version || ''}` : 'Disconnected'}</span>
      </div>
    </div>
  )

  const Card = (props: { icon: string; color: string; label: string; value: string | number }) => (
    <div className="col-md-3">
      <div className="card d-flex flex-row align-items-center">
        <div className="icon-box me-3" style={{ background: `${props.color}15`, color: props.color }}><i className={`bi bi-${props.icon}`}></i></div>
        <div><div className="val">{props.value || 'N/A'}</div><div className="lbl">{props.label}</div></div>
      </div>
    </div>
  )

  const pagesContent: Record<Page, JSX.Element> = {
    dashboard: (
      <>
        <div className="d-flex justify-content-between align-items-center mb-4">
          <div><h2 className="fw-bold mb-1">Dashboard</h2><p className="muted">System overview</p></div>
          <span className="muted" style={{ fontSize: 13 }}>{system.hostname || 'N/A'} &middot; v2.0.0</span>
        </div>
        <div className="row g-3 mb-4">
          <Card icon="server" color="#4a9eff" label="Servers" value={servers.length} />
          <Card icon="memory" color="#4ade80" label="Total RAM" value={system.ram_total || ''} />
          <Card icon="hdd" color="#fbbf24" label="Storage" value={system.storage_total || ''} />
          <Card icon="arrow-up" color="#c084fc" label="Uptime" value={system.uptime || ''} />
        </div>
        <div className="row g-3">
          <div className="col-md-6"><div className="card">
            <div className="d-flex justify-content-between mb-2"><span>CPU Usage</span><span>{system.load_avg || '0'}</span></div>
            <div className="progress"><div className="progress-bar" style={{ width: `${Math.min(parseFloat(system.load_avg || '0') * 8, 100)}%` }}></div></div>
          </div></div>
          <div className="col-md-6"><div className="card">
            <div className="d-flex justify-content-between mb-2"><span>RAM Usage</span><span>{system.ram_percent || '0%'}</span></div>
            <div className="progress"><div className="progress-bar" style={{ width: `${Math.min(parseFloat(system.ram_percent) || 0, 100)}%` }}></div></div>
          </div></div>
        </div>
      </>
    ),
    servers: (
      <>
        <div className="d-flex justify-content-between align-items-center mb-4">
          <div><h2 className="fw-bold mb-1">Servers</h2><p className="muted">{servers.length} total</p></div>
          <button className="btn btn-primary" data-bs-toggle="modal" data-bs-target="#addModal"><i className="bi bi-plus-lg"></i> Add</button>
        </div>
        {servers.length === 0 ? <div className="empty">No servers</div> : (
          <div className="card p-0" style={{ overflowX: 'auto' }}>
            <table><thead><tr><th>Name</th><th>IP</th><th>Status</th><th>Uptime</th><th>CPU</th><th>RAM</th><th>Actions</th></tr></thead>
              <tbody>{servers.map(s => (
                <tr key={s.id}>
                  <td>{s.name}</td><td>{s.ip}:{s.port || 22}</td>
                  <td><span className={`badge-${s.status}`}>{s.status.toUpperCase()}</span></td>
                  <td>{s.uptime || 'N/A'}</td><td title={s.cpu}>{(s.cpu || 'N/A').substring(0, 25)}</td>
                  <td>{s.ram || 'N/A'}</td>
                  <td>
                    <button className="btn btn-sm btn-outline-success me-1" onClick={() => act(s.id, 'start')}><i className="bi bi-play-fill"></i></button>
                    <button className="btn btn-sm btn-outline-danger me-1" onClick={() => act(s.id, 'stop')}><i className="bi bi-stop-fill"></i></button>
                    <button className="btn btn-sm btn-outline-warning me-1" onClick={() => act(s.id, 'restart')}><i className="bi bi-arrow-clockwise"></i></button>
                    <button className="btn btn-sm btn-outline-secondary" onClick={() => del(s.id)}><i className="bi bi-trash"></i></button>
                  </td>
                </tr>
              ))}</tbody>
            </table>
          </div>
        )}
        <div className="modal fade" id="addModal" tabIndex={-1}>
          <div className="modal-dialog"><div className="modal-content">
            <div className="modal-header"><h5 className="modal-title fw-bold">Add Server</h5>
              <button className="btn-close btn-close-white" data-bs-dismiss="modal"></button></div>
            <div className="modal-body">
              <div className="mb-3"><label className="form-label">Name</label><input className="form-control" id="add-name" defaultValue={`Server ${servers.length + 1}`} /></div>
              <div className="mb-3"><label className="form-label">IP</label><input className="form-control" id="add-ip" defaultValue={servers.length === 0 ? '127.0.0.1' : `10.0.0.${servers.length + 1}`} /></div>
              <div className="row g-2">
                <div className="col"><label className="form-label">Port</label><input className="form-control" id="add-port" defaultValue="22" /></div>
                <div className="col"><label className="form-label">User</label><input className="form-control" id="add-user" defaultValue="root" /></div>
              </div>
            </div>
            <div className="modal-footer">
              <button className="btn btn-outline-secondary" data-bs-dismiss="modal">Cancel</button>
              <button className="btn btn-primary" data-bs-dismiss="modal" onClick={addServer}>Add</button>
            </div>
          </div></div>
        </div>
      </>
    ),
    system: (
      <>
        <div className="d-flex justify-content-between align-items-center mb-4">
          <div><h2 className="fw-bold mb-1">System</h2><p className="muted">Hardware & OS</p></div>
          <button className="btn btn-outline-info" onClick={load}><i className="bi bi-arrow-clockwise"></i> Refresh</button>
        </div>
        <div className="row g-3">
          <div className="col-md-6"><div className="card">
            <div className="section-title">Overview</div>
            <table><tbody>
              {[['Hostname', system.hostname], ['OS', system.os], ['Kernel', system.kernel], ['CPU', system.cpu], ['Cores', system.cpu_cores], ['Uptime', system.uptime], ['Load Avg', system.load_avg], ['Processes', system.processes]].map(([k, v]) => (
                <tr key={k as string}><td className="muted" style={{ width: 160 }}>{k}</td><td>{(v ?? 'N/A')?.toString()}</td></tr>
              ))}
            </tbody></table>
          </div></div>
          <div className="col-md-6"><div className="card">
            <div className="section-title">Resources</div>
            <table><tbody>
              {[['RAM Total', system.ram_total], ['RAM Used', system.ram_used], ['RAM Free', system.ram_free], ['Storage Total', system.storage_total], ['Storage Used', system.storage_used], ['Storage Free', system.storage_free]].map(([k, v]) => (
                <tr key={k as string}><td className="muted" style={{ width: 160 }}>{k}</td><td>{v || 'N/A'}</td></tr>
              ))}
            </tbody></table>
          </div></div>
        </div>
      </>
    ),
    network: <NetworkPage />,
    processes: <ProcessesPage />,
    updates: <UpdatesPage onUpdate={runUpdate} />,
    firewall: <FirewallPage onRule={fwRule} />,
  }

  return (
    <>
      <Nav />
      <div className="main" style={{ minHeight: '100vh' }}>
        {pagesContent[page]}
      </div>
    </>
  )
}

function NetworkPage() {
  const [ports, setPorts] = useState<Record<string, string>[]>([])
  useEffect(() => { api('/api/system/network').then(setPorts).catch(() => setPorts([])) }, [])
  return (
    <div><h2 className="fw-bold mb-1">Network</h2><p className="muted mb-4">Open ports</p>
      <div className="card p-0">
        {ports.length === 0 ? <div className="empty">Loading...</div> : (
          <table><thead><tr><th>Proto</th><th>Address</th><th>State</th><th>Port</th></tr></thead>
            <tbody>{ports.map((p, i) => <tr key={i}><td>{p.proto}</td><td>{p.address}</td><td>{p.state}</td><td>{p.port}</td></tr>)}</tbody>
          </table>
        )}
      </div>
    </div>
  )
}

function ProcessesPage() {
  const [procs, setProcs] = useState<Record<string, string>[]>([])
  useEffect(() => { api('/api/system/processes').then(setProcs).catch(() => setProcs([])) }, [])
  return (
    <div><h2 className="fw-bold mb-1">Processes</h2><p className="muted mb-4">Top 30 by CPU</p>
      <div className="card p-0">
        {procs.length === 0 ? <div className="empty">Loading...</div> : (
          <table><thead><tr><th>PID</th><th>Name</th><th>CPU%</th><th>RAM%</th><th>State</th></tr></thead>
            <tbody>{procs.map((p, i) => <tr key={i}><td>{p.pid}</td><td>{p.name}</td><td>{p.cpu}%</td><td>{p.ram}%</td><td><span className="badge-online">{p.state}</span></td></tr>)}</tbody>
          </table>
        )}
      </div>
    </div>
  )
}

function UpdatesPage({ onUpdate }: { onUpdate: () => void }) {
  const [updates, setUpdates] = useState<Record<string, unknown>>({})
  useEffect(() => { api('/api/update/check').then(setUpdates).catch(() => setUpdates({})) }, [])
  const count = (updates.updates as number) || 0
  return (
    <div><div className="d-flex justify-content-between align-items-center mb-4">
      <div><h2 className="fw-bold mb-1">Updates</h2><p className="muted">Package management</p></div>
      <button className="btn btn-primary" onClick={onUpdate}><i className="bi bi-arrow-up-circle"></i> Update All</button>
    </div>
      <div className="card">
        <div className="d-flex align-items-center mb-3">
          <i className="bi bi-box-seam fs-3 me-3" style={{ color: updates.available ? '#fbbf24' : '#4ade80' }}></i>
          <div><div className="val">{count}</div><div className="lbl">Updates Available</div></div>
        </div>
        {updates.available
          ? <div className="alert-warning">Updates available. Click "Update All".</div>
          : <div className="alert-success">System up to date.</div>}
      </div>
    </div>
  )
}

function FirewallPage({ onRule }: { onRule: () => void }) {
  const [fw, setFw] = useState('')
  useEffect(() => { api<{ status: string }>('/api/firewall').then(r => setFw(r.status)).catch(() => setFw('Not enabled')) }, [])
  return (
    <div><h2 className="fw-bold mb-1">Firewall</h2><p className="muted mb-4">UFW management</p>
      <div className="card mb-3"><pre className="muted" style={{ whiteSpace: 'pre-wrap', margin: 0, fontSize: 13 }}>{fw || 'Loading...'}</pre></div>
      <div className="card">
        <div className="section-title">Quick Rule</div>
        <div className="row g-2 align-items-end">
          <div className="col"><label className="form-label">Action</label>
            <select className="form-select" id="fw-action"><option value="allow">Allow</option><option value="deny">Deny</option></select></div>
          <div className="col"><label className="form-label">Port</label><input className="form-control" id="fw-port" defaultValue="22" /></div>
          <div className="col"><label className="form-label">Protocol</label>
            <select className="form-select" id="fw-proto"><option value="tcp">TCP</option><option value="udp">UDP</option></select></div>
          <div className="col d-grid"><button className="btn btn-primary" onClick={onRule}>Apply</button></div>
        </div>
      </div>
    </div>
  )
}

function navIcon(p: string): string {
  const icons: Record<string, string> = {
    dashboard: 'bi-speedometer2', servers: 'bi-server', system: 'bi-cpu',
    network: 'bi-diagram-3', processes: 'bi-list-task', updates: 'bi-arrow-up-circle', firewall: 'bi-shield-check'
  }
  return icons[p] || 'bi-circle'
}
