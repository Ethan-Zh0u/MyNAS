import {afterEach,describe,it,expect,vi} from 'vitest';
import {ApiError,api,fmt,parent} from './api';
describe('client helpers',()=>{it('formats values',()=>expect(fmt(1073741824)).toContain('GB'));it('keeps parent inside virtual root',()=>expect(parent('a/b/file.txt')).toBe('a/b'))});
describe('API responses',()=>{
  afterEach(()=>vi.unstubAllGlobals());
  it('accepts a successful empty 201 response',async()=>{vi.stubGlobal('fetch',vi.fn().mockResolvedValue(new Response('',{status:201})));await expect(api('/folders',{method:'POST'})).resolves.toBeUndefined()});
  it('accepts a successful empty 204 response',async()=>{vi.stubGlobal('fetch',vi.fn().mockResolvedValue(new Response(null,{status:204})));await expect(api('/trash',{method:'POST'})).resolves.toBeUndefined()});
  it('classifies an unreachable private API',async()=>{vi.stubGlobal('fetch',vi.fn().mockRejectedValue(new TypeError('failed')));await expect(api('/health')).rejects.toMatchObject({kind:'network'} satisfies Partial<ApiError>)});
});
