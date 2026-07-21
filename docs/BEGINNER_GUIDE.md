# MyNAS 新手安装与接线指南

这份指南面向第一次接触树莓派、SSH、Tailscale 和外接硬盘的用户。请按顺序完成，不要先插硬盘、再边通电边反复拔线。

> MyNAS v0.3.1 仍是测试版本。网页中的连接、设备管理和接盘向导已经面向新手设计，但“在一台全新的树莓派上一键安装 MyNAS 服务”仍在开发中。当前发布版的树莓派端首次部署仍由项目维护者完成；安装好 MyNAS 后，普通用户可以通过网页向导和 `sudo mynas-setup` 接入硬盘。

## 1. 需要准备什么

- 一台 Raspberry Pi 4 或 Raspberry Pi 5，推荐 4GB 及以上内存。
- 一张 16GB 以上的 microSD 卡和读卡器。
- 对应型号的树莓派电源，电压或功率不足会导致硬盘掉线、文件损坏。
- 一台能正常上网的路由器。
- 一根网线，用于连接路由器 LAN 口和树莓派网口。
- 一台 Windows、macOS 或 Linux 电脑，用来写入系统、打开网页和通过 SSH 操作树莓派。
- 一块或多块硬盘，以及正确的硬盘盒、硬盘底座或 USB 转 SATA 设备。

### 硬盘供电特别提醒

- **3.5 英寸机械硬盘必须使用带独立电源的硬盘盒或硬盘底座。** 不要尝试仅靠树莓派 USB 给裸硬盘供电。
- 2.5 英寸机械硬盘或 SATA SSD 有时可以由 USB 供电，但如果出现反复断开、转速异常或系统提示欠压，应改用带电源的硬盘盒或有源 USB Hub。
- 裸 SATA 硬盘不能直接插入树莓派。必须使用 USB 转 SATA 设备，并确认它支持硬盘容量和 UASP。
- 优先连接树莓派的 USB 3.0 接口（通常是蓝色接口）。

## 2. 正确连接路由器、树莓派和硬盘

建议按下面顺序接线：

1. 暂时不要给树莓派通电。
2. 将网线一端插入路由器的 **LAN 口**，另一端插入树莓派的网口。不要插到路由器的 WAN/Internet 口。
3. 将硬盘装入硬盘盒或硬盘底座。
4. 如果硬盘盒有独立电源，先连接电源，但暂时不要反复开关。
5. 用 USB 线把硬盘盒连接到树莓派 USB 3.0 接口。
6. 插入已经写好 Raspberry Pi OS 的 microSD 卡。
7. 最后连接树莓派电源并开机。

接线关系如下：

```text
互联网
  │
路由器 ── LAN 口 ── 网线 ── 树莓派网口
                              │
                              └── USB 3.0 ── 带供电硬盘盒 ── 硬盘
```

## 3. 写入 Raspberry Pi OS 并开启 SSH

1. 在电脑上下载并打开 [Raspberry Pi Imager](https://www.raspberrypi.com/software/)。
2. 推荐选择 **Raspberry Pi OS Lite (64-bit)**。
3. 选择 microSD 卡。
4. 打开系统自定义设置，填写：
   - 主机名，例如 `mynas`；
   - 用户名和强密码；
   - 所在国家、时区和键盘布局；
   - Wi-Fi 可作为网线故障时的备用网络；
   - 在“服务”中开启 **SSH**，初次使用可选择密码认证。
5. 写入完成后，将 microSD 卡插入树莓派并开机。
6. 第一次启动通常需要 3～5 分钟。

如果没有开启 SSH，而且树莓派也没有连接显示器和键盘，电脑将无法远程进入树莓派。此时最简单的处理方式是重新用 Imager 写卡并开启 SSH。

## 4. 在电脑上通过 SSH 登录树莓派

SSH 命令运行在你的电脑上，不是在树莓派本机上：

- Windows：打开 PowerShell 或 Windows Terminal。
- macOS：按 `Command + Space`，搜索“终端”或“Terminal”。
- Linux：打开 Terminal，常见快捷键为 `Ctrl + Alt + T`。

运行：

```bash
ssh <Imager 中设置的用户名>@mynas.local
```

例如用户名是 `pi`：

```bash
ssh pi@mynas.local
```

第一次连接会询问是否信任设备，确认主机名和网络无误后输入 `yes`，再输入 Imager 中设置的密码。输入密码时终端不会显示星号，这是正常现象。

如果 `mynas.local` 找不到设备，请登录路由器管理页面，在“已连接设备”或“DHCP 客户端”中查找树莓派 IP，然后运行：

```bash
ssh 用户名@192.168.x.x
```

## 5. 在电脑和树莓派上安装 Tailscale

Tailscale 用于让电脑安全访问树莓派，不需要把 NAS 端口直接暴露到公网。

1. 在电脑上打开 [Tailscale 下载页](https://tailscale.com/download)，安装并登录账号。
2. SSH 登录树莓派后，在同一个终端窗口运行：

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

3. 终端会显示一个授权网址。在电脑浏览器中打开它，并登录与电脑端相同的 Tailscale 账号。
4. 如果账号下有多台服务器或多台树莓派，请根据设备名、操作系统和 Tailscale IP 选择正确设备，不要只看“在线”状态。

## 6. 安装 MyNAS 服务

v0.3.1 的通用一键初装程序仍在开发中。当前项目维护者从 Windows 工作区执行经过测试的部署脚本，把后端、网页、systemd 服务和 `mynas-setup` 安装到指定树莓派：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\MyNAS\deploy\deploy.ps1 -PagesOrigin https://mynas-rsp.pages.dev
```

这条命令包含项目维护者的 SSH 设备配置，不能原样用于任意新树莓派。普通用户不要随意修改并执行生产部署脚本。后续版本会提供可下载、可校验的一键安装包。

部署完成后，树莓派应满足：

- `mynas` 服务处于 `active (running)`；
- Tailscale Serve 已将私有 HTTPS 地址转发到 `127.0.0.1:8080`；
- 终端中可以运行 `sudo mynas-setup`；
- 在公共 MyNAS 页面中可以通过设备的 `https://设备名.tailxxxx.ts.net` 数据地址完成健康检查；不要把私有地址作为日常网页入口。

## 7. 接入第一块或新增硬盘

安装好 MyNAS 服务后，通过 SSH 登录树莓派并运行：

```bash
sudo mynas-setup
```

向导会：

1. 扫描硬盘并排除正在运行 Raspberry Pi OS 的系统盘；
2. 显示设备路径、型号、容量和文件系统；
3. 支持保留已有 `ext4`、`NTFS3`、`exFAT` 数据接入；
4. 对空白盘或需要初始化的硬盘要求输入完整擦除确认文字；
5. 按 UUID 写入 `/etc/fstab`，挂载到 `/mnt/mynas/<volume-id>`；
6. 更新 `/etc/mynas/volumes.json` 并重启 MyNAS。

请认真核对设备路径和容量。**格式化会永久删除所选硬盘上的数据，MyNAS 不会替你恢复。** 有重要文件的硬盘应先在另一台设备上完成备份。

## 8. 打开网页并完成首次连接

1. 确认电脑端 Tailscale 已登录并显示“已连接”。
2. 所有用户都打开同一个 [MyNAS 公共入口](https://mynas-rsp.pages.dev/)。这是共享的网页前端，不保存硬盘文件，也不需要为每台树莓派单独部署网页。
3. 第一次使用时，按照网页中的首次连接向导操作；在“设置 → 多 MyNAS 设备”中添加你自己的 `https://<设备名>.<你的 tailnet>.ts.net` 私有地址。
4. 如果连接失败，建议先关闭 Clash Verge、Surge 等软件的 **系统代理 TUN/增强模式**，然后回到网页点击“重新连接”。普通系统代理通常不必关闭。
5. 不要直接打开或收藏设备的 `*.ts.net` 私有数据地址。它只用于公共网页连接你的树莓派；如果代理冲突发生在页面加载前，直接打开私有地址也无法显示诊断提示。
6. 给树莓派 MyNAS 设置容易识别的名称，例如“客厅 NAS”或“书房备份”。
7. 如果有多台 MyNAS，在“设置 → 多 MyNAS 设备”中分别添加、命名和切换。
8. 在主页查看每块硬盘的容量、已用空间和在线状态；点击硬盘卡片可以查看详情或重命名。

完成配对后，浏览器会记住这台设备。以后如果树莓派离线，页面会显示重新连接提示，而不会重复展示完整的新手安装教程。

## 9. 日常使用注意事项

- 不要在上传、复制、移动或校验文件时拔掉硬盘。
- 拔盘前应停止相关任务，并在树莓派终端执行 `sudo umount 挂载点`；确认卸载成功后再断开硬盘电源。
- 3.5 英寸机械硬盘长期运行时需要通风和稳定供电。
- MyNAS 不是备份本身。重要文件至少保留两份，并且其中一份不应长期连接在同一台树莓派上。
- 不要把树莓派的 8080 端口直接映射到公网。当前版本推荐通过 Tailscale 访问。
- 定期安装 Raspberry Pi OS 安全更新，并关注 MyNAS GitHub Release 的升级说明。

## 10. 常见问题

### 网页提示树莓派未连接

依次检查树莓派电源、路由器网线、电脑端 Tailscale、树莓派端 Tailscale 和 MyNAS 服务状态：

```bash
tailscale status
systemctl status mynas
```

### 树莓派检测不到硬盘

检查硬盘盒电源、USB 线和 USB 3.0 接口，然后在树莓派终端运行：

```bash
lsblk -o NAME,SIZE,FSTYPE,MODEL,MOUNTPOINTS
```

### 硬盘反复离线

最常见原因是供电不足、USB 转 SATA 芯片兼容性或线材问题。先更换带独立电源的硬盘盒或有源 USB Hub，再检查系统日志：

```bash
journalctl -k -n 100 --no-pager
```

### 可以不使用 Tailscale 吗

同一局域网内未来可以提供本地账号模式；当前 v0.3.1 的远程访问和身份边界仍依赖 Tailscale，不建议直接暴露到公网。
