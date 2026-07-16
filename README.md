# MyNAS

**把树莓派和外接硬盘变成一个简单、私有、可以远程访问的个人 NAS。**

MyNAS 提供网页文件管理、多硬盘管理、上传下载、回收站和设备切换。网页使用 React，树莓派端使用 Go；真实文件保存在你自己的硬盘中，并通过 Tailscale 安全访问。

> ## 第一次使用？从这里开始
>
> **[打开《MyNAS 新手安装与接线指南》→](docs/BEGINNER_GUIDE.md)**
>
> 从准备设备、连接网线和硬盘，到写入 Raspberry Pi OS、开启 SSH、安装 Tailscale、接入硬盘和打开网页，全部按顺序说明。第一次接触树莓派也可以照着操作。

> [!IMPORTANT]
> 当前版本为 **v0.3.0 测试版**。网页连接和硬盘接入已经提供新手向导，上传进度与实时读写速率也已完善，但“在全新树莓派上一键安装 MyNAS 服务”仍在开发中。首次部署目前需要项目维护者完成，不建议普通用户直接执行仓库中的生产部署脚本，也不要把 MyNAS 当作重要文件的唯一备份。

## 最简单的使用路线

```text
准备树莓派和硬盘
        ↓
按新手指南完成接线、系统和 Tailscale
        ↓
维护者完成 MyNAS 首次部署
        ↓
运行接盘向导，打开网页开始使用
```

1. **准备设备**：树莓派 4/5、microSD 卡、网线、可靠电源，以及带正确供电的硬盘盒。
2. **完成基础设置**：写入 Raspberry Pi OS，开启 SSH，并在电脑和树莓派上登录同一个 Tailscale 账号。
3. **安装 MyNAS 服务**：当前版本由项目维护者完成首次部署；通用安装程序正在开发。
4. **接入硬盘并使用**：安装完成后，在树莓派终端运行：

   ```bash
   sudo mynas-setup
   ```

   按向导选择硬盘，再打开 [MyNAS 公共网页](https://mynas-rsp.pages.dev/)。需要完整步骤和故障处理时，请查看[新手安装与接线指南](docs/BEGINNER_GUIDE.md)。

## 接线一眼看懂

```text
互联网
  │
路由器 ── LAN 口 ── 网线 ── 树莓派
                              │
                              └── USB 3.0 ── 带供电硬盘盒 ── 硬盘
```

- 3.5 英寸机械硬盘必须使用带独立电源的硬盘盒或底座。
- 网线连接路由器 **LAN 口**，不要连接 WAN/Internet 口。
- 不要在上传、复制或移动文件时拔掉硬盘。
- 格式化会永久删除硬盘数据，操作前务必确认并备份。

## 你可以用它做什么

- 在网页中浏览、上传、下载、复制、移动和删除文件。
- 同时管理多块硬盘，查看每块盘的容量、已用空间和在线状态。
- 使用按硬盘隔离的回收站，以及操作审计记录。
- 给硬盘和 MyNAS 设备自定义名称。
- 管理并切换多台 MyNAS 设备。
- 使用中文/英文界面和深色主题。
- 通过 Tailscale 从外部网络安全访问，不直接暴露 NAS 端口。

## 访问方式

1. 在电脑和树莓派上登录同一个 Tailscale 账号。
2. 建议先关闭 Clash Verge、Surge 等 VPN/代理软件，尤其是 **TUN、增强模式或 Fake-IP**。
3. 只打开并收藏 [MyNAS 公共网页](https://mynas-rsp.pages.dev/)，不要直接打开或收藏 `*.ts.net` 私有地址。

公共网页只负责界面和连接诊断，不保存 NAS 文件。文件列表、上传和下载会通过 Tailscale 直接连接你的树莓派。

如果必须同时使用 Clash Verge 等代理，请将以下目标设为 `DIRECT`，然后重新打开公共网页：

```text
rsp.tail681937.ts.net
*.tail681937.ts.net
100.64.0.0/10
```

> 私有 `*.ts.net` 地址只用于后台数据连接。直接打开它时，如果代理提前终止连接，浏览器无法加载 MyNAS 的诊断页面。

## 当前状态与路线图

### 已完成

- 多硬盘容量展示与文件管理
- 上传任务暂停、继续、取消和状态恢复；保留 8 MB 分块效率并显示块内连续进度
- 按 MyNAS 实际传输字节计算每秒读写速率，避免 Linux 缓存导致长期显示为 0
- 跨硬盘文件操作、回收站与审计记录
- `mynas-setup` 接盘向导，支持 `ext4`、`NTFS3`、`exFAT`
- 多 MyNAS 设备管理和首次连接引导
- Tailscale Serve 私有 HTTPS 访问

### 正在推进

- 面向全新树莓派的通用一键安装与升级
- 视频在线预览与缩略图
- 可选的局域网账号密码登录
- 账户退出与切换：提供明确的退出入口，清理当前 MyNAS 会话/设备状态，并支持切换 Tailscale 或后续本地账号
- 磁盘健康检查、权限、备份和故障恢复

详细版本变化见 [CHANGELOG.md](CHANGELOG.md)。

---

## 以下内容面向开发者和维护者

如果你只是想安装和使用 MyNAS，读到这里就够了；下面是项目结构、开发、部署与安全实现说明。

## 技术结构

```text
浏览器（React）
   │
   │ Tailscale 私有 HTTPS
   ▼
树莓派（Go API，仅监听 127.0.0.1）
   │
   ├── 已注册硬盘卷
   └── SQLite 审计数据
```

- `frontend/`：React + TypeScript + Vite 客户端
- `backend/`：Go API 与 `mynas-setup` 接盘工具
- `scripts/`：Windows 本地开发和构建脚本
- `deploy/`：树莓派 systemd、部署与 Cloudflare Pages 发布脚本
- `docs/`：新手指南、运行、回滚和故障排查说明

## 本地开发

本地开发数据只写入 `D:\MyNAS\dev-data`。先运行完整测试与生产构建：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\MyNAS\scripts\build.ps1
```

再启动与树莓派部署形态一致的单端口服务：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\MyNAS\scripts\dev.ps1
# 打开 http://127.0.0.1:8080/

powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\MyNAS\scripts\stop-local.ps1
```

开发身份仅在 `MYNAS_ENV=development` 与 `MYNAS_DEV_IDENTITY=1` 同时设置时启用，生产模式会强制禁用。Windows 后端、Linux ARM64 后端和前端生产包都在开发机生成，树莓派只接收已经测试的产物。

## 维护者部署

> [!WARNING]
> 下面的脚本绑定当前维护者的 SSH 密钥、设备名、挂载路径和 Tailscale 环境，不是给普通用户使用的通用安装命令。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\MyNAS\deploy\deploy.ps1 -PagesOrigin https://mynas-rsp.pages.dev
```

部署使用 `/opt/mynas/releases/<UTC时间>/` 保存版本，并通过 `/opt/mynas/current` 原子切换。运维、回滚和故障排查见 [docs/operations.md](docs/operations.md)。

## 安全边界

- Go API 只监听 `127.0.0.1`，生产环境只信任 Tailscale Serve 注入的身份信息。
- 用户路径被限制在已注册硬盘卷内，并拒绝路径穿越、符号链接逃逸和系统目录访问。
- 修改请求必须携带 `X-MyNAS-Request: 1`，CORS 只允许已配置的 Pages 地址和 localhost。
- 每块硬盘有独立的 `.mynas/staging` 与 `.mynas/trash`；审计数据库与用户文件分开存放。
- 当前版本不建议把 8080 端口直接映射到公网。

账号密码只能解决“谁能登录”，不能单独解决公网连接、传输加密、可信 HTTPS、会话保护和防暴力破解。局域网账号模式可以作为后续选项，但当前远程访问仍推荐使用 Tailscale。

## 版本规则

项目使用语义化版本号 `主版本.次版本.修订版本`：

- Bug 修复：`0.2.0` → `0.2.1`
- 向后兼容的新功能：`0.2.1` → `0.3.0`
- 不兼容的重大变化：`1.4.0` → `2.0.0`

当前版本见 [VERSION](VERSION)，每次正式发布同步更新 [CHANGELOG.md](CHANGELOG.md) 并创建对应 Git 标签。
