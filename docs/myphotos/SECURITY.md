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
| 跨用户/卷上传、读取或删除 | session 查找和提交带 `owner_user_id + volume_id`，会话唯一约束还含 device/local identifier/fingerprint；启动迁移会把旧的少卷约束原子替换为含 volume 的约束。设备映射主键含 owner，去重键含 owner+volume；远端 asset、changes、资源读取和 H0 删除均按 owner 再校验 | `photos_uploads.go`、`photos_browse.go`、`photos_delete.go`；已覆盖 owner 隔离、跨卷会话不复用、旧库约束迁移、越权读取不泄露路径和删除候选重复校验，仍须在后续改动中保持该边界 |
| 路径穿越/符号链接 | 原件目录从 server opaque owner/asset ID 构造；输入文件名经清理，DB 仅存相对路径；读取使用 owner-scoped asset/resource 路由而不返回存储路径 | E3 已验证路径不泄露；symlink 与异常卷场景仍须作为阶段 J 的故障/安全回归覆盖 |
| 分片篡改/破损 | 4 MiB 上限、offset、`X-Chunk-SHA256`、每块 `File.Sync`、完成时完整 SHA-256；不完整 Live Photo 不能提交 | 坏 chunk checksum 与不完整资源组已有测试；目录 fsync、崩溃恢复扫描和断电语义尚未验收 |
| 误把低质量副本当备份 | 导出全部 `PHAssetResource`，不转 JPEG；`source_state` 与 `derivative_state` 分开；只有 required derivatives 均 ready 才能形成 `browseReady` | E1–E4 已部署并完成真实远端浏览验收；兼容字段 `backedUp` 仍只代表原始资源已安全上传，不能单独用于删除判断 |
| 错误合并或重复导入本机原件 | 元数据仅缩小候选范围；自动修复必须先有当前 server-committed 本机 mapping 作锚点，再串行比对全部资源角色、字节数和 SHA-256，并由正常 MyNAS duplicate-session 写入每个额外 local identifier。核验等待现有上传/映射恢复，后台扫描使用 `isNetworkAccessAllowed=false`，不会静默拉取 iCloud 原件；永不自动删除 Apple Photos 项目，明确再导入一份仍需二次确认 | 2026-08-05 Xcode 27 beta generic iOS 构建通过并已安装启动到连接的 iPhone；历史副本自动关联和大视频候选的实际耗时仍待真机观察，不能仅由安装结果宣称验收 |
| 转码损坏原件 | 衍生 worker 只读原件；普通媒体经 FFmpeg，DNG/ProRAW 经 `simple_dcraw`，HEIC/HEIF 先由 `heif-convert` 提取主图；输出位于独立 derivatives 目录 | 自动化与部署前后清单均覆盖原件 SHA-256；55/55 旧预览已按 `photos-browse-v2` 重建并验证主图，但灾难恢复级完整性扫描尚未实现 |
| 账号串缓存 | account/server/user namespace；账号、队列、自动策略及 G2 后台任务登记册使用 Data Protection 原子写入；登记册还绑定卷、当前源版本、资源 hash 与受限相对暂存文件名，暂存器复制后再次核对大小/SHA-256 才登记，并保存与前台协议共用的创建会话/完成 request body；按需分片文件只从已验证的副本读出、命名不可越界且不覆盖既有文件；每条记录至多绑定一个系统 task 的 ID、协议阶段、分片范围、body/response 文件名与 HTTP 状态/响应长度，错误形状在落盘前失败，传输完成只标为等待解析；当前台队列成功原子写入相同确认 outcome 后，才允许依据记录 UUID 的受限私有目录删除暂存副本与账本，失败一律保留；G2 engine 只有 capability、当前账号、卷与已启用策略全匹配才会在 resume 前落盘 task，网络策略分离 session，策略收紧/低电量/账号切换会取消并清除本地断点假设，并在暂存或续接的最终边界再读低电量状态；受限 BGProcessing handler 不读 PhotoKit，只能续接当前持久化账号/卷/策略仍匹配的已登记记录，并在低电量时保持暂停；服务端 capability 默认关闭，只有 `MYNAS_PHOTOS_BACKGROUND_TRANSFERS=1` 才会声明 true；该启动期只会按七天 TTL 删除经选定卷和精确 staging 路径核验的未完成会话，异常数据保持；远端 metadata/grid/preview 缓存按 server/user 隔离并验证 SHA-256 | `AccountContext`、persistence stores、`PhotoBackupAutomaticEligibility`、`PhotoBackupBackgroundTransferEngine`、`PhotoBackupBackgroundProcessingScheduler`、`MyPhotosTests/PhotoBackupBackgroundTransferTests.swift`、`RemotePhotoLibraryClient`；2026-08-03 的真机回归证明自动策略在账号三元组不匹配时失败关闭，且 Wi‑Fi/低电量/映射核验门槛先于导出；同一 iPhone 16 Pro 在真实低电量模式下实际显示“低电量模式已暂停”，关闭低电量后恢复“前台自动发现中”，关闭 Wi‑Fi 显示 5G 后在 Wi‑Fi-only 策略下显示“等待 Wi‑Fi”，改为允许蜂窝数据后恢复“前台自动发现中”；每次均已恢复自动策略为关闭。G2 本地完整性测试已于同日在 iPhone 17 Pro 模拟器及 iPhone 16 Pro 真机通过，系统任务账本和 capability 失败关闭测试已在同一模拟器完整 10 项套件通过；后端 capability 默认关闭/显式开启、跨卷会话隔离、旧库迁移和受限 TTL 清理回归也于同日通过。新增 BGProcessing handler、完成后清理与显式 Info.plist 的 13 项本地套件已在 iPhone 17 Pro 模拟器及 iPhone 16 Pro 通过。当前 0.8.5 的受控验收 release 已明确 capability=true，尚未创建或验证实际系统 task、background URLSession 回调或 BGTask；H2 的账号隔离容量统计、LRU、临时原件回收、正常取消/完成分享回调和显式缓存清理均已完成真机验收 |
| 跨 background session 同号回调 | G2 task 持久化 `networkPolicy + taskIdentifier` callback identity；仅 Wi‑Fi 与允许蜂窝 session 的同号 task 不能互相匹配，保存时拒绝同一策略命名空间中的重复 identity，取消同样只查询对应 session。旧登记册的缺失策略字段只能由唯一真实 callback candidate 补写，多个候选失败关闭 | 2026-08-03 新增等编号、不同 session identity 与旧 task 解码回归；Xcode 27 beta generic `build-for-testing` 与 iPhone 17 Pro 模拟器完整 15 项纯本地套件通过。随后 iPhone 16 Pro 的单账号 Wi‑Fi task 完成了锁屏回调；跨 session 冲突本身仍只由本地回归证明 |
| G2 真实锁屏回调 | 自动策略、账号/卷、完整暂存资源和 MyNAS 完成响应均须在登记、系统 task 和队列写入边界复核；不能由 transport completion 自行推断备份成功 | 2026-08-03 iPhone 16 Pro 仅 Wi‑Fi、低电量暂停策略下，未点手动备份的约 212.1 MB 资源组先显示“iOS 正在处理后台传输”，锁屏 90 秒后显示 6/6 原件已安全上传、无错误。该单次成功不替代终止、策略变化或服务重启的安全回归 |
| G2 开发终止/重新打开恢复 | 在 `resume()` 前落盘的 task→账号/卷/资源组绑定及 MyNAS outcome；重新启动时只通过同名 background session 和当前账号/策略重接，不把未完成 task 猜成完成 | 2026-08-03 第二个真实 G2 资源组在“iOS 正在处理后台传输”时被开发工具以不可捕获信号终止 App；15 秒后手动打开时仍为 6/7、212.1/272.4 MB，随后无手动备份达到 7/7、272.4/272.4 MB。它证明此开发终止/重新打开路径不误报完成且能恢复 MyNAS outcome；不证明进程终止期间继续传输，不等同用户强制退出，也不替代网络/电量、服务重启或长队列回归 |
| G2 系统重启回调交接空窗 | UIKit completion handler 只在主线程内按允许的固定 session identifier 暂存，并且**先于**同名 session 重建；全部 session 事件交付后才在主线程调用。未知 identifier 不创建 session、立即交还 handler | 2026-08-03 Xcode 27 beta 的 iPhone 17 Pro 模拟器完整 15 项纯本地测试与编译通过；该验证不创建上传或系统回调，真机条件验收仍暂缓 |
| G2 低电量交接空窗 | G2 engine 在自动策略要求低电量暂停时，于写暂存记录/创建系统 task 之前及续接前再次读取系统状态；拒绝时不创建新记录，自动 job 保持等待 | 2026-08-03 通过可注入的低电量状态，在 capability=true 和完整资源组已准备好的引擎入口验证不会落盘记录；截至 2026-08-04 的 iPhone 17 Pro 模拟器完整 17 项纯本地套件通过。随后真实 G2 传输中开启低电量正确暂停，关闭后无需手动操作即续传并得到 MyNAS-confirmed 完成，故该真机中断/恢复路径通过；不推断 App 挂起期间即时取消 socket，也不替代服务重启等回归 |
| G2 callback 已落盘但前台卡片滞后 | engine 只在受保护登记册成功写入后发布瞬时 revision；协调器立即以当前账号和当前源版本对账 completed record，并且只能在同一 MyNAS-confirmed outcome 已成功写入持久队列后显示完成、移除登记。账号/版本不匹配或队列写入失败一律不清理、不误报 | 2026-08-04 新增登记册变更 revision 回归；Xcode 27 beta 的 iPhone 17 Pro 模拟器完整 17 项纯本地套件与 `git diff --check` 通过。该测试不生成真实系统 callback；下一次真机完成回调仍须观察卡片无需重新进入即可更新 |
| 测试宿主意外恢复队列 | iOS XCTest 宿主检测 `XCTestConfigurationFilePath` 后只渲染空视图；`AccountStore` 仅由生产 `MyPhotosProductionRoot` 创建，因此纯本地测试不创建账号、`PhotoLibraryClient` 或 `PhotoBackupCoordinator`，也不由 `PhotoBackupView` 的启动任务恢复已持久化的手动队列 | 2026-08-03 首次真机测试暴露旧宿主会恢复既有手动工作；修复后的 `testXCTestHostDisablesProductionLifecycle`、当前图库总数摘要回归与 G2 本地完整性测试已在 iPhone 16 Pro 真机通过。真机正常 App 重启后显示当前可访问的 2/3 项、自动关闭且未产生新队列；Limited Photos 的后续“保留当前选择/选择更多照片”系统确认仍必须由用户决定 |
| 本地照片过度访问 | 用户授权、Limited 管理、缩略图不隐式 iCloud 下载 | `PhotoLibraryClient`；显式备份允许 iCloud 下载，必须是用户触发 |
| 日志/遥测泄露 | 不设计默认中心化遥测；文档禁止记录媒体内容/秘密 | 后续日志、诊断和 AI 索引必须落实脱敏/删除策略 |
| 删除误操作或断线时半完成 | H0 默认仅请求 PhotoKit 将本机项目移入“最近删除”；MyNAS 永久删除默认关闭，且服务端重复核验当前源版本、完整资源组、唯一 owner 映射和派生状态。客户端不把已保存账号等同于在线：会在页面/前台恢复及最终动作边界读取当前 MyNAS health；checking/unavailable 时所有 MyNAS 删除操作置灰并明确显示“Tailscale 未连接”。配对删除必须在 PhotoKit 变化前完成最终核验 | H0 已完成受限删除与系统“最近删除”恢复回归；2026-08-06 generic iOS/测试构建及 3 项模拟器门禁测试通过，Debug App 已安装运行但未自动点击真机删除控件。MyNAS 没有用户可恢复回收站，长期恢复演练和“仅保留 MyNAS”承诺仍未实现 |

> 进度呈现边界（2026-08-04）：G2 URLSession 发送字节只以已登记的 network policy 与 task ID 查找当前 task，且临时值被当前 part byte count 限制；它不写入登记册的 received bytes 或持久队列。重启、身份不匹配、异常或越界时丢弃临时值，只显示 MyNAS 已确认偏移；卡片必须写明“等待 MyNAS 确认”，不会因该计数显示原件已安全上传。实现已经通过 iOS App/测试目标编译；首轮重新构建后的真机观察曾到结束才跳至 100%，但同一实际传输随后在完成前实时更新，故可见进度通过。它仍不能推断 iOS 将持续或按固定频率投递发送进度。

> 状态更正（2026-08-03；2026-08-05 补正）：上表“账号串缓存”行中“尚未创建或验证实际系统 task”的句子记录的是真机观察之前的本地门槛。随后同一 iPhone 16 Pro 已完成一次 212.1 MB 锁屏 G2 系统 task、回调解析与 MyNAS-confirmed outcome，并完成开发工具终止后恢复、在途低电量暂停/续传完成，以及 Wi‑Fi 中断等待、恢复并达到 MyNAS-confirmed 最终完成。服务重启、账号/卷、iCloud-only 与长队列仍未验收；Wi‑Fi 中断恢复不再是待办。

> H2 本地安全边界（2026-08-05）：系统分享只能接收 H1 原件下载器已逐资源验证同源 URL、字节数和 SHA-256 后生成的受保护临时文件；不允许以预览、缓存命中或远端 URL 替代。分享完成/取消回调会移除完整临时组。缓存管理器只扫描当前 `AppCache/<server>/<user>` 根目录下的固定种类，跳过符号链接；清理以临时下载、预览/Live Photo、缩略图、元数据/搜索索引的顺序执行，并以文件修改时间作为受控 LRU 访问时间。Xcode Beta iPhone 17 模拟器的 4 项新缓存测试已覆盖淘汰顺序、同类 LRU、账号隔离与孤儿临时组回收；真机状态由下述更正继续约束。

> H2 真机安全更正（2026-08-05）：iPhone 16 Pro 的单资源 JPEG 已成功进入系统分享面板，且没有选择外部目标；但通过返回主页/重新进入 App 中断分享后，只读容器审计仍发现 `temporary-downloads` 下 1 个约 204 KiB 的孤儿组。当前实现不能把 activity completion handler 当作唯一清理边界，必须在安全启动/前台恢复时回收不属于活跃分享的旧临时组，并保留账号根目录约束。首轮 Device Hub 坐标验收还因异步 action sheet 出现后第二次点按而执行了 MyNAS-only 永久删除；本机 Photos 仍保持 12 项。后续自动化必须避开删除控件，且删除 UI 需要单独评估如何防止延迟双击落入破坏性确认项。

> H2 修复复测安全状态（2026-08-05）：启动清理只遍历持久化远端账号的 `temporary-downloads` 子目录并继续跳过符号链接；不会调用账号全缓存清理。iPhone 16 Pro 上单资源 611,921 字节和多资源 11,080,404 字节导出组均在分享面板存活时由只读容器复制确认存在，经 Home 中断与冷启动后变为 0 个文件、0 个子目录；17,970,916 字节预览/缩略图等缓存保持不变。分享面板显示多资源组为 4 个文档、2 张图像，未选择外部接收方。删除 UI 的范围选择不再执行突变，必须再通过独立 alert 点按最终破坏性操作；本轮未打开删除 UI。正常 activity 取消/完成回调和显式缓存清理仍未真机执行，不能据此扩大为 H2 全部安全验收。

> H2 最终安全验收（2026-08-05，通过）：使用非个人项目测试 PNG 验证系统分享正常取消和本机 `Copy` 完成，两条 activity 回调均在进程存活时把临时组归零；此前 Home 中断/冷启动的单资源和 6 资源组也已归零且不误删约 17.97 MB 可复用缓存。当前缓存低于 256 MB 时 LRU 不执行删除；用户明确授权后，确认框只清除当前 `AppCache/<server>/<user>`，UI 为 `Zero KB / 0`，只读审计为 0 文件、0 字节。随后远端图库重新载入 60 项且备份仍为 12/12，证明 Photos 和 MyNAS 原件未被触及。结合 4 项模拟器缓存回归，H2 的分享临时文件生命周期、账号隔离容量统计、LRU 与明确缓存清除边界验收通过。

> 远端删除的 Tailscale 门禁（2026-08-06）：`MyNASRemoteMutationPreflight` 通过当前账号的无代理 health 请求证明私网路径可达，短超时失败关闭。远端 UIKit/SwiftUI 详情会在页面出现和 App 回到 active 时刷新；不可达时底部删除入口和已打开确认框中的非取消操作同时禁用并显示明确原因。本机删除确认页只禁用“同时永久删除 MyNAS 备份”，不阻止纯 PhotoKit“最近删除”。所有远端删除函数仍在动作边界重新检查；配对路径在任何 PhotoKit 删除请求前检查，避免连接状态过期造成只删本机。该门禁是客户端事故防护，不取代 MyNAS 服务端的 owner/version/resource-group 授权校验。

> I1 本地索引安全边界（2026-08-06）：索引缺失即视为未启用；只有用户在搜索页明确启用后，客户端才读取当前 PhotoKit 权限范围内的类型、日期、收藏、RAW 和尺寸元数据。索引建立/更新不请求图片或视频数据；全库元数据快照在独立 utility worker 中读取，只有 `Sendable` 值记录回到 UI actor。用户执行查询并显示结果时，客户端只以索引内的 PhotoKit asset ID 请求本地缩略图，`isNetworkAccessAllowed=false`；缩略图不写入索引，不自动下载 iCloud 原件，也不调用 MyNAS API。I1 不写入人物姓名、生物特征、OCR、定位或 embedding。索引使用 Data Protection 原子写入当前 `AppCache/<server>/<user>/search-index`，文件内再次绑定 `accountID + serverID + userID`、schema version 和 model revision；身份不符、损坏、重复 asset ID 或未知 schema 失败关闭。清空、关闭删除和通用账号缓存清理均有明确删除路径。用户已在 iPhone 16 Pro 主动启用，首建和本轮更新均为 12 项。照片、视频、日期和收藏查询的真实缩略图、主辅信息及详情入口已经真机通过；真实收藏切换也已确认不会造成备份重传或统一时间线重复。对此类 PhotoKit 明确标记为 `assetContentChanged == false` 的元数据变更，客户端仅更新受信任的本地观察版本，保留原始上传/远端删除证明；无法明确分类时则失败关闭并按内容变化处理。用户已真机确认清空索引只移除当前账号的本地记录、重建恢复 12 项，关闭删除后回到默认关闭且再次启用正确重建，不影响系统照片或 MyNAS 备份；连续更新、查询、详情往返及后台恢复的轻量资源观察也通过。7 项 I1 新增索引测试、3 项收藏元数据不重传/不重复回归及完整 44 项 iPhone 17 Pro 模拟器套件通过；提交 `85cd4f2` 已部署为树莓派 `0.9.0`（systemd active、health/capabilities 均精确回读），签名安装/启动并在 iPhone 16 Pro 最终验收，随后发布 `v0.9.0` GitHub Release；I1 安全门槛完成。

> I2 像素分析许可与队列安全边界（v0.9.1，2026-08-06）：许可缺失即为拒绝；只有用户在“人物”页明确点击允许后，客户端才以现有的值类型 PhotoKit 元数据快照建立当前账号的待分析清单。I2 的队列 API 不接收图片、视频、`PHAsset`、缩略图或文件 URL，也不依赖 Vision、Core ML、AVFoundation、网络或导出器，因此在此阶段不存在像素读取、iCloud 原件下载或模型推理路径。受保护原子 JSON 仅存 `assetID`、metadata-derived `sourceVersion` 和入队时间，位于 `AppCache/<server>/<user>/analysis-queue`；文件内再次绑定 schema、许可 revision 与 `accountID + serverID + userID`，错账号复制、损坏、重复标识、未知 schema/许可 revision 和符号链接均失败关闭。撤回许可、删除不可读队列和当前账号的通用缓存清理均只删除该账号的队列，不触碰系统 Photos、MyNAS 原件或 I1 搜索索引。I2 的 7 项模拟器回归和完整 51 项套件通过；提交 `bf75153` 已部署为树莓派 `0.9.1`、在 iPhone 16 Pro 验收，并以 annotated tag `v0.9.1` 发布。I2 不包含任何 OCR、人物或语义能力。

> H1 部署状态（2026-08-05）：用户已要求优先实现 MyNAS 图库的下载与直接删除，以复用有限测试媒体。客户端现在只会把 owner-scoped、同源原件下载到 `serverID + userID` 隔离的临时目录，并在每个文件的大小和 SHA-256 均匹配前拒绝导入；PhotoKit 导入结束或任一错误后清除该目录。本机已有同一确认 mapping 且仍可访问时，UI 要求第二次确认。直接删除是独立于 H0 的 endpoint：服务器复核当前 gallery asset version、完整资源组、至多一条 mapping 和非 processing worker；成功后客户端仅失效本机 backup proof，绝不调用 PhotoKit 删除。H1 还提供受精确 mapping 限制的图库“双重删除”：先由 PhotoKit 将本机项目移入“最近删除”，才使用 H0 的映射证明删除 MyNAS；若后者失败，UI 不隐藏远端项目，并提示本机项目可从系统“最近删除”恢复。2026-08-05 的当前后端 `0.8.6` 已原子部署到 `20260805T013621Z`，health/capabilities 均回读 `0.8.6`、`photoDelete=true` 且 H1 路由存在；但当前 iOS build/test 与真实媒体验收尚未完成，故这些控制仍不能当作已交付的用户能力。

> H1 真机验收状态更正（2026-08-05，用户报告）：Xcode Beta 当前可用；上述 H1 控制的真实设备验收已完成，包括完整资源组的同源、大小与 SHA-256 校验后导入、重复副本保护/关联、MyNAS-only 删除、精确 mapping 的双端删除、删除后手动重新备份和临时文件清理。H1 的下载与删除可作为已交付能力；这不扩大为系统分享/导出、缓存 LRU、跨设备恢复或完整后台自动备份保证。

## 当前不可宣称的保证

1. **不能宣称所有已上传资产都已完整可浏览或可恢复导出。** E1–E4 已提供派生队列、tiny/grid/preview、远程浏览和受控 Range 读取；但只有 `derivative_state = ready` 的单个 asset 才是 browse-ready，原件导出/下载校验与恢复到新设备仍未交付。
2. **不能宣称灾难恢复级原子提交。** rename 和 SQLite transaction 覆盖常规错误路径，但没有 crash journal、目录 fsync 策略、孤儿扫描或断电故障注入。
3. **不能宣称系统后台自动备份。** G1 是用户明确开启后的前台自动发现：只在 active scene、当前账号、网络/低电量和服务器映射核验均满足时使用现有前台上传队列；它不是 `BGTaskScheduler` 或 background `URLSession`，不保证锁屏、退出或系统回收后继续上传。
4. **不能宣称通用跨端删除、MyNAS 回收站或完整隐私 AI。** H0–H2 已交付受限删除、经完整性校验的导入/分享和账号隔离缓存管理；仍没有 MyNAS 回收站或静默跨端删除。阶段 I 的 I1 是默认关闭的本地元数据索引，I2 候选只新增默认关闭的许可和无像素队列；两者均不包含 OCR、embedding、人物/物体分类、跨设备索引或任何身份识别。

## 后续阶段安全门槛

### 维持 E/F/H0：远程浏览、统一时间线与受限删除

- asset list、changes、文件读取、缓存和删除均以 owner 验证为先，且不得暴露真实路径、其他用户 ID、设备 ID、fingerprint 或身份头。
- derivative job 保持幂等并记录 recipe/input/output 版本和失败原因；原件与派生状态始终分开，策略升级必须安全重建。
- 持续回归 cursor、ETag、Range、缓存串号、越权 ID 猜测、损坏 derivative、HEIC 主图重建、版本转移和 H0 的拒绝路径。

### 阶段 G/H：自动、恢复、导出与缓存

- background URLSession task 和 BGTask 均永久绑定 account；换账号/卷/退出时不误发到另一个用户。
- 下载/导出验证 hash，缓存可清除但不影响服务器原件。清理顺序优先临时完整文件、旧 preview、旧 thumbnail。
- H0 之外的删除能力不得越过当前边界：本机删除必须由 PhotoKit 系统确认，MyNAS 永久删除必须严格重验；在原件导出、独立恢复演练和灾难恢复保证完成前，不得提供“仅保留 MyNAS”承诺。

### 阶段 I/J：AI、规模与恢复

- OCR/embedding/人物分类必须 owner-scoped、可删除、默认不上传中心化服务；不做跨用户识别。
- 引入 schema version、migration journal、完整性扫描、SQLite/卷恢复演练、密钥/配置轮换程序和不含媒体内容的诊断策略。
