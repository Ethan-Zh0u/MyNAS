# MyNAS Photos — 当前架构与演进边界

阶段状态和交付顺序由 [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) 定义。本文件记录代码已存在的边界，以及下一层应该放在哪里。

## 当前端到端路径

```text
SwiftUI（本地时间线 / 设置 / 连接 / 手动备份）
        │ @MainActor 状态
        ├─ PhotoLibraryClient ── PhotoKit / PHCachingImageManager
        │       │
        │       └─ 所有 PHAssetResource → 加密保护的临时目录 → SHA-256
        │
        ├─ AccountStore / AccountPersistenceStore
        │       └─ Application Support/Accounts 与 AppCache/<server>/<user>
        │
        └─ PhotoBackupCoordinator → PhotoBackupUploader
                    │  专用 URLSession；空 proxy 字典，保留系统 TLS 验证
                    ▼
 iPhone ── Tailscale ── https://<machine>.<tailnet>.ts.net ── Tailscale Serve
                                                                  │ 注入可信身份头
                                                                  ▼
                                                        Go (127.0.0.1:8080)
                                                         │        │
                                                         │        ├─ SQLite：用户、asset、资源、session、映射
                                                         │        └─ 已注册卷：staging → users/<hashed-owner>/photos/originals
                                                         ▼
                                                     用户自己的 MyNAS 卷
```

应用不持有 Tailscale 登录凭据。外部请求不能直连 Go listener；Tailscale Serve 应移除客户端伪造身份头后注入真实身份。MyNAS Photos 的 URLSession 显式不使用 Simulator/Mac 的 PAC/loopback proxy，以避免私有 tailnet 地址经 `127.0.0.1:7897` 代理导致 TLS 失败；这不取消 HTTPS 证书验证。

## iOS 分层

| 层 | 当前职责 | 不能承担的职责 |
| --- | --- | --- |
| SwiftUI Views | 呈现本地图库、连接、账号、手动备份队列和状态；iOS 26+ 采用原生 Glass | 直接读取 `PHAsset`、发网络请求或决定备份完整性 |
| View models / stores | `LocalPhotoLibraryViewModel` 管理分页和授权；`PhotoBackupCoordinator` 管理持久化队列及 source/derivative 状态；`AccountStore` 管理当前身份 | 计算文件 hash、泄露跨账号状态、把原件上传解释成可浏览备份 |
| `PhotoLibraryClient` | PhotoKit 授权、分页、缩略图、变更观察和所有 resource 导出 | 远程图库同步、删除 Apple Photos 项目 |
| `PhotoBackupUploader` | manifest、分片、hash header、前台重试、完成请求 | 背景 URLSession、自动调度、预览下载 |
| `MyNASConnectionService` | URL/二维码验证、capabilities/me/volumes 握手 | Tailscale SSO、存储密码、绕过 TLS |
| 持久化/缓存 | 账号 JSON 与备份队列使用 Data Protection；缓存路径以 server/user 隔离 | 当前尚未实现缓存内容、LRU 或下载索引 |

`PHAsset` 仅在 `PhotoLibraryClient` 内使用；UI 传递的是 Sendable 的 `LocalPhotoAsset` 值。网格缩略图使用 `PHCachingImageManager` 与 `isNetworkAccessAllowed = false`，显式备份资源导出才允许 iCloud 下载。

## 后端分层

| 层 | 当前职责 | 已知边界 |
| --- | --- | --- |
| middleware / Tailscale | 身份存在性、写请求 `X-MyNAS-Request: 1`、Origin 规则 | 安全前提是生产 Go 只监听 loopback 且 Serve 配置正确 |
| Photos handshake | capabilities、pairing、稳定 server ID、photo user、可选卷 | `photoAssets: true` 表示可原始入库，不能推导出可浏览图库 |
| 上传会话 | owner-scoped session、manifest、offset、4 MiB 分片 hash、完整文件 hash、去重 | 仅手动/前台客户端；没有 TTL 清理或并发/断电故障注入 |
| 提交 | 同一卷内 stage directory rename 到 originals，再写 SQLite asset/resource/mapping transaction | 当前没有跨文件系统/SQLite 的 crash journal 或目录 fsync 恢复扫描 |
| 衍生 worker | 单线程领取持久化 job；验证原件 hash；FFmpeg 输出到独立 recipe 目录；复核 JPEG/hash 后提交 derivative rows 与 ready | 0.6.0 已部署；DNG/ProRAW 与 Live Photo 真实样本未验收，E3 读取 API 未实现 |
| 远程浏览 | 尚不存在 | 无 assets cursor、changes、preview/original 资源 API；派生文件已生成但客户端不可直接读取 |

## 当前与目标的状态机

```text
本地：waiting → preparing → uploading → sourceCommitted
                                      └→ failed / 等待重试

服务端：waiting → uploading → 完整 hash 校验 → originals + metadata
                                                    │
当前兼容字段：backup_state = "backedUp"（仅 sourceCommitted）
E1 工作区：sourceCommitted → pending / processing → ready / failed
阶段 E 产品语义：ready + required outputs 可授权读取 → browseReady
目标阶段 H：browseReady → restore/export/trash 受控操作
```

`sourceCommitted` 是本文档使用的产品语义名，不是当前数据库枚举值。它避免把原始资源安全入库与“完整可浏览备份”混为一谈。

## 后续架构规则

1. 阶段 E 的 worker 必须与上传提交解耦：原件 hash/元数据完成不依赖耗时转码；派生失败可重试且不损坏原件。
2. 每个 Photos 查询和文件读取都必须先按 owner 过滤 asset，再解析服务器生成的相对路径。不得从请求文件名或通用 file API 推断授权。
3. cursor、ETag、derivative recipe/version 和 asset version 属于远程浏览层；不能塞回本地 `PHAsset` 模型。
4. 自动备份必须使用系统允许的 BGTask/background URLSession，不能把 foreground `Task` 描述为常驻后台服务。
5. 恢复、导出、删除和缓存是独立层。删除本机的资格只来自已验收的 `browseReady` + 恢复路径，不能仅来自原件入库。
