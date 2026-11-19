import {it,expect,afterAll} from 'vitest';
import {prisma} from '../src/lib/db';import {syncRepository} from '../src/lib/sync/engine';import {enqueueSync,claimNextTask,recoverTasks,failTask} from '../src/lib/sync/queue';import {GitHubError,type GitHubClient} from '../src/lib/github/client';
import {ensureCategory,listCategories,getDescendantIds} from '../src/lib/categories';import {runCommunitySync} from '../src/lib/community/sync';import {queryIssues,queryDiscussions,issueParams,discussionParams} from '../src/lib/community/query';
const now=new Date().toISOString();
function commit(sha:string){return {sha,commit:{message:`commit ${sha}`,author:{name:'Test',date:now},committer:{date:now}},author:null,html_url:`https://github.com/example/demo/commit/${sha}`}}
let stage=0,partial=false;
const repo={id:123,full_name:'example/demo',name:'demo',owner:{login:'example',avatar_url:null},description:'test',homepage:null,html_url:'https://github.com/example/demo',stargazers_count:1,forks_count:0,watchers_count:0,license:null,language:null,topics:[],default_branch:'main',archived:false,fork:false,created_at:now,updated_at:now,pushed_at:now};
const rel=(id:number)=>({id,tag_name:`v${id}.0`,name:`v${id}.0`,body:'notes',prerelease:false,draft:false,published_at:now,created_at:now,html_url:`https://github.com/example/demo/releases/tag/v${id}.0`,zipball_url:null,tarball_url:null,author:null,target_commitish:'main',assets:[]});
const response=(data:any)=>({status:200,data,notModified:false,link:{}});
const stats={requests:0,notModified:0};
const fake={stats,async request(path:string,opts?:any){stats.requests++;if(path==='/repos/example/demo')return response(repo);if(path.endsWith('/releases/latest')){if(stage===0)throw new GitHubError('missing','not_found',404);return response(rel(1))}if(path.includes('/commits/main'))return response(stage?'bbbbbbbb':'aaaaaaaa');if(path.includes('/commits?'))return response(stage?[commit('bbbbbbbb'),commit('aaaaaaaa')]:[commit('aaaaaaaa')]);if(path.endsWith('/contents'))return response([]);if(path.includes('/git/commits/'))return response({committer:{date:now}});throw Error('unexpected request '+path)},async paginate(path:string,_max:number,fn:any){stats.requests++;if(path.includes('/releases?')){if(partial)throw new GitHubError('server','server',500);await fn(stage?[rel(1)]:[],response([]),1)}else if(path.includes('/tags?'))await fn(stage?[{name:'v1.0',commit:{sha:'bbbbbbbb'},zipball_url:null,tarball_url:null}]:[],response([]),1);else if(path.includes('/commits?'))await fn(stage?[commit('bbbbbbbb'),commit('aaaaaaaa')]:[commit('aaaaaaaa')],response([]),1);else throw Error('unexpected page '+path)}} as unknown as GitHubClient;
afterAll(async()=>{await prisma.$disconnect()});
it('基线、增量发现和去重；部分失败不建立基线',async()=>{const r=await prisma.repository.create({data:{owner:'example',name:'demo',fullName:'example/demo',fullNameKey:'example/demo',htmlUrl:repo.html_url,defaultBranch:'main',notifyTag:true,notifyCommit:true}});partial=true;let res=await syncRepository(r.id,fake);expect(res.status).toBe('partial');expect((await prisma.repository.findUniqueOrThrow({where:{id:r.id}})).baselineEstablished).toBe(false);partial=false;res=await syncRepository(r.id,fake);expect(res.status).toBe('success');expect(await prisma.notification.count()).toBe(0);expect((await prisma.repository.findUniqueOrThrow({where:{id:r.id}})).baselineEstablished).toBe(true);stage=1;res=await syncRepository(r.id,fake);expect(res.status).toBe('success');expect([res.newReleases,res.newTags,res.newCommits]).toEqual([1,1,1]);expect(await prisma.notification.count()).toBe(3);await syncRepository(r.id,fake);expect(await prisma.release.count()).toBe(1);expect(await prisma.tag.count()).toBe(1);expect(await prisma.commit.count()).toBe(2);expect(await prisma.notification.count()).toBe(3)});
it('队列认领、恢复及失败退避',async()=>{const r=await prisma.repository.findFirstOrThrow();const a=await enqueueSync(r.id,{trigger:'manual'});const b=await enqueueSync(r.id,{trigger:'manual'});expect(a.id).toBe(b.id);const claimed=await claimNextTask('test-worker');expect(claimed?.id).toBe(a.id);expect(await recoverTasks({all:true})).toBe(1);const second=await claimNextTask('test-worker');expect(second?.id).toBe(a.id);const x=await failTask(a.id,new GitHubError('network','network'));expect(x.retried).toBe(true);expect((await prisma.syncTask.findUniqueOrThrow({where:{id:a.id}})).status).toBe('pending')});
it('分类去重与 Issues/Discussions 同步及多标签筛选',async()=>{
  const c1=await ensureCategory('AI 工具'),c2=await ensureCategory('ai 工具');expect(c1).toBe(c2);
  const r=await prisma.repository.findFirstOrThrow();
  await prisma.repository.update({where:{id:r.id},data:{categoryId:c1}});
  const sIssue=await prisma.communitySync.create({data:{repositoryId:r.id,kind:'issues'}});
  const sDisc=await prisma.communitySync.create({data:{repositoryId:r.id,kind:'discussions'}});
  const gh={
    authenticated:true,stats:{requests:0,notModified:0},
    async graphql(q:string){
      if(q.includes('hasIssuesEnabled'))return {repository:{hasIssuesEnabled:true,hasDiscussionsEnabled:true,openIssues:{totalCount:2},closedIssues:{totalCount:1},discussions:{totalCount:1},discussionCategories:{nodes:[{name:'Q&A',slug:'q-a',emojiHTML:'<g-emoji>🙏</g-emoji>',isAnswerable:true}]}}};
      return {repository:{discussions:{totalCount:1,pageInfo:{hasNextPage:false,endCursor:null},nodes:[{number:10,title:'Kobo libra color',url:'https://github.com/example/demo/discussions/10',body:'discussion body',createdAt:now,updatedAt:now,closed:false,locked:false,upvoteCount:3,isAnswered:true,author:{login:'alice',avatarUrl:'https://a'},category:{name:'Q&A',emojiHTML:'<g-emoji>🙏</g-emoji>',isAnswerable:true},labels:{nodes:[{name:'question',color:'d876e3'},{name:'Kobo',color:'0075ca'}]},comments:{totalCount:5}}]}}};
    },
    async paginate(_p:string,_m:number,fn:any){await fn([{name:'bug',color:'d73a4a',description:'Bug'},{name:'Kobo',color:'0075ca',description:null}],{status:200,data:[],notModified:false,link:{}},1);return 1},
    async request(url:string){
      const open=url.includes('state=open');
      const items=open?[
        {number:1,title:'Kobo Wi-Fi bug',state:'open',user:{login:'bob',avatar_url:'https://b'},labels:[{name:'bug',color:'d73a4a'},{name:'Kobo',color:'0075ca'}],assignees:[{login:'dev1',avatar_url:'https://d'}],milestone:{title:'v2.0'},type:{name:'Bug'},comments:4,reactions:{total_count:2},locked:false,html_url:'https://github.com/example/demo/issues/1',body:'details',created_at:now,updated_at:now,closed_at:null},
        {number:2,title:'PR should be skipped',state:'open',user:{login:'bob',avatar_url:'https://b'},labels:[],comments:0,locked:false,html_url:'https://github.com/example/demo/pull/2',created_at:now,updated_at:now,closed_at:null,pull_request:{}},
      ]:[
        {number:3,title:'Old issue',state:'closed',state_reason:'completed',user:{login:'carol',avatar_url:'https://c'},labels:[{name:'bug',color:'d73a4a'}],assignees:[],milestone:null,type:null,comments:1,reactions:{total_count:0},locked:false,html_url:'https://github.com/example/demo/issues/3',body:'fixed',created_at:now,updated_at:now,closed_at:now},
      ];
      return {status:200,data:items,notModified:false,link:{}};
    }
  } as unknown as GitHubClient;
  await runCommunitySync(sIssue.id,gh);
  await runCommunitySync(sDisc.id,gh);
  const iq=await queryIssues(r.id,issueParams({state:'open',label:['bug','Kobo'],milestone:'v2.0',assignee:'dev1',type:'Bug'}));
  expect(iq.total).toBe(1);expect(iq.openCount).toBe(1);expect(iq.closedCount).toBe(0);expect(iq.rows[0].number).toBe(1);
  const dq=await queryDiscussions(r.id,discussionParams({category:'Q&A',filter:'answered',label:['Kobo']}));
  expect(dq.total).toBe(1);expect(dq.rows[0].number).toBe(10);expect(dq.rows[0].categoryEmoji).toBe('🙏');
  // 多级分类：路径创建、不同父级允许同名、子树递归计数与后代筛选
  const macId=await ensureCategory('工具 / macOS');
  const tools=(await listCategories()).find(x=>x.name==='工具')!;
  const iosId=await ensureCategory('iOS',tools.id);
  const pluginMacId=await ensureCategory('插件 / macOS');
  expect(pluginMacId).not.toBe(macId);
  await prisma.repository.update({where:{id:r.id},data:{categoryId:macId}});
  const tree=await listCategories();
  const toolsNode=tree.find(x=>x.id===tools.id)!;
  const macNode=tree.find(x=>x.id===macId)!;
  expect(toolsNode.count).toBe(1);expect(toolsNode.directCount).toBe(0);expect(toolsNode.childrenCount).toBe(2);
  expect(macNode.path).toBe('工具 / macOS');expect(macNode.depth).toBe(1);
  const desc=getDescendantIds(tree,tools.id);
  expect(desc.has(tools.id)).toBe(true);expect(desc.has(macId)).toBe(true);expect(desc.has(iosId)).toBe(true);expect(desc.has(pluginMacId)).toBe(false);
});
