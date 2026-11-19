// 设备代码登录：凭证只保存到本地数据库，不输出 token。
const { PrismaClient } = require('@prisma/client');
const db = new PrismaClient();
const root = 'https://login.microsoftonline.com/consumers/oauth2/v2.0';
const scope = 'https://outlook.office.com/SMTP.Send offline_access';
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function request(path, params) {
  let res;
  try { res = await fetch(root + path, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams(params),signal:AbortSignal.timeout(15000)}); }
  catch { throw Error('无法连接 Microsoft 授权服务，请检查网络。'); }
  try { return {ok:res.ok, data:await res.json()}; } catch { throw Error('Microsoft 授权服务响应无效。'); }
}
async function main() {
  const row = await db.setting.findUnique({where:{key:'notify.email.outlook.clientId'}});
  const client = row?.value?.trim();
  if (!client) throw Error('请先在设置页面填写并保存 Outlook Microsoft 应用 Client ID。');
  const start=await request('/devicecode',{client_id:client,scope});
  if(!start.ok || typeof start.data.device_code!=='string' || typeof start.data.user_code!=='string' || typeof start.data.verification_uri!=='string') {
    const code=typeof start.data.error==='string'&&/^[a-z_]+$/.test(start.data.error)?start.data.error:'unknown';throw Error(`无法发起授权（${code}），请检查 Client ID 和应用配置。`);
  }
  const d=start.data;
  console.log(`请在自己的浏览器打开：${d.verification_uri}\n输入代码：${d.user_code}\n使用与设置页发件邮箱相同的 Microsoft 个人账户登录并同意授权。`);
  const deadline=Date.now()+Number(d.expires_in||900)*1000;let interval=Math.max(5,Number(d.interval)||5)*1000;
  while(Date.now()<deadline){
    await sleep(interval);
    const result=await request('/token',{client_id:client,grant_type:'urn:ietf:params:oauth:grant-type:device_code',device_code:d.device_code});
    if(result.ok && typeof result.data.refresh_token==='string' && result.data.refresh_token){
      await db.setting.upsert({where:{key:'notify.email.outlook.refreshToken'},create:{key:'notify.email.outlook.refreshToken',value:result.data.refresh_token},update:{value:result.data.refresh_token}});
      console.log('Outlook 授权成功，凭证已保存在本地数据库。');return;
    }
    const code=result.data.error;
    if(code==='authorization_pending')continue;
    if(code==='slow_down'){interval+=5000;continue}
    throw Error(`授权未完成（${typeof code==='string' && /^[a-z_]+$/.test(code)?code:'unknown'}）。`);
  }
  throw Error('授权超时，请重新运行此命令。');
}
main().catch(e=>{console.error(e.message);process.exitCode=1}).finally(()=>db.$disconnect());
