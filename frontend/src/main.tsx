import React, { Component, createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import * as I from 'lucide-react';
import '@fontsource/barlow-condensed/500.css';
import '@fontsource/barlow-condensed/600.css';
import '@fontsource/barlow-condensed/700.css';
import { API, api, fmt, parent, Item, PairedNode, MyNASNode, parsePairedNode, loadNodes, rememberNode, removeNode, activateNode, normalizeNodeUrl } from './api';
import './style.css';

type Page = 'home' | 'files' | 'transfers' | 'trash' | 'settings';
type Health = { ok: boolean; user: { login: string; name: string; avatar: string }; protocol: string };
type Volume = { id: string; name: string; uuid: string; device: string; filesystem: string; mount: string; status: 'online' | 'offline'; total: number; free: number; used: number; readBytes: number; writeBytes: number; protocol: string; smart: string };
type VolumeCandidate = { device: string; uuid: string; label: string; model: string; serial: string; filesystem: string; mount: string; size: number; removable: boolean; supported: boolean; registered: boolean; reason?: string };
type TrashRow = { id: string; volumeId: string; volumeName: string; original: string };
type UploadRow = { id: string; volumeId: string; name: string; target: string; status: string; size: number; received: number };
type UploadSession = UploadRow & { chunkSize?: number };
type Locale = 'zh' | 'en';
type SetupPlatform = 'windows' | 'macos' | 'linux';

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

const nav: Array<[Page, string, string, React.ComponentType<{ size?: number }>]> = [
  ['home', '主页', 'Home', I.Home], ['files', '文件', 'Files', I.Folder], ['transfers', '传输', 'Transfers', I.ArrowLeftRight], ['trash', '回收站', 'Trash', I.Trash2], ['settings', '设置', 'Settings', I.Settings],
];
const typeIcons: Record<string, React.ComponentType<{ className?: string }>> = {
  folder: I.Folder, image: I.Image, video: I.Video, audio: I.Music, pdf: I.FileText,
  office: I.FileSpreadsheet, text: I.FileText, code: I.FileCode2, archive: I.Archive,
  disk: I.Disc3, font: I.Type, exec: I.Terminal, unknown: I.File,
};
const errorText = (e: unknown) => e instanceof Error ? e.message : '请求失败，请稍后重试。';
const readSetting = (key: string) => { try { return localStorage.getItem(key) || ''; } catch { return ''; } };
const saveSetting = (key: string, value: string) => { try { localStorage.setItem(key, value); } catch { /* 私密模式下仍可正常使用当前会话 */ } };
const pairedNodeKey = `pairedNode:${API}`;
const readPairedNode = (): PairedNode | undefined => parsePairedNode(readSetting(pairedNodeKey),API);
const connectedNodeName = () => { try { const host=new URL(API).hostname; return ['localhost','127.0.0.1'].includes(host) ? 'rsp' : host.split('.')[0]; } catch { return 'MyNAS'; } };
const detectPlatform=():SetupPlatform=>{if(typeof navigator==='undefined')return'windows';const navInfo=navigator as Navigator&{userAgentData?:{platform?:string}};const value=(navInfo.userAgentData?.platform||navInfo.platform||navInfo.userAgent||'').toLowerCase();return value.includes('mac')?'macos':value.includes('linux')?'linux':'windows'};

const LocaleContext=createContext<{locale:Locale;setLocale:(value:Locale)=>void;t:(zh:string,en:string)=>string}>({locale:'zh',setLocale:()=>{},t:(zh)=>zh});
const useLocale=()=>useContext(LocaleContext);
function LocaleProvider({children}:{children:React.ReactNode}) {
  const [locale,setLocale]=useState<Locale>(()=>readSetting('locale')==='en'?'en':'zh');
  useEffect(()=>{saveSetting('locale',locale);document.documentElement.lang=locale==='en'?'en':'zh-CN'},[locale]);
  const value=useMemo(()=>({locale,setLocale,t:(zh:string,en:string)=>locale==='en'?en:zh}),[locale]);
  return <LocaleContext.Provider value={value}>{children}</LocaleContext.Provider>;
}

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
  const {locale,setLocale,t}=useLocale();
  const [health, setHealth] = useState<Health>();
  const [pairedNode, setPairedNode] = useState<PairedNode | undefined>(() => readPairedNode());
  const [nodeManager, setNodeManager] = useState(false);
  const [connection, setConnection] = useState<'checking' | 'offline'>('checking');
  const [connectionError, setConnectionError] = useState('');
  const [page, setPage] = useState<Page>('home');
  const [dark, setDark] = useState(() => { const saved=readSetting('theme'); return saved ? saved === 'dark' : globalThis.matchMedia?.('(prefers-color-scheme: dark)').matches ?? false; });
  const checking = useRef(false);
  const check = useCallback(async () => {
    if(checking.current)return;
    checking.current=true; setConnection('checking'); setConnectionError('');
    try { const result=await api<Health>('/health'); const paired={apiUrl:API,host:new URL(API).host,user:result.user.login,verifiedAt:new Date().toISOString()}; const known=loadNodes().find(node=>node.apiUrl===API); const pendingName=readSetting(`pendingNodeName:${API}`).trim(); setHealth(result); setPairedNode(paired); setConnectionError(''); saveSetting('lastUser',result.user.login); saveSetting(pairedNodeKey,JSON.stringify(paired)); rememberNode({...paired,name:pendingName||known?.name||connectedNodeName()}); if(pendingName)saveSetting(`pendingNodeName:${API}`,''); }
    catch(e) { setHealth(undefined); setConnection('offline'); setConnectionError(errorText(e)); }
    finally { checking.current=false; }
  }, []);
  useEffect(() => { document.documentElement.dataset.theme = dark ? 'dark' : 'light'; saveSetting('theme',dark ? 'dark' : 'light'); }, [dark]);
  useEffect(() => { check(); }, [check]);
  useEffect(() => { const timer=globalThis.setInterval(()=>void check(),10000); return()=>globalThis.clearInterval(timer); }, [check]);
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
  const onboardingPreview=typeof location!=='undefined'&&['localhost','127.0.0.1'].includes(location.hostname)&&new URLSearchParams(location.search).has('onboarding');
  const offlinePreview=typeof location!=='undefined'&&['localhost','127.0.0.1'].includes(location.hostname)&&new URLSearchParams(location.search).has('offline');
  if(onboardingPreview)return <Connect checking={false} error="" retry={check} previewGuide/>;
  if(offlinePreview)return <Connect checking={false} error="无法连接树莓派的 MyNAS 服务，请检查设备电源、网络和 Tailscale。" retry={check} pairedNode={pairedNode||{apiUrl:API,host:'rsp',user:'已授权用户',verifiedAt:new Date().toISOString()}}/>;
  if (!health) return <Connect checking={connection==='checking'} error={connectionError} retry={check} pairedNode={pairedNode} />;
  const PageView = page === 'home' ? Home : page === 'files' ? Files : page === 'transfers' ? Transfers : page === 'trash' ? Trash : Settings;
  return <main className="app">
    <aside>
      <div className="brand"><span className="brand-mark"><I.HardDrive /></span><span>MY<span>NAS</span><small>PRIVATE STORAGE</small></span></div>
      <button className="node-switcher" onClick={()=>setNodeManager(true)} aria-label={t('管理 MyNAS 设备','Manage MyNAS devices')}><i /><span><b>{connectedNodeName()}</b><small>{t('已连接 · 管理设备','Connected · Manage')}</small></span><I.ChevronDown /></button>
      <button className="language-toggle" onClick={()=>setLocale(locale==='zh'?'en':'zh')} aria-label={t('切换到英文','Switch to Chinese')}><I.Languages/><span>{locale==='zh'?'中文':'English'}</span><b>{locale==='zh'?'EN':'中'}</b></button>
      <label className="theme-toggle" title={dark ? t('切换到浅色主题','Switch to light theme') : t('切换到深色主题','Switch to dark theme')}>{dark ? <I.Sun /> : <I.Moon />}<span>{t('深色主题','Dark theme')}</span><input type="checkbox" checked={dark} onChange={e => setDark(e.target.checked)} aria-label={t('使用深色主题','Use dark theme')} /><i aria-hidden="true" /></label>
      <nav aria-label={t('主导航','Main navigation')}>{nav.map(([key, zh, en, Icon], index) => <button className={page === key ? 'active' : ''} onClick={() => setPage(key)} key={key}><span className="nav-index">0{index + 1}</span><Icon />{locale==='en'?en:zh}</button>)}</nav>
      <div className="secure-note"><I.ShieldCheck /><span>TAILSCALE LINK<small>{t('端到端私有通道','End-to-end private link')}</small></span></div>
      <div className="profile">{health.user.avatar ? <img src={health.user.avatar} alt="" /> : <I.UserRound />}<span><b>{health.user.name || health.user.login}</b><small>{health.user.login}</small></span></div>
    </aside>
    <section className="content"><PageBoundary key={page}><PageView /></PageBoundary></section>{nodeManager&&<NodeManager close={()=>setNodeManager(false)}/>}
  </main>;
}

function Connect({ checking, error, retry, pairedNode, previewGuide=false }: { checking: boolean; error: string; retry: () => void; pairedNode?: PairedNode; previewGuide?: boolean }) {
  const {locale,setLocale,t}=useLocale();
  const privateOrigin=typeof location!=='undefined'&&new URL(API).origin!==location.origin;
  const [guide,setGuide]=useState(previewGuide);
  return <><button className="connect-language" onClick={()=>setLocale(locale==='zh'?'en':'zh')} aria-label={t('切换到英文','Switch to Chinese')}><I.Languages/><span>{locale==='zh'?'English':'中文'}</span></button><div className={`connect ${pairedNode ? 'returning-node' : 'first-connect'}`}><div className="line-art"><I.HardDrive />{checking?<I.LoaderCircle className="spin"/>:pairedNode?<I.Unplug/>:<I.RadioTower/>}</div><h1>MyNAS</h1><h2>{checking ? t('正在验证私有连接…','Verifying private connection…') : pairedNode ? t(`树莓派 ${pairedNode.host} 当前未连接`,`Raspberry Pi ${pairedNode.host} is offline`) : t('连接你的第一台 MyNAS','Connect your first MyNAS')}</h2><p>{pairedNode ? t('这台设备已经完成过配对，不需要重新安装。请恢复树莓派电源、网络或 Tailscale 连接。','This device is already paired. Restore power, network, or its Tailscale connection; no reinstall is required.') : t('没有发现已配对的 MyNAS。首次使用需要准备树莓派、开启 SSH，并让电脑与树莓派加入同一个 Tailscale 私有网络。','No paired MyNAS was found. Prepare a Raspberry Pi, enable SSH, and join both devices to the same Tailscale network.')}</p>{error&&<p className="connection-error">{error}</p>}{!checking&&pairedNode&&<ol><li>{t('确认树莓派已经开机并连接网络','Make sure the Raspberry Pi is powered on and online')}</li><li>{t('打开电脑端 Tailscale，确认状态为已连接','Open Tailscale on this computer and confirm it is connected')}</li><li>{t('点击下方按钮重新连接树莓派','Use the button below to reconnect')}</li></ol>}<div className="row">{!checking&&!pairedNode&&<button className="primary onboarding-start" onClick={()=>setGuide(true)}><I.Route/>{t('开始首次连接向导','Start setup guide')}</button>}{privateOrigin&&pairedNode&&<a className="ghost" href={API + '/'}><I.ShieldCheck />{t('尝试打开私有地址','Open private address')}</a>}<button className={pairedNode?'primary':'ghost'} disabled={checking} onClick={() => void retry()}><I.RefreshCw />{checking?t('正在连接','Connecting'):t('重新连接树莓派','Reconnect Raspberry Pi')}</button>{pairedNode&&<a className="ghost" href="https://login.tailscale.com/admin/machines" target="_blank" rel="noreferrer">{t('查看 Tailscale 设备','View Tailscale devices')}</a>}</div>{pairedNode&&<small>{t('已配对设备','Paired device')}：{pairedNode.host} · {pairedNode.user || t('已授权用户','Authorized user')}。{t('连接恢复后会自动返回主页。','The dashboard will return automatically after reconnection.')}</small>}</div>{guide&&!pairedNode&&<FirstConnectionGuide close={()=>setGuide(false)}/>}</>;
}

const driveDemoVolumes=():Volume[]=>{
  const GiB=1024**3,TiB=1024**4;
  return [
    {id:'demo-system',name:'系统与应用',uuid:'DEMO-SYSTEM',device:'/dev/nvme0n1p2',filesystem:'ext4',mount:'/mnt/mynas/system',status:'online',total:512*GiB,used:186*GiB,free:326*GiB,readBytes:92*GiB,writeBytes:38*GiB,protocol:'HTTPS over Tailscale Serve',smart:'健康'},
    {id:'demo-media',name:'影音资料库',uuid:'DEMO-MEDIA',device:'/dev/sda1',filesystem:'exfat',mount:'/mnt/mynas/media',status:'online',total:4*TiB,used:3.12*TiB,free:.88*TiB,readBytes:468*GiB,writeBytes:121*GiB,protocol:'HTTPS over Tailscale Serve',smart:'健康'},
    {id:'demo-backup',name:'家庭备份',uuid:'DEMO-BACKUP',device:'/dev/sdb1',filesystem:'ext4',mount:'/mnt/mynas/backup',status:'online',total:8*TiB,used:2.71*TiB,free:5.29*TiB,readBytes:244*GiB,writeBytes:306*GiB,protocol:'HTTPS over Tailscale Serve',smart:'健康'},
    {id:'demo-archive',name:'离线归档盘',uuid:'DEMO-ARCHIVE',device:'/dev/sdc1',filesystem:'ntfs3',mount:'/mnt/mynas/archive',status:'offline',total:2*TiB,used:.91*TiB,free:1.09*TiB,readBytes:0,writeBytes:0,protocol:'HTTPS over Tailscale Serve',smart:'设备未连接'},
  ];
};

function Home() {
  const {t}=useLocale();
  const demo=typeof location!=='undefined'&&['localhost','127.0.0.1'].includes(location.hostname)&&new URLSearchParams(location.search).get('demo')==='drives';
  const [volumes, setVolumes] = useState<Volume[]>(()=>demo?driveDemoVolumes():[]);
  const [previous, setPrevious] = useState<Record<string, Volume>>({});
  const [selected, setSelected] = useState<Volume>();
  const [renameVolume, setRenameVolume] = useState<Volume>();
  const [wizard, setWizard] = useState(false);
  useEffect(() => { if(demo)return; const load = () => api<Volume[]>('/volumes').then(next => { setVolumes(current => { setPrevious(Object.fromEntries(current.map(volume => [volume.id, volume]))); return Array.isArray(next) ? next : []; }); }).catch(() => {}); void load(); const timer = setInterval(load, 2000); return () => clearInterval(timer); }, [demo]);
  const speed = (now: number, old?: number) => old === undefined ? '—' : `${fmt(Math.max(0, now - old))}/2s`;
  const rename=async(volume:Volume,name:string)=>{const updated=demo?{...volume,name}:await api<Volume>('/volumes',{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:volume.id,name})});setVolumes(rows=>rows.map(row=>row.id===updated.id?updated:row));setSelected(current=>current?.id===updated.id?updated:current);setRenameVolume(undefined)};
  return <><header className="home-header"><div><span className="eyebrow">STORAGE OVERVIEW / {t(demo?'多硬盘演示':'实时状态',demo?'DRIVE DEMO':'LIVE STATUS')}</span><h1>{t('你的私有存储空间','Your private storage')}</h1><p>{t(`${volumes.length} 块独立硬盘，文件只经由加密的 Tailscale 通道传输。`,`${volumes.length} independent drives. Files travel only through the encrypted Tailscale link.`)}</p></div><div className="home-actions"><button onClick={() => setWizard(true)}><I.Plus />{t('接入新硬盘','Add a drive')}</button><div className="live-stamp"><i /> {demo?'DEMO':'LIVE'}<br/><small>{demo?t('模拟数据','SAMPLE DATA'):t('每 2 秒更新','UPDATED EVERY 2S')}</small></div></div></header>
    {volumes.length ? <section className="volume-grid" aria-label={t('硬盘列表','Drive list')}>{volumes.map((volume, index) => { const percent = volume.total ? Math.round(volume.used / volume.total * 100) : 0; return <button className={`diskcard volume-card ${volume.status}`} onClick={() => setSelected(volume)} aria-label={t(`查看 ${volume.name} 详情`,`View details for ${volume.name}`)} key={volume.id}>
      <div className="disk-id"><span>VOLUME {String(index + 1).padStart(2, '0')} · {volume.status === 'online' ? t('在线','ONLINE') : t('离线','OFFLINE')}</span><h2>{volume.name}</h2><p>{volume.device} · {volume.filesystem}</p></div>
      <div className="capacity-number"><strong>{percent}</strong><span>%<small>USED</small></span></div>
      <div className="capacity-track" style={{ '--p': percent } as React.CSSProperties}><i /><span>{fmt(volume.used)} {t('已用','used')}</span><span>{fmt(volume.free)} {t('可用','free')}</span></div>
      <div className="disk-total"><span>TOTAL CAPACITY</span><strong>{volume.status === 'online' ? fmt(volume.total) : 'OFFLINE'}</strong></div><I.ArrowUpRight />
    </button>; })}</section> : <div className="empty"><I.LoaderCircle className="spin" /><p>{t('正在读取硬盘信息…','Reading drive information…')}</p></div>}
    {selected && <div className="drawer"><button className="close" onClick={() => setSelected(undefined)} aria-label={t('关闭','Close')}><I.X /></button><span className="eyebrow">DEVICE INSPECTION</span><div className="drawer-title"><h2>{selected.name}</h2><button onClick={()=>setRenameVolume(selected)} aria-label={t(`重命名 ${selected.name}`,`Rename ${selected.name}`)}><I.Pencil/>{t('重命名','Rename')}</button></div><dl><dt>{t('状态','Status')}</dt><dd>{selected.status === 'online' ? t('在线','Online') : t('离线','Offline')}</dd><dt>{t('设备','Device')}</dt><dd>{selected.device}</dd><dt>UUID</dt><dd>{selected.uuid || t('主数据盘','Primary data drive')}</dd><dt>{t('文件系统','File system')}</dt><dd>{selected.filesystem}</dd><dt>{t('挂载点','Mount point')}</dt><dd>{selected.mount}</dd><dt>{t('总容量','Total capacity')}</dt><dd>{fmt(selected.total)}</dd><dt>{t('已用 / 可用','Used / Free')}</dt><dd>{fmt(selected.used)} / {fmt(selected.free)}</dd><dt>{t('读取 / 写入','Read / Write')}</dt><dd>{speed(selected.readBytes, previous[selected.id]?.readBytes)} · {speed(selected.writeBytes, previous[selected.id]?.writeBytes)}</dd><dt>SMART</dt><dd>{selected.smart}</dd></dl></div>}
    {renameVolume&&<VolumeRenameDialog volume={renameVolume} close={()=>setRenameVolume(undefined)} save={name=>rename(renameVolume,name)}/>}
    {wizard && <VolumeWizard close={() => setWizard(false)} />}</>;
}

function VolumeRenameDialog({volume,close,save}:{volume:Volume;close:()=>void;save:(name:string)=>Promise<void>}) {
  const {t}=useLocale();
  const [name,setName]=useState(volume.name);
  const [saving,setSaving]=useState(false);
  const [error,setError]=useState('');
  const submit=async(event:React.FormEvent)=>{event.preventDefault();setSaving(true);setError('');try{await save(name.trim())}catch(e){setError(errorText(e));setSaving(false)}};
  return <div className="preview nested-preview" role="dialog" aria-modal="true" aria-labelledby="rename-volume-title"><form className="preview-card rename-volume" onSubmit={event=>void submit(event)}><button type="button" className="close" onClick={close} aria-label={t('关闭重命名','Close rename dialog')}><I.X/></button><span className="eyebrow">VOLUME NAME / {t('硬盘名称','DRIVE NAME')}</span><h2 id="rename-volume-title">{t('重命名硬盘','Rename drive')}</h2><p>{volume.device} · {volume.filesystem}</p><label className="field-label">{t('显示名称','Display name')}<input autoFocus value={name} onChange={event=>setName(event.target.value)} maxLength={40} required/></label><small className="rename-hint">{t('只修改 MyNAS 中显示的名称，不会格式化硬盘，也不会改变其中的文件。','This only changes the name shown in MyNAS. It does not format the drive or change any files.')}</small>{error&&<p className="error">{error}</p>}<div className="row rename-actions"><button type="button" onClick={close}>{t('取消','Cancel')}</button><button className="primary" type="submit" disabled={saving||!name.trim()}>{saving?<I.LoaderCircle className="spin"/>:<I.Check/>}{saving?t('正在保存','Saving'):t('保存名称','Save name')}</button></div></form></div>;
}

function VolumeWizard({ close }: { close: () => void }) {
  const {t}=useLocale();
  const [candidates, setCandidates] = useState<VolumeCandidate[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const load = useCallback(() => { setLoading(true); setError(''); api<VolumeCandidate[]>('/volumes/candidates').then(rows => setCandidates(Array.isArray(rows) ? rows : [])).catch(e => setError(errorText(e))).finally(() => setLoading(false)); }, []);
  useEffect(() => { void load(); }, [load]);
  return <div className="preview" role="dialog" aria-modal="true"><div className="preview-card setup-guide"><button className="close" onClick={close} aria-label={t('关闭','Close')}><I.X /></button><span className="eyebrow">NEW VOLUME / {t('接盘向导','DRIVE SETUP')}</span><h2>{t('接入新硬盘','Add a new drive')}</h2><div className="paired-banner"><I.BadgeCheck/><span><span className="paired-title"><b>{t('树莓派已连接','Raspberry Pi connected')}</b><em>{connectedNodeName()} - {t('已连接','connected')}</em></span><small>{t('Tailscale 与 MyNAS 身份验证已完成，无需重复查看首次安装教程。','Tailscale and MyNAS verification are complete. You do not need to repeat initial setup.')}</small></span></div><ol className="setup-steps"><li className="active"><b>01</b><span>{t('连接硬盘','Connect drive')}<small>{t('将硬盘接入树莓派 USB/SATA 接口','Connect the drive to a USB/SATA port on the Raspberry Pi')}</small></span></li><li><b>02</b><span>{t('检查设备','Check device')}<small>{t('确认下方检测到的型号、容量和文件系统','Confirm the detected model, capacity, and file system')}</small></span></li><li><b>03</b><span>{t('运行接盘向导','Run setup wizard')}<small>{t('在已连接的树莓派终端执行接盘命令','Run the command in the connected Raspberry Pi terminal')}</small></span></li></ol>
    <div className="candidate-head"><h3>{t('当前检测结果','Current scan')}</h3><button onClick={() => void load()} disabled={loading}><I.RefreshCw className={loading ? 'spin' : ''} />{t('重新检测','Scan again')}</button></div>
    {error && <p className="error">{error}</p>}{!loading && !candidates.length && <div className="notice">{t('未发现可接入硬盘，或当前正在 Windows 本地调试。请在树莓派上运行向导。','No eligible drive was found, or this is the Windows local preview. Run the wizard on the Raspberry Pi.')}</div>}
    <div className="candidate-list">{candidates.map(candidate => <div key={candidate.device}><I.HardDrive /><span><b>{candidate.label || candidate.model || candidate.device}</b><small>{candidate.device} · {fmt(candidate.size)} · {candidate.filesystem || t('未格式化','Unformatted')}</small></span><em className={candidate.registered ? 'ok' : candidate.supported ? 'ready' : 'warn'}>{candidate.registered ? t('已接入','Added') : candidate.supported ? t('可无损接入','Ready without formatting') : candidate.reason || t('需要初始化','Initialization required')}</em></div>)}</div>
    <CommandBlock label={t('在树莓派终端运行','Run in the Raspberry Pi terminal')} value="sudo mynas-setup" /></div></div>;
}

function CommandBlock({ label, value }: { label: string; value: string }) {
  const {t}=useLocale();
  const [state,setState]=useState<'idle'|'copied'|'failed'>('idle');
  const copy=async()=>{try{await navigator.clipboard.writeText(value);setState('copied');globalThis.setTimeout(()=>setState('idle'),1600)}catch{setState('failed')}};
  return <div className="command-block"><div className="command-meta"><span>{label}</span><i>SECURE TERMINAL</i></div><div className="command-line"><code>{value}</code><button className={`command-copy ${state}`} onClick={()=>void copy()} aria-label={t(`复制命令：${value}`,`Copy command: ${value}`)}>{state==='copied'?<I.Check/>:<I.Copy/>}<span>{state==='copied'?t('已复制','Copied'):state==='failed'?t('请手动复制','Copy manually'):t('复制命令','Copy command')}</span></button></div></div>;
}

function FirstConnectionGuide({ close, another=false, initialName='', onNameChange }: { close: () => void; another?: boolean; initialName?: string; onNameChange?: (value:string)=>void }) {
  const {t}=useLocale();
  const fallbackHost = 'rsp.tail681937.ts.net';
  let host = fallbackHost;
  try { const detected = new URL(API).hostname; if (!['localhost', '127.0.0.1'].includes(detected)) host = detected; } catch { /* use the configured Raspberry Pi address */ }
  const [deviceName,setDeviceName]=useState(initialName);
  const [platform,setPlatformState]=useState<SetupPlatform>(()=>{const saved=readSetting('setupPlatform');return saved==='windows'||saved==='macos'||saved==='linux'?saved:detectPlatform()});
  const setPlatform=(value:SetupPlatform)=>{setPlatformState(value);saveSetting('setupPlatform',value)};
  const changeName=(value:string)=>{setDeviceName(value);if(onNameChange)onNameChange(value);else saveSetting(`pendingNodeName:${API}`,value)};
  const platformName=platform==='windows'?'Windows':platform==='macos'?'macOS':'Linux';
  const terminalName=platform==='windows'?t('PowerShell 或 Windows 终端','PowerShell or Windows Terminal'):platform==='macos'?t('“终端”应用（Terminal）','the Terminal app'):t('终端（Terminal）','Terminal');
  const terminalHint=platform==='windows'?t('按 Win 键，搜索“PowerShell”或“终端”，然后打开。','Press the Windows key, search for PowerShell or Terminal, and open it.'):platform==='macos'?t('按 Command + 空格，搜索“终端”或“Terminal”，然后打开。','Press Command + Space, search for Terminal, and open it.'):t('从应用菜单打开“终端”，常用快捷键为 Ctrl + Alt + T。','Open Terminal from the app menu; Ctrl + Alt + T is common.');
  return <div className="preview nested-preview" role="dialog" aria-modal="true" aria-labelledby="ssh-guide-title"><div className="preview-card ssh-guide"><button className="close" onClick={close} aria-label={t('关闭首次连接向导','Close setup guide')}><I.X /></button><span className="eyebrow">FIRST CONNECTION / {t('首次安装','INITIAL SETUP')}</span><h2 id="ssh-guide-title">{another?t('配置另一台 MyNAS','Set up another MyNAS'):t('连接你的第一台 MyNAS','Connect your first MyNAS')}</h2><p className="guide-lead">{another?t('新设备复用相同的树莓派、SSH 和 Tailscale 注册流程，完成后回到设备管理添加它。','Use the same Raspberry Pi, SSH, and Tailscale setup flow, then return to Device Manager to add it.'):t('仅首次配置需要完成这些步骤。设备成功连接并保存配对记录后，这个入口会自动隐藏。','You only need these steps once. The guide hides automatically after the device is connected and paired.')}</p>
    <div className="guide-preferences"><div><b>{t('你的电脑系统','Your computer')}</b><small>{t(`已自动识别为 ${platformName}，如果不正确可手动切换。`,`Detected ${platformName}. Change it if needed.`)}</small></div><div className="platform-tabs" role="tablist" aria-label={t('选择电脑操作系统','Choose your computer operating system')}>{(['windows','macos','linux'] as SetupPlatform[]).map(value=><button type="button" role="tab" aria-selected={platform===value} className={platform===value?'active':''} onClick={()=>setPlatform(value)} key={value}>{value==='windows'?'Windows':value==='macos'?'macOS':'Linux'}</button>)}</div></div>
    <label className="onboarding-node-name"><I.Tag/><span><b>{t('先给这台 MyNAS 起个名字','Name this MyNAS')}</b><small>{t('例如“客厅 NAS”“书房备份”。这个名称以后可以在设备管理中修改。','For example, “Living Room NAS” or “Study Backup”. You can change it later in Device Manager.')}</small></span><input value={deviceName} onChange={event=>changeName(event.target.value)} placeholder={t('例如：客厅 NAS','For example: Living Room NAS')} maxLength={40}/></label>
    <div className="onboarding-track"><section><b>01</b><span><strong>{t('准备树莓派系统','Prepare Raspberry Pi OS')}</strong><small>{t('在 Raspberry Pi Imager 中设置用户名、密码、Wi-Fi，并在“服务”中开启 SSH。','In Raspberry Pi Imager, set a username, password, and Wi-Fi, then enable SSH under Services.')}</small></span><a href="https://www.raspberrypi.com/documentation/computers/remote-access.html#ssh" target="_blank" rel="noreferrer">{t('SSH 官方步骤','Official SSH guide')} <I.ExternalLink/></a></section><section><b>02</b><span><strong>{t('安装电脑端 Tailscale','Install Tailscale on your computer')}</strong><small>{t(`在 ${platformName} 安装并登录。树莓派稍后通过终端加入同一个 tailnet。`,`Install and sign in on ${platformName}. The Raspberry Pi will join the same tailnet from its terminal later.`)}</small></span><a href="https://tailscale.com/download" target="_blank" rel="noreferrer">{t('下载 Tailscale','Download Tailscale')} <I.ExternalLink/></a></section><section><b>03</b><span><strong>{t(`在 ${platformName} 上打开终端`,`Open a terminal on ${platformName}`)}</strong><small>{terminalHint} {t('下面第一条命令在电脑上运行，不是在树莓派本机上运行。','Run the first command below on your computer, not directly on the Raspberry Pi.')}</small></span></section></div>
    <div className="terminal-location computer"><I.Monitor/><span><b>{t(`运行位置：你的 ${platformName} 电脑`,`Run on: your ${platformName} computer`)}</b><small>{terminalName}</small></span></div><CommandBlock label={t(`在 ${terminalName} 中运行 · 使用 Imager 中设置的用户名`,`Run in ${terminalName} · use the username set in Imager`)} value={t('ssh <用户名>@mynas.local','ssh <username>@mynas.local')}/><div className="platform-note"><I.Info/><span>{t('如果找不到 ','If ')}<code>mynas.local</code>{t('，请在路由器后台查看树莓派 IP，然后使用 ',' cannot be found, check the Raspberry Pi IP in your router, then use ')}<code>{t('ssh 用户名@192.168.x.x','ssh username@192.168.x.x')}</code>{t('。如果 SSH 没有开启且树莓派没有显示器，需要重新用 Imager 写卡并启用 SSH。','. If SSH is disabled and the Pi has no display, rewrite the card with Imager and enable SSH.')}</span></div>
    <div className="onboarding-track compact"><section><b>04</b><span><strong>{t('看到树莓派命令提示符后继续','Continue after the Raspberry Pi prompt appears')}</strong><small>{t('SSH 登录成功后，同一个终端窗口已经进入树莓派；接下来的命令会在树莓派上执行。','After SSH succeeds, that same terminal window is now connected to the Raspberry Pi. Run the next commands there.')}</small></span></section></div><div className="terminal-location raspberry"><I.HardDrive/><span><b>{t('运行位置：已通过 SSH 登录的树莓派终端','Run on: Raspberry Pi terminal connected over SSH')}</b><small>{t('终端提示符通常会变成“用户名@mynas:~ $”','The prompt usually changes to “username@mynas:~ $”')}</small></span></div><CommandBlock label={t('SSH 登录成功后运行 · 安装树莓派端 Tailscale','After SSH login · install Tailscale on Raspberry Pi')} value="curl -fsSL https://tailscale.com/install.sh | sh"/><CommandBlock label={t('仍在树莓派终端运行 · 生成授权网址','Still in the Raspberry Pi terminal · create sign-in URL')} value="sudo tailscale up"/>
    {another?<div className="platform-note finish-note"><I.Info/><span>{t('完成 MyNAS 安装和 Tailscale Serve 配置后，返回设备管理，点击“已经配置好 MyNAS？”查找并填写这台设备的地址。','After MyNAS and Tailscale Serve are configured, return to Device Manager and choose “MyNAS already configured?” to enter its address.')}</span></div>:<div className="address-card"><div><span>{t('授权完成后验证 MyNAS 地址','Verify the MyNAS address after sign-in')}</span><a href={`https://${host}`} target="_blank" rel="noreferrer">https://{host} <I.ExternalLink /></a></div><i>{t('返回本页点击“重新检测”，连接成功后向导会自动消失。','Return here and select “Scan again”. The guide will disappear after connection succeeds.')}</i></div>}<div className="guide-footer"><button className="ghost" onClick={close}>{t('稍后继续','Continue later')}</button><button className="primary" onClick={close}>{another?t('完成后返回设备管理','Return to Device Manager'):t('完成后返回检测','Return to connection check')}</button></div></div></div>;
}

function ExistingNodeGuide({close}:{close:()=>void}) {
  const {t}=useLocale();
  return <div className="preview nested-preview" role="dialog" aria-modal="true" aria-labelledby="existing-node-title"><div className="preview-card existing-node-guide"><button className="close" onClick={close} aria-label={t('关闭地址指南','Close address guide')}><I.X/></button><span className="eyebrow">EXISTING MYNAS / {t('已配置设备','CONFIGURED DEVICE')}</span><h2 id="existing-node-title">{t('找到 MyNAS 地址','Find the MyNAS address')}</h2><p className="guide-lead">{t('MyNAS 地址是树莓派在 Tailscale 中的私有 HTTPS 地址，不是普通局域网 IP。格式通常类似：','A MyNAS address is the Raspberry Pi private HTTPS address in Tailscale, not a regular LAN IP. It usually looks like:')}</p><div className="address-example"><I.Link/><code>https://mynas-2.tailxxxx.ts.net</code></div><div className="address-methods"><section><b>{t('推荐方法','Recommended')}</b><h3>{t('在树莓派终端查看','Check in the Raspberry Pi terminal')}</h3><p>{t('通过 SSH 登录已经配置好的树莓派，然后运行下面的命令。复制输出中以 https:// 开头的完整地址。','SSH into the configured Raspberry Pi and run the command below. Copy the complete address beginning with https://.')}</p><CommandBlock label={t('在已登录的树莓派终端运行','Run in the connected Raspberry Pi terminal')} value="tailscale serve status"/></section><section><b>{t('备用方法','Alternative')}</b><h3>{t('从 Tailscale 设备页查找','Find it on the Tailscale devices page')}</h3><p>{t('打开设备列表，找到这台树莓派，复制它的完整 MagicDNS 名称，并在前面加上 https://。','Open the device list, find this Raspberry Pi, copy its full MagicDNS name, and add https:// in front.')}</p><a className="button" href="https://login.tailscale.com/admin/machines" target="_blank" rel="noreferrer"><I.ExternalLink/>{t('打开 Tailscale 设备列表','Open Tailscale devices')}</a></section></div><div className="platform-note"><I.ShieldCheck/><span>{t('粘贴地址后，MyNAS 会先访问健康接口验证身份。普通服务器或未安装 MyNAS 的树莓派不会被保存。','MyNAS verifies the health endpoint before saving. Ordinary servers and Raspberry Pis without MyNAS will not be added.')}</span></div><div className="guide-footer"><button className="primary" onClick={close}>{t('我找到地址了','I found the address')}</button></div></div></div>;
}

function RenameNodeDialog({node,close,save}:{node:MyNASNode;close:()=>void;save:(value:string)=>void}) {
  const {t}=useLocale();
  const [value,setValue]=useState(node.name);
  return <div className="preview nested-preview" role="dialog" aria-modal="true" aria-labelledby="rename-node-title"><form className="preview-card rename-node" onSubmit={event=>{event.preventDefault();if(value.trim())save(value.trim())}}><button type="button" className="close" onClick={close} aria-label={t('关闭重命名','Close rename dialog')}><I.X/></button><span className="eyebrow">DEVICE NAME / {t('设备名称','DISPLAY NAME')}</span><h2 id="rename-node-title">{t('重命名 MyNAS','Rename MyNAS')}</h2><p>{node.host}</p><label className="field-label">{t('显示名称','Display name')}<input autoFocus value={value} onChange={event=>setValue(event.target.value)} maxLength={40} required/></label><div className="row rename-actions"><button type="button" onClick={close}>{t('取消','Cancel')}</button><button className="primary" type="submit"><I.Check/>{t('保存名称','Save name')}</button></div></form></div>;
}

function Files() {
  const {t}=useLocale();
  const [volumes, setVolumes] = useState<Volume[]>([]);
  const [volumeId, setVolumeIdState] = useState(readSetting('lastVolume'));
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
  const setVolumeId = (value: string) => { setVolumeIdState(value); setPath(''); saveSetting('lastVolume', value); saveSetting('lastPath', ''); };
  const loadVolumes = useCallback(() => api<Volume[]>('/volumes').then(rows => setVolumes(Array.isArray(rows) ? rows : [])).catch(e => setLoadError(errorText(e))), []);
  const load = useCallback(async () => { if (!volumeId) { setItems([]); setSelected([]); return; } try { const result = await api<{ items: Item[] }>('/files?volumeId=' + encodeURIComponent(volumeId) + '&path=' + encodeURIComponent(path)); setItems(Array.isArray(result.items) ? result.items : []); setSelected([]); setLoadError(''); saveSetting('lastPath',path); } catch (e) { setLoadError(errorText(e)); } }, [volumeId, path]);
  useEffect(() => { void loadVolumes(); }, [loadVolumes]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => { const stream = new EventSource(API + '/api/v1/events'); stream.addEventListener('update', () => void load()); return () => stream.close(); }, [load]);
  const shown = useMemo(() => items.filter(x => x.name.toLocaleLowerCase().includes(search.toLocaleLowerCase())), [items, search]);
  const toggle = (value: string) => setSelected(old => old.includes(value) ? old.filter(x => x !== value) : [...old, value]);
  const upload = async (file: File) => { setUploading(file.name); try { const created = await api<{ id: string; volumeId: string; chunkSize: number; status: string }>('/uploads', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ volumeId, path, name: file.name, size: file.size }) }); await sendUpload(file, { ...created, name: file.name, target: path, size: file.size, received: 0 }); } catch (e) { if (!(e instanceof DOMException && e.name === 'AbortError')) setLoadError(`${t('上传失败','Upload failed')}：${errorText(e)}`); } finally { setUploading(''); void load(); } };
  const open = (item: Item) => { if (item.type === 'folder') setPath(item.path); else if (['image', 'video', 'audio', 'text', 'code'].includes(item.type)) setPreview(item); else window.open(`${API}/api/v1/files/${encodeURI(item.path)}?volumeId=${encodeURIComponent(item.volumeId || volumeId)}`, '_blank', 'noopener'); };
  const currentVolume = volumes.find(volume => volume.id === volumeId);
  if (!volumeId) return <><header><div><h1>{t('硬盘','Drives')}</h1><p>{t('选择一块硬盘进入文件目录。','Choose a drive to browse its files.')}</p></div></header>{loadError && <div className="notice">{loadError}</div>}<div className="volume-picker">{volumes.map(volume => <button key={volume.id} disabled={volume.status !== 'online'} onClick={() => setVolumeId(volume.id)}><I.HardDrive /><span><b>{volume.name}</b><small>{volume.status === 'online' ? `${fmt(volume.free)} ${t('可用','free')} · ${volume.filesystem}` : t('硬盘离线','Drive offline')}</small></span><I.ChevronRight /></button>)}</div></>;
  return <><header><div><div className="file-title-row"><button className="up-button" onClick={() => path ? setPath(parent(path)) : setVolumeId('')} title={path ? t('返回上级目录','Go to parent folder') : t('返回硬盘列表','Back to drive list')}><I.ArrowLeft />{t('返回上级','Back')}</button><h1>{t('文件','Files')}</h1></div><div className="crumb"><button onClick={() => setVolumeId('')}>MyNAS</button> / <button onClick={() => setPath('')}>{currentVolume?.name || volumeId}</button>{path.split('/').filter(Boolean).map((part: string, index: number) => <React.Fragment key={index}> / <button onClick={() => setPath(path.split('/').slice(0, index + 1).join('/'))}>{part}</button></React.Fragment>)}</div></div><div className="row"><input placeholder={t('搜索文件名','Search file names')} value={search} onChange={e => setSearch(e.target.value)} /><button onClick={() => setDialog({ mode: 'folder' })}><I.FolderPlus />{t('新建文件夹','New folder')}</button><button className="primary" onClick={() => input.current?.click()}><I.Upload />{t('上传','Upload')}</button><input hidden ref={input} type="file" multiple onChange={e => Array.from(e.target.files || []).forEach(file => void upload(file))} /></div></header>{uploading && <div className="notice">{t('正在分块上传','Uploading in chunks')} {uploading}</div>}{loadError && <div className="notice">{loadError}<button onClick={() => void load()}>{t('重试','Retry')}</button></div>}<div className="tools"><span>{currentVolume?.name} · {selected.length ? t(`已选 ${selected.length} 项`,`${selected.length} selected`) : t(`${shown.length} 项`,`${shown.length} items`)}</span><button title={t('切换视图','Switch view')} onClick={() => { const next = view === 'grid' ? 'list' : 'grid'; setView(next); saveSetting('fileView',next); }}>{view === 'grid' ? <I.List /> : <I.Grid2X2 />}</button><button disabled={!selected.length} onClick={() => setDialog({ mode: 'delete' })}><I.Trash2 />{t('删除','Delete')}</button></div><div className={`files ${view}`}>{shown.map(item => <FileCard key={item.path} item={item} selected={selected.includes(item.path)} toggle={() => toggle(item.path)} open={() => open(item)} action={mode => setDialog({ mode, item })} />)}</div>{!shown.length && !loadError && <div className="empty">{t('此目录为空。拖入文件或点击上传。','This folder is empty. Drop files here or select Upload.')}</div>}{preview && <Preview item={preview} close={() => setPreview(undefined)} />}{dialog && <ActionDialog dialog={dialog} volumeId={volumeId} volumes={volumes} path={path} selected={selected} close={() => setDialog(undefined)} done={load} />}</>;
}

function FileCard({ item, selected, toggle, open, action }: { item: Item; selected: boolean; toggle: () => void; open: () => void; action: (mode: 'rename' | 'copy' | 'move' | 'delete') => void }) {
  const {t}=useLocale();
  const Icon = typeIcons[item.type] || I.File;
  return <article className={selected ? 'selected' : ''} onDoubleClick={open}><input type="checkbox" checked={selected} onChange={toggle} aria-label={t(`选择 ${item.name}`,`Select ${item.name}`)} /><Icon className={`type ${item.type}`} /><div className="filename" title={item.name}>{item.name}</div><small>{item.type === 'folder' ? t('文件夹','Folder') : fmt(item.size)} · {new Date(item.modified).toLocaleString()}</small><div className="actions"><button title={t('打开','Open')} onClick={open}><I.ExternalLink /></button><button title={t('复制','Copy')} onClick={() => action('copy')}><I.Copy /></button><button title={t('移动','Move')} onClick={() => action('move')}><I.FolderInput /></button><button title={t('重命名','Rename')} onClick={() => action('rename')}><I.Pencil /></button><a title={t('下载','Download')} href={`${API}/api/v1/files/${encodeURI(item.path)}?volumeId=${encodeURIComponent(item.volumeId)}`}><I.Download /></a></div></article>;
}

function ActionDialog({ dialog, volumeId, volumes, path, selected, close, done }: { dialog: { mode: 'folder' | 'rename' | 'copy' | 'move' | 'delete'; item?: Item }; volumeId: string; volumes: Volume[]; path: string; selected: string[]; close: () => void; done: () => Promise<void> }) {
  const {t}=useLocale();
  const [value, setValue] = useState(dialog.mode === 'rename' ? dialog.item?.name || '' : dialog.mode === 'copy' || dialog.mode === 'move' ? parent(dialog.item?.path || '') : '');
  const [targetVolumeId, setTargetVolumeId] = useState(volumeId);
  const [error, setError] = useState('');
  const labels = { folder: t('新建文件夹','New folder'), rename: t('重命名','Rename'), copy: t('复制到','Copy to'), move: t('移动到','Move to'), delete: t('删除到回收站','Move to trash') };
  const submit = async (event: React.FormEvent) => { event.preventDefault(); try { if (dialog.mode === 'folder') await api('/folders', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ volumeId, path, name: value }) }); else { const sources = dialog.item ? [dialog.item.path] : selected; for (const from of sources) { if (dialog.mode === 'delete') await api('/operations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'delete', fromVolumeId: volumeId, from }) }); else { const destinationVolumeId = dialog.mode === 'rename' ? volumeId : targetVolumeId; const base = dialog.mode === 'rename' ? `${parent(from)}${parent(from) ? '/' : ''}${value}` : `${value.replace(/\/$/, '')}${value ? '/' : ''}${from.split('/').pop()}`; await api('/operations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: dialog.mode, fromVolumeId: volumeId, toVolumeId: destinationVolumeId, from, to: base, conflict: 'rename' }) }); } } } await done(); close(); } catch (e) { setError(errorText(e)); } };
  const choosesVolume = dialog.mode === 'copy' || dialog.mode === 'move';
  return <div className="preview" role="dialog" aria-modal="true"><form className="preview-card" onSubmit={submit}><button type="button" className="close" onClick={close} aria-label={t('关闭','Close')}><I.X /></button><h2>{labels[dialog.mode]}</h2>{dialog.mode === 'delete' ? <p>{t(`将 ${dialog.item?.name || `${selected.length} 个项目`} 移入当前硬盘的回收站，可在回收站中恢复。`,`Move ${dialog.item?.name || `${selected.length} items`} to this drive's trash. You can restore it later.`)}</p> : <>{choosesVolume && <label className="field-label">{t('目标硬盘','Target drive')}<select value={targetVolumeId} onChange={e => setTargetVolumeId(e.target.value)}>{volumes.filter(volume => volume.status === 'online').map(volume => <option value={volume.id} key={volume.id}>{volume.name}</option>)}</select></label>}<input autoFocus value={value} onChange={e => setValue(e.target.value)} placeholder={dialog.mode === 'folder' || dialog.mode === 'rename' ? t('名称','Name') : t('目标硬盘内的文件夹路径（根目录可留空）','Folder path on target drive (leave blank for root)')} required={dialog.mode === 'folder' || dialog.mode === 'rename'} maxLength={180} /></>}{error && <p className="error">{error}</p>}<div className="row" style={{ marginTop: 20 }}><button type="button" onClick={close}>{t('取消','Cancel')}</button><button className="primary" type="submit">{t('确认','Confirm')}</button></div></form></div>;
}

function Preview({ item, close }: { item: Item; close: () => void }) { const {t}=useLocale(); const url = `${API}/api/v1/files/${encodeURI(item.path)}?volumeId=${encodeURIComponent(item.volumeId)}`; const [text, setText] = useState(t('加载中…','Loading…')); useEffect(() => { if (item.type === 'text' || item.type === 'code') fetch(url, { headers: { Range: 'bytes=0-262143' }, credentials: 'include' }).then(r => r.text()).then(setText).catch(() => setText(t('预览读取失败','Preview failed to load'))); }, [item.type, url,t]); return <div className="preview" role="dialog" aria-modal="true"><div className="preview-card"><button className="close" onClick={close} aria-label={t('关闭预览','Close preview')}><I.X /></button><h2>{item.name}</h2>{item.type === 'image' && <img src={url} alt={item.name} />}{item.type === 'video' && <video controls src={url} />}{item.type === 'audio' && <audio controls src={url} />}{(item.type === 'text' || item.type === 'code') && <pre>{text}</pre>}</div></div>; }

function Transfers() {
  const {t}=useLocale();
  const [rows, setRows] = useState<UploadRow[]>([]);
  const [error, setError] = useState('');
  const [resumeRow, setResumeRow] = useState<UploadRow>();
  const fileInput = useRef<HTMLInputElement>(null);
  const load = useCallback(() => api<UploadRow[]>('/uploads').then(x => setRows(Array.isArray(x) ? x : [])).catch(e => setError(errorText(e))), []);
  useEffect(() => { void load(); const timer = setInterval(load, 1500); return () => clearInterval(timer); }, [load]);
  const run = async (action: () => Promise<void>) => { try { setError(''); await action(); await load(); } catch (e) { setError(errorText(e)); } };
  const chooseResume = (row: UploadRow) => { setResumeRow(row); fileInput.current?.click(); };
  const resume = (file?: File) => { const row = resumeRow; setResumeRow(undefined); if (!row || !file) return; void run(() => sendUpload(file, row)); };
  const labels: Record<string, string> = { waiting: t('等待上传','Waiting'), uploading: t('上传中','Uploading'), paused: t('已暂停','Paused'), verifying: t('正在校验','Verifying'), 'processing-cover': t('正在生成封面','Creating thumbnail'), completed: t('已完成','Completed'), failed: t('失败','Failed') };
  return <><header><div><h1>{t('传输','Transfers')}</h1><p>{t('上传可暂停、续传或取消；续传时浏览器会要求重新选择原文件。','Uploads can be paused, resumed, or canceled. To resume, select the original file again.')}</p></div><button onClick={() => void load()}><I.RefreshCw />{t('刷新','Refresh')}</button></header><input ref={fileInput} hidden type="file" onChange={e => { resume(e.target.files?.[0]); e.currentTarget.value = ''; }} />{error && <div className="notice">{error}</div>}{rows.length ? <div className="list transfer-list">{rows.map(row => { const percent = row.size ? Math.min(100, Math.round(row.received / row.size * 100)) : 0; const pausable = row.status === 'waiting' || row.status === 'uploading'; const resumable = row.status === 'paused' || row.status === 'failed'; const cancellable = !['completed', 'verifying', 'processing-cover'].includes(row.status); return <div key={row.id}><I.ArrowUpToLine /><span><b>{row.name}</b><small>{row.target || 'MyNAS'} · {labels[row.status] || row.status} · {fmt(row.received)} / {fmt(row.size)}</small><progress value={percent} max="100" /></span><em>{percent}%</em><div className="transfer-actions">{pausable && <button onClick={() => void run(() => pauseUpload(row.id))}><I.Pause />{t('暂停','Pause')}</button>}{resumable && <button onClick={() => chooseResume(row)}><I.Play />{t('继续','Resume')}</button>}{cancellable && <button onClick={() => void run(() => cancelUpload(row.id))}><I.X />{t('取消','Cancel')}</button>}</div></div>; })}</div> : <div className="empty"><I.ArrowLeftRight /><h2>{t('暂无传输任务','No transfer tasks')}</h2></div>}<div className="notice download-note"><I.Download />{t('下载由浏览器的下载面板管理，可在浏览器中暂停或取消；服务器已支持断点续传。','Downloads are managed by your browser, where they can be paused or canceled. The server supports resuming downloads.')}</div></>;
}

function Trash() { const {t}=useLocale(); const [rows, setRows] = useState<TrashRow[]>([]); const [error, setError] = useState(''); const [pending,setPending]=useState<{row:TrashRow;action:'restore'|'purge'}>(); const load = () => api<TrashRow[]>('/trash').then(x => { setRows(Array.isArray(x) ? x : []); setError(''); }).catch(e => setError(errorText(e))); useEffect(() => { void load(); }, []); const act = async () => { if(!pending)return; try { await api('/trash', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id:pending.row.id, volumeId:pending.row.volumeId, action:pending.action }) }); setPending(undefined); void load(); } catch (e) { setError(errorText(e)); } }; return <><header><h1>{t('回收站','Trash')}</h1><button onClick={load}><I.RefreshCw />{t('刷新','Refresh')}</button></header>{error && <div className="notice">{error}</div>}<div className="list">{rows.map(row => <div key={`${row.volumeId}:${row.id}`}><I.Trash2 /><span><b>{row.original}</b><small>{row.volumeName}</small></span><button onClick={() => setPending({row,action:'restore'})}>{t('恢复','Restore')}</button><button className="danger" onClick={() => setPending({row,action:'purge'})}>{t('永久删除','Delete forever')}</button></div>)}{!rows.length && !error && <div className="empty">{t('回收站为空','Trash is empty')}</div>}</div>{pending&&<div className="preview" role="dialog" aria-modal="true"><div className="preview-card"><button className="close" aria-label={t('关闭','Close')} onClick={()=>setPending(undefined)}><I.X/></button><h2>{pending.action==='purge'?t('确认永久删除','Delete forever?'):t('确认恢复','Restore item?')}</h2><p>{pending.action==='purge'?t('此操作无法撤销。将永久删除：','This cannot be undone. Permanently delete:'):t('将文件恢复到原始位置：','Restore the file to its original location:')}<br/><b>{pending.row.volumeName} / {pending.row.original}</b></p><div className="row"><button onClick={()=>setPending(undefined)}>{t('取消','Cancel')}</button><button className={pending.action==='purge'?'danger primary':'primary'} onClick={()=>void act()}>{pending.action==='purge'?t('永久删除','Delete forever'):t('恢复','Restore')}</button></div></div></div>}</>; }

function NodeManager({close}:{close:()=>void}) {
  const {t}=useLocale();
  const [nodes,setNodes]=useState<MyNASNode[]>(()=>loadNodes());
  const [name,setName]=useState('');
  const [address,setAddress]=useState('');
  const [checking,setChecking]=useState(false);
  const [error,setError]=useState('');
  const [newGuide,setNewGuide]=useState(false);
  const [addressGuide,setAddressGuide]=useState(false);
  const [renaming,setRenaming]=useState<MyNASNode>();
  const add=async(event:React.FormEvent)=>{event.preventDefault();setChecking(true);setError('');try{const apiUrl=normalizeNodeUrl(address);const controller=new AbortController();const timer=globalThis.setTimeout(()=>controller.abort(),8000);let response:Response;try{response=await fetch(`${apiUrl}/api/v1/health`,{credentials:'include',signal:controller.signal})}finally{globalThis.clearTimeout(timer)}if(!response.ok)throw new Error(t(`设备返回 HTTP ${response.status}`,`Device returned HTTP ${response.status}`));const result=await response.json() as Health&{version?:string};if(result.ok!==true||!result.protocol||!result.version)throw new Error(t('该地址没有返回有效的 MyNAS 设备身份','This address did not return a valid MyNAS device identity'));const host=new URL(apiUrl).host;const node:MyNASNode={apiUrl,name:name.trim()||host.split('.')[0],host,user:result.user?.login||'',verifiedAt:new Date().toISOString()};setNodes(rememberNode(node));saveSetting(`pairedNode:${apiUrl}`,JSON.stringify({apiUrl,host,user:node.user,verifiedAt:node.verifiedAt}));setName('');setAddress('')}catch(e){setError(e instanceof DOMException&&e.name==='AbortError'?t('连接超时，请确认目标 MyNAS 已开机并连接 Tailscale','Connection timed out. Make sure the target MyNAS is powered on and connected to Tailscale'):errorText(e))}finally{setChecking(false)}};
  const connect=(node:MyNASNode)=>{if(node.apiUrl===API){close();return}activateNode(node.apiUrl);location.assign(location.origin+location.pathname)};
  const forget=(node:MyNASNode)=>{if(node.apiUrl===API)return;setNodes(removeNode(node.apiUrl))};
  const startRename=(node:MyNASNode)=>setRenaming(node);
  const rename=(value:string)=>{if(!renaming)return;setNodes(rememberNode({...renaming,name:value}));setRenaming(undefined)};
  return <div className="preview" role="dialog" aria-modal="true" aria-labelledby="node-manager-title"><div className="preview-card node-manager"><button className="close" onClick={close} aria-label={t('关闭设备管理','Close Device Manager')}><I.X/></button><span className="eyebrow">MYNAS NODES / {t('多设备','MULTI-DEVICE')}</span><h2 id="node-manager-title">{t('管理 MyNAS 设备','Manage MyNAS devices')}</h2><p className="guide-lead">{t('这里只显示通过 MyNAS 健康接口验证的设备；同一 Tailscale 网络中的普通服务器不会加入列表。','Only devices verified by the MyNAS health endpoint are shown. Other servers on the same tailnet are not added.')}</p><div className="node-registry">{nodes.map(node=>{const current=node.apiUrl===API;return <article className={current?'current':''} key={node.apiUrl}><div className="node-icon"><I.Server/><i/></div><span><b>{node.name}</b><small>{node.host}</small><em>{current?t('当前设备 · 在线','Current device · Online'):t(`已验证 · ${new Date(node.verifiedAt).toLocaleDateString()}`,`Verified · ${new Date(node.verifiedAt).toLocaleDateString()}`)}</em></span><div><button className={current?'node-current':'primary'} disabled={current} onClick={()=>connect(node)}>{current?<><I.Check/>{t('正在使用','In use')}</>:<><I.ArrowRightLeft/>{t('连接','Connect')}</>}</button><button onClick={()=>startRename(node)} aria-label={t(`重命名 ${node.name}`,`Rename ${node.name}`)}><I.Pencil/></button><button className="danger" disabled={current} onClick={()=>forget(node)} aria-label={t(`移除 ${node.name}`,`Remove ${node.name}`)}><I.Trash2/></button></div></article>})}{!nodes.length&&<div className="empty compact-empty">{t('还没有保存任何 MyNAS 设备','No MyNAS device has been saved yet')}</div>}</div><form className="node-add" onSubmit={add}><div className="node-add-intro"><span className="eyebrow">ADD DEVICE / {t('添加设备','NEW DEVICE')}</span><h3>{t('连接另一台 MyNAS','Connect another MyNAS')}</h3><p>{t('新树莓派可以复用首次注册流程；已经安装完成的设备可以直接填写地址。','A new Raspberry Pi can use the initial setup flow; enter the address directly for an already configured device.')}</p><div className="node-path-actions"><button type="button" onClick={()=>setNewGuide(true)}><I.Sparkles/>{t('配置新的 MyNAS','Set up a new MyNAS')}</button><button type="button" className="text-link" onClick={()=>setAddressGuide(true)}>{t('已经配置好 MyNAS？','MyNAS already configured?')}</button></div></div><label>{t('设备名称','Device name')}<input value={name} onChange={event=>setName(event.target.value)} placeholder={t('例如：书房 NAS','For example: Study NAS')} maxLength={40} required/></label><label>MyNAS {t('地址','address')} <button type="button" className="field-help" onClick={()=>setAddressGuide(true)}>{t('这是什么？','What is this?')}</button><input value={address} onChange={event=>setAddress(event.target.value)} placeholder="https://mynas-2.tailxxxx.ts.net" required/></label>{error&&<p className="connection-error">{error}</p>}<button className="primary" disabled={checking} type="submit">{checking?<I.LoaderCircle className="spin"/>:<I.Plus/>}{checking?t('正在验证设备','Verifying device'):t('验证并添加','Verify and add')}</button></form></div>{newGuide&&<FirstConnectionGuide another initialName={name} onNameChange={setName} close={()=>setNewGuide(false)}/>} {addressGuide&&<ExistingNodeGuide close={()=>setAddressGuide(false)}/>} {renaming&&<RenameNodeDialog node={renaming} close={()=>setRenaming(undefined)} save={rename}/>}</div>;
}

function Settings() { const {t}=useLocale(); const [manager,setManager]=useState(false); return <><header><h1>{t('设置','Settings')}</h1></header><div className="setting"><I.Server/><div><h2>{t('多 MyNAS 设备','Multiple MyNAS devices')}</h2><p>{t('添加和切换多台树莓派 MyNAS；每台设备可以继续管理自己的多块硬盘。','Add and switch between Raspberry Pi MyNAS devices. Each one can manage its own drives.')}</p><button onClick={()=>setManager(true)}><I.Settings2/>{t('管理设备','Manage devices')}</button></div></div>{manager&&<NodeManager close={()=>setManager(false)}/>}</>; }

const root=document.getElementById('root');
if(root)createRoot(root).render(<LocaleProvider><PageBoundary full><App /></PageBoundary></LocaleProvider>);
