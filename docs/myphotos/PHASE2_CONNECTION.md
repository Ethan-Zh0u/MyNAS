# MyNAS Photos — 私有 MyNAS 连接与配对指南

> 本文件保留历史文件名以避免旧链接失效。它描述的是权威路线图中的**阶段 C：私有 MyNAS 连接、配对与账号隔离**，不再定义含混的“Phase 2”。状态和后续顺序见 [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md)。

## 三层职责

```text
官方 Tailscale iOS App       MyNAS Photos                  MyNAS / Tailscale Serve
完成 SSO 与 VPN 登录      →  调用 *.ts.net 私有 API  →  验证 tailnet 权限并注入身份
```

MyNAS Photos 不实现 Tailscale 密码登录，不保存 Tailscale OAuth token。用户先在官方 Tailscale App 登录并连上 VPN；MyNAS Photos 以普通 `URLSession` 调用 `https://<机器>.<tailnet>.ts.net`。生产 MyNAS Go 服务应只监听 `127.0.0.1:8080`，由 `tailscale serve` 代理 HTTPS 请求。

## MyNAS 设备准备

1. 在 MyNAS 安装并登录 Tailscale，配置 ACL/Grants 让目标 iPhone 身份可访问设备。
2. 开启 MagicDNS 和 HTTPS；机器名会出现在地址/证书相关记录中，不应含敏感文字。
3. 以生产模式启动 MyNAS，保持 `MYNAS_LISTEN=127.0.0.1:8080`。
4. 配置并核对 `tailscale serve` 指向 loopback API，例如 `tailscale serve status` 应显示标准 `https://*.ts.net` 地址。
5. 部署具有 Photos 接口的 MyNAS 0.5.0；当前已实现 capabilities、pairing、me、volumes 和原始资源上传 session。

## 配对二维码

服务器 `GET /api/v1/photos/pairing` 可生成以下版本化 JSON，网页可将其编码成二维码：

```json
{
  "format": "mynas-photos-pairing",
  "version": 1,
  "serverURL": "https://rsp.tail681937.ts.net",
  "serverID": "srv-..."
}
```

- 二维码不能包含 password、cookie、token 或照片路径。
- `serverURL` 必须是服务器配置的标准 HTTPS `*.ts.net` 根地址。
- iOS 使用原生 VisionKit 扫码；相机不可用时保留粘贴/手动输入。
- 扫码不授予权限，也不绕过验证：握手得到的 capabilities server ID 必须等于二维码 server ID，否则取消连接。

## iPhone 连接步骤

1. 安装官方 Tailscale，允许 VPN 配置，使用获准访问该 MyNAS 的 tailnet 身份登录并连接。
2. 打开 MyNAS Photos → 设置 → 连接 MyNAS（或添加另一台 MyNAS）。
3. 扫描二维码，或手动输入完整根地址；App 拒绝 HTTP、IP、非 `*.ts.net`、端口、子路径、query 和 fragment。
4. App 依次执行：
   - `GET /api/v1/photos/capabilities`：检查 API、最低 App 版本、server ID 和能力边界；
   - `GET /api/v1/photos/me`：由可信 Tailscale 身份取得稳定 server user ID；
   - `GET /api/v1/photos/volumes`：取得可选卷，不接收 mount/device 路径。
5. 三步成功且 server ID 一致后才保存账号，选择默认在线卷（否则选择第一个在线卷）并切换到该 server/user 缓存命名空间。

App 对 MyNAS 的专用 URLSession 将 `connectionProxyDictionary` 设为空，以避免开发 Mac/模拟器的 `127.0.0.1:7897` PAC/系统代理错误转发私有 tailnet TLS 流量。这只是禁用代理发现，**不是**禁用 TLS 验证。

## 本机保存与移除连接

Application Support 的账号 JSON 仅保存服务器 URL、server/user ID、显示名、capabilities、卷和当前账号，且使用 `completeUntilFirstUserAuthentication` Data Protection 原子写入。当前没有 App 自有凭据；若将来加入局域网账号或 OAuth，秘密必须进入 Keychain，不能写入二维码或 JSON。

“移除此连接”只删除本机连接元数据，不退出 Tailscale，不删除 MyNAS 内容，也不清除未来应由缓存管理页面单独处理的缓存。

## 常见错误

| App 提示 | 可能原因 / 处理 |
| --- | --- |
| 地址无效 | 使用了 HTTP、IP、端口、子路径、query 或非 `*.ts.net` 地址；改为完整 HTTPS 根地址。 |
| 无法通过 Tailscale 找到 MyNAS | iPhone Tailscale 未连接、NAS 离线、MagicDNS/ACL 或地址错误。 |
| 没有收到 Tailscale 用户身份 | 绕开 Serve、反代配置错误，或 tagged device 没有用户身份头。 |
| 服务器尚不支持 Photos | MyNAS 版本过旧或未知 API 被 SPA 返回；部署带 Photos 接口的 0.5.0。 |
| 要求更高 App 版本 | capabilities 的 `minimumClientVersion` 高于当前 App。 |
| 服务器身份发生变化 | 二维码/第一次 capabilities 与后续 me 的 server ID 不一致；停止连接并核查 URL。 |

连接完成只证明阶段 C 的身份和卷边界已经建立。它不自动上传照片；手动原始资源入库属于阶段 D，远程可浏览备份属于阶段 E。
