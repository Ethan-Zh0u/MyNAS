import React, { Component, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import * as I from 'lucide-react';
import '@fontsource/barlow-condensed/500.css';
import '@fontsource/barlow-condensed/600.css';
import '@fontsource/barlow-condensed/700.css';
import { API, api, fmt, parent, Item } from './api';
import './style.css';

type Page = 'home' | 'files' | 'transfers' | 'trash' | 'settings';
type Health = { ok: boolean; user: { login: string; name: string; avatar: string }; protocol: string };
type Disk = { name: string; device: string; filesystem: string; mount: string; total: number; free: number; used: number; readBytes: number; writeBytes: number; protocol: string; smart: string };
type TrashRow = { id: string; original: string };
type UploadRow = { id: string; name: string; target: string; status: string; size: number; received: number };
type UploadSession = UploadRow & { chunkSize?: number };

const uploadControllers = new Map<string, AbortController>();
const activeUploadKey = 'activeUploadIds';
const readActiveUploads = () => { try { return JSON.parse(localStorage.getItem(activeUploadKey) || '[]') as string[]; } catch { return []; } };
const writeActiveUploads = (ids: string[]) => { try { localStorage.setItem(activeUploadKey, JSON.stringify(ids)); } catch { /* best effort */ } };
const rememberActiveUpload = (id: string) => writeActiveUploads([...new Set([...readActiveUploads(), id])]);
const forgetActiveUpload = (id: string) => writeActiveUploads(readActiveUploads().filter(value => value !== id));

async function setUploadStatus(id: string, status: 'paused' | 'uploading') {
  return api<UploadSession>(`/uploads/${id}`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ status }) });
}

async function pauseUpload(id: string) {
  uploadControllers.get(id)?.abort();
  uploadControllers.delete(id);
  forgetActiveUpload(id);
  await setUploadStatus(id, 'paused');
}

async function cancelUpload(id: string) {
  uploadControllers.get(id)?.abort();
  uploadControllers.delete(id);
  forgetActiveUpload(id);
  try { await setUploadStatus(id, 'paused'); } catch { /* DELETE below is authoritative */ }
  for (let attempt = 0; attempt < 4; attempt++) {
    try { await api(`/uploads/${id}`, { method: 'DELETE' }); return; }
    catch (error) { if (attempt === 3) throw error; await new Promise(resolve => setTimeout(resolve, 150)); }
  }
}

async function sendUpload(file: File, session: UploadSession) {
  if (file.name !== session.name || file.size !== session.size) throw new Error(`请选择同一个文件：${session.name}（${fmt(session.size)}）`);
  if (file.size === 0) return;
  const controller = new AbortController();
  uploadControllers.get(session.id)?.abort();
  uploadControllers.set(session.id, controller);
  rememberActiveUpload(session.id);
  try {
    await setUploadStatus(session.id, 'uploading');
    const chunkSize = session.chunkSize || 8 * 1024 * 1024;
    for (let offset = session.received || 0; offset < file.size;) {
      const body = file.slice(offset, offset + chunkSize);
      const response = await fetch(`${API}/api/v1/uploads/${session.id}`, { method: 'PATCH', headers: { 'X-MyNAS-Request': '1', 'X-Upload-Offset': String(offset) }, body, credentials: 'include', signal: controller.signal });
      if (!response.ok) throw new Error((await response.text()).trim() || `HTTP ${response.status}`);
      const result = await response.json() as { received: number };
      offset = result.received;
    }
  } catch (error) {
    try { await setUploadStatus(session.id, 'paused'); } catch { /* upload may already be finalizing */ }
    throw error;
  } finally {
    if (uploadControllers.get(session.id) === controller) uploadControllers.delete(session.id);
    forgetActiveUpload(session.id);
  }
}

const nav: Array<[Page, string, React.ComponentType<{ size?: number }>]> = [
  ['home', '主页', I.Home], ['files', '文件', I.Folder], ['transfers', '传输', I.ArrowLeftRight], ['trash', '回收站', I.Trash2], ['settings', '设置', I.Settings],
];
const typeIcons: Record<string, React.ComponentType<{ className?: string }>> = {
  folder: I.Folder, image: I.Image, video: I.Video, audio: I.Music, pdf: I.FileText,
  office: I.FileSpreadsheet, text: I.FileText, code: I.FileCode2, archive: I.Archive,
  disk: I.Disc3, font: I.Type, exec: I.Terminal, unknown: I.File,
};
const errorText = (e: unknown) => e instanceof Error ? e.message : '请求失败，请稍后重试。';
const readSetting = (key: string) => { try { return localStorage.getItem(key) || ''; } catch { return ''; } };
const saveSetting = (key: string, value: string) => { try { localStorage.setItem(key, value); } catch { /* 私密模式下仍可正常使用当前会话 */ } };

class PageBoundary extends Component<{ children: React.ReactNode; full?: boolean }, { broken: boolean }> {
  state = { broken: false };
  static getDerivedStateFromError() { return { broken: true }; }
  componentDidCatch(error: unknown) { console.error('MyNAS page error', error); }
  render() {
    if (this.state.broken) return <div className={this.props.full ? 'fatal' : 'empty'}><I.TriangleAlert /><h2>MyNAS 页面加载失败</h2><p>错误已被隔离，没有继续显示空白页。请重新加载应用。</p><button className="primary" onClick={() => location.reload()}><I.RefreshCw />重新加载</button></div>;
    return this.props.children;
  }
}

function App() {
  const [health, setHealth] = useState<Health>();
  const [connection, setConnection] = useState<'checking' | 'offline'>('checking');
  const [connectionError, setConnectionError] = useState('');
  const [page, setPage] = useState<Page>('home');
  const [dark, setDark] = useState(() => { const saved=readSetting('theme'); return saved ? saved === 'dark' : globalThis.matchMedia?.('(prefers-color-scheme: dark)').matches ?? false; });
  const checking = useRef(false);
  const check = useCallback(async () => {
    if(checking.current)return;
    checking.current=true; setConnection('checking'); setConnectionError('');
    try { const result=await api<Health>('/health'); setHealth(result); setConnectionError(''); saveSetting('lastUser',result.user.login); }
    catch(e) { setHealth(undefined); setConnection('offline'); setConnectionError(errorText(e)); }
    finally { checking.current=false; }
  }, []);
  useEffect(() => { document.documentElement.dataset.theme = dark ? 'dark' : 'light'; saveSetting('theme',dark ? 'dark' : 'light'); }, [dark]);
  useEffect(() => { check(); }, [check]);
  useEffect(() => { const online=()=>void check(); addEventListener('online',online); return()=>removeEventListener('online',online); }, [check]);
  useEffect(() => {
    const interrupted = readActiveUploads();
    writeActiveUploads([]);
    interrupted.forEach(id => void setUploadStatus(id, 'paused').catch(() => {}));
    const stopForPageExit = () => {
      for (const [id, controller] of uploadControllers) {
        controller.abort();
        fetch(`${API}/api/v1/uploads/${id}`, { method: 'PUT', headers: { 'Content-Type': 'application/json', 'X-MyNAS-Request': '1' }, body: JSON.stringify({ status: 'paused' }), credentials: 'include', keepalive: true }).catch(() => {});
      }
    };
    addEventListener('pagehide', stopForPageExit);
    return () => removeEventListener('pagehide', stopForPageExit);
  }, []);
  if (!health) return <Connect checking={connection==='checking'} error={connectionError} retry={check} />;
  const PageView = page === 'home' ? Home : page === 'files' ? Files : page === 'transfers' ? Transfers : page === 'trash' ? Trash : () => <Settings dark={dark} setDark={setDark} />;
  return <main className="app">
    <aside>
      <div className="brand"><span className="brand-mark"><I.HardDrive /></span><span>MY<span>NAS</span><small>PRIVATE STORAGE</small></span></div>
      <div className="node-state"><i /> 私有节点在线</div>
      <nav aria-label="主导航">{nav.map(([key, label, Icon], index) => <button className={page === key ? 'active' : ''} onClick={() => setPage(key)} key={key}><span className="nav-index">0{index + 1}</span><Icon />{label}</button>)}</nav>
      <div className="secure-note"><I.ShieldCheck /><span>TAILSCALE LINK<small>端到端私有通道</small></span></div>
      <div className="profile">{health.user.avatar ? <img src={health.user.avatar} alt="" /> : <I.UserRound />}<span><b>{health.user.name || health.user.login}</b><small>{health.user.login}</small></span></div>
    </aside>
    <section className="content"><PageBoundary key={page}><PageView /></PageBoundary></section>
  </main>;
}

function Connect({ checking, error, retry }: { checking: boolean; error: string; retry: () => void }) {
  const privateOrigin=typeof location!=='undefined'&&new URL(API).origin!==location.origin;
  return <div className="connect"><div className="line-art"><I.HardDrive />{checking?<I.LoaderCircle className="spin"/>:<I.WifiOff />}</div><h1>MyNAS</h1><h2>{checking ? '正在验证私有连接…' : '尚未连接 Tailscale，或当前账号没有 rsp 的访问权限'}</h2><p>此公共页面始终可以打开；NAS 文件仍只通过 Tailscale 私有 HTTPS 传输。浏览器无法可靠区分“未登录”和“没有设备权限”。</p>{error&&<p className="connection-error">{error}</p>}<ol><li>打开 Tailscale 并确认状态为已连接</li><li>登录有 rsp 访问权的账号</li><li>返回此页后重新检测</li></ol><div className="row">{privateOrigin&&<a className="button" href={API + '/'}><I.ShieldCheck />打开稳定的私有 MyNAS</a>}<button className="ghost" disabled={checking} onClick={() => void retry()}><I.RefreshCw />{checking?'检测中':'刷新连接状态'}</button><a className="ghost" href="https://login.tailscale.com/admin/machines" target="_blank" rel="noreferrer">Tailscale 登录页</a><a className="ghost" href="https://tailscale.com/download" target="_blank" rel="noreferrer">下载 Tailscale</a></div><small>推荐将 {new URL(API).host} 加入书签；连接 Tailscale 后它与 API 同源，不会触发跨站本地网络访问提示。</small></div>;
}

function Home() {
  const [disk, setDisk] = useState<Disk>();
  const [previous, setPrevious] = useState<Disk>();
  const [drawer, setDrawer] = useState(false);
  useEffect(() => { const load = () => api<Disk>('/disk').then(d => { setDisk(current => { setPrevious(current); return d; }); }).catch(() => {}); void load(); const timer = setInterval(load, 2000); return () => clearInterval(timer); }, []);
  if (!disk) return <div className="empty"><I.LoaderCircle className="spin" /><p>正在读取真实磁盘信息…</p></div>;
  const percent = Math.round(disk.used / disk.total * 100);
  const speed = (now: number, old?: number) => old === undefined ? '—' : `${fmt(Math.max(0, now - old))}/2s`;
  return <><header className="home-header"><div><span className="eyebrow">STORAGE OVERVIEW / 实时状态</span><h1>你的私有存储空间</h1><p>文件只经由加密的 Tailscale 通道传输。</p></div><div className="live-stamp"><i /> LIVE<br/><small>每 2 秒更新</small></div></header>
    <section className="storage-stage" aria-label="存储概览">
      <button className="diskcard" onClick={() => setDrawer(true)} aria-label="查看硬盘详情">
        <div className="disk-id"><span>PRIMARY ARRAY</span><h2>{disk.name}</h2><p>{disk.device} · {disk.filesystem}</p></div>
        <div className="capacity-number"><strong>{percent}</strong><span>%<small>USED</small></span></div>
        <div className="capacity-track" style={{ '--p': percent } as React.CSSProperties}><i /><span>{fmt(disk.used)} 已用</span><span>{fmt(disk.free)} 可用</span></div>
        <div className="disk-total"><span>TOTAL CAPACITY</span><strong>{fmt(disk.total)}</strong></div><I.ArrowUpRight />
      </button>
      <div className="telemetry" aria-label="实时遥测">
        <div><span>READ / 2S</span><strong>{speed(disk.readBytes, previous?.readBytes)}</strong></div>
        <div><span>WRITE / 2S</span><strong>{speed(disk.writeBytes, previous?.writeBytes)}</strong></div>
        <div><span>SMART</span><strong>{disk.smart || '正常'}</strong></div>
        <div><span>PROTOCOL</span><strong>{disk.protocol}</strong></div>
      </div>
    </section>
    {drawer && <div className="drawer"><button className="close" onClick={() => setDrawer(false)} aria-label="关闭"><I.X /></button><span className="eyebrow">DEVICE INSPECTION</span><h2>硬盘详情</h2><dl><dt>设备</dt><dd>{disk.device}</dd><dt>文件系统</dt><dd>{disk.filesystem}</dd><dt>挂载点</dt><dd>{disk.mount}</dd><dt>总容量</dt><dd>{fmt(disk.total)}</dd><dt>已用 / 可用</dt><dd>{fmt(disk.used)} / {fmt(disk.free)}</dd><dt>读取 / 写入</dt><dd>{speed(disk.readBytes, previous?.readBytes)} · {speed(disk.writeBytes, previous?.writeBytes)}</dd><dt>SMART</dt><dd>{disk.smart}</dd><dt>Tailscale</dt><dd>在线 · {disk.protocol}</dd></dl></div>}</>;
}

function Files() {
  const [path, setPath] = useState(readSetting('lastPath'));
  const [items, setItems] = useState<Item[]>([]);
  const [view, setView] = useState(readSetting('fileView') || 'grid');
  const [selected, setSelected] = useState<string[]>([]);
  const [search, setSearch] = useState('');
  const [loadError, setLoadError] = useState('');
  const [uploading, setUploading] = useState('');
  const [preview, setPreview] = useState<Item>();
  const [dialog, setDialog] = useState<{ mode: 'folder' | 'rename' | 'copy' | 'move' | 'delete'; item?: Item }>();
  const input = useRef<HTMLInputElement>(null);
  const load = useCallback(async () => { try { const result = await api<{ items: Item[] }>('/files?path=' + encodeURIComponent(path)); setItems(Array.isArray(result.items) ? result.items : []); setSelected([]); setLoadError(''); saveSetting('lastPath',path); } catch (e) { setLoadError(errorText(e)); } }, [path]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => { const stream = new EventSource(API + '/api/v1/events'); stream.addEventListener('update', () => void load()); return () => stream.close(); }, [load]);
  const shown = useMemo(() => items.filter(x => x.name.toLocaleLowerCase().includes(search.toLocaleLowerCase())), [items, search]);
  const toggle = (value: string) => setSelected(old => old.includes(value) ? old.filter(x => x !== value) : [...old, value]);
  const upload = async (file: File) => { setUploading(file.name); try { const created = await api<{ id: string; chunkSize: number; status: string }>('/uploads', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ path, name: file.name, size: file.size }) }); await sendUpload(file, { ...created, name: file.name, target: path, size: file.size, received: 0 }); } catch (e) { if (!(e instanceof DOMException && e.name === 'AbortError')) setLoadError(`上传失败：${errorText(e)}`); } finally { setUploading(''); void load(); } };
  const open = (item: Item) => { if (item.type === 'folder') setPath(item.path); else if (['image', 'video', 'audio', 'text', 'code'].includes(item.type)) setPreview(item); else window.open(`${API}/api/v1/files/${encodeURI(item.path)}`, '_blank', 'noopener'); };
  return <><header><div><h1>文件</h1><div className="crumb"><button onClick={() => setPath('')}>MyNAS</button>{path.split('/').filter(Boolean).map((part: string, index: number) => <React.Fragment key={index}> / <button onClick={() => setPath(path.split('/').slice(0, index + 1).join('/'))}>{part}</button></React.Fragment>)}</div></div><div className="row"><input placeholder="搜索文件名" value={search} onChange={e => setSearch(e.target.value)} /><button onClick={() => setDialog({ mode: 'folder' })}><I.FolderPlus />新建文件夹</button><button className="primary" onClick={() => input.current?.click()}><I.Upload />上传</button><input hidden ref={input} type="file" multiple onChange={e => Array.from(e.target.files || []).forEach(file => void upload(file))} /></div></header>{uploading && <div className="notice">正在分块上传 {uploading}</div>}{loadError && <div className="notice">{loadError}<button onClick={() => void load()}>重试</button></div>}<div className="tools"><span>{selected.length ? `已选 ${selected.length} 项` : `${shown.length} 项`}</span><button title="切换视图" onClick={() => { const next = view === 'grid' ? 'list' : 'grid'; setView(next); saveSetting('fileView',next); }}>{view === 'grid' ? <I.List /> : <I.Grid2X2 />}</button><button disabled={!selected.length} onClick={() => setDialog({ mode: 'delete' })}><I.Trash2 />删除</button></div><div className={`files ${view}`}>{shown.map(item => <FileCard key={item.path} item={item} selected={selected.includes(item.path)} toggle={() => toggle(item.path)} open={() => open(item)} action={mode => setDialog({ mode, item })} />)}</div>{!shown.length && !loadError && <div className="empty">此目录为空。拖入文件或点击上传。</div>}{preview && <Preview item={preview} close={() => setPreview(undefined)} />}{dialog && <ActionDialog dialog={dialog} path={path} selected={selected} close={() => setDialog(undefined)} done={load} />}</>;
}

function FileCard({ item, selected, toggle, open, action }: { item: Item; selected: boolean; toggle: () => void; open: () => void; action: (mode: 'rename' | 'copy' | 'move' | 'delete') => void }) {
  const Icon = typeIcons[item.type] || I.File;
  return <article className={selected ? 'selected' : ''} onDoubleClick={open}><input type="checkbox" checked={selected} onChange={toggle} aria-label={`选择 ${item.name}`} /><Icon className={`type ${item.type}`} /><div className="filename" title={item.name}>{item.name}</div><small>{item.type === 'folder' ? '文件夹' : fmt(item.size)} · {new Date(item.modified).toLocaleString()}</small><div className="actions"><button title="打开" onClick={open}><I.ExternalLink /></button><button title="复制" onClick={() => action('copy')}><I.Copy /></button><button title="移动" onClick={() => action('move')}><I.FolderInput /></button><button title="重命名" onClick={() => action('rename')}><I.Pencil /></button><a title="下载" href={`${API}/api/v1/files/${encodeURI(item.path)}`}><I.Download /></a></div></article>;
}

function ActionDialog({ dialog, path, selected, close, done }: { dialog: { mode: 'folder' | 'rename' | 'copy' | 'move' | 'delete'; item?: Item }; path: string; selected: string[]; close: () => void; done: () => Promise<void> }) {
  const [value, setValue] = useState(dialog.mode === 'rename' ? dialog.item?.name || '' : dialog.mode === 'copy' || dialog.mode === 'move' ? parent(dialog.item?.path || '') : '');
  const [error, setError] = useState('');
  const labels = { folder: '新建文件夹', rename: '重命名', copy: '复制到', move: '移动到', delete: '删除到回收站' };
  const submit = async (event: React.FormEvent) => { event.preventDefault(); try { if (dialog.mode === 'folder') await api('/folders', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ path, name: value }) }); else { const sources = dialog.item ? [dialog.item.path] : selected; for (const from of sources) { if (dialog.mode === 'delete') await api('/operations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'delete', from }) }); else { const base = dialog.mode === 'rename' ? `${parent(from)}${parent(from) ? '/' : ''}${value}` : `${value.replace(/\/$/, '')}${value ? '/' : ''}${from.split('/').pop()}`; await api('/operations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: dialog.mode, from, to: base, conflict: 'rename' }) }); } } } await done(); close(); } catch (e) { setError(errorText(e)); } };
  return <div className="preview" role="dialog" aria-modal="true"><form className="preview-card" onSubmit={submit}><button type="button" className="close" onClick={close} aria-label="关闭"><I.X /></button><h2>{labels[dialog.mode]}</h2>{dialog.mode === 'delete' ? <p>将 {dialog.item?.name || `${selected.length} 个项目`} 移入 MyNAS 回收站，可在回收站中恢复。</p> : <input autoFocus value={value} onChange={e => setValue(e.target.value)} placeholder={dialog.mode === 'folder' || dialog.mode === 'rename' ? '名称' : '目标文件夹（相对 MyNAS）'} required maxLength={180} />}{error && <p className="error">{error}</p>}<div className="row" style={{ marginTop: 20 }}><button type="button" onClick={close}>取消</button><button className="primary" type="submit">确认</button></div></form></div>;
}

function Preview({ item, close }: { item: Item; close: () => void }) { const url = `${API}/api/v1/files/${encodeURI(item.path)}`; const [text, setText] = useState('加载中…'); useEffect(() => { if (item.type === 'text' || item.type === 'code') fetch(url, { headers: { Range: 'bytes=0-262143' }, credentials: 'include' }).then(r => r.text()).then(setText).catch(() => setText('预览读取失败')); }, [item.type, url]); return <div className="preview" role="dialog" aria-modal="true"><div className="preview-card"><button className="close" onClick={close} aria-label="关闭预览"><I.X /></button><h2>{item.name}</h2>{item.type === 'image' && <img src={url} alt={item.name} />}{item.type === 'video' && <video controls src={url} />}{item.type === 'audio' && <audio controls src={url} />}{(item.type === 'text' || item.type === 'code') && <pre>{text}</pre>}</div></div>; }

function Transfers() {
  const [rows, setRows] = useState<UploadRow[]>([]);
  const [error, setError] = useState('');
  const [resumeRow, setResumeRow] = useState<UploadRow>();
  const fileInput = useRef<HTMLInputElement>(null);
  const load = useCallback(() => api<UploadRow[]>('/uploads').then(x => setRows(Array.isArray(x) ? x : [])).catch(e => setError(errorText(e))), []);
  useEffect(() => { void load(); const timer = setInterval(load, 1500); return () => clearInterval(timer); }, [load]);
  const run = async (action: () => Promise<void>) => { try { setError(''); await action(); await load(); } catch (e) { setError(errorText(e)); } };
  const chooseResume = (row: UploadRow) => { setResumeRow(row); fileInput.current?.click(); };
  const resume = (file?: File) => { const row = resumeRow; setResumeRow(undefined); if (!row || !file) return; void run(() => sendUpload(file, row)); };
  const labels: Record<string, string> = { waiting: '等待上传', uploading: '上传中', paused: '已暂停', verifying: '正在校验', 'processing-cover': '正在生成封面', completed: '已完成', failed: '失败' };
  return <><header><div><h1>传输</h1><p>上传可暂停、续传或取消；续传时浏览器会要求重新选择原文件。</p></div><button onClick={() => void load()}><I.RefreshCw />刷新</button></header><input ref={fileInput} hidden type="file" onChange={e => { resume(e.target.files?.[0]); e.currentTarget.value = ''; }} />{error && <div className="notice">{error}</div>}{rows.length ? <div className="list transfer-list">{rows.map(row => { const percent = row.size ? Math.min(100, Math.round(row.received / row.size * 100)) : 0; const pausable = row.status === 'waiting' || row.status === 'uploading'; const resumable = row.status === 'paused' || row.status === 'failed'; const cancellable = !['completed', 'verifying', 'processing-cover'].includes(row.status); return <div key={row.id}><I.ArrowUpToLine /><span><b>{row.name}</b><small>{row.target || 'MyNAS'} · {labels[row.status] || row.status} · {fmt(row.received)} / {fmt(row.size)}</small><progress value={percent} max="100" /></span><em>{percent}%</em><div className="transfer-actions">{pausable && <button onClick={() => void run(() => pauseUpload(row.id))}><I.Pause />暂停</button>}{resumable && <button onClick={() => chooseResume(row)}><I.Play />继续</button>}{cancellable && <button onClick={() => void run(() => cancelUpload(row.id))}><I.X />取消</button>}</div></div>; })}</div> : <div className="empty"><I.ArrowLeftRight /><h2>暂无传输任务</h2></div>}<div className="notice download-note"><I.Download />下载由浏览器的下载面板管理，可在浏览器中暂停或取消；服务器已支持断点续传。</div></>;
}

function Trash() { const [rows, setRows] = useState<TrashRow[]>([]); const [error, setError] = useState(''); const [pending,setPending]=useState<{row:TrashRow;action:'restore'|'purge'}>(); const load = () => api<TrashRow[]>('/trash').then(x => { setRows(Array.isArray(x) ? x : []); setError(''); }).catch(e => setError(errorText(e))); useEffect(() => { void load(); }, []); const act = async () => { if(!pending)return; try { await api('/trash', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id:pending.row.id, action:pending.action }) }); setPending(undefined); void load(); } catch (e) { setError(errorText(e)); } }; return <><header><h1>回收站</h1><button onClick={load}><I.RefreshCw />刷新</button></header>{error && <div className="notice">{error}</div>}<div className="list">{rows.map(row => <div key={row.id}><I.Trash2 />{row.original}<span /><button onClick={() => setPending({row,action:'restore'})}>恢复</button><button className="danger" onClick={() => setPending({row,action:'purge'})}>永久删除</button></div>)}{!rows.length && !error && <div className="empty">回收站为空</div>}</div>{pending&&<div className="preview" role="dialog" aria-modal="true"><div className="preview-card"><button className="close" aria-label="关闭" onClick={()=>setPending(undefined)}><I.X/></button><h2>{pending.action==='purge'?'确认永久删除':'确认恢复'}</h2><p>{pending.action==='purge'?'此操作无法撤销。将永久删除：':'将文件恢复到原始位置：'}<br/><b>{pending.row.original}</b></p><div className="row"><button onClick={()=>setPending(undefined)}>取消</button><button className={pending.action==='purge'?'danger primary':'primary'} onClick={()=>void act()}>{pending.action==='purge'?'永久删除':'恢复'}</button></div></div></div>}</>; }

function Settings({ dark, setDark }: { dark: boolean; setDark: (value: boolean) => void }) { return <><header><h1>设置</h1></header><div className="setting"><div><h2>外观</h2><label><input type="checkbox" checked={dark} onChange={e => setDark(e.target.checked)} /> 使用深色主题</label><h2 style={{ marginTop: 24 }}>连接</h2><p>文件数据只通过 rsp.tail681937.ts.net 的 HTTPS over Tailscale Serve 传输；公共页面不传输 NAS 文件。</p></div></div></>; }

const root=document.getElementById('root');
if(root)createRoot(root).render(<PageBoundary full><App /></PageBoundary>);
