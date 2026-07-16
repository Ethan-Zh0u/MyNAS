const configuredApi=import.meta.env.VITE_API_URL as string|undefined;
const localOrigin=!configuredApi&&typeof location!=='undefined'&&['localhost','127.0.0.1'].includes(location.hostname)?location.origin:'';
const storageGet=(key:string)=>{try{return localStorage.getItem(key)||''}catch{return ''}};
const storageSet=(key:string,value:string)=>{try{localStorage.setItem(key,value)}catch{/* storage is optional */}};
const activeNodeKey='activeMyNASApi';
const nodeRegistryKey='myNASNodes';
export const API=localOrigin || storageGet(activeNodeKey) || configuredApi || 'https://rsp.tail681937.ts.net';
type LocalRequestInit=RequestInit&{targetAddressSpace?:'local'};
export class ApiError extends Error {
  constructor(message:string, public readonly status=0, public readonly kind:'network'|'timeout'|'http'|'invalid'='http') { super(message); this.name='ApiError'; }
}
export type ProxyBypassGuide={hostname:string;tailnetSuffix:string;targets:string[];clashConfig:string};
export function proxyBypassGuide(apiUrl:string):ProxyBypassGuide|undefined{
  try{
    const hostname=new URL(apiUrl).hostname.toLowerCase();
    const labels=hostname.split('.');
    if(labels.length<4||labels.at(-2)!=='ts'||labels.at(-1)!=='net')return undefined;
    const tailnetSuffix=labels.slice(1).join('.');
    const targets=[hostname,`*.${tailnetSuffix}`,'100.64.0.0/10'];
    const clashConfig=`dns:\n  fake-ip-filter:\n    - '+.${tailnetSuffix}'\n\nrules:\n  - DOMAIN-SUFFIX,${tailnetSuffix},DIRECT\n  - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve`;
    return{hostname,tailnetSuffix,targets,clashConfig};
  }catch{return undefined}
}
export const isPrivateApiCrossOrigin=()=>typeof location!=='undefined'&&new URL(API).origin!==location.origin;
export async function api<T>(path:string, init:RequestInit={}, timeoutMs=8000) :Promise<T>{
  const controller=new AbortController();
  const timeout=globalThis.setTimeout(()=>controller.abort(),timeoutMs);
  const method=(init.method||'GET').toUpperCase();
  const headers=new Headers(init.headers);
  if(method!=='GET'&&method!=='HEAD')headers.set('X-MyNAS-Request','1');
  const request:LocalRequestInit={...init,signal:controller.signal,headers,credentials:'include'};
  if(isPrivateApiCrossOrigin())request.targetAddressSpace='local';
  try{
    const r=await fetch(API+'/api/v1'+path,request);
    const body=await r.text();
    if(!r.ok)throw new ApiError(body.trim()||r.statusText||`HTTP ${r.status}`,r.status,'http');
    if(!body.trim())return undefined as T;
    try{return JSON.parse(body) as T}catch{throw new ApiError('服务器返回了无法识别的数据',r.status,'invalid')}
  }catch(error){
    if(error instanceof ApiError)throw error;
    if(error instanceof DOMException&&error.name==='AbortError')throw new ApiError('连接超时，请确认 Tailscale 已连接',0,'timeout');
    throw new ApiError('无法连接私有 MyNAS，请确认 Tailscale 已连接且 rsp 可访问',0,'network');
  }finally{globalThis.clearTimeout(timeout)}
}
export type Item={name:string,path:string,volumeId:string,type:string,size:number,modified:string,thumbnail:boolean};
export type PairedNode={apiUrl:string;host:string;user:string;verifiedAt:string};
export type MyNASNode={apiUrl:string;name:string;host:string;user:string;verifiedAt:string};
export const parsePairedNode=(raw:string,apiUrl:string):PairedNode|undefined=>{try{const value=JSON.parse(raw) as PairedNode;return value?.apiUrl===apiUrl&&typeof value.host==='string'&&value.host&&typeof value.verifiedAt==='string'?value:undefined}catch{return undefined}};
export const normalizeNodeUrl=(value:string)=>{const candidate=/^https?:\/\//i.test(value.trim())?value.trim():`https://${value.trim()}`;const url=new URL(candidate);if(url.protocol!=='https:'&&!['localhost','127.0.0.1'].includes(url.hostname))throw new Error('MyNAS 设备必须使用 HTTPS 地址');return url.origin};
export const parseNodeRegistry=(raw:string):MyNASNode[]=>{try{const rows=JSON.parse(raw) as MyNASNode[];return Array.isArray(rows)?rows.filter(row=>typeof row?.apiUrl==='string'&&typeof row?.name==='string'&&typeof row?.host==='string'):[]}catch{return []}};
export const loadNodes=()=>parseNodeRegistry(storageGet(nodeRegistryKey));
export const rememberNode=(node:MyNASNode)=>{const next=[node,...loadNodes().filter(row=>row.apiUrl!==node.apiUrl)];storageSet(nodeRegistryKey,JSON.stringify(next));return next};
export const removeNode=(apiUrl:string)=>{const next=loadNodes().filter(row=>row.apiUrl!==apiUrl);storageSet(nodeRegistryKey,JSON.stringify(next));if(storageGet(activeNodeKey)===apiUrl)storageSet(activeNodeKey,'');return next};
export const activateNode=(apiUrl:string)=>storageSet(activeNodeKey,apiUrl);
export const fmt=(n:number)=>n<1024?`${n} B`:n<1048576?`${(n/1024).toFixed(1)} KB`:n<1073741824?`${(n/1048576).toFixed(1)} MB`:`${(n/1073741824).toFixed(2)} GB`;
export const bytesPerSecond=(current:number,previous:number,elapsedMs:number)=>elapsedMs>0?Math.max(0,current-previous)*1000/elapsedMs:0;
export const displayedUploadBytes=(confirmed:number,inFlight:number|undefined,total:number)=>Math.min(total,Math.max(confirmed,inFlight??0));
export const parent=(p:string)=>p.split('/').slice(0,-1).join('/');
