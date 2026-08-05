# MyNAS Photos — 数据模型

本文件区分**当前已部署 schema**与**下一阶段需要的模型**。E1–E3 已随 MyNAS 0.8.1 部署到真实 MyNAS；阶段状态以 [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) 为准。

## 当前服务端 SQLite 模型

迁移目前在 `App.migrate()` 中以 `CREATE TABLE IF NOT EXISTS` 建立；尚没有独立 schema version 或 migration journal，这是阶段 J 的工作。

| 实体 | 关键字段 / 约束 | 当前语义 |
| --- | --- | --- |
| `photo_users` | `id`、唯一 `authentication_identity`、显示名、头像版本 | Tailscale 登录映射到稳定 opaque user ID |
| `photo_assets` | `id`、owner/volume/fingerprint、媒体/拍摄元数据、兼容 `backup_state`、`source_state`、`derivative_state`、recipe/error/updated | 原件提交后为 `sourceCommitted + pending`；只有 required derivatives 都完成才能进入 `ready` |
| `photo_resources` | asset/owner/volume、role、文件名、content type、大小、SHA-256、相对 `storage_path` | 一个 asset 多条记录；Live Photo/RAW/HDR 都用同一结构 |
| `photo_upload_sessions` | owner、volume、device、PhotoKit local ID、fingerprint、目标 asset ID、stage dir、状态 | 持久化续传会话；唯一身份为 `owner + volume + device + local ID + fingerprint`，状态为 waiting/uploading/completed/failed。仅在后台 capability 显式开启的进程启动期，超过七天的未完成会话才可能被清理，且须通过卷/精确暂存路径校验 |
| `photo_upload_resources` | session、客户端资源 ID、role、hash、stage name、`received`、4 MiB `chunk_size`、状态 | 服务器以 `received` 为真相恢复每个资源 |
| `photo_derivative_jobs` | asset/owner/volume、recipe version、status、attempt/error/next attempt | E2 worker 领取 pending/failed，processing 在重启后恢复；最多五次退避 |
| `photo_derivatives` | asset、kind、recipe、状态、输出尺寸/大小/hash/storage path/error | E2 只在 required JPEG 输出复核通过后 upsert；0.8.1 worker 支持普通媒体与 DNG/ProRAW 内嵌预览 |
| `photo_changes` | 自增 sequence、owner、asset、change type、asset updated、created | E3 的 owner-scoped 增量读取游标；当前只写 `upsert` 且尚未裁剪日志 |
| `device_asset_mappings` | `(owner, device, local_identifier)` 主键，fingerprint 和 asset ID | 同一设备本地 asset 的映射；防止跨用户碰撞 |

服务端原件布局由服务器构造，用户输入的原始文件名不能决定目录：

```text
<volume>/users/<sha256-derived-owner>/photos/
  originals/<fingerprint-prefix>/<asset-id>/<numbered-resource-files>
  .mynas/photos-staging/<upload-session-id>/<numbered-resource-files>
```

在正常完成路径中，服务端先核对全部文件长度与 SHA-256，再把整个 staging directory rename 到同卷 originals，随后在 SQLite 事务中写 asset、全部 resource、device mapping 和 completed session。若事务失败，代码尝试把目录移回 staging。这个实现不是断电/进程崩溃后的跨资源事务保证；阶段 J 要加入可扫描的提交日志和恢复策略。

## 当前 iOS 模型

| 模型 | 关键字段 / 语义 |
| --- | --- |
| `AccountContext` | `accountID`、server/user ID、URL、Tailscale identity、卷、capabilities；无 MyNAS 密码/token |
| `LocalPhotoAsset` | local identifier、创建/修改时间、媒体种类、像素、时长、favorite；不承诺远端状态 |
| `PreparedPhotoAsset` | 当前上传期的完整 resource group、每资源临时文件/大小/SHA-256 和 manifest fingerprint |
| `PhotoBackupJob` | account、local ID、源修改日期、waiting/preparing/uploading/completed/failed、字节/资源数/asset ID、可选 source/derivative 状态，以及持久化的失败类别/详情/发生时间；H1 删除成功后仅将匹配的 completed proof 转为 `remoteDeleted` failed，保留 local ID 与源版本，等待用户明确手动重传；它明确记录本机照片是仍保留还是已由 iOS 移入“最近删除” |
| `PhotoBackupBackgroundTransferRecord` | G2 的受保护任务登记册记录；绑定 `accountID + serverID + userID + volumeID`、当前 local identifier/source version、manifest fingerprint 与每资源 hash/相对暂存文件名，并最多绑定一个 future system task 的 ID、协议阶段、资源/分片范围、body/response 文件名、HTTP 状态和响应长度，以及只在完整响应验证后写入的上传 outcome。2026-08-03 的受控部署允许创建后台会话或任务；同日 iPhone 16 Pro 已完成一项 212.1 MB 的真实锁屏系统传输并得到 MyNAS outcome，终止/中断恢复等其余验收仍待完成。 |
| `PhotoBackupProgressSnapshot` | **队列**完成数、失败数和总数；不是服务器完整图库数，也不是 browse-ready 计数 |
| `ServerPhotoAsset` | 远端 asset/version、媒体元数据、source/derivative/browse-ready 状态、全部 resource 与 derivative 描述；与 `LocalPhotoAsset` 保持分离 |
| `DownloadedRemotePhotoResource` / `RemotePhotoOriginalDownload` | H1 的短寿命本地值：每个资源在 `AppCache/<server>/<user>/temporary-downloads/<UUID>` 中经大小/SHA-256 校验后，才可作为完整组交给 PhotoKit；导入结束或任一失败时删除该目录，不作为长期原件缓存 |
| `ServerAssetPage` | owner-scoped 稳定分页结果、opaque next cursor 与 has-more |
| `CacheDirectoryProvider` | `AppCache/<serverID>/<userID>/<kind>` 的目录约定；E4 已用于带 ETag 的 metadata 以及经 SHA-256 校验的 grid/preview，尚未实现 LRU/缓存索引 |

`PhotoBackupJob.completed` 仍表示上传协议返回 `completed`/`duplicate` 且原始资源已经校验；E1 已增加可选的 `sourceState`、`derivativeState` 和计算属性 `isBrowseReady`，以兼容旧的本地队列 JSON。不要把 job 的 completed 直接扩展成远程浏览/删除资格。

G2 登记册与前台队列分开存放，使用同一等级的 Data Protection 原子写入。对应暂存器只会在逐资源复制后再次验证字节数和 SHA-256 均匹配时写入记录；失败会清理尚未登记的暂存目录。它使用与前台上传共享的 manifest 类型写入创建会话 request body，并写入空完成 request body；按需分片准备器只从已验证的暂存资源生成唯一、不覆盖既有文件的 part body，返回该文件的字节数和 SHA-256。每条记录至多登记一个 iOS 协议 task，且 task ID、请求阶段、资源/分片范围、相对 body/response 文件名和回调 HTTP 状态/响应长度均必须与记录形状相符；传输结束后只进入“等待 App 解析”，不能据此标记上传成功。客户端的 background engine 使用按网络策略分离的 file-backed session，回调只在完整响应被解析、来源/派生状态符合现有完整性契约后，才写入 outcome；中断或策略暂停会清除 session/offset 假设，重新用幂等 create-session 获得 MyNAS 权威 received bytes。仅当相关前台队列已成功原子写入同一完成 outcome 时，才可按记录 UUID、server/user 私有路径再次核验并删除该暂存目录及登记册；任一写入或清理失败都会保留记录。服务端续传会话也以 `owner + volume + device + local ID + fingerprint` 为唯一身份，旧库在启动迁移中保留所有行并升级该约束，因而切卷绝不复用 session 或 received bytes。App 的 BGProcessing handler 只读取这些持久记录，且每次再核验当前账号、卷、capability、用户策略和低电量条件；它不读取 PhotoKit 或创建新备份。它不保存凭据、服务器存储路径或完整 App 沙盒绝对路径；暂存目录由记录 UUID 推导，资源文件名只能是受限的单一路径组件。2026-08-03 的受控部署 capability 为 true，因此首次真实后台 `URLSession`/`BGTask` 验收可以创建记录；在回调、媒体完整性和终止恢复被观察前，仍不能把任一记录解释为已在系统后台完成。

2026-08-03 起，task 的 callback identity 是 `networkPolicy + taskIdentifier`，而不是裸 task ID：两个固定 background `URLSession` 可以各自产生相同编号，登记册会拒绝同一网络策略内的重复 identity，委托回调与取消也必须匹配该策略命名空间。这保持 Wi‑Fi 与允许蜂窝任务、以及旧回调与新任务之间的账户/策略隔离。为兼容更新前缺少 `networkPolicy` 的在途登记册，只有一个 callback candidate 时才能由真实 session 回调补写该字段；多个候选保持暂停。

系统交给 `UIApplicationDelegate` 的 background-session completion handler 不属于可持久化传输数据，也绝不写入登记册。2026-08-03 起，App 在主线程先将它按固定 session identifier 暂存，再重建同名 session；只有对应 session 的全部事件已被委托交付后才取出并调用它。该瞬时交接避免系统在 session 重建时立即送达回调而落入无 handler 的空窗，且未知 identifier 不会取得任何 G2 状态。

低电量状态也不写入登记册：它只代表当前系统条件，不能作为恢复时的历史事实。G2 engine 在写入新暂存记录和续接既有记录的最终边界重新读取它；若策略要求暂停，就不创建 task，协调器把自动 job 留在 `waiting`。2026-08-04 的真实在途传输已验证开启低电量暂停、关闭后从 MyNAS-confirmed 位置自动续传并最终完成；该结果仍不推断 App 挂起期间系统 task 的即时取消语义。

`stateRevision` 同样不是登记册字段或上传 outcome：它是 engine 仅在登记册成功原子写入后发布的进程内瞬时通知。协调器收到通知后，只为当前活跃自动请求按账号和当前 PhotoKit 源版本读取 completed record；它必须先把同一 MyNAS-confirmed outcome 成功写入持久队列，才可显示完成并删除登记。这样 callback 落盘不会要求用户重新进入备份页才影响卡片，同时也不会把仅有 transport 回调或任意 revision 当作完成。

同日的真实 iPhone 16 Pro 观察已经覆盖一次 create → part → complete 的系统回调解析：锁屏 90 秒后该 212.1 MB 资源组显示为 6/6 原件已安全上传。该结果是单次受控路径的端到端证据，不推导出终止、网络/电量中断或服务重启恢复保证。

同日第二个真实 G2 资源组在用户确认“iOS 正在处理后台传输”后，其 App 进程被开发工具终止；15 秒后手动重新打开，队列先保持 6/7、212.1/272.4 MB，随后无需手动备份即持久化为 7/7、272.4/272.4 MB。该结果证明登记册在该终止/重新打开路径上没有把在途 task 错标完成，并可恢复到 MyNAS-confirmed outcome；它不保存或推断进程终止期间的字节进度，也不替代网络/低电量中断、服务重启、账号/卷或长队列验收。

G2 的 PhotoBackupBackgroundTransferProgress 也是进程内模型，不编码进登记册或队列。它绑定 record UUID、账号、当前 source version、confirmed bytes、reported bytes 与总大小；reported bytes 最多等于已确认偏移加当前持久 task 的 byte count。它的唯一用途是当前界面展示“iOS 已发送、等待 MyNAS 确认”的传输进度；下次启动或 task 身份不匹配时丢弃该叠加值，继续以 received bytes 为真相。

## Manifest 与去重

客户端与服务端使用相同的 SHA-256 manifest 规则。客户端先稳定排序 resource draft，赋予 `resource-000` 等 ID；fingerprint 逐行包含：

```text
clientResourceID \0 resourceRole \0 resourceSHA256 \0 byteSize \n
```

服务端重新按 `clientResourceID` 排序并计算相同格式。去重键必须包含 owner 与 volume，并优先检查设备映射；相同内容来自不同 local ID 时可复用 asset。文件名、拍摄日期、尺寸都不能单独判重。

## 后续阶段仍待实现的模型

| 模型 | 用途 | 不可缺少的字段 |
| --- | --- | --- |
| `CacheEntry` | 可淘汰的远端缓存 | account、asset、type、path、bytes、ETag、last access、integrity state |
| deletion / restore intent | 受控删除与恢复 | owner、asset/version、目标端、确认时间、trash expiry、审计 ID |
| AI index record | 端侧/本地搜索索引 | owner、asset/version、index model/version、可删除标记；禁止跨用户 |
| migration/integrity checkpoint | 升级、扫描和灾难恢复 | schema version、operation/checkpoint、manifest/scan result、可恢复状态 |
