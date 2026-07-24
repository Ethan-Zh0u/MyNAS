# MyNAS Photos — 安全、隐私与完整性模型

## 资产与信任边界

照片/视频原件、缩略图、拍摄时间、定位、OCR、人物索引、账号缓存、Tailscale 身份和上传 session 都是敏感资产。信任路径是：

```text
iPhone Photos 权限 → MyNAS Photos → Tailscale → Tailscale Serve → loopback Go API → 已注册用户卷
```

公共网页不能成为照片数据代理，通用文件 API 也不能代替 Photos 的 owner/resource 模型。数据默认留在用户 iPhone 和 MyNAS；默认不发送中心化遥测，不上传第三方照片服务。

## 当前控制与证据

| 威胁 | 当前控制 | 证据 / 余留风险 |
| --- | --- | --- |
| 伪造身份头 | 生产后端预期 loopback listener；Tailscale Serve 负责去除伪造头并注入真实身份；middleware 拒绝无身份请求 | `main.go`、`TestPhotosRoutesRejectMissingTailscaleIdentity`；部署必须持续验证 Serve 配置 |
| 错误服务器/中间人 | iOS 只接受根 `https://*.ts.net`，二维码/握手验证 server ID；专用 session 禁用系统代理但保留 TLS | `MyNASConnectionService.swift`；不允许以“修复代理”为由跳过证书验证 |
| 跨用户上传/会话访问 | session 查找和提交带 `owner_user_id`，设备映射主键含 owner，去重键含 owner+volume | `photos_uploads.go`；远程读取 API 尚未实现，阶段 E 必须另测 owner 授权 |
| 路径穿越/符号链接 | 原件目录从 server opaque owner/asset ID 构造；输入文件名经清理，DB 仅存相对路径 | 当前 Photos 代码；阶段 E/H 必须对每次读取再做 owner/path 校验和 symlink 测试 |
| 分片篡改/破损 | 4 MiB 上限、offset、`X-Chunk-SHA256`、每块 `File.Sync`、完成时完整 SHA-256 | 坏 chunk checksum 与 Live Photo 未完整测试；目录 fsync/断电语义尚未验收 |
| 误把低质量副本当备份 | 导出全部 `PHAssetResource`，不转 JPEG；E1 已拆分 source/derivative 状态并修正文案 | 兼容字段 `backedUp` 仍存在；E2–E4 必须证明 required outputs 可授权读取后才产生 browse-ready |
| 转码损坏原件 | E2 worker 只以只读路径调用 FFmpeg，处理前后比较选定原件 SHA-256，输出位于独立 derivatives 目录 | 自动化已覆盖原件不变；0.6.0 上线前后已完整复核 43/43 个原件 SHA-256 |
| 账号串缓存 | account/server/user namespace；账号和队列 Data Protection 原子写入 | `AccountContext`、两份 persistence store；缓存实体/LRU 尚未实现 |
| 本地照片过度访问 | 用户授权、Limited 管理、缩略图不隐式 iCloud 下载 | `PhotoLibraryClient`；显式备份允许 iCloud 下载，必须是用户触发 |
| 日志/遥测泄露 | 不设计默认中心化遥测；文档禁止记录媒体内容/秘密 | 后续日志、诊断和 AI 索引必须落实脱敏/删除策略 |
| 删除误操作 | 当前不提供 Photos 删除/远端照片删除流程 | 阶段 H 前不能声称“保留 NAS 后可删本机” |

## 当前不可宣称的保证

1. **不能宣称完整可浏览备份。** 当前没有 derivative queue、tiny/grid/preview、远程浏览或恢复 API；原始资源 hash 成功不等价于用户可以浏览或恢复。
2. **不能宣称灾难恢复级原子提交。** rename 和 SQLite transaction 覆盖常规错误路径，但没有 crash journal、目录 fsync 策略、孤儿扫描或断电故障注入。
3. **不能宣称后台自动备份。** 当前为用户点击的前台 `URLSessionConfiguration.ephemeral` 上传，虽可在重开 App 时续传，但不是 system background transfer。
4. **不能宣称跨端删除或隐私 AI。** 这些功能尚未实现，且必须另行通过 PhotoKit、回收站和模型数据隐私审查。

## 下一阶段安全门槛

### 阶段 E：远程浏览

- asset list、changes、文件读取和缓存均以 owner 验证为先，且不得暴露真实路径、其他用户 ID 或身份头。
- derivative job 应是幂等的，记录 recipe/input/output 版本和失败原因；原件与派生状态分开。
- 对 cursor、ETag、Range、缓存串号、越权 ID 猜测、损坏 derivative 和重建进行自动测试。

### 阶段 G/H：自动、恢复与删除

- background URLSession task 和 BGTask 均永久绑定 account；换账号/卷/退出时不误发到另一个用户。
- 下载/导出验证 hash，缓存可清除但不影响服务器原件。清理顺序优先临时完整文件、旧 preview、旧 thumbnail。
- 删除默认软删除；本机删除需要 PhotoKit 系统确认。仅在 browse-ready、恢复演练和用户二次确认均满足时，才提供“仅保留 MyNAS”。

### 阶段 I/J：AI、规模与恢复

- OCR/embedding/人物分类必须 owner-scoped、可删除、默认不上传中心化服务；不做跨用户识别。
- 引入 schema version、migration journal、完整性扫描、SQLite/卷恢复演练、密钥/配置轮换程序和不含媒体内容的诊断策略。
