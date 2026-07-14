# 运维与回滚

## 服务

```bash
sudo systemctl status mynas
sudo systemctl restart mynas
journalctl -u mynas -f
tailscale serve status
```

当前私有入口：`https://rsp.tail681937.ts.net/`。后端仅监听 `127.0.0.1:8080`，浏览器身份由 Tailscale Serve 注入。

部署前会确认现有主盘 `/mnt/nas` 已挂载。服务以 `rbp` 身份运行，应用数据为 `/home/rbp/.local/share/mynas`。新增硬盘使用 `sudo mynas-setup` 接入；向导会备份 `/etc/fstab`、按 UUID 挂载到 `/mnt/mynas/<volume-id>`，并更新 `/etc/mynas/volumes.json`，但不会修改 Samba 配置。

## 接入新硬盘

```bash
sudo mynas-setup
```

向导支持 `ext4`、`NTFS3` 和 `exFAT`。已有文件系统默认无损接入；空白盘格式化前必须输入完整的 `ERASE /dev/...` 确认文字。完成后向导会验证 `rbp` 用户写入权限并重启 MyNAS。

## 回滚

列出版本并查看当前版本：

```bash
readlink -f /opt/mynas/current
ls -1 /opt/mynas/releases
```

回滚时把链接切到上一个版本并重启：

```bash
sudo ln -sfn /opt/mynas/releases/<上一个UTC时间> /opt/mynas/current
sudo systemctl restart mynas
systemctl is-active mynas
```

旧版 `/opt/mynas/mynas` 与 `/opt/mynas/web` 仍保留但不再由 systemd 使用。不要删除 `/mnt/nas/.mynas/trash`，除非已确认没有需恢复文件。不要执行 `tailscale serve reset`，除非已确认不会影响该节点其他 Serve 配置。

## Pages

正式项目为 `mynas-rsp`，使用 Wrangler Direct Upload 发布，公共地址是 `https://mynas-rsp.pages.dev/`。树莓派 `/etc/mynas/mynas.env` 的 `MYNAS_ALLOWED_ORIGIN` 已精确设为 `https://mynas-rsp.pages.dev`。现有 `mynas.pages.dev` 与本项目无关，不得覆盖。

## 代理与中国境内网络

Tailscale 在线时，私有地址可经直连或 Tailscale 中继访问；网络质量会影响速度。任何启用系统代理的客户端都要为以下目标配置 DIRECT/绕过：

```text
rsp.tail681937.ts.net
*.tail681937.ts.net
100.64.0.0/10
```

公共 Pages 页面可以独立加载，但 NAS 文件 API 始终要求 Tailscale 身份。无法承诺被网络策略完全阻断 Tailscale 的环境仍可访问。

## 日志与故障排查

```bash
journalctl -u mynas -n 200 --no-pager
journalctl -u mynas -f
tailscale status
tailscale ping rsp
tailscale serve status
findmnt -no SOURCE,FSTYPE,TARGET /mnt/nas
df -h /mnt/nas
```

浏览器显示 `ERR_CONNECTION_CLOSED` 而 `tailscale ping rsp` 正常时，优先检查代理绕过列表；浏览器能打开页面但 API 显示未连接时，确认当前设备登录的是拥有 rsp 权限的 Tailscale 账号。
