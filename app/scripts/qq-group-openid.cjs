// 临时监听群 @机器人事件，只输出群 OpenID，不打印凭证或消息正文。
const { PrismaClient } = require('@prisma/client');
const db = new PrismaClient();
async function main() {
  const rows = await db.setting.findMany({ where: { key: { in: ['notify.qq.appId','notify.qq.clientSecret'] } } });
  const s = Object.fromEntries(rows.map(x => [x.key,x.value]));
  if (!s['notify.qq.appId'] || !s['notify.qq.clientSecret']) throw Error('请先在设置页面填写并保存 QQ 机器人 AppID 和 AppSecret。');
  const fetchJson = async (url, opts) => {
    let res;
    try { res = await fetch(url, { ...opts, signal: AbortSignal.timeout(15000) }); }
    catch { throw Error('连接 QQ 失败，请检查 Worker 的网络。'); }
    let data; try { data = await res.json(); } catch { throw Error(`QQ 返回无效响应（HTTP ${res.status}）`); }
    const code = typeof data?.code === 'number' ? data.code : data?.err_code;
    if (!res.ok || (typeof code === 'number' && code !== 0)) throw Error(`QQ 接口错误（HTTP ${res.status}，错误码 ${code ?? '未知'}）`);
    return data;
  };
  const auth = await fetchJson('https://api.bot.qq.com/app/getAppAccessToken',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({appId:s['notify.qq.appId'],clientSecret:s['notify.qq.clientSecret']})});
  if (typeof auth.access_token !== 'string' || !auth.access_token) throw Error('QQ 令牌响应无效。');
  const gateway = await fetchJson('https://api.bot.qq.com/gateway/bot',{headers:{Authorization:`QQBot ${auth.access_token}`}});
  if (typeof gateway.url !== 'string' || !gateway.url.startsWith('wss://')) throw Error('QQ 网关地址无效。');
  if (gateway.shards && gateway.shards !== 1) throw Error('此工具仅支持单分片机器人，请使用现有事件接收服务获取群 OpenID。');
  await new Promise((resolve,reject)=>{
    let done=false, seq=null, timer, timeout; const ws=new WebSocket(gateway.url);
    const finish=(error)=>{if(done)return;done=true;clearInterval(timer);clearTimeout(timeout);try{ws.close()}catch{};error?reject(error):resolve()};
    timeout=setTimeout(()=>finish(Error('等待超时。请确认事件订阅方式为 WebSocket，并在群内 @机器人。')),180000);
    ws.addEventListener('error',()=>finish(Error('QQ 网关连接失败，请检查网络和机器人配置。')));
    ws.addEventListener('close',(e)=>finish(Error(`QQ 网关已关闭（代码 ${e.code}）。`)));
    ws.addEventListener('message',(event)=>{
      let m;try{m=JSON.parse(String(event.data))}catch{return}
      if(typeof m.s==='number') seq=m.s;
      if(m.op===10){
        ws.send(JSON.stringify({op:2,d:{token:`QQBot ${auth.access_token}`,intents:1<<25,shard:[0,1],properties:{$os:'linux',$browser:'opensource-hub',$device:'opensource-hub'}}}));
        if(m.d?.heartbeat_interval) timer=setInterval(()=>{if(ws.readyState===WebSocket.OPEN)ws.send(JSON.stringify({op:1,d:seq}))},m.d.heartbeat_interval);
      } else if(m.op===9){finish(Error('QQ 网关鉴权失败，请检查机器人事件订阅和权限。'))}
      else if(m.op===0 && m.t==='READY'){console.log('已连接。请在目标 QQ 群里 @机器人 并发送一条消息。等待最多 3 分钟……')}
      else if(m.op===0 && m.t==='GROUP_AT_MESSAGE_CREATE' && typeof m.d?.group_openid==='string'){
        console.log('\n目标群 OpenID：'+m.d.group_openid+'\n请复制到 OpenSource Hub 设置页的「QQ 群 OpenID」，不要发到聊天中。');finish();
      }
    });
  });
}
main().catch(e=>{console.error('获取失败：'+e.message);process.exitCode=1}).finally(()=>db.$disconnect());
