# OpenSource Hub 邮件通知

## 范围和安全

当前配置支持一个发件账号和一个收件地址，选择一种服务商即可；不需要把五种邮箱都填一遍。邮件内容包括仓库名称、更新标题和链接，会发送给所选邮件服务商和收件人。

SMTP 授权码与 Outlook 刷新令牌保存在本机 SQLite 数据库中（未加密），请保护 `data` 目录和备份；不要将凭证或数据库发给别人，也不要把应用直接暴露到公网。系统仅发送配置完成后发现的新更新，不会补发之前的失败通知。

## 通用配置

1. 在「设置 → 邮件服务商」选择 QQ 邮箱、Gmail、iCloud、Outlook.com 或 163。
2. 填写收件邮箱和发件邮箱（SMTP 用户名通常填写完整发件地址）。切换服务商会清除之前保存的 SMTP 授权码；检查 SMTP 主机、端口及加密方式是否与邮箱服务商要求相符。
3. QQ、Gmail、iCloud、163 在「SMTP 授权码」填写各自生成的专用授权码或应用专用密码，而不是通常的登录密码。Outlook 不在这里填密码，需另做下方的 OAuth2 授权。
4. 点击「保存设置」，再点击「发送测试邮件（使用已保存的设置）」。服务商接受后仍需检查收件箱或垃圾邮件；接受不保证最终送达。
5. 通过测试后，可发布新的测试 Release 验证 Worker 自动发送。

## 服务商设置

- QQ 邮箱：开通 SMTP 服务并生成授权码，选择 QQ 邮箱；默认 `smtp.qq.com`、465、SSL/TLS。
- Gmail：Google 账户需开启两步验证并生成应用专用密码（部分账号可能不可用）；默认 `smtp.gmail.com`、465、SSL/TLS。
- iCloud：在 Apple 账户中生成应用专用密码；默认 `smtp.mail.me.com`、587、STARTTLS；SMTP 用户名使用完整邮箱地址。
- 163：在邮箱设置启用 SMTP 并获取客户端授权码；默认 `smtp.163.com`、465、SSL/TLS。
- Outlook.com 个人账户：默认 `smtp-mail.outlook.com`、587、STARTTLS；使用 OAuth2，见下文。此版本未实现 Microsoft 365 工作或学校账户的租户配置。

SMTP 预设可以手动调整；请勿关闭加密或把授权码当作聊天内容发送。网络连通、服务商风控和账号权限也可能影响发送。

## Outlook.com 授权

Outlook.com 不应使用普通密码或简单应用密码替代 OAuth2。本功能需要你自行注册一个 Microsoft Entra 应用，支持个人 Microsoft 账户，启用“允许公共客户端流”，配置/同意 Outlook 的委派权限 `https://outlook.office.com/SMTP.Send` 和 `offline_access`。注册或同意权限可能受 Microsoft 策略及账户条件限制。

1. 在设置中选择 Outlook.com，填写发件邮箱、收件邮箱和你注册应用的 **Application (client) ID**，保存。不要创建或输入 client secret。
2. 在项目目录执行：

```bash
docker compose exec worker node scripts/outlook-authorize.cjs
```

3. 在自己的浏览器打开终端显示的 Microsoft 登录网址，输入临时设备代码，以设置页同一个 Outlook 账户登录并同意权限。终端显示授权成功后，回到设置页面点击「发送测试邮件」。不要分享设备代码、刷新令牌或数据库。

如果提示权限不可用、应用受阻、网络连接失败或需要管理员批准，请先截图错误信息并遮盖个人信息。此接入还需要在你的 Microsoft 账户上完成真实测试。

## 参考

- QQ 邮箱授权码：<https://help.mail.qq.com/detail/108/1088?expand=8>
- Gmail 应用密码：<https://support.google.com/accounts/answer/185833>
- iCloud SMTP 和应用密码：<https://support.apple.com/en-us/102525>
- Outlook.com OAuth2：<https://support.microsoft.com/en-us/outlook/pop-imap-and-smtp-settings-for-outlook-com>
- Microsoft SMTP OAuth2：<https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth>
