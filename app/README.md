# OpenSource Hub

面向个人使用的 GitHub 软件源管理原型。输入 `owner/repo` 或 GitHub 地址后，独立 Worker 将仓库信息、Release/附件、Tag、默认分支 Commit、README 和常见版本文件写入 SQLite。无 Release、无 Tag、无附件的仓库也可以展示；不同来源不会混作正式 Release。首次成功同步建立历史基线，不通知历史事件。

> **当前交付是可运行的开发版，不是已完成全部验收的生产版本。** Docker 环境、全部七类真实仓库、外部通知实际送达与生产安全尚未验证，详见下方限制与验收记录。

## 安全须知

- 当前没有用户登录、授权或多租户隔离。所有 API 可以修改设置、删除数据、读取仓库信息；**不要直接暴露到公网或不可信网络**。Compose 默认只绑定 `127.0.0.1`，远程访问请使用安全隧道或在经过独立安全评估的认证代理后部署。Webhook 如需公网接收，应单独保护服务、严格限制入口，并设置随机签名密钥。
- Token、Webhook 地址和通知密钥以明文保存在 SQLite，或通过环境变量传入；保护 `.env` 和 `data/` 的权限与备份。页面不回显完整密钥。`GITHUB_TOKEN` 环境变量优先于页面设置。
- 不会运行下载的文件。附件分类仅是启发式推断，并不保证可安装或安全；已从上游删除的历史附件仍保留，其下载链接可能失效。SHA256 仅使用 GitHub API 提供的有效 digest，不自行猜测。
- `npm audit --omit=dev` 在本次环境中报告 Prisma 依赖链及 Next/PostCSS 漏洞；尚未完成升级或安全评估。请勿将此版本视为已加固的软件。

## 技术架构和目录

- Next.js 15、TypeScript、React、Tailwind CSS、自编组件与 Lucide；GitHub REST 客户端使用自编 `fetch`，不是 Octokit；未引入 shadcn/ui。
- Prisma + SQLite；Web 和**一个**独立 Worker 共享数据库，持久化任务、日志、HTTP 条件请求缓存。Worker 定期调度、认领、重试和恢复任务，依靠 ETag / Last-Modified 减少请求。
- `src/app/` 页面及 API；`src/components/` 界面；`src/lib/github/` 客户端与解析；`src/lib/sync/` 同步、队列和调度；`src/worker/` 后台服务；`prisma/schema.prisma` 数据模型；`tests/` 测试；`scripts/` CLI。
- 数据表：`repositories`、`releases`、`assets`、`tags`、`commits`、`tracked_files`、`changelog_entries`、`version_events`、`sync_tasks`、`sync_logs`、`settings`、`notifications`、`http_cache`。唯一约束用于同仓库来源去重。切换 PostgreSQL 需要迁移和兼容性测试，不能仅修改连接字符串。

## Docker Compose（Mac Docker Desktop / Linux VPS）

需要 Docker Engine 和 Compose v2。该配置**尚未在 Docker 环境实测**；建议先在本机验证并备份。项目目录执行：

```sh
cp .env.example .env
# 可在 .env 中填写 GITHUB_TOKEN；设置较强的 GITHUB_WEBHOOK_SECRET 才启用 Webhook
mkdir -p data
docker compose up --build -d
docker compose logs -f web worker
```

打开 `http://localhost:3000`。`init` 服务运行 Prisma `db push` 初始化共享 `/app/data/hub.db`，web、worker 待初始化成功后启动。`data/` 持久化数据库。停止：`docker compose down`。数据库结构更新前先停服并备份整个 `data/`（包括 SQLite WAL 文件）；`db push` 不是经过验证的生产迁移方案。更新：备份后重新 `docker compose up --build -d`。仅运行一个 worker 实例；当前启动恢复逻辑不支持多个 Worker 互相安全协调。默认端口仅本机可访问，Linux VPS 请通过 SSH 端口转发访问。

## 本地开发

需要 Node.js 22 或以上与 npm：

```sh
npm ci
cp .env.example .env
npm run db:generate
npm run db:push
npm run dev             # 终端 1
npm run worker          # 终端 2
```

访问 `http://localhost:3000`。生产模式使用 `npm run build` 后 `npm start`。命令行手动同步：`npm run sync:once -- owner/repo --full`。测试：`npm test`（临时隔离 SQLite，不会清空开发数据库）；`npm run typecheck`。

## 使用与行为

1. 点击「添加软件源」，每行输入一个地址或 `owner/repo`；成功后进入任务队列。首页显示 Worker 是否在线。
2. 详情页分别查看版本、下载、Tags、Commits、源码、同步记录和设置。下载列表支持按平台、架构、格式、名称筛选；空列表是正常状态。可为单仓库设置间隔、暂停及通知类型。
3. 设置页可设置全局间隔、Token 和通知渠道。站内、Telegram、Discord、通用 Webhook 已实现；邮件仅预留接口。配置外部渠道后仍须自行进行送达验证。渠道发送失败会记录状态，但当前没有可靠的独立投递重试队列。
4. 默认匿名 GitHub API 额度通常为每小时 60 次/出口 IP；登录 Token 通常可提高额度，具体以 GitHub 策略为准。页面及 Worker 显示已观察到的额度。同步会处理 304、限流与退避，但多个进程和共享出口不构成全局限速器，仓库多时五分钟轮询可能超额；增加间隔或使用 Token。
5. 可为有权限的仓库配置 GitHub Webhook，事件选 push、release、create、delete，Content-Type 选 JSON，URL 为 `/api/webhooks/github`，Secret 与环境变量一致。Webhook 只是入队触发；并不替代 API 同步。公网入口需单独安全设计。

## 已知边界

- 历史 Release / Tag 默认分别最多获取 20 / 10 页，每页 100 条；超出上限时会记录部分失败，需在设置中增加上限。Tag 的提交时间每次限量补全；每次增量最多追溯 300 个 Commit，首次默认 30 个。强推或长期离线后超出范围可能遗漏中间提交。
- 增量同步按首页变化优化，历史页中单独修改的旧 Release/Tag 不保证立即发现；可手动做完整同步的 CLI。已经从上游删除的 Release 和附件保留历史，链接不保证仍可用。仓库在 GitHub 删除或不可访问时历史保留；**在本应用设置里主动删除软件源会连同其本地历史一起删除**。
- 新增事件的写入和外部通知不在同一可靠事务里；崩溃时可能漏发。初次同步任一步骤失败不会建立完整基线；下次会重试全量。暂不支持 GitLab、Codeberg、PWA 或实时双向同步。
- 每个 Worker 启动会恢复所有 `running` 任务，故不支持多个 Worker 副本。测试中的恢复为隔离数据库内的状态恢复，不等于真实容器断电和并发故障验证。

## 阶段记录与当前验收

这些记录基于本次运行，测试仓库的内容会随时间变化。未验证项不视为通过。

1. **架构与导入**：建立 Prisma 模型、输入解析和导入 API；涉及 `prisma/`、`src/lib/repos.ts`、`src/app/api/repos/`。真实导入 Wenku8、Gopeed、nanoGPT 与归档仓库成功；不存在的仓库返回不存在或无权访问。待办：验证私有仓库与 Docker 环境。
2. **版本同步**：Release、Tag、Commit、版本文件与统一事件实现；涉及 `src/lib/sync/engine.ts`。隔离数据库测试覆盖首次基线、增量事件和去重；真实 Gopeed 全量取得 66 个 Release、66 个 Tag，复查零新增。待办：真实仅 Tag 仓库验收；`actions/checkout` 实测 58 个 Release、0 个附件（该次暂时关闭 Tag 时间回填）。
3. **附件与详情**：分类、详情和筛选实现；涉及 `src/lib/assets.ts`、`src/app/repos/`、`src/components/AssetList.tsx`。Wenku8 实测 5 个附件；Gopeed 实测 1,100 个附件、识别 Android/iOS/Linux/macOS/Windows。待办：全平台实际下载与识别误差检查。
4. **调度与日志**：SQLite 队列、指数退避、日志与 Worker；涉及 `src/lib/sync/queue.ts`、`src/worker/`。隔离测试覆盖队列去重、认领、恢复和网络错误重试；未做真实进程中断、Docker 重启或多进程压力测试。
5. **发现与界面**：首页、发现、通知、设置与仓库详情；涉及 `src/app/`、`src/components/`。生产页面和 API HTTP 冒烟测试通过；移动端及交互仍需完整人工验收。
6. **测试与部署**：`npm run build` 和 10 项自动测试通过，测试包括 304、429、403、404、500 的模拟。真实 `karpathy/nanoGPT` 无 Release/Tag、有 Commit；`facebookarchive/fb-adb` 显示归档。真实新 Release/Tag/Commit 通知仅通过模拟数据验证；Docker、本地 Mac、邮件、真实限流与仅 Tag 的公开仓库仍待验收。
