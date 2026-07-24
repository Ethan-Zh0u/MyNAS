# MyNAS Photos — 数据模型

本文件区分**当前已部署 schema**与**下一阶段需要的模型**。E1/E2 已随 MyNAS 0.6.0 部署到真实 MyNAS；阶段状态以 [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) 为准。

## 当前服务端 SQLite 模型

迁移目前在 `App.migrate()` 中以 `CREATE TABLE IF NOT EXISTS` 建立；尚没有独立 schema version 或 migration journal，这是阶段 J 的工作。

| 实体 | 关键字段 / 约束 | 当前语义 |
| --- | --- | --- |
| `photo_users` | `id`、唯一 `authentication_identity`、显示名、头像版本 | Tailscale 登录映射到稳定 opaque user ID |
| `photo_assets` | `id`、owner/volume/fingerprint、媒体/拍摄元数据、兼容 `backup_state`、`source_state`、`derivative_state`、recipe/error/updated | 原件提交后为 `sourceCommitted + pending`；只有 required derivatives 都完成才能进入 `ready` |
| `photo_resources` | asset/owner/volume、role、文件名、content type、大小、SHA-256、相对 `storage_path` | 一个 asset 多条记录；Live Photo/RAW/HDR 都用同一结构 |
| `photo_upload_sessions` | owner、volume、device、PhotoKit local ID、fingerprint、目标 asset ID、stage dir、状态 | 持久化续传会话；状态为 waiting/uploading/completed/failed |
| `photo_upload_resources` | session、客户端资源 ID、role、hash、stage name、`received`、4 MiB `chunk_size`、状态 | 服务器以 `received` 为真相恢复每个资源 |
| `photo_derivative_jobs` | asset/owner/volume、recipe version、status、attempt/error/next attempt | E2 worker 领取 pending/failed，processing 在重启后恢复；最多五次退避 |
| `photo_derivatives` | asset、kind、recipe、状态、输出尺寸/大小/hash/storage path/error | E2 只在 required JPEG 输出复核通过后 upsert；0.6.0 worker 已部署 |
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
| `PhotoBackupJob` | account、local ID、源修改日期、waiting/preparing/uploading/completed/failed、字节/资源数/asset ID，以及可选 source/derivative 状态 |
| `PhotoBackupProgressSnapshot` | **队列**完成数/总数；不是服务器完整图库数，也不是 browse-ready 计数 |
| `CacheDirectoryProvider` | `AppCache/<serverID>/<userID>/<kind>` 的目录约定；尚未实现 LRU/缓存索引 |

`PhotoBackupJob.completed` 仍表示上传协议返回 `completed`/`duplicate` 且原始资源已经校验；E1 已增加可选的 `sourceState`、`derivativeState` 和计算属性 `isBrowseReady`，以兼容旧的本地队列 JSON。不要把 job 的 completed 直接扩展成远程浏览/删除资格。

## Manifest 与去重

客户端与服务端使用相同的 SHA-256 manifest 规则。客户端先稳定排序 resource draft，赋予 `resource-000` 等 ID；fingerprint 逐行包含：

```text
clientResourceID \0 resourceRole \0 resourceSHA256 \0 byteSize \n
```

服务端重新按 `clientResourceID` 排序并计算相同格式。去重键必须包含 owner 与 volume，并优先检查设备映射；相同内容来自不同 local ID 时可复用 asset。文件名、拍摄日期、尺寸都不能单独判重。

## 阶段 E–J 仍待实现的模型

| 模型 | 用途 | 不可缺少的字段 |
| --- | --- | --- |
| `photo_changes` | 远程 cursor 增量同步 | owner、连续版本/cursor、asset/version、变更类型、保留期 |
| `ServerAsset` | iOS 远端时间线值类型 | account、asset/version、来源、resource/derivative/backup/trash 状态、ETag |
| `CacheEntry` | 可淘汰的远端缓存 | account、asset、type、path、bytes、ETag、last access、integrity state |
| deletion / restore intent | 受控删除与恢复 | owner、asset/version、目标端、确认时间、trash expiry、审计 ID |
| AI index record | 端侧/本地搜索索引 | owner、asset/version、index model/version、可删除标记；禁止跨用户 |
| migration/integrity checkpoint | 升级、扫描和灾难恢复 | schema version、operation/checkpoint、manifest/scan result、可恢复状态 |
