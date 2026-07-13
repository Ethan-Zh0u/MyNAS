# MyNAS

MyNAS 是一个 React + Go 的私人 NAS 管理界面。静态前端部署到 Cloudflare Pages；真实文件数据只经由树莓派 Tailscale Serve 的 HTTPS API 传输。

## 目录

- `frontend/`：React + TypeScript + Vite 客户端
- `backend/`：Go API（仅监听 localhost）
- `scripts/`：Windows 本地开发、构建脚本
- `deploy/`：树莓派 systemd、部署与 Pages 发布脚本
- `docs/`：运行、回滚与故障排查说明

## 本地开发

本地数据仅使用 `D:\MyNAS\dev-data`。先完成全量测试和两个平台的生产构建：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\MyNAS\scripts\build.ps1
```

再启动与树莓派部署形态一致的单端口服务：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\MyNAS\scripts\dev.ps1
# http://127.0.0.1:8080/
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\MyNAS\scripts\stop-local.ps1
```

开发身份仅由 `MYNAS_ENV=development` 与 `MYNAS_DEV_IDENTITY=1` 同时启用；production 会强制禁用。Windows 本地后端、Linux ARM64 后端、前端生产包全部由本机生成，树莓派只接收已测试产物。

## 访问地址

- 私有管理入口：`https://rsp.tail681937.ts.net/`（必须连接 Tailscale）
- 公共静态入口：`https://mynas-rsp.pages.dev/`；未连接 Tailscale 时只显示诚实的连接引导，不传输 NAS 数据

若 Windows/macOS 开启了系统代理或 Clash 类代理，必须将 `rsp.tail681937.ts.net`、`*.tail681937.ts.net` 与 Tailscale `100.64.0.0/10` 设为直连，否则代理会对私有地址返回连接关闭。

## 安全边界

- 所有用户路径被限制在 `/mnt/nas`；拒绝穿越、符号链接逃逸、`.mynas`、`$RECYCLE.BIN`、`System Volume Information`。
- 生产 API 仅信任 Tailscale Serve 注入的身份头，且只监听 `127.0.0.1`。
- 修改请求要求 `X-MyNAS-Request: 1`，CORS 仅允许 Pages 地址和 localhost。
- SQLite 审计数据库存放于 `/home/rbp/.local/share/mynas`；NAS 隐藏服务文件仅在 `/mnt/nas/.mynas`。

## 树莓派部署

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\MyNAS\deploy\deploy.ps1 -PagesOrigin https://mynas-rsp.pages.dev
```

部署使用 `/opt/mynas/releases/<UTC时间>/` 版本目录和 `/opt/mynas/current` 原子链接；不会修改 `/etc/fstab` 或 Samba 配置。
