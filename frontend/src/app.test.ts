import {afterEach,describe,it,expect,vi} from 'vitest';
import {ApiError,api,bytesPerSecond,displayedUploadBytes,fmt,formatTemperature,parent,photosPairingPayloadText,parsePairedNode,normalizeNodeUrl,parseNodeRegistry,proxyBypassGuide} from './api';
describe('client helpers',()=>{it('formats values',()=>expect(fmt(1073741824)).toContain('GB'));it('keeps parent inside virtual root',()=>expect(parent('a/b/file.txt')).toBe('a/b'))});
describe('device temperature',()=>{it('formats a live Celsius reading',()=>expect(formatTemperature(43.875)).toBe('43.9 °C'));it('does not invent an unavailable reading',()=>expect(formatTemperature(undefined)).toBe('—'))});
describe('disk throughput',()=>{it('converts a counter delta over the real sample interval to bytes per second',()=>expect(bytesPerSecond(9*1024*1024,1024*1024,2000)).toBe(4*1024*1024));it('does not report a negative rate after a counter reset',()=>expect(bytesPerSecond(100,200,2000)).toBe(0))});
describe('upload progress',()=>{it('shows in-flight bytes without moving behind confirmed progress',()=>expect(displayedUploadBytes(8,11,24)).toBe(11));it('caps browser progress at the file size',()=>expect(displayedUploadBytes(16,25,24)).toBe(24));it('falls back to server-confirmed bytes',()=>expect(displayedUploadBytes(8,undefined,24)).toBe(8))});
describe('paired node memory',()=>{
  const node={apiUrl:'https://nas.example.ts.net',host:'nas.example.ts.net',user:'owner@example.com',verifiedAt:'2026-07-14T00:00:00.000Z'};
  it('restores a node only for the same private API',()=>expect(parsePairedNode(JSON.stringify(node),node.apiUrl)).toEqual(node));
  it('rejects another node or damaged memory',()=>{expect(parsePairedNode(JSON.stringify(node),'https://other.example.ts.net')).toBeUndefined();expect(parsePairedNode('{broken',node.apiUrl)).toBeUndefined()});
});
describe('MyNAS node registry',()=>{
  it('normalizes a MagicDNS host to an HTTPS origin',()=>expect(normalizeNodeUrl('study.tailnet.ts.net/')).toBe('https://study.tailnet.ts.net'));
  it('rejects insecure remote devices',()=>expect(()=>normalizeNodeUrl('http://study.tailnet.ts.net')).toThrow('HTTPS'));
  it('ignores damaged registry entries',()=>{expect(parseNodeRegistry('{broken')).toEqual([]);expect(parseNodeRegistry('[{"name":"missing url"}]')).toEqual([])});
});
describe('proxy compatibility guidance',()=>{
  it('derives the tailnet suffix and DIRECT targets from a MagicDNS host',()=>expect(proxyBypassGuide('https://rsp.tail681937.ts.net')).toMatchObject({tailnetSuffix:'tail681937.ts.net',targets:['rsp.tail681937.ts.net','*.tail681937.ts.net','100.64.0.0/10']}));
  it('generates Clash rules for the current tailnet',()=>expect(proxyBypassGuide('https://rsp.tail681937.ts.net')?.clashConfig).toContain('DOMAIN-SUFFIX,tail681937.ts.net,DIRECT'));
  it('does not suggest Tailscale rules for an unrelated host',()=>expect(proxyBypassGuide('https://nas.example.com')).toBeUndefined());
});
describe('MyNAS Photos pairing',()=>{
  const pairing={format:'mynas-photos-pairing' as const,version:1 as const,serverURL:'https://rsp.tail681937.ts.net',serverID:'srv-test'};
  it('serializes a versioned private pairing payload',()=>expect(JSON.parse(photosPairingPayloadText(pairing))).toEqual(pairing));
  it('rejects a non-Tailscale pairing address',()=>expect(()=>photosPairingPayloadText({...pairing,serverURL:'https://example.com'})).toThrow('配对信息无效'));
  it('rejects an empty server identity',()=>expect(()=>photosPairingPayloadText({...pairing,serverID:''})).toThrow('配对信息无效'));
});
describe('API responses',()=>{
  afterEach(()=>vi.unstubAllGlobals());
  it('accepts a successful empty 201 response',async()=>{vi.stubGlobal('fetch',vi.fn().mockResolvedValue(new Response('',{status:201})));await expect(api('/folders',{method:'POST'})).resolves.toBeUndefined()});
  it('accepts a successful empty 204 response',async()=>{vi.stubGlobal('fetch',vi.fn().mockResolvedValue(new Response(null,{status:204})));await expect(api('/trash',{method:'POST'})).resolves.toBeUndefined()});
  it('classifies an unreachable private API',async()=>{vi.stubGlobal('fetch',vi.fn().mockRejectedValue(new TypeError('failed')));await expect(api('/health')).rejects.toMatchObject({kind:'network'} satisfies Partial<ApiError>)});
});
