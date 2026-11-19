import { describe,it,expect,beforeEach,vi } from 'vitest';
import {parseRepoInput,splitBatchInput} from '../src/lib/github/parse';
import {classifyAsset,parseDigest} from '../src/lib/assets';
import {compareVersions,selectLatestTag} from '../src/lib/version';
import {parseChangelog,parseVersionFile} from '../src/lib/changelog';
import {GitHubClient,GitHubError,MemoryCacheStore,rateLimitState} from '../src/lib/github/client';
import {retryDelayMs} from '../src/lib/sync/queue';
describe('输入、版本与附件',()=>{
 it('解析 GitHub 地址并去重批量输入',()=>{expect(parseRepoInput('https://github.com/a/b.git')).toMatchObject({owner:'a',name:'b'});expect(parseRepoInput('git@github.com:a/b.git')).toMatchObject({owner:'a',name:'b'});expect(parseRepoInput('https://gitlab.com/a/b')).toHaveProperty('error');expect(splitBatchInput('a/b\na/b, c/d')).toEqual(['a/b','c/d'])});
 it('识别平台、架构并且只接受可靠 SHA256',()=>{expect(classifyAsset('app-macos-arm64.dmg').platform).toBe('macos');expect(classifyAsset('app-win-x64.exe').arch).toBe('x64');expect(classifyAsset('app.apk').platform).toBe('android');expect(parseDigest('sha256:'+ 'a'.repeat(64))).toBe('a'.repeat(64));expect(parseDigest('md5:abcd')).toBeNull()});
 it('版本按数字而非字符串排序',()=>{expect(compareVersions('v1.10.0','v1.9.0')).toBeGreaterThan(0);expect(compareVersions('v2.0.0-rc1','v2.0.0')).toBeLessThan(0)});
 it('混合 Tag 命名且日期不全时不猜测最新版本',()=>{expect(selectLatestTag([{name:'weekly.2012-01-15',commitDate:null},{name:'go1.27.4',commitDate:null}])).toBeNull();expect(selectLatestTag([{name:'v1.9.0',commitDate:null},{name:'v1.10.0',commitDate:null}])?.name).toBe('v1.10.0');expect(selectLatestTag([{name:'weekly.2012-01-15',commitDate:new Date('2012-01-16')},{name:'go1.27.4',commitDate:new Date('2026-11-01')}])?.name).toBe('go1.27.4')});
 it('解析 changelog 与版本文件',()=>{expect(parseChangelog('## [1.2.3] - 2024-01-01\n修复问题')[0]).toMatchObject({version:'1.2.3',date:'2024-01-01'});expect(parseVersionFile('package.json','{"version":"1.2.3"}')).toBe('1.2.3');expect(parseVersionFile('Cargo.toml','[package]\nversion = "2.0.0"')).toBe('2.0.0')});
 it('指数退避有上限',()=>{expect(retryDelayMs(1)).toBe(60000);expect(retryDelayMs(2)).toBe(120000);expect(retryDelayMs(20)).toBe(3600000)})
});
describe('GitHub 条件请求和错误处理',()=>{
 beforeEach(()=>{Object.assign(rateLimitState,{limit:null,remaining:null,reset:null,updatedAt:null})});
 it('ETag 304 使用缓存数据',async()=>{const f=vi.fn().mockResolvedValueOnce(new Response('{"value":1}',{headers:{etag:'"abc"','content-type':'application/json'}})).mockResolvedValueOnce(new Response(null,{status:304}));const c=new GitHubClient({fetchImpl:f,cache:new MemoryCacheStore(),minIntervalMs:0});expect((await c.request('/test')).data).toEqual({value:1});const r=await c.request('/test');expect(r.notModified).toBe(true);expect(r.data).toEqual({value:1});expect(f.mock.calls[1][1].headers['If-None-Match']).toBe('"abc"')});
 it('429 按 Retry-After 延迟',async()=>{const c=new GitHubClient({fetchImpl:vi.fn().mockResolvedValue(new Response('{"message":"limited"}',{status:429,headers:{'retry-after':'120'}})),minIntervalMs:0,now:()=>100000,maxInlineWaitMs:0});await expect(c.request('/test')).rejects.toMatchObject({kind:'rate_limited',retryAt:new Date(220000)})});
 it('403 限额重置、404 和 500',async()=>{let c=new GitHubClient({fetchImpl:vi.fn().mockResolvedValue(new Response('{"message":"rate limit"}',{status:403,headers:{'x-ratelimit-remaining':'0','x-ratelimit-reset':'200'}})),minIntervalMs:0,now:()=>100000,maxInlineWaitMs:0});await expect(c.request('/test')).rejects.toMatchObject({kind:'rate_limited',retryAt:new Date(201000)});Object.assign(rateLimitState,{remaining:null,reset:null});c=new GitHubClient({fetchImpl:vi.fn().mockResolvedValue(new Response('{}',{status:404})),minIntervalMs:0});await expect(c.request('/test')).rejects.toMatchObject({kind:'not_found'});const sleeper=vi.fn().mockResolvedValue(undefined);c=new GitHubClient({fetchImpl:vi.fn().mockResolvedValue(new Response('{}',{status:500})),minIntervalMs:0,maxRetries:2,backoffBaseMs:1,sleep:sleeper});await expect(c.request('/test')).rejects.toBeInstanceOf(GitHubError);expect(sleeper).toHaveBeenCalledTimes(2)})
});
