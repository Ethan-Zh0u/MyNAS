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
| SwiftUI Views | 呈现本地图库、MyNAS 图库、连接、账号、手动备份队列及 G1 前台自动备份策略/原因；H1 的图库详情会把当前且精确确认的本机副本直接标注为已有，类型/尺寸候选则在后台自动执行完整资源核验，用户只在明确再创建物理副本时确认。统一“全部”会把已确认指向同一 MyNAS asset 的本机副本逻辑合并并显示份数，绝不删除物理 Photos 项目；当前远端详情保留 UIKit 稳定边界，但预览按源媒体比例布局，视频及 Live Photo 配对视频通过 AVFoundation Range 流自动加载，媒体未就绪时详情只显示固定 28 pt SF Symbol，远端网格占位固定为 16 pt；启动页改由 `LaunchScreenLayout.storyboard` 的 Auto Layout 最大宽度、安全边距和源比例约束控制，不再把整屏 PNG 直接交给 `UILaunchScreen` 缩放。同时只触发“下载到 Photos”、“仅删除 MyNAS”或（有精确本机 mapping 时）“同时移入本机最近删除”的原生确认，iOS 26+ 采用原生 Glass | 直接读取 `PHAsset`、发网络请求、决定备份完整性，或凭文件名、日期、尺寸/缩略图猜测跨端同一项目 |
| View models / stores | `LocalPhotoLibraryViewModel` 管理 PhotoKit 分页和授权；`RemotePhotoLibraryViewModel` 管理远端分页、离线缓存、下一页重试和前台 `/changes` 提示；`UnifiedPhotoTimelineViewModel` 以当前设备已确认的 backup job asset ID 合并本地/远端只读记录，并在“全部”使用 metadata-only 完整本机快照避免旧分页副本漏合并；`PhotoBackupCoordinator` 管理持久化队列、source/derivative 状态、失败分类、定向重试，以及以一个当前 server-committed mapping 为锚点，串行后台核验并登记同一 MyNAS asset 的额外本机副本；核验等待现有上传/映射恢复，不与大媒体任务并发，后台全库扫描固定禁止 iCloud 网络读取，最终身份仍由正常 MyNAS duplicate-session 确认。用户主动打开单项详情时可按现有原件读取边界自动完成 iCloud 候选核验。它还管理 G1 按 `accountID + serverID + userID` 隔离、仅随当前账号、先核验设备映射再入队的前台自动发现策略；`AccountStore` 管理当前身份 | 计算文件 hash、泄露跨账号状态、把原件上传解释成可浏览备份，或凭文件名/日期/尺寸/缩略图猜测跨端同一项目 |
| `PhotoLibraryClient` | PhotoKit 授权、分页、缩略图、变更观察、按已确认 `localIdentifier` 解析未加载到时间线首屏的本机项目，以及在不取资源的前提下读取当前授权范围元数据来缩小 H1 本机核验候选；所有 resource 导出及 H1 在完整远端资源组已校验后的一次原子导入，并把创建占位符的 local identifier 返还给登记层；导入前以 PhotoKit 预检资源类型组合，若图库 XPC 服务中断，仅在创建占位符尚未落库时重试一次；若用户明确选择图库双重删除，先以一次 `performChanges` 将精确本机项目移入“最近删除” | 远程图库同步、基于日期/文件名判断远端重复项，或由 MyNAS 删除请求删除 Apple Photos 项目 |
| `PhotoBackupUploader` | manifest、分片、hash header、前台重试、完成请求 | 背景 URLSession、自动调度、预览下载 |
| `MyNASConnectionService` | URL/二维码验证、capabilities/me/volumes 握手 | Tailscale SSO、存储密码、绕过 TLS |
| `MyNASRemoteMutationPreflight` | 以短超时、无代理的当前账号 MyNAS health 请求证明 Tailscale 私网路径在破坏性操作发生前可用；向 UIKit/SwiftUI 提供失败关闭的 checking/available/unavailable 状态 | 推断 Tailscale App 自身 UI 状态、缓存长期在线状态，或代替服务端 owner/version/resource-group 删除复核 |
| `RemotePhotoLibraryClient` | owner-scoped asset 分页、ETag/304、相对 URL 同源校验、grid/preview SHA-256 校验、网络失败时使用账号隔离缓存，以及供 AVFoundation 按 Range 读取原视频的无代理流通道；H1 会使用当前设备精确 mapping（不可用时由持久化、当前源版本的 backup proof 提供同等本机提示）做副本确认、用单次文件型下载委托把每个原件写入账号隔离临时目录并报告累计字节、核验大小/SHA-256、调用独立 version-bound MyNAS-only 删除，或在 PhotoKit 已确认本机移入“最近删除”后调用 H0 的映射证明删除 | 文件名/日期猜测重复项、长期原件缓存 LRU、后台持续同步，或本机 Photos 删除 |
| 持久化/缓存 | 账号 JSON、备份队列、G1 自动备份策略及 G2 任务登记册使用 Data Protection；G2 actor 暂存器逐资源复核副本的大小/SHA-256 后，登记册才以 server/user/volume 绑定当前源版本与安全相对暂存文件名，并写入与前台协议共用的 manifest/完成 request body；按需分片准备器会生成唯一且不覆盖既有文件的受保护 body；记录至多保留一个 system task 的 ID、协议阶段、分片范围、body/response 文件和响应状态/长度，防止回调被错误绑定。`PhotoBackupBackgroundTransferEngine` 用按网络策略隔离的 file-backed background session 处理 create/part/complete，UIKit adapter 在系统重新启动 App 后接收回调；受限 `BGProcessingTask` 只续接已登记任务并在每次运行重验账号、卷、capability、策略和低电量，绝不发现新的 PhotoKit 项目。引擎在暂存和续接的最终边界再次读取低电量：策略要求暂停时不写入新记录/任务，已有自动任务保持等待。每次登记册成功写入后，引擎发布一个瞬时 revision；协调器立刻将活跃自动请求的 MyNAS-confirmed outcome 对账进其 `@Published` 队列，因此可见卡片不依赖销毁/重建才能更新。前台队列先原子写入同一 server-confirmed 完成结果，再允许删除已完成记录的精确私有暂存目录与账本；失败会保留记录。当前受控部署 capability=true，允许进行真实系统会话验收，但不能把该开关视为成功传输证据 | 尚未完成其余真实条件回调/终止验证、`CacheEntry` 索引、容量上限、LRU 或用户清理入口 |

2026-08-03 的 iPhone 16 Pro 受控观察已验证一次约 212.1 MB 的任务由 background `URLSession` 创建、在锁屏后回调并以 MyNAS `outcome` 更新为 6/6 原件已安全上传；这更新了上表的“尚未完成真实系统回调”历史状态。它不覆盖终止、条件变化、服务重启或长期队列恢复。

同日第二个 G2 真机场景在确认“iOS 正在处理后台传输”后，由开发工具以不可捕获终止信号结束 App 进程；15 秒后手动重新打开时，界面仍诚实显示 6/7、212.1/272.4 MB，而没有误报完成，随后未点击备份即达到 7/7、272.4/272.4 MB。该观察更新上表的“尚未完成终止验证”历史状态：它证明已登记的系统任务和前台队列可在该开发终止/手动重新打开路径上恢复并以 MyNAS outcome 完成；它不证明数据在进程已终止期间持续传输，不等同用户从切换器强制退出，也不覆盖网络/电量、服务重启或长期队列恢复。

2026-08-04 修复了一条前台呈现链路：background `URLSession` callback 先改写受保护登记册，过去 `PhotoBackupCoordinator` 只在备份页恢复时才读取它，造成卡片需要重新进入才显示完成。登记册每次成功落盘才发布瞬时 revision；协调器仅对内存中仍活跃、且当前账号与当前 PhotoKit 源版本匹配的自动请求立即对账并发布队列变更。它只反映已持久化、MyNAS-confirmed 的状态，不试图把 iOS 接管的上传按字节映射为 UI 实时进度；真机回调下的卡片即时更新仍待观察。

2026-08-04 的另一条真实 G2 传输完成了低电量中断路径：任务传输中开启低电量模式即暂停，关闭后无需点备份或重试便以 MyNAS-confirmed 位置自动续传，最终显示“原件已安全上传”。它验证了策略暂停/恢复与登记册重接的这一条真机路径，但不承诺系统会在 App 挂起时立即断开 socket，也不覆盖服务重启、账号/卷、iCloud-only 或长队列。

`PHAsset` 仅在 `PhotoLibraryClient` 内使用；UI 传递的是 Sendable 的 `LocalPhotoAsset` 值。网格缩略图使用 `PHCachingImageManager` 与 `isNetworkAccessAllowed = false`，显式备份资源导出才允许 iCloud 下载。

2026-08-04 起，G2 还把系统上传的 in-flight 字节呈现与持久状态分开：background URLSession 的发送回调只生成内存中的、受当前已登记分片上限约束的显示值，供当前前台卡片推进。它既不改写 MyNAS 权威的 received bytes，也不写回持久队列；App 重开、任务不匹配或超出分片范围时一律只显示已由 MyNAS 确认的位置。卡片会明确标明该部分“等待 MyNAS 确认”，而“原件已安全上传”仍只来自完整 outcome。首轮真机一度长期静止并在结束时跳至 100%，但同一实际 G2 传输随后已确认在完成前连续更新，故实时呈现的真机观察通过。普通前台启动还会为当前账号的已登记 `transferring` 任务重建其固定 session，以便系统继续向新进程投递委托回调；此加固不创建请求、不改确认偏移，待本地回归。

该普通启动重连的 App 与测试目标已于 2026-08-04 用 Xcode 27 beta generic iOS Simulator `build-for-testing` 成功编译；新增回归只验证当前账号、`transferring` 状态及已有网络策略的选择，避免 XCTest 创建真实 background URLSession。模拟器执行器曾卡住，因此不把这项编译门槛写作 XCTest 通过。

## 后端分层

| 层 | 当前职责 | 已知边界 |
| --- | --- | --- |
| middleware / Tailscale | 身份存在性、写请求 `X-MyNAS-Request: 1`、Origin 规则 | 安全前提是生产 Go 只监听 loopback 且 Serve 配置正确 |
| Photos handshake | capabilities、pairing、稳定 server ID、photo user、可选卷 | `photoAssets: true` 表示可原始入库，不能推导出可浏览图库 |
| 上传会话 | `owner + volume + device + local identifier + fingerprint` 精确隔离的 session、manifest、offset、4 MiB 分片 hash、完整文件 hash、去重；启动时把旧 session 唯一约束迁移为含 volume 的约束；仅在显式后台 capability 的启动期，按七天 TTL 清理已验证的 staging 目录和对应未完成 metadata | 仅手动/前台客户端；没有运行中 TTL、并发/断电故障注入或完整孤儿扫描 |
| 提交 | 同一卷内 stage directory rename 到 originals，再写 SQLite asset/resource/mapping transaction | 当前没有跨文件系统/SQLite 的 crash journal 或目录 fsync 恢复扫描 |
| 衍生 worker | 单线程领取持久化 job；验证原件 hash；HEIC/HEIF 先由 `heif-convert` 解出主图，DNG/ProRAW 先由 `simple_dcraw -E` 提取内嵌全尺寸 JPEG，其余普通媒体由 FFmpeg 处理；再生成版本化衍生文件并复核 JPEG/hash 后提交 ready | 缺少必要解码器时明确失败而不替换原件；所有衍生文件都是可丢弃视图 |
| 远程浏览 | owner-scoped assets/detail/changes、tiny/grid/preview/original；稳定分页、ETag/304、Range/206，并把 PhotoKit UTI 映射为标准 HTTP MIME | 0.8.1 热修复已部署并以 45 项真实资产验收；iOS 已完成独立只读网格、preview、账号隔离缓存、视频 Range 播放、资源清单和前台 changes 提示；原件导出、缓存管理及 Live Photo 真实设备回归仍待完成 |

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

1. 阶段 E 的 worker 与上传提交解耦：原件 hash/元数据完成不依赖耗时转码；派生失败可重试且不损坏原件。
2. 每个 Photos 查询和文件读取都必须先按 owner 过滤 asset，再解析服务器生成的相对路径。不得从请求文件名或通用 file API 推断授权。
3. cursor、ETag、derivative recipe/version 和 asset version 属于远程浏览层；不能塞回本地 `PHAsset` 模型。
4. G1 只能在 active scene 内用 PhotoKit 变化、网络和电量条件触发前台队列；服务器支持设备映射读取时，映射请求必须成功后才能自动入队，失败不是空结果。它不注册 BGTask，也不使用 background URLSession。自动备份在锁屏/退出/回收后仍持续的能力，必须使用系统允许的 BGTask/background URLSession，不能把 foreground `Task` 描述为常驻后台服务。
5. 恢复、导出、删除和缓存是独立层。删除本机的资格只来自已验收的 `browseReady` + 恢复路径，不能仅来自原件入库。
6. G2 因 system background URLSession 唤醒 App 时，UIKit completion handler 必须先在主线程写入内存，再以相同 identifier 重建对应网络策略 session；系统重建时就可能开始投递回调。`urlSessionDidFinishEvents` 只能在所有已排队事件处理后，回到主线程取出并调用该 handler。未知 identifier 不得创建 session，立即交还其 handler。
7. G2 不能只相信前台观察到的低电量状态。引擎必须在 PhotoKit 资源已导出、即将写入暂存/创建系统 task 的最后边界，以及重新续接既有记录的边界再次检查当前状态；策略要求暂停时不写新登记册、不猜测断点，自动队列保持 `waiting`。这不表示 iOS 在 App 挂起时必然立即中止已拥有的 task，真实传输中断恢复仍须单独验收。
8. G2 的登记册是系统 callback 的持久真相，SwiftUI 队列则是可见投影。每次成功写入登记册后都必须让活跃前台投影重新对账；不得要求用户靠离开再进入页面才能看见已确认 outcome。反之，revision 不是传输进度或成功信号：只有队列成功持久化同一 MyNAS-confirmed outcome 后才能显示完成并清理登记册。
9. H1 的下载在全部资源通过同源、大小和 SHA-256 校验前不得调用 PhotoKit；导入只使用公开 `PHAssetCreationRequest`，结束后清除账号隔离临时目录。若可选服务器 mapping 不可用，重复下载提示只能来自账号匹配、已完成/`committed`、asset ID 匹配且本机 PhotoKit 源版本仍相同的持久化 backup proof，并按该 proof 的 `localIdentifier` 直接查询当前 PhotoKit，不能受分页时间线影响；不可由文件名、日期、尺寸或缩略图推断。全量 Photos 元数据只能产生核验候选，绝不能直接产生绿色已存在标记；存在一个当前 server-committed 锚点时，协调器必须在前台后台串行完成全部候选的资源角色、字节数和 SHA-256 核验，并自动把匹配副本送入正常 MyNAS duplicate-session 登记，用户无需逐项点按。核验不得与现有上传或映射恢复并发，也永不自动删除 Photos 项目；只有用户明确要另建物理副本时才需要二次确认。新导入项目必须尽快以 creation placeholder 返还的 local identifier 登记当前设备 mapping，避免下次显示为无关的“需要备份”项目。H1 的直接删除与 H0 配对删除是不同 endpoint：删除仅 MyNAS 时必须以当前 gallery version、owner、非共享映射与非 processing worker 为边界，成功后只能失效本机 backup proof，不能请求 PhotoKit 删除。若用户选择图库“双重删除”，必须先由 PhotoKit 确认精确 mapping 的本机项目已移入“最近删除”，才可调用 H0；H0 拒绝时不得把远端标为删除成功，且要说明本机项目可在系统“最近删除”恢复。
10. 保存过 `.ts.net` 地址只证明历史连接，不能启用当前破坏性操作。所有修改 MyNAS 的删除控件必须由当前 health 结果驱动：checking/unavailable 时失败关闭、置灰并明确显示 Tailscale 不可用；App 回到前台要刷新。最终确认后必须重新核验，配对删除的核验必须发生在 PhotoKit `performChanges` 之前，防止确认期间断线后只删本机。纯本机 PhotoKit 删除不受该远端门禁影响。服务端的 owner、version、完整资源组、共享映射和 worker 状态复核仍是独立的最终授权边界。
