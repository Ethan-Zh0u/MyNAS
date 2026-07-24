# MyNAS Photos — 产品需求与完整性约定

## 产品边界

MyNAS Photos 是一款 iOS 照片管理与备份应用，目标体验类似 Google Photos，但数据路径不同：照片和视频默认保存在用户自己拥有的 MyNAS 中，访问通过其 tailnet 完成。产品不建立中心化照片云，不把照片上传到第三方照片服务，也不在树莓派上运行大型 AI 模型。

应用可以展示用户允许访问的 iPhone Photos，也可以在后续阶段展示同一用户 MyNAS 上的照片。两种来源的统一时间线是目标，不是当前已实现功能。阶段与当前完成度以 [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) 为唯一依据。

## 用户承诺

- 只读取用户在 Photos 权限中允许的项目；Limited 权限必须直说“仅部分照片”，不得暗示已访问完整图库。
- 网格缩略图不隐式从 iCloud 下载完整资源。显式的用户备份动作可以下载所选 asset 的原始 PhotoKit 资源，并必须展示等待/失败原因。
- 每个账号、请求、后台任务、缓存文件和服务端记录均以 `serverID + userID`（或 `accountID`）隔离。切换账号不能复用另一账号的缓存或上传会话。
- 所有类似 UI 组件优先使用公开的 iOS 原生 Liquid Glass 能力；系统不支持时使用系统 Material/控件回退，不仿制私有 API。
- 用户可以随时停留在“仅本地图库”模式；连接 MyNAS 不是读取本地图库的前提。

## 备份完整性：asset，而不是 JPEG

备份单位是一个 PhotoKit asset，不是单张导出的 JPEG。客户端必须导出 `PHAssetResource.assetResources(for:)` 返回的全部原始资源，并保留每个资源的字节、原始文件名、UTI/content type、resource role、大小和 SHA-256。

这意味着：

- Live Photo 的静态照片与 `pairedVideo`/`fullSizePairedVideo` 是一个组；任何一个缺失都不能完成该 asset。
- HDR、ProRAW、RAW、DNG、alternate photo、adjustment/base/full-size 资源和原始视频必须保留原字节，不得以普通 JPEG 代替。
- 客户端和服务端都以 manifest fingerprint、资源 SHA-256、owner 和 volume 做准确性/去重判断；文件名只能显示，不能单独判重。
- 服务器必须校验每个分片和完整文件 SHA-256，并仅在整组资源满足条件后写入 asset/resource/设备映射元数据。

## 三层备份语义

为避免误导删除决策，产品文案、数据库状态和测试必须区分：

| 语义 | 必需条件 | 当前情况 |
| --- | --- | --- |
| 原始资源已安全上传 | 全部资源导出；服务端完整 SHA-256；同卷原子文件提交和元数据写入；按 owner/volume 去重 | 阶段 D 已实现首版 |
| 完整可浏览备份 | 原始资源安全上传，且本版本规定的 tiny/grid/preview 成功并可授权读取 | 未实现；不能用当前 `backedUp` 字段替代 |
| 可在保留 MyNAS 后删除本机 | 完整可浏览备份、可恢复/导出已验收、删除与回收站策略生效 | 未实现；不得提供此承诺 |

兼容字段 `photo_assets.backup_state = "backedUp"` 和队列 `completed` 仍只表示第一行。E1 已加入 source/derivative 状态并把用户文案改为“原件已安全上传”，但 E2–E4 完成前仍不具备完整可浏览备份；阶段 H 之前禁止把它用于删除本机照片的判断。

## 当前已交付的用户能力

- 本地照片和视频的日期倒序分页网格、方形居中裁剪缩略图、详情、长按/选择、多列捏合缩放（2–10 列）和基础本地类型/日期搜索。
- Photos 权限、Limited 管理、iCloud-only 缩略图状态和无可访问项目状态。
- iOS 原生底栏、iOS 26+ Liquid Glass 选中/重点控件与低版本系统回退。
- Tailscale `*.ts.net` 地址连接、二维码配对、稳定账号/卷选择、多账号切换和缓存命名空间。
- 用户手动启动的原始资源备份队列：多资源导出、SHA-256、4 MiB 分片、前台网络重试/重开续传、服务端校验与去重。

远程照片浏览、统一时间线、自动备份、导出/删除/缓存清理、AI 和灾难恢复仍不是当前用户能力。

## 平台与安全限制

- PhotoKit 不允许第三方 App 拦截用户在 Apple Photos 或其他 App 中的删除；应用只能从变化通知中发现变化。
- 公开 PhotoKit API 对某些编辑后的资源导出存在系统限制。若无法取得所需资源，必须明确失败并保留本机项目，不能降级伪装为完整备份。
- App 不实现 Tailscale 登录、不保存 Tailscale 密码或 OAuth token；认证由官方 Tailscale App、tailnet ACL 和 Tailscale Serve 完成。
- 如果未来支持应用层凭据，它们必须进入 Keychain，不能写入账号 JSON、缓存、日志或二维码。
