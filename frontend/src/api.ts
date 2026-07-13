const configuredApi=import.meta.env.VITE_API_URL as string|undefined;
const localOrigin=typeof location!=='undefined'&&['localhost','127.0.0.1'].includes(location.hostname)?location.origin:'';
export const API=configuredApi || localOrigin || 'https://rsp.tail681937.ts.net';
type LocalRequestInit=RequestInit&{targetAddressSpace?:'local'};
export class ApiError extends Error {
  constructor(message:string, public readonly status=0, public readonly kind:'network'|'timeout'|'http'|'invalid'='http') { super(message); this.name='ApiError'; }
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
export type Item={name:string,path:string,type:string,size:number,modified:string,thumbnail:boolean};
export const fmt=(n:number)=>n<1024?`${n} B`:n<1048576?`${(n/1024).toFixed(1)} KB`:n<1073741824?`${(n/1048576).toFixed(1)} MB`:`${(n/1073741824).toFixed(2)} GB`;
export const parent=(p:string)=>p.split('/').slice(0,-1).join('/');
