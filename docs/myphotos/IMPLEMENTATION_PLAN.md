# MyNAS Photos — 权威交付路线图与当前状态

> **这是阶段、状态和验收标准的唯一权威来源。** 其他 `docs/myphotos` 文档只说明各自领域的设计与当前事实，不另行维护阶段编号或状态。历史文件名 `PHASE2_CONNECTION.md` 仅为兼容已有链接；它现在对应本文件的“阶段 C”，不是一个可复用的“Phase 2”定义。

## 审计基线（2026-07-24）

| 项目 | 已核查事实 | 证据 |
| --- | --- | --- |
| 版本 | MyNAS 后端声明和仓库 `VERSION` 均为 `0.7.0`；iOS target 的 `MARKETING_VERSION` 为 `1.0`。 | `backend/photos_phase2.go`、`VERSION`、`ios/MyPhotos/MyPhotos.xcodeproj/project.pbxproj` |
| 代码状态 | Photos 后端文件、iOS 项目和本目录文档均为未跟踪的工作区交付物；另有 `VERSION`、后端入口和前端文件的用户改动。不得覆盖或提交这些改动。 | `git status --short` |
| 后端测试 | 有握手、配对、卷信息保护、Live Photo 多资源续传、分片 hash 拒绝、未完整组拒绝、E1 旧 schema 幂等迁移/任务补建，以及 E2 成功、幂等、失败和重启恢复测试；`go test -race ./...`、`go vet ./...` 与部署脚本回归通过。 | `backend/photos_phase2_test.go`、`photos_uploads_test.go`、`photos_derivatives_test.go`、`photos_derivative_worker_test.go`；本轮命令记录 |
| iOS 验证 | 项目没有可发现的 iOS 单元测试 target；E1 已使用 Xcode 27 beta 对 iPhone 17 Pro 模拟器目标构建成功并安装启动，界面显示“原件已上传”语义。另有 iPhone 16 Pro 人工验证及真实端到端上传与大视频续传记录。 | Xcode 工程、本轮构建/模拟器验收、用户提供的部署/验收记录 |
| 已部署能力 | 树莓派 MyNAS `0.7.0` 已于 2026-07-24 部署；Tailscale HTTPS health 返回实时 CPU 温度，capabilities 返回状态模型 v1、`photos-browse-v1` 和三项 derivative recipe。43 个旧 asset 已迁移并完成 129 个派生文件，处理中的服务重启恢复通过。 | 真实部署健康检查、数据库状态与 systemd 重启验收 |
| E1/E2 状态 | 状态模型、兼容迁移、持久化任务、单线程幂等 derivative worker 和 iOS 原件/可浏览文案已经实现并部署；上线前后的 43/43 原件 SHA-256 一致，129/129 派生 JPEG 的 hash、尺寸和元数据一致，SQLite 完整性正常。树莓派 FFmpeg 7.1.5 已验证 JPG/HEIC/MP4/MOV；真实 DNG/ProRAW 与 Live Photo 派生选择仍缺样本验收。 | `backend/photos_derivatives.go`、`photos_derivative_worker.go` 及测试、iOS backup models/views；2026-07-24 部署验收记录 |

### 术语与状态约束（先于所有阶段）

一个 **PhotoKit asset** 是备份单位，且必须包含 `PHAssetResource.assetResources(for:)` 返回的全部原始资源。Live Photo 的静态照片和配对视频、HDR、RAW、ProRAW、DNG、调整资源和原始视频均不得用 JPEG 替代。

当前必须区分以下三种状态：

1. **本地队列完成 / 原始资源已安全上传**：所有资源已导出、SHA-256 已在服务端重新校验、文件已移入 originals，且 asset/resource/设备映射元数据已写入。阶段 D 实现的是这个状态。
2. **完整可浏览备份**：在第 1 项之外，约定的 tiny、grid、preview 等衍生文件已成功生成、可授权读取且能从远端时间线浏览。阶段 E 完成前不得对用户宣称达到该状态。
3. **可用于保留 MyNAS 后删除本机的备份**：在第 2 项之外，恢复/导出、回收站和删除确认策略均已验收。阶段 H 完成前不得提供该承诺。

兼容字段 `photo_assets.backup_state = "backedUp"` 仍保留，但 E1 已新增 `source_state`、`derivative_state` 和 recipe version，并把 iOS 文案改为“原件已安全上传”。只有 `derivative_state = ready` 才能形成 `browseReady`；所有阶段的“完成”均指阶段目标，不可据此跳过上述状态边界。

## 阶段一览

| 阶段 | 可交付成果 | 当前状态 | 下一道门槛 |
| --- | --- | --- | --- |
| A | 产品边界与工程基础 | 已完成 | 保持文档与版本事实一致 |
| B | 本地图库与应用外壳 | 已完成 | 补足可访问性/真机回归自动化 |
| C | 私有 MyNAS 连接、配对与账号隔离 | 已完成 | 持续在真实 tailnet 回归 |
| D | 手动原始资源备份（安全入库） | 已完成（首版） | 做崩溃一致性硬化；不能视为可浏览备份 |
| E | 衍生文件、远程图库与可浏览备份 | 进行中（E1 完成；E2 已部署并通过当前样本验收） | 补充 DNG/Live Photo 样本并进入 E3 读取 API |
| F | 本地/远程统一时间线与去重 | 未开始 | 依赖 E 的远端索引和版本模型 |
| G | 后台自动备份 | 未开始 | 依赖 D 的稳定恢复语义及 iOS 后台策略 |
| H | 恢复、导出、删除与缓存管理 | 未开始 | 依赖 E；删除还依赖完整可浏览备份 |
| I | 端侧 AI 搜索、人物/物体分类 | 未开始 | 依赖受控本地索引和隐私设计 |
| J | 大规模、灾难恢复与版本升级 | 部分完成 | 通用卷/健康基础已有，Photos 专项韧性未做 |

## 阶段 A — 产品边界与工程基础

- **阶段目标：** 固化“用户自有 MyNAS 优先”的产品边界，并建立可演进的 iOS、Go、SQLite 和文档基线。
- **用户可见成果：** 用户知道照片保留在自己的 MyNAS，不存在中心化 Photos 云或第三方照片服务上传。
- **iOS 端改动：** `MyNAS Photos` iOS 18+ 工程、PhotoKit 用途说明、SwiftUI 根视图和账号/缓存抽象已建立。
- **MyNAS 后端改动：** Go `/api/v1` 服务、SQLite、卷注册、健康检查、Tailscale Serve loopback 部署边界可用。
- **数据模型/API 变化：** 稳定 volume ID、应用设置和健康 API 为 Photos 交付提供基础；尚不把通用 file/upload API 当作 Photos API。
- **前置依赖：** 无；后续每一阶段均依赖此边界。
- **验收标准和测试方法：** 审查产品需求、部署配置和公开接口，确认没有中心化存储路径或第三方上传 SDK；编译 iOS 工程并运行 Go 测试/vet。
- **明确不包含：** 远程照片浏览、自动备份、AI、跨设备删除。
- **状态与证据：** **已完成。** iOS 工程 target 为 iOS 18；后端已有 health/volumes/上传基础；`PRODUCT_REQUIREMENTS.md`、`ARCHITECTURE.md`、`SECURITY.md` 均明确自托管边界。

## 阶段 B — 本地图库与应用外壳

- **阶段目标：** 让用户安全、高效地浏览系统授权给 App 的本地照片和视频。
- **用户可见成果：** 本地时间线、居中裁剪方形缩略图、双指改变每行 2–10 列、详情、多选、基础搜索、人物/相册占位页、原生 Liquid Glass 风格底栏和显眼的备份入口。
- **iOS 端改动：** `PhotoLibraryClient` 分页读取/观察 PhotoKit；`PHCachingImageManager` 缩略图预热；Limited、拒绝和 iCloud-only 状态；iOS 26+ 使用 `glassEffect` / `glassProminent`，旧系统回退 Material/系统按钮。
- **MyNAS 后端改动：** 无 Photos 依赖。
- **数据模型/API 变化：** UI 只持有 Sendable 的 `LocalPhotoAsset`，不跨线程保存 `PHAsset`；本地搜索目前只匹配媒体类型和日期。
- **前置依赖：** 阶段 A；用户授予 Photos 的完整或 Limited 权限。
- **验收标准和测试方法：** 在 iPhone 17 Pro 模拟器及 iPhone 16 Pro 检查授权、网格、捏合、滚动、视频/Live Photo 标记、Limited、动态字体、横屏、深色、VoiceOver 和 iCloud-only；确保网格请求 `isNetworkAccessAllowed = false`。
- **明确不包含：** 远程照片、服务器缩略图、语义搜索、删除本机照片。
- **状态与证据：** **已完成。** `PhotoTimelineView.swift`、`PhotoLibraryClient.swift`、`MyPhotosRootView.swift`；既有模拟器/真机人工验证记录。iOS 自动化 UI/单元测试仍是质量欠账，不影响已交付范围的事实。

## 阶段 C — 私有 MyNAS 连接、配对与账号隔离

- **阶段目标：** 通过用户已登录的 Tailscale 安全地连接指定 MyNAS，并把身份、卷和缓存隔离到 server/user 边界。
- **用户可见成果：** 分步连接引导、扫码/手动 `https://*.ts.net` 地址、清楚的 Tailscale 错误、服务器/账号/卷选择与多账号切换；不保存 Tailscale 密码或 OAuth token。
- **iOS 端改动：** `MyNASConnectionService` 顺序握手 capabilities → me → volumes，严格标准 HTTPS `*.ts.net` 根地址校验，二维码 server ID 比对；`AccountPersistenceStore` 使用 Data Protection 原子保存；MyNAS 专用 `URLSession` 清空 `connectionProxyDictionary`，但不绕过 TLS 验证。
- **MyNAS 后端改动：** `/photos/capabilities`、`/pairing`、`/me`、`/volumes`；Tailscale 身份映射为稳定 `photo_users.id`；卷响应不泄露 mount/device。
- **数据模型/API 变化：** `AccountContext = serverID + userID`，缓存规范为 `AppCache/<serverID>/<userID>/…`；见 `API.md` 与 `DATA_MODEL.md`。
- **前置依赖：** 阶段 A；设备已通过 Tailscale ACL/Serve 获准访问 MyNAS。
- **验收标准和测试方法：** 真实 `*.ts.net` 上完成三次 GET 与二维码 ID 匹配；测试缺失身份返回 401、路径/端口/HTTP 被拒绝、卷 JSON 无路径；在曾受 127.0.0.1:7897 代理影响的模拟器上确认 TLS 仍正常。
- **明确不包含：** App 内 Tailscale 登录、局域网直连、应用层密码、照片传输本身。
- **状态与证据：** **已完成。** `MyNASConnectionService.swift`、`AccountContext.swift`、`backend/photos_phase2.go`；`photos_phase2_test.go`；用户已验证部署 0.5.0 的健康、能力、用户和卷接口。

## 阶段 D — 手动原始资源备份（安全入库）

- **阶段目标：** 在用户手动触发时，把一个 PhotoKit asset 的所有原始资源完整、可续传地写入用户选定 MyNAS 卷，并以 SHA-256 证明字节一致。
- **用户可见成果：** 设置和照片页可进入备份，显示等待/读取/上传/完成/失败、项目数、进度和已上传/总文件大小；尚未读出全部 PhotoKit 资源大小时会显示待统计项目数；断网后前台重试，重新打开 App 时从服务器已接收的位置续传；Live Photo、HDR、RAW/ProRAW 和视频不转 JPEG。
- **iOS 端改动：** `PhotoLibraryClient.prepareBackupAsset` 导出全部 `PHAssetResource`（显式备份时允许 iCloud 下载），临时文件逐个 SHA-256；`PhotoBackupUploader` 4 MiB 分片、每片 SHA-256、5 次瞬态网络重试；`PhotoBackupCoordinator` 持久化队列并按账号隔离。
- **MyNAS 后端改动：** 创建/读取 session、按 owner/volume/fingerprint 去重、offset 冲突处理、分片和全文件 SHA-256、同卷 rename、asset/resource/mapping SQLite 事务、按 owner 的原件目录。
- **数据模型/API 变化：** 新增 `photo_assets`、`photo_resources`、`photo_upload_sessions`、`photo_upload_resources`、`device_asset_mappings` 及 `/photos/upload-sessions` 协议。兼容字段 `photo_assets.backup_state = backedUp` 仅表示“原始资源安全入库”；E1 的细分状态不改变阶段 D 的验收边界。
- **前置依赖：** 阶段 C、可访问的 PhotoKit asset、在线且空间足够的卷。
- **验收标准和测试方法：** 对普通照片、Live Photo、HDR、RAW/ProRAW/DNG 和大视频，比较每个资源服务端 SHA-256；中断后检查 offset 续传；重复上传验证 owner+volume 去重；未上传完整 Live Photo 必须拒绝提交；检查多账号不能读取/续传对方会话。
- **明确不包含：** 衍生文件、远端照片列表/预览、后台 URLSession/BGTask、删除本机原件或“完整可浏览备份”承诺。
- **状态与证据：** **已完成（首版原始资源安全入库）。** `PhotoBackupUploader.swift`、`PhotoBackupCoordinator.swift`、`PhotoLibraryClient.swift`、`backend/photos_uploads.go`；`TestPhotosMultiResourceUploadResumesVerifiesAndDeduplicates`、坏分片 hash 与不完整 Live Photo 的测试；用户已完成真实媒体及大视频端到端续传验证。

  **需在后续硬化：** 当前实现以 rename 后 SQLite 事务及失败回移组成应用级提交；进程在二者之间崩溃的恢复扫描、目录 fsync 策略、session 过期清理、并发/断电故障注入和可观测的修复流程尚未实现。服务端还把一个 asset 限制为最多 32 个 resource；超过上限必须显式失败而不能丢资源，需用罕见编辑资产验证或调整该上限。因此不能把“代码中的 `backedUp`”扩展解释为灾难恢复级保证。

## 阶段 E — 衍生文件、远程图库与完整可浏览备份

- **阶段目标：** 为安全入库的原件生成受版本约束的 tiny/grid/preview，并提供 owner-scoped 远程列表、资源读取和变更同步。
- **用户可见成果：** 用户能从 MyNAS 浏览照片、缩略图、预览、视频 Range 播放和 Live Photo；仅在所需衍生文件可用时，界面显示“完整可浏览备份”。
- **iOS 端改动：** `ServerAsset`、分页/ETag 缓存、远程缩略图/预览/原图加载、派生处理中 UI；不把失败的 preview 伪装成原件或成功备份。
- **MyNAS 后端改动：** E2 已部署 durable derivative queue、单线程幂等 FFmpeg worker、recipe/version、失败退避和重启恢复；资源授权、`assets`/`changes`/受控 Range 下载属于 E3。
- **数据模型/API 变化：** E1 已为 asset 加入 `source_state`、`derivative_state`、recipe/version/error/updated_at，并新增 `photo_derivatives` 与 `photo_derivative_jobs`；后续实现 `GET /photos/assets`、`/changes`、`/assets/{id}`、`/{tiny|grid|preview|original}`。读取路由仍未实现；当前部署在 FFmpeg processor 可用时发布三项 recipe，工具缺失时仍保持空数组。
- **前置依赖：** 阶段 D；明确每种媒体的 required derivative policy 和低资源树莓派转码预算。
- **验收标准和测试方法：** 新上传及重启后重建任务；校验 owner 越权为 404/403、不泄露路径；ETag/条件请求、分页/cursor 过期、Range、Live Photo 配对展示；任何 required derivative 缺失时，状态必须不是“完整可浏览备份”。
- **明确不包含：** 本地/远端合并时间线、后台自动扫描、删除工作流、AI。
- **状态与证据：** **进行中。E1 完成；E2 已于 2026-07-24 以 MyNAS 0.6.0 部署，并通过当前真实样本验收。** 旧 `backedUp` asset 已幂等迁移为 `sourceCommitted + pending` 并获得任务；worker 校验候选原件 SHA-256，生成独立 JPEG tiny/grid/preview，重新校验输出，并只在三项齐全后原子提交 metadata 与 `ready`。43/43 asset 已变为 `sourceCommitted + ready`，43 个任务 completed，129/129 输出复核通过；处理中重启后同一任务被重新领取且最终无失败。上线前后 43/43 originals SHA-256 一致，SQLite `integrity_check=ok`，服务无 warning。`go test -race ./...`、`go vet ./...` 通过。DNG/ProRAW 和 Live Photo 因当前真实测试库缺对应资源组仍未验收；asset list/changes/resource 路由和远程网格也未实现，因此阶段 E 未完成。

## 阶段 F — 本地与远程统一时间线及去重

- **阶段目标：** 在一个按时间排序的界面中合并可访问的本机与 MyNAS 项目，并可解释地识别同一 asset/内容。
- **用户可见成果：** 单一时间线显示本地、仅远端和已关联项目；不会因文件名相同而错误合并。
- **iOS 端改动：** 统一 timeline view model、分页合并、来源/同步状态、冲突 UI、仅按必要范围缓存元数据。
- **MyNAS 后端改动：** cursor 变更日志、asset version、设备映射读取和 owner scoped metadata 查询。
- **数据模型/API 变化：** 依序使用 `localIdentifier + device mapping`、asset ID、manifest/资源 SHA-256、时间/尺寸和 Live Photo 资源组；文件名只能作显示信息，不能作唯一依据。
- **前置依赖：** 阶段 E 的远端索引、可读取的版本和明确的 merge policy。
- **验收标准和测试方法：** 同设备重复、不同设备相同内容、相似时间但不同照片、编辑后版本和 Live Photo 组的测试；离线/分页/过期 cursor 回归。
- **明确不包含：** 自动上传调度、删除、AI 自动聚类。
- **状态与证据：** **未开始。** iOS 仅有 `LocalPhotoAsset` 时间线，`ServerAssetPage` 只是空协议占位；后端无远端 asset list API。

## 阶段 G — 后台自动备份

- **阶段目标：** 在系统允许的时间、网络与电源条件下持续发现变化并可靠上传，而不误称 iOS 后台执行为无限制常驻任务。
- **用户可见成果：** 用户可设置自动备份与网络策略，看到“待处理/等待系统/上传/验证/暂停”原因，并可一键暂停。
- **iOS 端改动：** PhotoKit change 增量、BGTaskScheduler、background `URLSession`、持久化任务标识和重启恢复；前后台切换不能丢失 account 绑定。
- **MyNAS 后端改动：** session TTL/清理、幂等 resume、速率/并发限制、可观测状态；必要时为长期 upload session 设计续期。
- **数据模型/API 变化：** 自动备份策略、候选集版本、背景 task/session 映射和失败分类；现有 `backgroundTransfers: false` 必须在实现后才改为 true。
- **前置依赖：** 阶段 D 的可靠恢复语义；真实设备的系统后台限制测试。
- **验收标准和测试方法：** 锁屏、重启、网络切换、低电量、iCloud 原件未本地化、账号/卷切换、服务器重启和 24 小时以上队列回归。
- **明确不包含：** 不保证即时或无限时后台运行；不在无用户许可时上传；不做删除。
- **状态与证据：** **未开始。** 当前是用户点击的前台 `URLSessionConfiguration.ephemeral` 手动流程；capabilities 返回 `backgroundTransfers: false`。

## 阶段 H — 恢复、导出、删除与缓存管理

- **阶段目标：** 让用户安全取回、导出、软删除和管理本地缓存，且绝不以未浏览验证的原件作为删除依据。
- **用户可见成果：** 预览/原件下载或导出、可恢复回收站、缓存空间与 LRU 清理；选择“仅保留 MyNAS”前会检查完整可浏览备份。
- **iOS 端改动：** 下载/导出到系统分享或 Photos、下载校验、缓存索引/LRU、删除确认和清理 UX。
- **MyNAS 后端改动：** owner-scoped original/preview 读取、Range、soft trash/restore、保留期和审计日志；不能复用无 owner 语义的通用文件删除流程。
- **数据模型/API 变化：** `CacheEntry`、trash state、download verification、deletion intent；完成 Stage E 后实现 trash/restore API。
- **前置依赖：** 阶段 E；“完整可浏览备份”状态与恢复演练。
- **验收标准和测试方法：** SHA-256 导出比对、断点下载、低磁盘 LRU、不同账号缓存隔离、单端/双端删除确认、误删除恢复、无衍生文件或验证失败时禁止“保留 MyNAS 后删除本机”。
- **明确不包含：** 绕过 PhotoKit 对其他 App 删除的限制；静默跨端删除。
- **状态与证据：** **未开始。** `StorageProvider`、`CacheDirectoryKind` 是占位；无 Photos 下载、trash、restore 或 cache eviction 实现。

## 阶段 I — 端侧 AI 搜索、人物/物体分类

- **阶段目标：** 在用户设备或其 MyNAS 的受控范围内提供隐私优先的搜索、人物/物体分类和可删除索引。
- **用户可见成果：** 选择性启用的本地语义/人物/物体/文字搜索；可查看并清除索引，人物不自动猜测姓名。
- **iOS 端改动：** Vision/Core ML/本地索引任务、权限说明、结果解释、索引清理与性能/电量策略。
- **MyNAS 后端改动：** 只在明确选择后保存必要索引元数据；树莓派不运行大型模型；不上传中心化服务。
- **数据模型/API 变化：** owner-scoped OCR/embedding/分类版本和删除标记，禁止跨用户检索。
- **前置依赖：** 阶段 F/H 的可控元数据和缓存；隐私审查与低端设备性能基准。
- **验收标准和测试方法：** 离线工作、撤销授权/删除索引、跨账号隔离、误报反馈、热/电量/内存基准。
- **明确不包含：** 云端人脸识别、跨用户身份识别、树莓派大型模型推理。
- **状态与证据：** **未开始。** 人物页和搜索页都明确是占位，当前仅本地类型/日期字符串匹配。

## 阶段 J — 大规模、灾难恢复与版本升级

- **阶段目标：** 让大量资产、多卷故障、数据库/进程异常和版本升级都具备可验证的恢复路径。
- **用户可见成果：** 可理解的容量/健康告警、可恢复的升级、明确的备份完整性报告和恢复演练指引。
- **iOS 端改动：** 大库分页/内存基准、增量同步、升级兼容/迁移提示、诊断包（不含敏感媒体）。
- **MyNAS 后端改动：** 可版本化 migration、备份/恢复 SQLite 元数据、原件清单校验与重建、session/derivative 孤儿回收、卷失效/换盘恢复、指标与限流。
- **数据模型/API 变化：** schema version、migration journal、integrity scan checkpoint、灾难恢复清单和兼容矩阵。
- **前置依赖：** D–H 的稳定数据语义；测试盘和可破坏的演练环境。
- **验收标准和测试方法：** 10 万级元数据和大视频压力、服务重启/断电窗口、数据库恢复、丢失卷、跨版本升级/回滚、随机抽样 SHA-256 审计、从备份恢复到新设备的演练。
- **明确不包含：** 把本机和单块 NAS 宣称为唯一灾备；不承诺未演练的 RPO/RTO。
- **状态与证据：** **部分完成。** 通用 MyNAS 已有健康检查、稳定卷 ID、离线状态和 SQLite 单连接以降低 `SQLITE_BUSY`；Photos 专用 migration version、灾备扫描、断电恢复和大规模基准尚未实现。

## 下一步：补足 E2 格式样本并进入 E3

E2 已部署到真实树莓派，并在不改变 originals 的前提下完成当前媒体库验收。下一道门槛是 **补足特殊格式证据，同时实现受控读取 API**：

1. 加入至少一个 DNG/ProRAW 和一组 Live Photo 测试资产；验证 DNG 可解码或辅助照片回退，且 paired video 原件不被替换。
2. 实现 E3：owner-scoped asset list、changes、grid/preview/original 读取，以及 ETag/Range/越权测试。
3. 用当前 129 个派生文件回归 E3 的分页、条件请求和访问控制；保持路径永不出现在 API 响应中。
4. E4 再在 iOS 增加只读远端网格、处理/失败状态与账号隔离缓存，最后显示真实的“完整可浏览备份”。
