# MyNAS Photos — 权威交付路线图与当前状态

> **这是阶段、状态和验收标准的唯一权威来源。** 其他 `docs/myphotos` 文档只说明各自领域的设计与当前事实，不另行维护阶段编号或状态。历史文件名 `PHASE2_CONNECTION.md` 仅为兼容已有链接；它现在对应本文件的“阶段 C”，不是一个可复用的“Phase 2”定义。

## 审计基线（2026-07-24）

| 项目 | 已核查事实 | 证据 |
| --- | --- | --- |
| 版本 | 当前 MyNAS 后端声明和仓库 `VERSION` 均为 `0.8.6`；iOS target 的 `MARKETING_VERSION` 为 `1.0`，Storyboard 启动屏修正版的 `CURRENT_PROJECT_VERSION` 为 `4`。 | `backend/photos_phase2.go`、`VERSION`、`ios/MyPhotos/MyPhotos.xcodeproj/project.pbxproj` |
| 代码状态 | E3/ProRAW、既有 iOS 功能和文档改动仍在工作区；LaunchScreen 资源另有用户已暂存改动。不得覆盖或擅自提交这些改动。 | `git status --short` |
| 后端测试 | 除握手、上传和 E1/E2 worker 测试外，E3 已覆盖 owner 隔离、分页、changes、ETag/304、Range/206、路径不泄露和正确的 CORS 分片 hash header；`go test -race ./...`、`go vet ./...` 通过。 | `backend/photos_browse_test.go` 及既有 Photos 测试；本轮命令记录 |
| iOS 验证 | `MyPhotosTests` 已于 2026-08-03 新增为首个 iOS XCTest target，目前覆盖 G2 的纯本地完整性前提：受保护资源副本、登记册、共享 manifest、完成 request body、不覆盖已存在分片 body，以及“仅在前台队列已持久化同一完成结果后才删除该记录的暂存目录”。截至 2026-08-04，完整 17 项套件已在 iOS 27.0 iPhone 17 Pro 模拟器通过；XCTest 宿主不会连接 MyNAS、读取 PhotoKit 或发起上传，因此不代替真实系统后台或设备策略回归。E4 首个只读远端图库切片已使用 Xcode 27 beta 对 iPhone 17 Pro 模拟器构建、安装并连接真实 MyNAS。2026-07-26 的真实增量回归从 45 项测试库连续备份到 47 项：本地与远端均显示 47 项，前台图库显示更新提示，后续重新加载才更新分页网格。2026-07-27 已在同一模拟器完成 H0 真实删除与恢复：唯一测试资源本机移入 iOS“最近删除”且 MyNAS 资源组永久删除；从系统“最近删除”恢复后，客户端以正常管线重新备份为新的、可浏览的单映射资源组；重复映射资源被安全拒绝。另有 iPhone 16 Pro 人工验证及真实端到端上传与大视频续传记录。 | `MyPhotosTests/PhotoBackupBackgroundTransferTests.swift`、Xcode 工程、2026-08-03 至 2026-08-04 模拟器与真机 XCTest 结果、账号隔离缓存及用户提供的部署/验收记录 |
| 已部署能力 | 树莓派 MyNAS `0.8.6` 已于 2026-08-05 原子部署到 release `20260805T013621Z`。Tailscale HTTPS health 和 capabilities 均回读 `0.8.6`；后者返回状态模型 v1、`photos-browse-v2`、remote browsing/change feed、device mapping recovery、精确内容关联摘要、F4 版本转移、`photoDelete=true`、三项 derivative recipe 和 `backgroundTransfers=true`。H1 的 `/assets/{assetID}/delete` 路由已在该 release 中；后台 capability 仅为受控真机系统传输验收显式开启，尚无完整系统会话证据。HEIC/HEIF 由 `heif-convert` 解出主图后生成预览，55/55 旧预览已重建并以真实 Live Photo 内容验收。 | 2026-08-05 原子部署；23 项前端测试、Go 测试与 vet、ARM64 构建、systemd active、health/capabilities `0.8.6` 只读复核 |
| E1–E3 状态 | 状态模型、持久化任务、FFmpeg/LibRaw 衍生 worker、owner-scoped assets/changes/detail、ETag/304、Range/206 和路径隔离已经部署。46/46 原件 SHA-256 与 pre-E3 快照清单一致；真实 Live Photo 保留 `photo + pairedVideo`，IMG_4074.DNG 原件 SHA-256 不变并成功生成 tiny/grid/preview。 | 后端 Photos 文件及测试、0.8.1 真实部署验收记录 |

### 术语与状态约束（先于所有阶段）

一个 **PhotoKit asset** 是备份单位，且必须包含 `PHAssetResource.assetResources(for:)` 返回的全部原始资源。Live Photo 的静态照片和配对视频、HDR、RAW、ProRAW、DNG、调整资源和原始视频均不得用 JPEG 替代。

当前必须区分以下三种状态：

1. **本地队列完成 / 原始资源已安全上传**：所有资源已导出、SHA-256 已在服务端重新校验、文件已移入 originals，且 asset/resource/设备映射元数据已写入。阶段 D 实现的是这个状态。
2. **完整可浏览备份**：在第 1 项之外，约定的 tiny、grid、preview 等衍生文件已成功生成、可授权读取且能从远端时间线浏览。阶段 E 完成前不得对用户宣称达到该状态。
3. **可用于删除本机和 MyNAS 备份的流程**：H0 已部署并完成“本机进入 iOS 最近删除 + 可选永久删除 MyNAS 备份”的受限配对验收。本机恢复以系统“最近删除”为入口，恢复后重新备份；这不等于完整阶段 H 能力。

兼容字段 `photo_assets.backup_state = "backedUp"` 仍保留，但 E1 已新增 `source_state`、`derivative_state` 和 recipe version，并把 iOS 文案改为“原件已安全上传”。只有 `derivative_state = ready` 才能形成 `browseReady`；所有阶段的“完成”均指阶段目标，不可据此跳过上述状态边界。

## 阶段一览

| 阶段 | 可交付成果 | 当前状态 | 下一道门槛 |
| --- | --- | --- | --- |
| A | 产品边界与工程基础 | 已完成 | 保持文档与版本事实一致 |
| B | 本地图库与应用外壳 | 已完成 | 补足可访问性/真机回归自动化 |
| C | 私有 MyNAS 连接、配对与账号隔离 | 已完成 | 持续在真实 tailnet 回归 |
| D | 手动原始资源备份（安全入库） | 已完成（首版） | 做崩溃一致性硬化；不能视为可浏览备份 |
| E | 衍生文件、远程图库与可浏览备份 | 已完成（E1–E4） | 在阶段 F 保持远端分页与资源组语义，不提前混入本地 `PHAsset` |
| F | 本地/远程统一时间线与去重 | 已完成（F1–F4） | 进入阶段 G 的后台自动备份设计与真机策略验收 |
| G | 后台自动备份 | 进行中（G1 已完成模拟器及 iPhone 16 Pro 的默认关闭、持久化、前台自动上传、低电量暂停/恢复、Wi‑Fi/蜂窝网络策略、一次锁屏后完成的受限观察，以及真实 App 终止/重新打开后的自动恢复；G2 已完成真实 212.1 MB 锁屏系统会话、开发终止后恢复、真机实时进度、传输中低电量暂停/续传完成，以及 Wi‑Fi 中断后等待、恢复并达到 MyNAS-confirmed 最终完成；服务重启、账号/卷、iCloud-only 与长队列仍未验收） | 验证服务重启，再完成账号/卷、iCloud-only 和长队列边界 |
| H | 恢复、导出、删除与缓存管理 | 已完成（H0–H2 均已真机验收） | 返回阶段 G，从 MyNAS 服务重启边界继续 |
| I | 端侧 AI 搜索、人物/物体分类 | 进行中（I1 本地索引底座已实现，尚未通过发布门槛） | 完成 I1 真机收尾、树莓派同版本部署回读和 GitHub Release，之后才允许进入 I2 |
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
- **iOS 端改动：** E4 已新增 `ServerPhotoAsset`、分页/ETag 客户端、SHA-256 校验的账号隔离 grid/preview 缓存、独立只读远端方形网格、捏合 2–10 列、Live Photo/RAW/视频标记、派生处理中 UI 和详情 preview；视频及 Live Photo paired video 使用 AVFoundation 按 Range 播放，`MyNASMediaResourceLoader` 经 `RemotePhotoLibraryClient` 的无代理会话读取私有 Tailscale 流；详情只读展示全部原件资源，前台 `/changes` cursor 建立基线并提示更新。原件导出/下载、缓存 LRU 和 Live Photo 真实媒体回归仍待完成；不把失败的 preview 伪装成原件或成功备份。
- **MyNAS 后端改动：** E2 已部署 durable derivative queue、单线程幂等 worker、recipe/version、失败退避和重启恢复；普通媒体由 FFmpeg 处理，DNG/ProRAW 通过 `simple_dcraw` 提取内嵌全尺寸 JPEG 后再生成衍生文件；E3 已部署资源授权、`assets`/`changes`、ETag 和受控 Range 下载。
- **数据模型/API 变化：** E1 已为 asset 加入 `source_state`、`derivative_state`、recipe/version/error/updated_at，并新增 `photo_derivatives` 与 `photo_derivative_jobs`；E3 新增 `photo_changes` 及 `GET /photos/assets`、`/changes`、`/assets/{id}`、`/{tiny|grid|preview|original}`。FFmpeg processor 可用时发布三项 recipe，工具缺失时仍保持空数组。
- **前置依赖：** 阶段 D；明确每种媒体的 required derivative policy 和低资源树莓派转码预算。
- **验收标准和测试方法：** 新上传及重启后重建任务；校验 owner 越权为 404/403、不泄露路径；ETag/条件请求、分页/cursor 过期、Range、Live Photo 配对展示；任何 required derivative 缺失时，状态必须不是“完整可浏览备份”。
- **明确不包含：** 本地/远端合并时间线、后台自动扫描、删除工作流、AI。
- **状态与证据：** **已完成（E1–E4）。** iPhone 17 Pro 模拟器通过真实 Tailscale/MyNAS 读取初始 45/45 browse-ready asset（含 1 个 Live Photo、1 个 DNG），缓存 45 张 grid 和 1 张 preview；元数据缓存保存服务器 ETag，目录为实际 server/user namespace。远端网格不显示重复的绿色“已备份”角标，仅非 ready 项显示处理中状态。2026-07-25 部署前生成 `pre-e4-mime-20260725T155837Z` 快照（SQLite `ok`、46 原件、135 衍生清单），随后原子部署 0.8.1 热修复；相同 MOV 的 Range 响应为 `206 + video/quicktime`，iPhone 17 Pro 模拟器成功渲染 12.8 MB MOV 的真实首帧；真实 Live Photo 的 HEIC 预览与 paired MOV 均成功渲染。最终启动创建 cursor `91`，对 `/changes` 的同 ETag 条件请求返回 `304`，验证历史变更不会被首次基线误报。2026-07-26 在模拟器新增两张独立测试 PNG；前台自动备份后，本地与远端图库从 45 连续达到 47 项。第二次增量发生时远端列表保留既有分页、状态卡显示蓝色更新提示；随后重新加载后读取 47 项，证明更新不会令网格跳动。原件导出/下载与缓存 LRU 属于阶段 H。服务端真实验收覆盖 45 项/5 页、46 条 changes、ETag/304、Range/206、owner 隔离、路径不泄露、Live Photo 双资源，以及 91,483,916 字节 IMG_4074.DNG 的原件哈希和三档衍生图。自动化 `go test ./...`、`go test -race ./...`、`go vet ./...` 通过。

## 阶段 F — 本地与远程统一时间线及去重

- **阶段目标：** 在一个按时间排序的界面中合并可访问的本机与 MyNAS 项目，并可解释地识别同一 asset/内容。
- **用户可见成果：** 单一时间线显示本地、仅远端和已关联项目；不会因文件名相同而错误合并。该显示模式由“设置 > 照片显示 > 统一时间线”控制，照片页不再长期显示范围切换或汇总状态卡。
- **iOS 端改动：** 统一 timeline view model、分页合并、来源/同步状态、冲突 UI、仅按必要范围缓存元数据；设置页以原生开关保存显示偏好，Limited Photos 的访问范围说明和管理入口也集中在设置页。
- **MyNAS 后端改动：** cursor 变更日志、asset version、设备映射读取和 owner scoped metadata 查询；F3 以 `(owner, asset)` 索引统计已验证资源组的匿名跨设备关联数，并在新映射创建时发出 asset upsert change。F4 的工作区 schema 还会持久化同一设备、同一 `localIdentifier` 资源组切换的前后 asset/fingerprint 审计转移，并为两端 asset 写入 change，使缓存能刷新版本关系。
- **数据模型/API 变化：** 依序使用 `localIdentifier + device mapping`、asset ID、manifest/资源 SHA-256、时间/尺寸和 Live Photo 资源组；文件名只能作显示信息，不能作唯一依据。F3 只返回 `exactContentDeviceCount` 和 `exactContentMappingCount` 聚合值，不返回 fingerprint、其他设备 ID 或 other-device local identifier。F4 已部署字段 `previousVersionCount` 和 `nextVersionCount` 只反映已记录的转移数量，不公开转移中的设备或本地标识，也不根据历史数据推断关系。
- **前置依赖：** 阶段 E 的远端索引、可读取的版本和明确的 merge policy。
- **验收标准和测试方法：** 同设备重复、不同设备相同内容、相似时间但不同照片、编辑后版本和 Live Photo 组的测试；离线/分页/过期 cursor 回归。
- **明确不包含：** 自动上传调度、删除、AI 自动聚类。
- **状态与证据：** **已完成（F1–F4）。** `UnifiedPhotoTimelineItem` 只在当前设备的持久化备份任务仍指向当前 `PHAsset` 源版本、且含服务器确认的 MyNAS asset ID 时合并本机与远端记录；绝不以拍摄时间、文件名或缩略图猜测为同一项目。`UnifiedPhotoTimelineViewModel` 以 120 项远端 cursor 页读取并在主照片页按拍摄时间排序，远端独有项目保留“仅 MyNAS”，本机项目明确显示等待、上传、失败、原件已安全入库或“已备份 · 可浏览”。F2 服务器在 0.8.2 新增 owner + device 双重隔离的映射分页接口；iOS 以 Keychain 保留随机设备 ID，仅在本地 `PHAsset` 的源版本与服务器 `sourceModificationDate` 严格相等、且 `sourceCommitted` 时恢复完成状态，不能匹配的项目仍走正常备份。F3 在 0.8.3 以同一 owner、同一卷、完整 manifest SHA-256/角色/字节数一致的资源组返回匿名 `exactContentDeviceCount`/`exactContentMappingCount`；详情页和统一时间线只做说明，绝不静默合并或隐藏项目。F4 已于 0.8.4 部署：同一设备同一 `localIdentifier` 切换完整资源组后，仅返回匿名的前序/后续计数并保留两份原件。普通照片与 Live Photo 均已完成“原版 → 编辑版 → 撤销编辑”真实回归，Live Photo 的静态图与 paired video 始终成组；跨设备相同普通照片、Live Photo 和 ProRAW 只增加 F3 内容关联，不创建 F4 转移；App 重装映射恢复与同名近时间但字节不同的资源组回归均已完成。`TestPhotosAssetsExposeSameDeviceVersionTransitionsWithoutMappingIdentity` 还锁定 Live Photo 的反向撤销转移，服务端测试覆盖跨设备严格去重、列表/详情摘要与无 fingerprint/device ID 泄露。删除与导出仍不在 F 范围。

**F4 已部署状态：** 同一设备、同一 `localIdentifier` 切到另一完整资源组时，后端会保存私有转移审计，并让列表/详情返回匿名前序/后续计数；Live Photo 静态图与 paired video 必须一起完成才形成转移。iOS 对字段保持兼容，统一“全部”页前台会通过 `/changes` 刷新新的远端 asset 版本。

**2026-08-05 设置承载调整：** “当前仅可访问部分图片”的说明与系统授权管理入口，以及“统一时间线”的显示偏好，均移至“设置”；照片页不再显示范围选择器或统一时间线汇总卡。该开关仅改变显示，不会触发上传、下载、合并或删除。三处相关 SwiftUI 文件已通过 `swiftc -frontend -parse`，并且 `git diff --check` 通过；但本机 Xcode 26.6 的三次无签名 `build-for-testing` 都在 `CompileAssetCatalogVariant` 阶段因 CoreSimulator/图标导出服务不可用而停止，尚未取得可宣称为通过的完整 Xcode 构建或设备验收结果。

## 阶段 G — 后台自动备份

- **阶段目标：** 在系统允许的时间、网络与电源条件下持续发现变化并可靠上传，而不误称 iOS 后台执行为无限制常驻任务。
- **用户可见成果：** G1 已提供每个 MyNAS 账号独立、默认关闭的“前台自动备份”开关；用户可选择仅 Wi‑Fi 或允许蜂窝数据、低电量模式暂停，并看到等待前台/网络/Wi‑Fi、低电量暂停、核验已有备份、等待其他前台备份完成、上传和前台发现等原因，也可一键暂停。真正后台能力完成后，才会提供系统调度状态。
- **iOS 端改动：** G1 使用 PhotoKit 变更后的当前前台图库快照、scene phase、`NWPathMonitor` 和低电量通知重新判断策略；策略持久化时同时绑定 `accountID + serverID + userID`，自动队列任务带来源标记，不能因重启恢复逻辑绕过暂停。`PhotoBackupAutomaticEligibility` 把这个前台门槛抽成无副作用的纯规则，并按身份、前台、当前账号、卷、映射核验、低电量、网络的安全优先顺序返回可解释暂停状态；只有返回允许时协调器才会考虑 PhotoKit 导出。单一前台上传队列会记录当前账号和自动/手动来源，其他账号等待时不会误显示为自动上传；队列释放后重新判断全部当前自动请求。自动请求只跟随当前正在查看的账号，切换账号后的旧自动队列在当前项目结束后停住。若服务器提供设备映射读取，自动发现会先成功核验此设备映射；请求失败绝不被当作空映射，自动上传会保持暂停至下次前台核验成功。G2 已建立受 Data Protection 保护的任务登记册：它将未来的文件型系统上传任务绑定到 `accountID + serverID + userID + volumeID`、当前 PhotoKit 源版本、资源哈希和安全的私有暂存文件名；对应暂存器会逐资源复制并重新核对字节数与 SHA-256，只有完整资源组都通过才原子登记。它还预先保存与前台上传共用的创建会话清单、空完成请求体，并可按服务器要求生成不可覆盖的受保护分片文件；这使系统会话不必在 App 重启后重新读取 PhotoKit 或重建元数据。登记册持久绑定**至多一个**待执行系统请求的 task ID、协议阶段、分片范围、相对 body/response 文件名和回调后的 HTTP 状态/响应长度；任务必须先登记才允许恢复。`PhotoBackupBackgroundTransferEngine` 已以两个 network-policy 固定的 file-backed background `URLSession`（仅 Wi‑Fi / 允许蜂窝）发送 create → part → complete，`UIApplicationDelegate` 在系统重启 App 时重建同名 session 并交回完成回调；完成只进入等待解析，MyNAS 的完整响应才会更新任务。策略暂停、收紧为仅 Wi‑Fi、低电量暂停或账号切换会取消并清空旧 task 映射，下次必须重取 MyNAS 断点。App 已登记受限 `BGProcessingTask` handler：它不发现 PhotoKit 项目，只会重新核验当前持久化账号、卷、capability、用户策略和低电量后续接一项已有登记记录；在进入后台或系统传输失败时才可能请求一次处理机会。前台队列写入同一完成结果成功后才会删除该完成记录的私有暂存目录和账本；任何持久化或清理错误都保留副本。该代码只有 `supportsBackgroundTransfers == true`、当前账号仍被选中、卷/账号三元组和已启用策略均匹配时才可暂存或调度；2026-08-03 的 0.8.5 受控验收 release 已返回 capability=true，因而可开始真实系统 task 验收，但尚未观察到系统回调或端到端媒体完成。
- **MyNAS 后端改动：** session TTL/清理、幂等 resume、速率/并发限制、可观测状态；必要时为长期 upload session 设计续期。
- **数据模型/API 变化：** G1 新增按账号隔离的自动备份策略和自动/手动队列来源。G2 的 `PhotoBackupBackgroundTransferRecord` 已定义并持久化账号/卷/资源组与至多一个待执行 system task（task ID、请求阶段、资源/分片范围、受保护 body/response 文件、HTTP 状态与响应长度）的映射，以及创建会话、完成和按需分片请求文件；2026-08-03 的受控验收服务已返回 `backgroundTransfers: true`，但只能在真实系统任务、完整性与恢复测试通过后才成为用户可宣称的后台能力。
- **前置依赖：** 阶段 D 的可靠恢复语义；真实设备的系统后台限制测试。
- **验收标准和测试方法：** 锁屏、重启、网络切换、低电量、iCloud 原件未本地化、账号/卷切换、服务器重启和 24 小时以上队列回归。
- **明确不包含：** 不保证即时或无限时后台运行；不在无用户许可时上传；不做删除。
- **状态与证据：** **进行中（G1 已实现，已完成 iPhone 17 Pro 模拟器与 iPhone 16 Pro 的正向前台自动上传、低电量暂停/恢复、Wi‑Fi/蜂窝网络策略，以及一次锁屏后完成的受限观察；G2 已完成任务登记、安全暂存及文件型请求准备基础，并通过模拟器和真机的本地完整性测试；其余真机/策略验收由用户于 2026-08-03 暂缓）。** 自动发现仅在 App active 时由图库变化、账号切换或回到前台触发；不满足当前账号、服务器映射核验、Wi‑Fi、低电量或卷条件时不会启动自动上传。策略 JSON 与备份队列均使用 Data Protection，且策略不会跨 `serverID + userID` 复用；设备映射请求失败保持“等待核验”，不会把失败降级为空列表而重传已有项目，账号切换不会继续消费旧账号的自动队列。若其他账号的手动或自动工作占用单一前台队列，当前账号明确显示“等待当前备份完成”，并在队列释放后重新评估，绝不伪装为正在自动上传。2026-07-27 已通过相关 Swift 源码解析、`git diff --check`，以及 Xcode 27.0 beta（27A5228h）面向 iOS 27.0 iPhone 17 Pro 模拟器的完整资源构建；Liquid Glass `.icon`、`Assets.xcassets` 与所有 Swift 源码均成功参与编译，先前 26.5 SDK/runtime 不匹配阻塞已解除。2026-08-02 已再次用同一 Xcode beta 对已启动 iPhone 17 Pro 完成完整资源构建和 `git diff --check`，安装包已准备好；这仅证明构建可用，尚未替代 Wi‑Fi、低电量、账号/卷切换等设备策略验收。2026-08-03，Device Hub 的 iOS 27.0 iPhone 17 Pro 在真实 MyNAS 账号上确认：默认策略为关闭；开启“仅 Wi‑Fi + 低电量暂停”并重启 App 后策略仍保留且恢复“前台自动发现中”；导入项目内无隐私测试 PNG 后，当前源版本队列从 51/51 变为 52/52“原件已安全上传”，统一时间线同时显示本机 52 项、可浏览备份 52 项。测试后已将自动开关恢复为关闭。同日连接的 iOS 27.0 iPhone 16 Pro 在 Device Hub 中显示自动开关关闭，同时仍显示一个用户已有的“手动备份”队列和 1/2 个原始资源进度；这只验证关闭自动策略不会在 UI 上取消或误标已有手动工作，未启动新的上传。随后用户在该 iPhone 的现有 Limited Photos 范围内准备了第 3个非私密测试项目；修正进度标题口径后，页面先显示“2/3、1 项待备份、67%”。开启“前台自动备份”后，状态显示“前台自动发现中”，策略为“仅 Wi‑Fi + 低电量模式暂停”，随后当前源版本达到 3/3“原件已安全上传”、100%（98.8 MB）；手动按钮全程没有被触碰。测试结束已恢复自动开关为关闭。`PhotoBackupAutomaticEligibility` 的 4 项纯规则回归随后在该真机通过：Wi‑Fi-only 会暂停蜂窝网络、允许蜂窝的策略放行、低电量优先暂停、设备映射未核验时保持失败关闭、账号三元组不匹配时禁用策略；连同摘要、G2 暂存与 XCTest 宿主隔离用例共 7 项均通过，完整 Debug 构建无并发警告且 `git diff --check` 通过。这证明代码级门槛，但不代替系统级条件变化。随后，用户在同一 iPhone 16 Pro 手动开启 iOS 低电量模式；在自动策略开启、仍为“仅 Wi‑Fi + 低电量模式暂停”、且当前 3/3 资源已完成时，App 实际显示“低电量模式已暂停”。用户再关闭系统低电量模式并重新开启自动策略后，App 实际显示“前台自动发现中”；随后通过 App 的“暂停自动备份”操作恢复默认关闭，页面显示“自动备份已关闭”并明确不会因图库变化自动上传。该项真实设备验证确认低电量状态会在导出前拦住自动发现、恢复后重新观察图库，但没有待上传资源，故不构成传输中断恢复验收。同日，用户关闭 Wi‑Fi、使同一真机显示 5G 蜂窝网络；在自动策略开启且仍选择“仅 Wi‑Fi”时，App 实际显示“等待 Wi‑Fi”，并说明当前策略只允许 Wi‑Fi 自动上传。现有 3/3 资源已完成，所以该安全暂停没有产生媒体流量。此项确认真实 `NWPathMonitor` 网络转换会在导出前拦住自动发现。随后在相同 5G 状态把策略改为“允许蜂窝数据”后，App 实际显示“前台自动发现中”，说明网络门槛已解除；两次网络策略测试均由“暂停自动备份”操作恢复默认关闭。没有待上传资源，所以这证明的是发现/导出前策略分支，不是蜂窝媒体传输量或中断恢复验收。随后，用户在同一 iPhone 16 Pro 的 Limited Photos 范围内导入第 4个安全测试项；开启前页面显示 3/4项、1 项待备份、75% 和 98.8 MB，且自动策略关闭。用户开启前台自动备份且不触碰手动备份按钮后立即锁屏，约一分钟后解锁并确认该项是在锁屏后完成；iPhone 镜像随即显示 4/4 项“原件已安全上传”、100% 和 114.3 MB。这是一项真机观察：现有前台队列在这次锁屏期间获得了足以完成小型待上传资源的系统允许执行时间。它没有创建 background `URLSession`、BGTask、系统回调或重启恢复，不能保证更长传输、App 终止、重启或系统后续回收后的结果，也不能把 `backgroundTransfers: false` 改为 true。结果记录后，App 内“暂停自动备份”已实际恢复策略为关闭，并显示“自动备份已关闭”，所以之后的图库变化不会被本次测试自动加入队列。受限运行时仍没有第二账号/卷，因此账号/卷切换、映射失败恢复、iCloud-only、App 终止/重启、服务器重启及长队列仍未验收；用户已要求暂时跳过这些测试，恢复验收前不得把它们视作通过，也不得据此推进或宣称 G2 系统后台能力。2026-08-03 已新增 `PhotoBackupBackgroundTransferRecord`、受保护登记册与资源组暂存器；每项记录必须精确匹配账号三元组与卷，并只保存资源哈希、协议 ID、相对暂存文件名和未来系统 task ID。暂存器逐资源复制并复核大小和 SHA-256，失败时不写入记录；随后以与前台上传相同的编码规则写入创建会话清单和空完成请求体。未来的分片准备器仅从已验证的暂存原件读取所需字节，生成唯一且不覆盖在用文件的受保护 request body，并重新得出该分片 SHA-256。2026-08-03 已新增 `MyPhotosTests`：其已在 iOS 27.0 iPhone 17 Pro 模拟器和 iOS 27.0 iPhone 16 Pro 真机上通过资源副本、登记册、manifest、完成 body 和“不覆盖既有分片 body”的 G2 本地完整性测试（分别为 0.046 秒和 0.033 秒）；它不联网、不访问 PhotoKit，也不证明系统后台执行。三者仍没有调用入口，因此不创建 `BGTaskScheduler` 请求或 background `URLSession`，也不会修改当前 G1 队列。2026-08-03 已以 Xcode 27.0 beta（27A5228h）完整构建并消除该层的 Swift actor-isolation 警告，`git diff --check` 通过。测试还发现历史任务会令标题与当前图库进度不一致，现已改为按当前账号和当前 PhotoKit 源版本计算，并在同一模拟器复核 52/52 一致。随后在同一 iPhone 16 Pro 导入第 3项后复现“标题 2/2、总数 2/3”口径冲突；`PhotoBackupProgressSnapshot.statusSummary` 现统一使用当前获准访问图库的总数，新增回归测试与既有两项 G2/XCTest 宿主隔离测试均在真机通过（0.002、0.008、0.001 秒），完整 Debug 构建和 `git diff --check` 通过。当前上传仍为前台 `URLSessionConfiguration.ephemeral`，capabilities 保持 `backgroundTransfers: false`；不得将 G1 描述为锁屏、退出或系统回收后仍持续上传。

- **G2 受控部署状态（2026-08-03）：** 上一段 G1 历史观察末尾的 `backgroundTransfers: false` 指的是当时尚未部署 G2 的状态；随后用户授权的原子部署及重启已经回读 `backgroundTransfers: true`。这只解除真机创建系统 task 的服务端门槛，不是系统上传、回调或终止恢复已经通过的证据。

- **G2 session-scoped task identity（本地门槛已通过，2026-08-03）：** iOS `URLSession` 的 task ID 只在单一 session 内唯一；G2 登记册现将每个 task ID 与其固定网络策略（仅 Wi‑Fi / 允许蜂窝）共同持久化，并以这两个字段查找回调、限制取消范围。登记册拒绝在同一策略 session 内把相同 callback identity 写给两条记录，因此旧 Wi‑Fi 回调不能匹配同号的允许蜂窝任务。为不丢弃更新前的在途记录，缺失策略字段的旧 task 仅会在一个真实回调能唯一匹配该 task ID 时补写策略；有多个候选时一律保持暂停，不猜测归属。Xcode 27 beta generic `build-for-testing` 与 iPhone 17 Pro 模拟器的完整 **15** 项纯本地套件通过；这项回归不访问 PhotoKit、MyNAS 或真实系统任务。

- **G2 会话隔离修复安装后状态（真机通过，2026-08-03）：** 在上述锁屏传输已完成后，session-scoped identity 与旧账本安全解码修复包已安装到同一 iPhone 16 Pro 并正常启动。正常根界面仍显示 6/6 项原件已上传、212.1/212.1 MB 和 100%，说明此安装没有清空既有完成状态或错误触发新的队列；由于没有第二账号、第二网络策略或在途旧记录，这不是跨 session 冲突或旧记录回调迁移的真实设备覆盖。

- **G2 真机系统 task 与锁屏完成（部分验收通过，2026-08-03）：** 用户在已连接的 iPhone 16 Pro 开启“前台自动备份”、仅 Wi‑Fi 与低电量暂停后导入一个本地可用、非私密的约 212.1 MB 测试媒体，未触碰“立即备份”。App 先显示当前 5/6 项完成及“iOS 正在处理后台传输”；用户随即锁屏 90 秒。解锁后的实际截图显示“原件已上传 6/6 项”“原件已安全上传 6/6 项”、212.1/212.1 MB、100%，状态回到“前台自动发现中”且无错误。这证明自动发现已把资源暂存并登记给真实 background `URLSession`，并已在该锁屏观察后完成系统回调解析、MyNAS 确认 outcome 与队列持久化；它取代本阶段前文“尚未观察实际回调/端到端完成”的部署前描述。终止恢复、策略/网络/低电量中断、服务器重启、账号/卷切换、iCloud-only 和长队列仍在验收，不能宣称后台备份整体完成。

- **G2 真机开发终止/重新打开恢复（部分验收通过，2026-08-03）：** 用户为第 7 个本地可用、非私密测试项开启同一仅 Wi‑Fi 自动策略，并确认页面已显示“iOS 正在处理后台传输”。开发工具随后以不可捕获信号终止 MyNAS Photos 进程，等待 15 秒后手动重新启动 App。首次恢复画面显示 6/7 项、212.1/272.4 MB，证明在途项没有被误标完成；随后未点“立即备份”或“重试”即显示 7/7 项、272.4/272.4 MB，并且统一时间线显示 7 个可浏览备份。该项通过 G2 的开发终止→手动重新打开→持久账本恢复和 MyNAS-confirmed outcome 路径。它不证明进程终止期间仍在传输，不等同用户从 App 切换器强制退出时 iOS 必然重新唤起 App；网络/低电量中断、服务重启、账号/卷切换、iCloud-only 和长队列仍在验收，不能宣称后台备份整体完成。

- **阶段 G 当前状态更正（2026-08-03）：** 本节上方“尚未观察到系统回调或端到端媒体完成”及“其余真机/策略验收暂缓”均为本次两项 G2 真机观察之前的历史描述。当前已通过 212.1 MB 锁屏系统 task 与开发终止/手动重新打开恢复；待验证项只剩传输中的网络/低电量中断、服务器重启、iCloud-only、账号/卷切换、映射失败/重试与 24 小时以上队列，不能把这两条受控路径扩大为无限制后台保证。

- **验收排期（2026-08-03）：** 用户要求先暂缓上述剩余 G1/G2 真机条件测试，改为更新 GitHub 项目说明。暂缓只改变当前工作优先级，不构成测试通过、产品承诺或 Phase G 阶段切换；恢复后仍按本节的网络、低电量、服务重启、iCloud-only、账号/卷、映射失败/重试及长队列清单执行。

- **G2 系统重启回调交接加固（本地门槛通过，2026-08-03）：** Apple 的 background URLSession 生命周期要求 App 在收到 `application(_:handleEventsForBackgroundURLSession:completionHandler:)` 时先保存 UIKit completion handler，再用相同 identifier 重建 session；重建时系统即可投递保留事件。`MyPhotosBackgroundTransferAppDelegate` 与 `PhotoBackupBackgroundTransferEngine` 现统一在 MainActor 同步执行这两步，只接受固定的 Wi‑Fi/允许蜂窝 identifier；未知 identifier 会立即归还 UIKit handler。这样 `urlSessionDidFinishEvents` 不会落在“session 已重建、handler 尚未保存”的异步空窗，并仍只在主线程归还 handler。Xcode 27 beta（27A5228h）在 iOS 27.0 iPhone 17 Pro 模拟器的完整 15 项 `MyPhotosTests` 通过、`git diff --check` 通过；测试不创建真实上传、不给此改动任何锁屏/终止/网络条件验收结论。

- **G2 低电量最终交接门槛（本地门槛通过，2026-08-03）：** 前台观察到低电量时会先暂停自动发现，但 PhotoKit 导出期间状态仍可能变化。因此 background engine 在写入任何受保护暂存副本前、以及重新续接既有系统记录前，都会再次读取当前低电量状态；若用户的策略要求暂停，就拒绝交接，协调器将自动任务保留为 `waiting` 而非误报失败。电量来源已可由测试注入：在 capability=true、完整资源组已准备好的情况下，模拟低电量调用 `beginAutomaticTransfer` 会抛出暂停错误，登记册保持为空；关闭“低电量暂停”后规则允许继续。Xcode 27 beta（27A5228h）在 iOS 27.0 iPhone 17 Pro 模拟器完整 **16** 项 `MyPhotosTests` 通过，`git diff --check` 通过。该测试不模拟真实系统在传输中切换低电量，后者仍在用户暂缓的真机验收清单中。

- **G2 前台状态即时对账（本地门槛通过、真机观察待执行，2026-08-04）：** 用户观察到真实系统传输完成后，备份卡片有时仍停在“iOS 正在处理后台传输”，直到离开再进入备份页才跳至完成。原因是系统 callback 已将结果安全写入 G2 登记册，但 `PhotoBackupCoordinator.jobs` 过去只在进入/恢复备份页时对账，SwiftUI 卡片订阅的队列没有收到该次变化。现在 engine 只在登记册成功落盘后递增瞬时 `stateRevision`；协调器订阅它，并立刻以活跃的前台自动请求重新核验当前 PhotoKit 源版本、将同一 MyNAS-confirmed outcome 原子写回队列，再清理完成登记。它不把传输层的每个字节伪装成实时进度，也不会由 HTTP 结束猜测完成。新增回归证明完成登记册被安全移除时会发布 revision；Xcode 27 beta（27A5228h）iOS 27.0 iPhone 17 Pro 模拟器完整 **17** 项 `MyPhotosTests` 和 `git diff --check` 通过。随后同一 Xcode beta 成功为已连接 iPhone 构建、签名、安装并启动 Debug App，未重启或改动 MyNAS 服务。该套件不创建真实系统 callback，因此“无需重新进入页面即可更新卡片”仍须在下一次 iPhone 实际完成回调中观察，不能据此扩大 G2 验收。

- **XCTest 宿主隔离（2026-08-03）：** iOS 单测需要以 `MyPhotos.app` 为宿主；首次真机 G2 测试由此创建了正常根视图，而 `PhotoBackupView` 的启动任务恢复了手机上已持久化的手动队列。测试本体没有发起网络或 PhotoKit 操作，但宿主生命周期产生了这个不应有的副作用。现在 `MyPhotosRuntime.isRunningXCTest` 会让宿主只渲染空视图，并把 `AccountStore` 放入仅生产路径会创建的 `MyPhotosProductionRoot`；因此测试不创建账户、PhotoKit 观察或备份协调器。`testXCTestHostDisablesProductionLifecycle` 与原有 G2 完整性测试已在 iPhone 17 Pro 模拟器通过，并在手动队列自然完成后于 iPhone 16 Pro 真机再次通过（0.001 秒与 0.007 秒）；补充当前图库总数摘要的回归测试后，三项真机测试再次通过（0.001、0.002、0.008 秒）。随后重新启动正常 App，界面显示 2/3 项、自动开关关闭且没有新的队列，完成“G2 单测无真实队列副作用”的隔离验收。

- **自动任务重启归一化回归（真机本地断言已通过，2026-08-03）：** 新增 `testRestartNormalizesAutomaticInFlightJobToWaiting`，以临时持久化队列模拟自动任务停在 `uploading`。重新构建 `PhotoBackupCoordinator` 后，该任务必须保持自动来源、转成 `waiting`、保留已确认字节并显示“等待从 MyNAS 已接收的位置继续”；它不能被显示为完成，也不会在已终止状态自行继续。Xcode 27 beta 面向 generic iOS 的 `build-for-testing`、iOS 27.0 iPhone 17 Pro 模拟器完整 8 项 `MyPhotosTests`、iPhone 16 Pro 的该单测（0.014 秒）和完整 8 项套件（新测 0.015 秒）及 `git diff --check` 均通过。XCTest 宿主隔离保证这些断言不读取 PhotoKit、不连接 MyNAS；它们证明持久化状态归一化，仍不替代含真实媒体的 App 终止/重启恢复观察。

- **G1 真机 App 终止/重新打开恢复（2026-08-03）：** 用户在 iPhone 16 Pro 的已授权 Limited Photos 范围内导入一个约 300 MB 的非私密测试视频，保持 Wi‑Fi、关闭低电量模式并开启前台自动备份；确认已有上传字节增长后，从 App 切换器强制结束 MyNAS Photos。约 15 秒后重新打开 App，未点“立即备份”或“重试”，自动任务自行继续并最终显示 5/5，且无错误提示。该项证明自动来源的持久化队列会在真实 App 终止后归一化、重新核验并沿既有前台上传/断点续传管线继续，而不把中断误标为完成。它仍不是 background `URLSession`、BGTask 或终止期间持续上传的证据；账号/卷切换、映射失败恢复、iCloud-only、服务器重启和长队列验收仍未完成。

- **G2 系统任务账本形状（模拟器本地断言已通过，2026-08-03）：** `PhotoBackupBackgroundTransferRecord` 现最多保留一个待执行的协议请求；它把 iOS task ID、创建会话/分片/完成阶段、分片范围、受保护 body/response 文件名与回调后的 HTTP 状态、响应长度一起绑定到已核验的账号、卷、源版本和资源组。写入错误 body、错误资源或错误分片范围的记录在登记边界直接失败；回调只先记为“等待 App 解析”，不会由传输完成猜测为备份成功。iPhone 17 Pro 模拟器完整 9 项 `MyPhotosTests` 通过；该测试不创建 `URLSession`、不联网且不读取 PhotoKit，故只是回调恢复所需的数据完整性证据，并非系统后台上传验收。

- **G2 系统 URLSession 代码接入（模拟器本地门槛已通过，2026-08-03）：** 新增 `PhotoBackupBackgroundTransferEngine` 与 SwiftUI App 的 UIKit callback adapter。它只有在当前 MyNAS capability、当前选中账号、卷、账号三元组和用户已启用策略同时满足时，才把完整暂存资源交给 iOS 的 file-backed background `URLSession`；按仅 Wi‑Fi/允许蜂窝使用不同 session，建立会话、每个分片和完成请求均在 `resume()` 前登记 task ID，并在系统回调后持久解析响应。系统 task 失败、暂停策略、网络策略从蜂窝收紧为 Wi‑Fi、低电量暂停或切换账号时，会清除本地 session/offset 假设并从 MyNAS 的幂等 create-session 重新取断点。自动任务在 capability 关闭时于暂存前失败关闭；`build-for-testing`、iPhone 17 Pro 模拟器完整 10 项 `MyPhotosTests` 以及 `git diff --check` 均通过。**在随后受控部署之前**，MyNAS 0.8.5 返回 `backgroundTransfers: false`，所以该本地验证没有创建系统 task、网络请求或后台回调；它不是系统后台上传验收。**同日的后端 G2 前置加固**将 upload-session 的续传身份固定为 `owner + volume + device + local identifier + fingerprint`，并以 SQLite 启动迁移把旧的未含 volume 唯一约束原子替换；capability 仅由默认关闭的 `MYNAS_PHOTOS_BACKGROUND_TRANSFERS=1` 显式控制。该开关为 true 的服务启动期仅会清理超过七天、未完成、时间戳可解析、卷在线且 staging 路径精确匹配的会话；异常/陌生路径一律保留。macOS 原子部署脚本现默认写入 `MYNAS_PHOTOS_BACKGROUND_TRANSFERS=0`，只接受 `0/1`，并在远端重启后回读 capability；因此真机验收时必须显式传 `1`，否则部署失败关闭。默认关闭/显式开启、跨卷会话不复用、旧库迁移、TTL 的删除与拒绝陌生路径、完整 `go test`、`go test -race`、`go vet`、23 项前端测试与 `git diff --check` 均通过；**随后已按用户授权原子部署并回读 `backgroundTransfers: true`**，但仍不得据此声称系统传输已经验收。

- **G2 BGProcessing 恢复入口、完成后清理与产物配置（本地门槛已通过，2026-08-03）：** App 在启动时只注册 `com.ethanzhou.MyPhotos.photo-backup-processing`，进入后台或 background URLSession 失败后才可能提交一次处理请求。handler 不接触 PhotoKit、新任务发现或手动队列；它只读取受保护登记册，并重新核验当前持久化账号、同一卷、服务 capability、用户策略和低电量状态后，才续接一项已暂存任务。系统完成回调已由前台队列持久化相同 server-confirmed outcome 后，才移除记录 UUID 所推导的私有暂存目录和对应账本；未完成/形状错误/持久化失败记录一律保留。显式 `Info.plist` 已以数组形式写入该 permitted identifier 与 `UIBackgroundModes=processing`，并保留既有照片/相机权限、启动屏、方向和 scene 配置；此前自动生成 plist 忽略自定义数组键的问题已由同步资源排除项修正。Xcode 27 beta 的 generic iOS `build-for-testing`、iPhone 17 Pro 模拟器与 iPhone 16 Pro 真机完整 **13** 项 `MyPhotosTests`、iPhoneOS 产物 `plutil` 检查以及 `git diff --check` 均通过。2026-08-03 的 0.8.5 受控验收 release 已返回 capability=true，因此后续真机可创建实际 background URLSession/BGTask；真实系统回调、终止恢复、网络/电量和服务器重启验收仍未完成。

- **G2 在途传输字节呈现与 Wi‑Fi 中断恢复（真机已通过，2026-08-04；2026-08-05 用户再次更正）：** 用户在实际 background URLSession 传输中观察到卡片的字节数与百分比不变。根因是登记册只在 MyNAS 为一个最多 4 MiB 的分片返回协议响应后才推进 received bytes，且 engine 尚未接收系统的发送字节回调。现在 URLSession 的发送进度按 task 的网络策略与 task ID 查回受保护登记册，并只为当前分片生成进程内、上限受账本分片范围约束的显示计数；它不写入 received bytes 或持久化队列。卡片在资源大小已齐全时以这些字节推进百分比，并明确写作“iOS 已发送…等待 MyNAS 确认”；完成项目数和“原件已安全上传”仍只由 MyNAS-confirmed outcome 更新。错误 session、越界字节或 App 重开都会回退到已确认的登记册位置。Xcode 27 beta 已成功编译 App 与新增测试；模拟器 XCTest 运行器在执行阶段卡住并被安全停止，因此新增 XCTest 尚无执行通过结果。**同日首轮真机曾长时间静止并在结束时跳至 100%，但随后用户在同一实际 G2 传输中确认卡片已于完成前实时更新，故本项真机可见行为通过。**普通启动时还会只为当前账号已有的 `transferring` 任务重建对应固定 session，以减少重建后失去委托回调的风险；新增的“当前账号 + transferring + 持久网络策略”纯选择回归及 App/测试目标已由 Xcode 27 beta generic iOS Simulator `build-for-testing` 成功编译；由于模拟器执行器此前会卡住，尚无 XCTest 执行通过结果。仅 Wi‑Fi 策略下断开 Wi‑Fi 后卡片正确进入“等待 Wi‑Fi”，恢复 Wi‑Fi 后无需手动备份即继续，且同一任务随后达到 MyNAS-confirmed 最终完成；该网络中断恢复路径已完整通过，不再是待验收项。

- **G2 真机传输中低电量中断（通过，2026-08-04）：** 在实际系统后台传输进行时，用户开启低电量模式后观察到自动任务暂停；关闭低电量模式后，未点击手动备份或重试，任务自动从 MyNAS-confirmed 位置继续，并最终显示“原件已安全上传”。这证明当前账号已启用的低电量暂停策略在该真机路径上不会把在途任务误标完成或遗失恢复能力。它不承诺 iOS 在 App 挂起时会即时取消网络 socket，也不覆盖服务重启、账号/卷、iCloud-only 或长队列。

## 阶段 H — 恢复、导出、删除与缓存管理

- **阶段目标：** 让用户安全取回、导出、软删除和管理本地缓存，且绝不以未浏览验证的原件作为删除依据。
- **用户可见成果：** H0 工作区在“本机”多选模式提供删除入口：默认只请求 iOS 将项目移入“最近删除”；可选“同时永久删除 MyNAS 备份”默认关闭，且只在每项有当前、sourceCommitted 的本机→MyNAS 映射时可选。本机删除成功后，服务端会再次检查版本、完整资源组、唯一映射和衍生 worker 状态；共享原件、旧版本或不完整备份被拒绝。若需找回，用户从系统“最近删除”恢复本机项目后重新备份。预览/原件下载或导出、缓存空间与 LRU 清理仍待实现。
- **iOS 端改动：** H0 使用一个 PhotoKit `performChanges` 批量删除请求，不触碰 Photos 文件系统；`PhotoBackupCoordinator` 只为当前源版本且已提交的资源组生成 MyNAS 删除候选，网格绿色勾也改为相同的严格判断。仍待下载/导出到系统分享或 Photos、下载校验、缓存索引/LRU。
- **MyNAS 后端改动：** H0 新增 owner-scoped 的完整资源组永久删除。服务端先在同卷短暂暂存原件目录和存在的衍生目录，事务提交后立即清除暂存；这仅用于失败回滚，不构成用户可见或可恢复的 MyNAS 回收站。不能复用无 owner 语义的通用文件删除流程。
- **数据模型/API 变化：** 新增批量 `/assets/delete`；删除 intent 只能携带本机映射证明，fingerprint 与存储路径永不返回客户端。恢复入口由 iOS 系统“最近删除”提供，恢复后通过正常备份管线写回 MyNAS。
- **前置依赖：** 阶段 E；“完整可浏览备份”状态与恢复演练。
- **验收标准和测试方法：** SHA-256 导出比对、断点下载、低磁盘 LRU、不同账号缓存隔离、单端/双端删除确认、误删除恢复、无衍生文件或验证失败时禁止“保留 MyNAS 后删除本机”。
- **明确不包含：** 绕过 PhotoKit 对其他 App 删除的限制；静默跨端删除。
- **状态与证据：** **进行中（H0 已于 0.8.4 部署并完成删除与恢复验收；H1 后端已于 2026-08-05 部署，iOS 当前实现与真实媒体流程仍未验收）。** E4 已写入按账号隔离并进行 SHA-256 校验的 metadata/grid/preview 文件缓存；H0 新增系统“最近删除”入口与受限 MyNAS 永久删除。2026-07-27，iPhone 17 Pro 模拟器将唯一 1200 × 1200 测试图先安全入库，再由系统确认移入“最近删除”；owner-scoped MyNAS 列表从 49 项降至 48 项，查询不再返回该资源。随后从系统“最近删除”恢复该图：本机从 49 变为 50 项，客户端完成 50/50 原始资源备份；MyNAS 由 50 增至 51 个资源组，新的记录为 `sourceCommitted`、`derivativeState=ready`、`browseReady=true`，有 1 份原始资源、3 个衍生文件和恰好 1 条当前内容映射，未沿用已删除的旧映射。先前重复内容的两条映射被正确拒绝，未误删共享原件。用户为释放有限测试媒体，已明确优先开发 H1：本地代码现在能把 MyNAS 图库的完整原件组逐资源同源下载、精确校验大小/SHA-256 后才经 PhotoKit 导入；当前 iPhone 映射仍可访问时会二次确认副本。独立的 MyNAS-only 删除以可见 asset version 作并发校验，服务端复核 owner、完整资源组、非共享映射和非 processing worker，客户端只将对应本机备份状态降为“需手动重传”，绝不调用 PhotoKit 删除。图库详情还新增“同时删除本机照片（移入‘最近删除’）”：它只在 MyNAS 返回本机的精确、已提交 mapping 且 PhotoKit 仍可访问该项目时提供，固定先由 PhotoKit 移入“最近删除”，再调用 H0 的带 mapping 证明删除；后者拒绝时远端保留，UI 明确提示本机可从“最近删除”恢复。两个结果都写入不同的 `remoteDeleted` 本机状态，防止自动备份静默重建。后端新增回归和既有完整 `go test ./...` 通过，新增的本机状态 XCTest 已被 Xcode 27 beta generic iOS `build-for-testing` 编译；两次 iPhone 17 Pro 模拟器 `test-without-building` 都未产生有效 result bundle，不能计为 XCTest 通过。2026-08-04，用户在真机下载时得到 PhotoKit `NSCocoaErrorDomain 4099`（图库 XPC 服务中断）；客户端现先预检资源类型组合，并且只对该中断在确认创建占位符尚未落库后延迟重试一次。该 Debug App 已由 Xcode 27 beta 成功构建、签名、安装并启动，尚待真实媒体重试，不能视为导入验收。2026-08-05，当前后端／Web 工作区经 23 项前端测试、Go 测试与 vet、ARM64 编译后原子部署至 MyNAS release `20260805T011724Z`；health 正常、systemd active、`photoDelete=true`，且二进制包含 H1 的 `/assets/{assetID}/delete` 路由。部署版本字符串仍为 `0.8.5`，不能以版本号区分此 release 与 2026-08-03 release；后续功能发布必须先递增版本号。尚未在真机把当前 iOS 实现的原件导入或直接删除流程验收；尚无 `CacheEntry` 索引、容量展示或 LRU 淘汰。

- **H1 v0.8.6 发布更正（2026-08-05）：** 上述 `20260805T011724Z` 是版本源未同步时的过渡部署，不能作为当前版本事实。现已把仓库 `VERSION` 与后端 health/capabilities 的版本源一并统一为 `0.8.6`，并在经过 23 项前端测试、生产构建、Go 测试/vet 及 ARM64 编译后原子部署到 `20260805T013621Z`；systemd active，health/capabilities 均回读 `0.8.6`，`photoDelete=true`、`backgroundTransfers=true`，H1 的 `/assets/{assetID}/delete` 路由仍在。GitHub Release 已以相同的 `v0.8.6` tag 发布；这不改变“当前 iOS H1 真实媒体下载／删除尚未验收”的状态。

- **H1 诊断更新（2026-08-04）：** 真机随后明确显示，当前 MyNAS 的可选“本设备 mapping”接口会返回当前客户端无法解析的响应。该查询只用于下载前的重复副本提示；因此 `feature unavailable`、404/405/501 与格式不兼容均降级为跳过该提示，继续走独立的原件下载。下载本身的同源 URL、精确大小和 SHA-256 校验没有改变。新 Debug App 已由 Xcode 27 beta 构建、签名、安装并启动，仍待真实媒体重试，不能计为下载/导入验收。

- **H1 下载进度与完成提示（本地实现，2026-08-04）：** 原件下载现使用单次、文件型 `URLSessionDownloadDelegate` 写入账号隔离的受保护临时目录；每 128 KiB（或一个资源结束）向详情页报告整个资源组的累计已下载字节，不把大视频读入内存。PhotoKit 导入只会在所有资源仍通过同源、精确大小和 SHA-256 校验后开始。成功后改为自动消失、不可交互的小型完成 toast，失败仍显示错误。UIKit 详情和遗留 SwiftUI 详情均已接入；Xcode 27 beta 真机构建成功，尚未以真实媒体确认进度节奏或完成导入。

- **H1 重复原件自动修复与远端预览恢复（本地实现，2026-08-05）：** 此前若可选设备 mapping 不可读、但系统图库其实已有未登记的相同原件，下载路径仍会 PhotoKit 导入一个新的物理副本；这会使“全部”同时出现一个已备份项目和一个“需要备份”项目。现在类型/尺寸只缩小范围：只要某个远端 asset 已有一条当前、server-committed 本机 mapping 作锚点，`PhotoBackupCoordinator` 就会在远端分页/映射变化后串行核验额外候选的全部资源角色、字节数和 SHA-256，并自动通过正常 MyNAS duplicate-session 登记全部匹配副本；它等待既有上传和映射恢复，不要求用户逐项点按，也不会自动删除任何 Apple Photos 项目。后台全库扫描以 `isNetworkAccessAllowed=false` 导出候选，不会为修复状态静默下载 iCloud 原件；用户主动打开某个详情时，该单项仍可按现有原件读取边界自动完成核验。候选未核验完成前不能隐式导入，只有用户明确选择再创建一份副本时才二次确认。新导入的 `PHAssetCreationRequest` 占位符 local identifier 会立即用于登记。“全部”在 metadata-only 全量本机快照上合并所有当前、已提交且指向同一 MyNAS asset 的本机副本为一个格子并显示份数；物理文件仍保留。当前 UIKit 远端详情也移除固定 330pt 黑底预览，按源媒体比例布局，并把现有 `MyNASMediaResourceLoader` 的 AVFoundation Range 流重新接到视频和 Live Photo 配对视频，进入详情即开始加载。新增合并 XCTest 已写入；Xcode 27 beta generic iOS Debug 构建通过，并已构建、签名、安装和启动到连接的“柚栀的 iPhone”。这仍只是构建/安装证据，自动关联结果及真实视频/Live Photo 播放需用户观察。

- **H1 预览与启动页比例打磨（Storyboard 修正已安装、模拟器视觉通过、真机待复核，2026-08-05）：** 首版只把 UIKit 详情占位符设为 44 pt，用户反馈没有明显缩小；媒体占位随后已覆盖三条实际路径：UIKit 详情 28 pt、远端网格 `RemotePhotoImageView` 16 pt、遗留详情 24 pt，播放按钮图标另固定为 14 pt。启动页的 PNG 内缩、资源改名和构建号 2/3 均未得到正确真机结果：改名版只剩白底，恢复原名版仍呈旧尺寸。这证明问题是系统 launch snapshot/整屏 `UILaunchScreen` 路径，而非 PNG 像素本身。build 4 已完全移除 `UILaunchScreen` 字典，改用编译后的 `LaunchScreenLayout.storyboardc`；Auto Layout 将承载整屏素材的图片视图最大宽度限制为 280 pt、保持 201:437 源比例并受四边 24 pt 安全边距约束，内部品牌标志在 iPhone 17 Pro 冷启动截图中约占屏宽五分之一。generic iOS 和 iPhone 17 Pro simulator 构建均通过；模拟器用 `--wait-for-debugger` 停在系统启动页并成功截图确认小图标，Xcode 真机实际产物也回读 build `4`、`UILaunchStoryboardName=LaunchScreenLayout` 且包含编译 storyboard。该版已安装并运行到“柚栀的 iPhone”，真机视觉仍须用户确认。

- **远端删除的 Tailscale 前置门禁（2026-08-06）：** 已保存 MyNAS 账号不再被当作当前可达。远端详情出现、App 回到前台以及最终删除动作边界都会用短超时读取当前账号的 MyNAS health；检查中或不可达时，所有会修改 MyNAS 的删除入口及已打开确认框中的非取消操作均置灰，并直接显示“Tailscale 未连接，无法删除 MyNAS 文件”。本机多选删除仍可只由 PhotoKit 移入“最近删除”，但“同时永久删除 MyNAS 备份”开关会关闭并置灰。配对删除会在 PhotoKit 发生任何变化前再次检查，因此确认框打开期间 Tailscale 断开时，本机和远端都不会删除。generic iOS Debug 构建、测试目标构建及 3 项 iPhone 17 Pro 模拟器门禁测试通过；Debug App 已由 Xcode 27 beta 安装并运行到“柚栀的 iPhone”。未通过自动化点击任何真机删除控件，断开 Tailscale 的真机视觉仍由用户观察。

## 阶段 I — 端侧 AI 搜索、人物/物体分类

- **阶段目标：** 在用户设备或其 MyNAS 的受控范围内提供隐私优先的搜索、人物/物体分类和可删除索引。
- **用户可见成果：** 选择性启用的本地语义/人物/物体/文字搜索；可查看并清除索引，人物不自动猜测姓名。
- **iOS 端改动：** Vision/Core ML/本地索引任务、权限说明、结果解释、索引清理与性能/电量策略。
- **MyNAS 后端改动：** 只在明确选择后保存必要索引元数据；树莓派不运行大型模型；不上传中心化服务。
- **数据模型/API 变化：** owner-scoped OCR/embedding/分类版本和删除标记，禁止跨用户检索。
- **前置依赖：** 阶段 F/H 的可控元数据和缓存；隐私审查与低端设备性能基准。
- **验收标准和测试方法：** 离线工作、撤销授权/删除索引、跨账号隔离、误报反馈、热/电量/内存基准。
- **明确不包含：** 云端人脸识别、跨用户身份识别、树莓派大型模型推理。
- **串行子阶段：** I1 元数据索引收尾 → I2 端侧分析队列与独立像素分析许可 → I3 Vision OCR → I4 系统视觉标签与相似度 → I5 MobileCLIP Core ML 选型/真机门槛 → I6 本地语义搜索 → I7 匿名人物聚类 → I8 统一搜索与人物界面 → I9 隐私、生命周期、性能和可选 MyNAS 派生索引同步总验收。任何时刻只推进一个子阶段，后续阶段不得和当前阶段并行开发或提前宣称。
- **每个子阶段的强制发布门槛（用户于 2026-08-06 明确）：** 子阶段只有同时满足以下条件才可标记完成并进入下一个：①实现、自动化回归和文档/安全边界同步完成；②`VERSION`、服务端 health/capabilities 版本源、CHANGELOG 与发布 README 统一到同一个候选版本；③由候选提交构建并原子部署 MyNAS 服务到树莓派，回读 systemd active、health 和 capabilities，版本必须精确一致；④由同一提交构建、签名并安装 iOS App 到 iPhone 16 Pro，完成该子阶段的真机验收；⑤验收通过后才把同一提交推送到 GitHub，创建 annotated tag 并发布对应 GitHub Release。即使子阶段只有 iOS 改动，也必须走完整的树莓派部署和 GitHub 发布门槛；任一验收失败都留在当前子阶段修复，不发布完成状态，也不开始下一阶段。
- **状态与证据：** **进行中（I1 本地可删除索引底座已实现，模型分析尚未开始）。** 搜索页默认关闭，用户明确启用后才读取当前 PhotoKit 权限范围内的元数据；I1 只索引媒体类型、拍摄日期、收藏、RAW 标记和像素尺寸。索引建立/更新不请求图像像素；用户输入查询并看到结果时，界面用索引中的 PhotoKit asset ID 按需请求本地缩略图，明确禁止 PhotoKit 网络访问，不把缩略图写入索引、不下载 iCloud 原件且不联网到 MyNAS。单一受保护 JSON 索引位于当前 `AppCache/<server>/<user>/search-index` 命名空间，包含 schema/model revision 与 `accountID + serverID + userID` 身份封套；错账号、损坏数据、重复 asset ID 和未知 schema 均失败关闭。同步会复用源版本未变的记录、替换变更版本并移除已不在权限范围的项目；清空索引保持用户选择，关闭或通用缓存清理会删除索引并保守回到未启用。搜索页可查看项目数/更新时间、手动更新、清空或关闭删除，并明确说明人物/OCR/物体属于 I2 且人物不会自动命名。用户已在 iPhone 16 Pro 主动启用，首建显示 **12** 个项目，与当时可访问的本机图库 12 项一致。首轮结果 UI 只显示日期和类型、没有视觉预览；现已改为 72 pt 缩略图、媒体类型主标题、日期/尺寸辅助信息，并可点入完整本地详情，失效权限项目给出明确提示。2026-08-06 真机复核中，`photo`、`video` 和 `2026-07` 分别返回 4、8 和 10 项，真实缩略图、媒体类型主标题、日期/尺寸辅助信息和普通照片详情入口均通过；用户随后以真实照片完成收藏切换验收，收藏检索标记可用，且切换收藏不会令已完成的备份重新排队或在统一时间线重复显示。用户也已在同一设备完成清空索引→重建、关闭并删除→重新启用：记录归零、默认关闭和 12 项重建均正确，未影响系统照片或 MyNAS 备份；随后 3 次更新、三类查询、详情往返和后台恢复的轻量热/电量/内存观察也获用户通过。全库 PhotoKit 元数据快照已从 `@MainActor` 移到独立 utility worker，只把 `Sendable` 值记录回传 UI，以消除原始元数据按需读取阻塞主线程的风险。对 PhotoKit 明确标为 `assetContentChanged == false` 的元数据变更，备份队列只推进受信任的本地修改观察值，保留原始上传/删除证明；不能明确分类的变更仍失败关闭并重新备份。Xcode 27 beta（27A5228h）iPhone 17 Pro 模拟器完整 **44** 项 `MyPhotosTests` 通过，其中 7 项 I1 回归覆盖默认关闭、增量更新、跨账号隔离、复制错账号索引拒绝、重复 ID 拒绝、清空/关闭及损坏索引恢复；最终候选已为“柚栀的 iPhone”构建、签名、覆盖安装并启动。现在仅剩同一候选版本的树莓派部署回读与 GitHub Release 门槛；完成前 I1 仍在进行中。Vision/OCR/人物/物体/embedding 尚未实现。

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

## 当前工作状态与下一优先级：阶段 I 的 I1 搜索结果真机复核

2026-08-05，用户明确要求进入阶段 I。I1 已把原先同步的类型/日期字符串过滤替换为默认关闭、按账号隔离、可查看和可删除的持久本地元数据索引；用户已在 iPhone 16 Pro 主动启用，首建 12 项与当前可访问图库一致。首次搜索暴露结果呈现缺口：日期被放在主标题且没有缩略图/详情入口。修正版已用 PhotoKit asset ID 按需显示禁止网络访问的本地缩略图，类型为主标题、日期/尺寸为辅助信息，并可点入本地详情；38 项模拟器回归通过且已安装启动真机。2026-08-06，用户进一步规定阶段 I 必须严格串行，且每个子阶段完成前都要部署同一候选版本到树莓派、回读服务状态、完成 iPhone 真机验收并发布同一提交的 GitHub tag/Release。因此当前仍停留在 I1：类型、日期、收藏搜索的视觉结果、收藏切换、索引清空/重建/关闭/重启用和轻量资源观察均已真机通过；下一步执行 I1 的版本同步、树莓派部署回读和 GitHub 发布；全部通过后才进入 I2 的端侧分析队列与独立像素分析许可。阶段 G 仍保留服务重启、账号/卷、iCloud-only 与长队列边界，但 Wi-Fi 中断恢复并达到 MyNAS-confirmed 最终完成已经通过，不能再次列为待验收。

**I1 真机收尾更新（2026-08-06，本地验收完成）：** iPhone 16 Pro 已复核 12 项索引状态；照片、视频、日期和收藏查询的缩略图、类型标题、日期/尺寸辅助信息及详情入口均通过，英文系统零结果页已替换为中文并真机通过。用户实测切换一张已备份照片的收藏后，备份仍为 12/12、没有重新排队或重复时间线项目；恢复收藏状态后结果一致。用户随后亲自完成索引清空→更新重建，以及关闭并删除→再次启用：索引按预期归零/默认关闭并重建回 12 项，系统照片和 MyNAS 备份均不变。最后的 3 次更新、三类查询、详情往返和后台恢复均通过轻量资源观察。全库元数据读取已移出主线程，完整 44 项模拟器测试再次通过，最终候选已覆盖安装。本地验收已完成；I1 仍须完成统一版本、树莓派部署回读和 GitHub Release，才可进入 I2。

阶段 F 的统一时间线、严格内容关联和版本边界已验收。G1 的“前台自动备份策略与可解释状态”已完成实现，并已在 iPhone 16 Pro 验证低电量和 Wi‑Fi/蜂窝发现门槛；它仍不是常驻后台服务。G2 已接入受保护登记册、file-backed background `URLSession` 与受限 `BGProcessingTask` 恢复入口，并在同一 iPhone 完成一次 212.1 MB 锁屏系统传输、一次开发终止/手动重新打开后的恢复完成、一次传输中低电量暂停/续传完成，以及一次 Wi‑Fi 中断等待、恢复并达到 MyNAS-confirmed 最终完成。Phase G 仍在进行：服务重启，以及 G1/G2 的 iCloud-only、账号/卷切换和长队列验收仍未完成；不得把有限的受控路径误称为无限制常驻上传。

2026-08-04，用户因测试媒体数量有限，明确把下一项开发优先级切到 H1。H1 会先让 MyNAS 图库详情能把完整原件组校验后写入 iPhone Photos；如果当前设备已有 MyNAS 确认的同一映射且该本机项目仍可访问，必须再确认才允许创建副本。即使旧 MyNAS 不支持或返回损坏的可选设备 mapping 接口，客户端也会从本机持久化的已完成、`committed`、账号匹配、远端 asset ID 匹配且源版本仍未变化的备份 job 恢复这一证明；它直接用 job 的 `localIdentifier` 查询 PhotoKit，而非依赖时间线首屏的 120 项分页。详情页和远端网格显示紧凑的绿色“本机已有同一原件”标记、下载按钮改为“仍然下载一份副本”，并在点按后再次确认。客户端会读取当前 Photos 授权范围的全量元数据（不取图、不下载 iCloud 原件）来发现候选，并每 120 项让出主线程；候选不会因元数据相似而升级为已存在。对于已有一条可信 committed mapping 的远端 asset，完整资源角色、大小和 SHA-256 核验及 mapping 登记现在由协调器在前台自动串行完成，用户无需逐项点按；没有完整证明时仍不得隐式导入。详情还提供单项“仅删除 MyNAS”操作：它永不请求 PhotoKit 删除本机项目，并且服务端仍要复核 owner、当前 asset 版本、完整资源组、非共享映射和非 processing worker。用户也可以在精确 mapping 已验证且本机仍可访问时，明确选择“同时删除本机照片（移入‘最近删除’）”。2026-08-05，H1 后端已部署，当前自动修复/Range 预览 iOS Debug App 已安装启动到真机；真实媒体行为仍须逐项验收，部署和安装本身不替代结果。

2026-08-04，`RemotePhotoLocalCopyVerificationTests` 在 iPhone 17 Pro 模拟器通过，随后 Xcode 27 beta 已成功构建、签名、安装并启动包含上述本机检测/标记改动的 Debug App 到连接的 iPhone 16 Pro。该记录仅证明构建与安装，不替代用户对旧分页项目、候选资源核验、下载或导入的真机行为确认。

2026-08-05，用户报告“全部”出现 2–3 份视觉相同的本机项目，分别显示为已备份和需要备份。诊断为旧下载路径已实际写入额外 PhotoKit 项目，而不是凭日期或缩略图的错误合并；旧文件有 mapping，新导入副本尚未登记。H1 现在阻止候选存在时的隐式导入，并以旧文件的可信 mapping 为锚点自动串行核验和批量登记额外本机副本；“全部”在登记后把它们逻辑合并。用户不必逐项打开远端详情或按“核验并关联”。它绝不会自动删除已存在的系统照片；若想释放空间，仍须使用系统 Photos 的删除流程。相同 Debug App 同时恢复按媒体比例的远端详情和视频/Live Photo 配对视频 Range 流，已在真机启动但实际关联/播放仍待用户验收。

**H1 真机验收状态更正（2026-08-05，用户报告）：** Xcode Beta 当前可用。用户确认 H1 的全部真机验收完成：受校验的原件下载/导入、重复副本保护与关联、MyNAS-only 删除、精确 mapping 的双端删除、删除后的本机状态及手动重新备份，以及受保护临时下载目录的清理均已通过。H1 因此可作为已交付能力；阶段 H 仍在进行，因为系统分享/导出、缓存容量呈现和 LRU 清理尚未实施。

H2 最终验收完成后，阶段 G 的下一未验收边界从服务重启开始，随后是账号/卷切换、iCloud-only 与长队列；Wi‑Fi 中断恢复后的 MyNAS-confirmed 最终完成已经通过，不得再次列为待办。

**H2 本地实现与模拟器门槛（2026-08-05）：** 远端详情现在可把 H1 的完整原件下载路径重新用于系统分享：每个资源仍须通过同源 URL、精确字节数和 SHA-256 校验，才以临时本地文件交给 `UIActivityViewController`；预览、未校验缓存和远端 URL 均不参与导出，分享结束后清理整个临时资源组。设置页会显示当前账号缓存占用/条目数，提供保留最近 256 MB 的文件级 LRU 清理和明确确认的“清除当前账号缓存”；淘汰顺序是完整临时下载、预览/Live Photo、缩略图、元数据/搜索索引，且只会读取 `AppCache/<server>/<user>`、跳过符号链接。新增 `RemotePhotoCacheManagerTests` 覆盖临时下载优先、同类 LRU、跨账号隔离和只回收孤儿临时组；Xcode Beta iPhone 17 模拟器的该 4 项测试通过，`git diff --check` 通过。仍须在真机确认多资源组分享、用户取消/完成后的临时文件清理，以及设置页缓存统计与清理的可见结果；在此之前 H2 不能标为已验收。

**H2 iPhone 16 Pro 首轮真机结果（2026-08-05，部分通过并发现阻塞缺陷）：** 当前 Debug App 已由 Xcode Beta 面向连接的 iPhone 16 Pro 构建、签名、覆盖安装并启动。一个 207 KB 的单资源 JPEG 经“导出已核验原件”成功进入系统分享面板，面板显示本地 JPEG 文件且未选择任何分享目标，证明单资源的下载、验证和系统交接路径可达。随后通过系统返回主页/重新进入 App 中断分享；只读复制应用容器后发现 `temporary-downloads` 仍有 1 个目录、1 个文件、约 204 KiB，故“取消/中断后清理”真机验收失败。多资源 Live Photo 分享未继续执行，设置页缓存清理也未点按；在补上启动期/前台恢复期的孤儿临时组回收并复测前，H2 保持未验收。首轮坐标操作还误触发一次“仅删除 MyNAS 项目”：本机 Photos 总数保持 12，备份页变为 11/12 且显示 1 个失败/等待恢复项目；不得把这次事故计为任何删除验收，后续自动化不得靠近删除控件。

**H2 iPhone 16 Pro 修复复测（2026-08-05，核心通过、最终验收仍进行中）：** App 冷启动现在只回收每个持久化远端账号 `temporary-downloads` 下不属于存活任务的非符号链接子项；详情页重新可见且系统分享已消失时也会释放仍被持有的导出组。单资源 `IMG_4324.JPG`（611,921 字节）和一个 6 资源实况照片组（4 个文档、2 张图像，共 11,080,404 字节）均完成逐资源校验并进入系统分享面板，未选择任何外部目标。两次都先只读确认临时组存在，再以 Home + 冷启动模拟中断；启动后容器审计均为 0 个临时文件、0 个临时子目录，同时 17,970,916 字节可复用缓存保持不变。设置页真机显示约 18 MB、170 个逻辑缓存条目，并可见刷新、按最近使用清理至 256 MB 和清除当前账号缓存入口；未执行清除。用户重新上传后首页也已恢复 12/12、100%。删除范围选择已改为非破坏步骤，UIKit 与备用 SwiftUI 详情均要求再出现一个独立的最终永久删除确认；本轮没有进入删除 UI。H2 的阻塞缺陷已修复，但正常下拉取消/实际完成分享的 activity 回调，以及用户明确同意后的缓存清理操作仍未真机执行，因此尚不标为全部验收。

**H2 iPhone 16 Pro 最终验收（2026-08-05，通过）：** 使用明确的项目测试图 `mynas-h0-delete-test-20260727.png`（46 KB）完成两条系统 activity 路径。第一条在分享面板外点按正常取消，未重启 App 的只读容器审计立即显示 0 个临时文件、0 个临时子目录；第二条选择系统 `Copy` 写入本机剪贴板，面板完成退出后同样在未重启 App 时归零，约 17.97 MB 可复用缓存保持不变。设置页“按最近使用清理至 256 MB”在当前约 18 MB 低于阈值时不删除缓存；随后按用户明确授权，通过独立确认清除当前账号缓存，UI 显示 `Zero KB / 0` 和“已清除 170 项缓存，释放 18 MB”，只读容器审计为 0 个文件、0 字节。清除后 MyNAS 图库重新读取 60 项，首页仍为 12/12、100%，证明只删除可重建的当前账号缓存，未影响系统照片或 MyNAS 原件。结合此前单/多资源分享、中断冷启动回收、4 项缓存测试和账号隔离，H2 标记为已验收；阶段 H 完成。
