import {afterEach,describe,it,expect,vi} from 'vitest';
import {ApiError,api,fmt,parent,parsePairedNode,normalizeNodeUrl,parseNodeRegistry} from './api';
describe('client helpers',()=>{it('formats values',()=>expect(fmt(1073741824)).toContain('GB'));it('keeps parent inside virtual root',()=>expect(parent('a/b/file.txt')).toBe('a/b'))});
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
describe('API responses',()=>{
  afterEach(()=>vi.unstubAllGlobals());
  it('accepts a successful empty 201 response',async()=>{vi.stubGlobal('fetch',vi.fn().mockResolvedValue(new Response('',{status:201})));await expect(api('/folders',{method:'POST'})).resolves.toBeUndefined()});
  it('accepts a successful empty 204 response',async()=>{vi.stubGlobal('fetch',vi.fn().mockResolvedValue(new Response(null,{status:204})));await expect(api('/trash',{method:'POST'})).resolves.toBeUndefined()});
  it('classifies an unreachable private API',async()=>{vi.stubGlobal('fetch',vi.fn().mockRejectedValue(new TypeError('failed')));await expect(api('/health')).rejects.toMatchObject({kind:'network'} satisfies Partial<ApiError>)});
});
