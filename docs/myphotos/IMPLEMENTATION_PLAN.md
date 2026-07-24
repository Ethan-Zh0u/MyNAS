# MyNAS Photos — 权威交付路线图与当前状态

> **这是阶段、状态和验收标准的唯一权威来源。** 其他 `docs/myphotos` 文档只说明各自领域的设计与当前事实，不另行维护阶段编号或状态。历史文件名 `PHASE2_CONNECTION.md` 仅为兼容已有链接；它现在对应本文件的“阶段 C”，不是一个可复用的“Phase 2”定义。

## 审计基线（2026-07-24）

| 项目 | 已核查事实 | 证据 |
| --- | --- | --- |
| 版本 | E3 ProRAW fallback 修正版的 MyNAS 后端声明和仓库 `VERSION` 均为 `0.8.1`；iOS target 的 `MARKETING_VERSION` 为 `1.0`。 | `backend/photos_phase2.go`、`VERSION`、`ios/MyPhotos/MyPhotos.xcodeproj/project.pbxproj` |
| 代码状态 | E3/ProRAW、既有 iOS 功能和文档改动仍在工作区；LaunchScreen 资源另有用户已暂存改动。不得覆盖或擅自提交这些改动。 | `git status --short` |
| 后端测试 | 除握手、上传和 E1/E2 worker 测试外，E3 已覆盖 owner 隔离、分页、changes、ETag/304、Range/206、路径不泄露和正确的 CORS 分片 hash header；`go test -race ./...`、`go vet ./...` 通过。 | `backend/photos_browse_test.go` 及既有 Photos 测试；本轮命令记录 |
| iOS 验证 | 项目没有可发现的 iOS 单元测试 target；E4 首个只读远端图库切片已使用 Xcode 27 beta 对 iPhone 17 Pro 模拟器构建、安装并连接真实 MyNAS，读取 45 项远端资产、45 张网格图及详情 preview。另有 iPhone 16 Pro 人工验证及真实端到端上传与大视频续传记录。 | Xcode 工程、本轮构建/模拟器验收、账号隔离缓存及用户提供的部署/验收记录 |
| 已部署能力 | 树莓派 MyNAS `0.8.1` 已于 2026-07-24 部署；Tailscale HTTPS health 返回实时 CPU 温度，capabilities 返回状态模型 v1、`photos-browse-v1`、remote browsing/change feed 和三项 derivative recipe。45 个 asset、46 个原始资源和 135 个派生文件全部 ready。 | 真实部署健康检查、数据库状态、原件清单和 E3 验收脚本 |
| E1–E3 状态 | 状态模型、持久化任务、FFmpeg/LibRaw 衍生 worker、owner-scoped assets/changes/detail、ETag/304、Range/206 和路径隔离已经部署。46/46 原件 SHA-256 与 pre-E3 快照清单一致；真实 Live Photo 保留 `photo + pairedVideo`，IMG_4074.DNG 原件 SHA-256 不变并成功生成 tiny/grid/preview。 | 后端 Photos 文件及测试、0.8.1 真实部署验收记录 |

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
| E | 衍生文件、远程图库与可浏览备份 | 进行中（E1–E4 首个 iOS 只读切片已验收） | 补齐远端视频/Live Photo 播放、原件读取与 changes 增量刷新 |
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
- **用户可见成果：** 设置和照片页可进入备份，显示等待/读取/上传/完成/失败、项目数、进度和已上传/总文件大小；尚未读出全部 PhotoKit 资源大小时会显示待统计项目数；失败项按网络、本地原件、空间、完整性、身份、服务和配置分类，并可“仅重试失败项”；断网后前台重试，重新打开 App 时从服务器已接收的位置续传；Live Photo、HDR、RAW/ProRAW 和视频不转 JPEG。
- **iOS 端改动：** `PhotoLibraryClient.prepareBackupAsset` 导出全部 `PHAssetResource`（显式备份时允许 iCloud 下载），临时文件逐个 SHA-256；`PhotoBackupUploader` 4 MiB 分片、每片 SHA-256，并对网络错误与 408/429/5xx 做瞬态退避；`PhotoBackupCoordinator` 持久化队列、错误分类和按账号隔离，只将当前可访问的失败任务重置为等待，已完成任务保持不变。
- **MyNAS 后端改动：** 创建/读取 session、按 owner/volume/fingerprint 去重、offset 冲突处理、分片和全文件 SHA-256、同卷 rename、asset/resource/mapping SQLite 事务、按 owner 的原件目录。
- **数据模型/API 变化：** 新增 `photo_assets`、`photo_resources`、`photo_upload_sessions`、`photo_upload_resources`、`device_asset_mappings` 及 `/photos/upload-sessions` 协议。兼容字段 `photo_assets.backup_state = backedUp` 仅表示“原始资源安全入库”；E1 的细分状态不改变阶段 D 的验收边界。
- **前置依赖：** 阶段 C、可访问的 PhotoKit asset、在线且空间足够的卷。
- **验收标准和测试方法：** 对普通照片、Live Photo、HDR、RAW/ProRAW/DNG 和大视频，比较每个资源服务端 SHA-256；中断后检查 offset 续传；重复上传验证 owner+volume 去重；未上传完整 Live Photo 必须拒绝提交；检查多账号不能读取/续传对方会话。
- **明确不包含：** 衍生文件、远端照片列表/预览、后台 URLSession/BGTask、删除本机原件或“完整可浏览备份”承诺。
- **状态与证据：** **已完成（首版原始资源安全入库与前台失败恢复）。** `PhotoBackupUploader.swift`、`PhotoBackupCoordinator.swift`、`PhotoBackupModels.swift`、`PhotoBackupView.swift`、`PhotoLibraryClient.swift`、`backend/photos_uploads.go`；`TestPhotosMultiResourceUploadResumesVerifiesAndDeduplicates`、坏分片 hash 与不完整 Live Photo 的测试；用户已完成真实媒体及大视频端到端续传验证。iPhone 17 Pro 模拟器已用 44 完成 + 1 网络失败的可恢复队列验证 98% 摘要、失败分类、“仅重试 1 项”及恢复后 45/45，旧版无 failure 字段的队列可直接解码。

  **需在后续硬化：** 当前实现以 rename 后 SQLite 事务及失败回移组成应用级提交；进程在二者之间崩溃的恢复扫描、目录 fsync 策略、session 过期清理、并发/断电故障注入和可观测的修复流程尚未实现。服务端还把一个 asset 限制为最多 32 个 resource；超过上限必须显式失败而不能丢资源，需用罕见编辑资产验证或调整该上限。因此不能把“代码中的 `backedUp`”扩展解释为灾难恢复级保证。

## 阶段 E — 衍生文件、远程图库与完整可浏览备份

- **阶段目标：** 为安全入库的原件生成受版本约束的 tiny/grid/preview，并提供 owner-scoped 远程列表、资源读取和变更同步。
- **用户可见成果：** 用户能从 MyNAS 浏览照片、缩略图、预览、视频 Range 播放和 Live Photo；仅在所需衍生文件可用时，界面显示“完整可浏览备份”。
- **iOS 端改动：** E4 已新增 `ServerPhotoAsset`、分页/ETag 客户端、SHA-256 校验的账号隔离 grid/preview 缓存、独立只读远端方形网格、捏合 2–10 列、Live Photo/RAW/视频标记、派生处理中 UI 和详情 preview；尚需补齐视频 Range/Live Photo 播放、原件读取及 changes 增量刷新。不把失败的 preview 伪装成原件或成功备份。
- **MyNAS 后端改动：** E2 已部署 durable derivative queue、单线程幂等 worker、recipe/version、失败退避和重启恢复；普通媒体由 FFmpeg 处理，DNG/ProRAW 通过 `simple_dcraw` 提取内嵌全尺寸 JPEG 后再生成衍生文件；E3 已部署资源授权、`assets`/`changes`、ETag 和受控 Range 下载。
- **数据模型/API 变化：** E1 已为 asset 加入 `source_state`、`derivative_state`、recipe/version/error/updated_at，并新增 `photo_derivatives` 与 `photo_derivative_jobs`；E3 新增 `photo_changes` 及 `GET /photos/assets`、`/changes`、`/assets/{id}`、`/{tiny|grid|preview|original}`。FFmpeg processor 可用时发布三项 recipe，工具缺失时仍保持空数组。
- **前置依赖：** 阶段 D；明确每种媒体的 required derivative policy 和低资源树莓派转码预算。
- **验收标准和测试方法：** 新上传及重启后重建任务；校验 owner 越权为 404/403、不泄露路径；ETag/条件请求、分页/cursor 过期、Range、Live Photo 配对展示；任何 required derivative 缺失时，状态必须不是“完整可浏览备份”。
- **明确不包含：** 本地/远端合并时间线、后台自动扫描、删除工作流、AI。
- **状态与证据：** **进行中。E1–E3 服务端已部署；E4 的只读远端网格、preview 和账号隔离缓存已完成首个 iOS 切片。** iPhone 17 Pro 模拟器通过真实 Tailscale/MyNAS 读取 45/45 browse-ready asset（含 1 个 Live Photo、1 个 DNG），缓存 45 张 grid 和 1 张 preview；元数据缓存保存服务器 ETag，目录为实际 server/user namespace。远端网格不显示重复的绿色“已备份”角标，仅非 ready 项显示处理中状态。尚未完成远端视频/Live Photo 播放、original 读取 UI 和 changes 增量刷新，因此阶段 E 仍未完成。0.8.1 数据库为 45/45 asset ready、46 个原始资源、135 个衍生文件、SQLite integrity `ok`；pre-E3 清单 46/46 SHA-256 通过。服务端真实验收覆盖 45 项/5 页、46 条 changes、ETag/304、Range/206、owner 隔离、路径不泄露、Live Photo 双资源，以及 91,483,916 字节 IMG_4074.DNG 的原件哈希和三档衍生图。自动化 `go test ./...`、`go test -race ./...`、`go vet ./...` 通过。

## 阶段 F — 本地与远程统一时间线及去重

- **阶段目标：** 在一个按时间排序的界面中合并可访问的本机与 MyNAS 项目，并可解释地识别同一 asset/内容。
- **用户可见成果：** 单一时间线显示本地、仅远端和已关联项目；不会因文件名相同而错误合并。
- **iOS 端改动：** 统一 timeline view model、分页合并、来源/同步状态、冲突 UI、仅按必要范围缓存元数据。
- **MyNAS 后端改动：** cursor 变更日志、asset version、设备映射读取和 owner scoped metadata 查询。
- **数据模型/API 变化：** 依序使用 `localIdentifier + device mapping`、asset ID、manifest/资源 SHA-256、时间/尺寸和 Live Photo 资源组；文件名只能作显示信息，不能作唯一依据。
- **前置依赖：** 阶段 E 的远端索引、可读取的版本和明确的 merge policy。
- **验收标准和测试方法：** 同设备重复、不同设备相同内容、相似时间但不同照片、编辑后版本和 Live Photo 组的测试；离线/分页/过期 cursor 回归。
- **明确不包含：** 自动上传调度、删除、AI 自动聚类。
- **状态与证据：** **未开始。** iOS 已有独立的 `LocalPhotoAsset` 本地时间线和 `ServerPhotoAsset` 远端时间线，但有意保持两套列表分离；尚无统一排序、跨端映射合并或冲突策略。

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
- **状态与证据：** **未开始。** E4 已写入按账号隔离并进行 SHA-256 校验的 metadata/grid/preview 文件缓存，但尚无 `CacheEntry` 索引、容量展示、LRU 淘汰、原件导出、trash 或 restore。

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

## 下一步：E4 iOS 远端图库，并行补强大库弱网可恢复性

E3 的受控读取 API 已部署并通过真实树莓派验收。下一道门槛是 **让 iOS 以只读方式消费远端图库，同时先把大相册的失败恢复做成用户可理解、可重复执行的闭环**：

1. 在 iOS 增加 `ServerAsset`、远端分页客户端、账号隔离 metadata/thumbnail 缓存，以及 processing/failed/browse-ready 状态。
2. 用数千项模拟数据和真实弱网继续测试 4 MiB offset 续传、App 重启、MyNAS 重启、网络切换及 Live Photo 多资源的部分失败；当前已完成失败分类和定向重试的 45 项功能验收，尚不能替代大规模压力测试。
3. 远端网格验收稳定后，再进入阶段 F 的本地/远端统一时间线；后台自动备份仍留在阶段 G。
