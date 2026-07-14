# MyNAS

MyNAS 是一个基于树莓派和机械硬盘开发的个人 NAS 管理系统，前端使用 React，后端使用 Go。当前版本服务于一台已经接入硬盘的树莓派：静态前端部署到 Cloudflare Pages，真实文件数据只经由树莓派 Tailscale Serve 的 HTTPS API 传输。

项目长期目标是发展成面向通用树莓派和外接硬盘的版本，让用户拿到一台新的树莓派和一块硬盘后，可以通过标准化安装脚本快速部署整套 MyNAS 管理系统，而不必手工拼装每个服务。

> 当前项目仍处于早期开发阶段，版本为 **v0.2.0**，尚不建议把它作为唯一的数据管理工具。

第一次接触树莓派和硬盘？请从 [MyNAS 新手安装与接线指南](docs/BEGINNER_GUIDE.md) 开始。指南包含路由器网线、树莓派 SSH、Tailscale、硬盘盒供电、硬盘接入和网页首次连接的完整流程。

## 当前状态

- 已具备多硬盘容量展示、文件浏览、上传、下载、跨盘文件操作、回收站和审计记录。
- 支持硬盘接入向导、硬盘重命名、多 MyNAS 设备管理以及设备自定义名称。
- 提供中文/英文界面、深色主题、目录返回按钮和 Windows/macOS/Linux 首次连接说明。
- 当前树莓派端首次部署仍与维护者的设备配置有关，还不是开箱即用的通用安装程序；不要把维护者部署命令直接用于未知设备。

## 计划中的方向

- 通用树莓派部署：自动检测外接硬盘、生成配置、安装服务，并提供可重复执行的安装和升级流程。
- 视频在线预览：优先支持浏览器原生可播放格式，再评估缩略图、转码和断点播放。
- 本地账号与密码登录：为局域网使用和多用户管理提供可选的认证方式。
- 更完善的磁盘健康检查、权限管理、备份、升级和故障恢复能力。

### 账号密码能否代替 Tailscale？

可以开发账号密码登录，但它解决的是“谁可以登录”，Tailscale 同时解决了“设备如何安全连到树莓派”和“通信如何加密”。因此：

- 在同一个局域网内，可以采用账号密码登录，不一定安装 Tailscale。
- 从外网访问时，当前版本仍必须连接 Tailscale。
- 未来可以提供不依赖 Tailscale 的公网模式，但必须同时提供可信 HTTPS、公网入口或安全隧道、密码安全存储、会话保护、限速、防暴力破解和及时安全更新。对于存放私人文件的 NAS，Tailscale 仍会是默认推荐方案。

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

- 所有用户路径被限制在已注册卷的挂载点（现有主盘 `/mnt/nas`，新增盘 `/mnt/mynas/<volume-id>`）；每次请求都显式绑定卷 ID，并拒绝穿越、符号链接逃逸、`.mynas`、`$RECYCLE.BIN`、`System Volume Information`。
- 生产 API 仅信任 Tailscale Serve 注入的身份头，且只监听 `127.0.0.1`。
- 修改请求要求 `X-MyNAS-Request: 1`，CORS 仅允许 Pages 地址和 localhost。
- SQLite 审计数据库存放于 `/home/rbp/.local/share/mynas`；每块硬盘拥有独立的 `.mynas/staging` 和 `.mynas/trash`。

## 树莓派部署

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\MyNAS\deploy\deploy.ps1 -PagesOrigin https://mynas-rsp.pages.dev
```

部署使用 `/opt/mynas/releases/<UTC时间>/` 版本目录和 `/opt/mynas/current` 原子链接。部署后可在树莓派终端运行半图形化接盘向导：

```bash
sudo mynas-setup
```

向导自动排除系统盘，支持保留已有 `ext4`、`NTFS3`、`exFAT` 数据接入，也支持对空白硬盘进行明确确认后的初始化。只有该向导会临时以 root 权限备份并更新 `/etc/fstab`；日常 MyNAS 服务仍以 `rbp` 用户运行。新增硬盘按文件系统 UUID 挂载到 `/mnt/mynas/<volume-id>`，注册信息写入 `/etc/mynas/volumes.json`。

## 版本记录

项目采用语义化版本号 `主版本.次版本.修订版本`：

- 修复 Bug：增加修订版本，例如 `0.1.0` → `0.1.1`。
- 增加兼容功能：增加次版本，例如 `0.1.1` → `0.2.0`。
- 出现不兼容的重大变化：增加主版本，例如 `1.4.0` → `2.0.0`。

当前版本保存在根目录的 `VERSION` 文件中，每次发布都要同步更新 `CHANGELOG.md` 并创建对应的 Git 标签。开发过程中的每一个小提交仍由 Git 提交号记录；只有形成可识别的发布节点时才升级版本号，避免版本号失去意义。
