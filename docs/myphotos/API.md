# MyNAS Photos — API 契约

当前已部署 MyNAS `0.8.5` 使用 API version `v1`，包含 E1 状态字段、E2 服务端派生任务、E3 受控远程读取接口、F2 同设备映射恢复、F3 精确内容关联摘要、F4 显式版本转移和 H0 受限删除配对。路由以 `/api/v1/photos` 为前缀，不改变 MyNAS 的通用 `health`、`files`、`uploads`、`trash` 等 API；后者不是 Photos 授权或完整性协议的替代品。通用 `GET /api/v1/health` 在 Linux thermal zone 可读时返回 `system.temperatureC`，不可读时省略该字段。2026-08-03 的受控 G2 验收 release 明确返回 `features.backgroundTransfers=true`；这不是已完成后台能力声明。**H1 的下列接口已在本地源码与回归中实现，但尚未部署到该 0.8.5 服务或经真机验收。**

## 共同安全规则

- 生产 Go API 只监听 loopback，并由 Tailscale Serve 注入可信 `Tailscale-User-*` 身份头。每个 Photos handler 从该身份取得 owner。
- 非 GET/HEAD 请求需要 `X-MyNAS-Request: 1`。iOS 原生客户端没有 CORS 限制，但 web 客户端必须通过受限 Origin 的预检。
- 客户端只接受标准根地址 `https://<machine>.<tailnet>.ts.net`；不可使用 HTTP、端口、path、query 或局域网地址。
- 资源访问阶段实现后，缓存键必须包括 server/user/account，且服务端必须先验证 asset owner。不得把 URL 单独作为跨账户缓存键。

## 当前已实现：连接与身份

| Method | Path | 成功响应 / 约束 |
| --- | --- | --- |
| GET | `/capabilities` | `serverID`、`apiVersion`、`serverVersion`、`minimumClientVersion`、`backupStateModelVersion=1`、`derivativePolicyVersion=photos-browse-v2`、`features`、`derivativeRecipes`、`supportsVolumes`。`features.backgroundTransfers` 默认是 false；源码仅在维护者显式设置 `MYNAS_PHOTOS_BACKGROUND_TRANSFERS=1` 时才为 true。2026-08-03 的受控 G2 验收 release 为真实 iOS 系统会话测试返回 true，尚未等同于已交付能力。启动时找到 FFmpeg processor 后列出三项 recipe；工具不可用时保持空数组，不能虚报支持。 |
| GET | `/pairing` | `mynas-photos-pairing` v1 的 `serverURL` 和 `serverID`；仅在服务器配置了根 `https://*.ts.net` private origin 时可用。二维码不含 token/password。 |
| GET | `/me` | 稳定 `userID`、`authenticationIdentity`、显示名、头像版本和 `serverID`。 |
| GET | `/volumes` | 当前用户可选择的卷 ID/名称/在线状态/总量/可用量/default；不得暴露 mount/device/path。 |

iOS 必须依序调用 capabilities → me → volumes，并验证 capabilities 与 me 的 `serverID`（及二维码期望 ID）一致后才保存账号。

## 当前已实现：原始资源上传

| Method | Path | 行为 |
| --- | --- | --- |
| POST | `/upload-sessions` | 提交一个 asset 的完整 manifest；按 `owner + volume + device + localIdentifier + fingerprint` 返回新/既有可续传 session，或返回 `status=duplicate` 的已有 asset。不同卷绝不复用 session 或 received bytes。 |
| GET | `/upload-sessions/{id}` | 读取 owner 自己的 session 与每资源 `receivedBytes`，供重开/断网续传。 |
| PUT | `/upload-sessions/{id}/resources/{resourceID}/parts/{n}` | 上传恰好一个不超过 4 MiB 的分片；要求 `X-Upload-Offset` 和 `X-Chunk-SHA256`。已接收 part 幂等返回当前位置，跳跃 offset 返回冲突。 |
| POST | `/upload-sessions/{id}/complete` | 逐资源核对长度和完整 SHA-256；整组通过后提交原件和元数据；有任一资源缺失/不匹配则拒绝。 |

`POST /upload-sessions` body 的核心字段：

```json
{
  "volumeID": "primary",
  "deviceID": "ios-…",
  "localIdentifier": "PhotoKit local identifier",
  "fingerprint": "sha256 of canonical manifest",
  "mediaType": "photo | video | livePhoto",
  "captureDate": "RFC3339 optional",
  "modificationDate": "RFC3339 optional",
  "pixelWidth": 4032,
  "pixelHeight": 3024,
  "duration": 0,
  "favorite": false,
  "resources": [{
    "clientResourceID": "resource-000",
    "resourceRole": "photo | pairedVideo | alternatePhoto | …",
    "originalFilename": "IMG_0001.HEIC",
    "contentType": "public.heic",
    "byteSize": 123,
    "sha256": "64 lowercase hex chars"
  }]
}
```

响应包含 session/asset ID、`waiting|uploading|completed|failed|duplicate`、fingerprint、总/已接收字节和资源状态。完成或去重响应还包含 `sourceState`、`derivativeState` 和 `browseReady`。上传完成的即时结果通常是 `sourceCommitted + pending + false`；E2 worker 只有在 required outputs 均完成后才把 asset 变为 ready。

## 当前已实现：远程图库与资源读取

| Method | Path | 行为 |
| --- | --- | --- |
| GET/HEAD | `/assets?cursor=&limit=` | owner-scoped，按捕获时间与 asset ID 稳定分页；`limit` 最大 200，返回 next cursor、资源与可用衍生文件。 |
| GET/HEAD | `/changes?cursor=&limit=` | owner-scoped 连续 sequence 增量流，返回 next cursor、hasMore 和 resetRequired。 |
| GET/HEAD | `/device-asset-mappings?deviceID=` | 仅返回当前 owner 且该持久设备 ID 的 `localIdentifier ↔ assetID` 已验证映射；按更新时间稳定分页，最大 200 项。响应不含 fingerprint、storage path 或其他设备记录。H1 源码还支持可选 `assetID=` 精确查询；它不能与 cursor 混用，最多返回该设备对该 owner asset 的一条映射。 |
| GET/HEAD | `/assets/{id}` | 单 asset 的来源、状态、版本、资源、衍生文件和 `browseReady`。 |
| GET/HEAD | `/assets/{id}/{tiny|grid|preview}` | 仅返回当前 recipe 的 ready 衍生文件；支持 ETag 与 `If-None-Match`。 |
| GET/HEAD | `/assets/{id}/original?resourceID=` | 读取一个原始资源；多资源 Live Photo/调整资源通过 resource ID 选择，支持 ETag、Range/206。 |
| POST | `/assets/delete` | 接受最多 200 个当前本地版本的 `assetID + deviceID + localIdentifier + sourceModificationDate`；仅当每项仍是 owner 的完整当前资源组、恰有一条映射且无衍生 worker 正在处理时，批量永久删除 MyNAS 的原件、衍生文件和相关元数据。全部项目先校验，任一项不安全则一个也不删除。H1 本地图库的“同时删除本机照片”选项只会在 PhotoKit 已将该精确对应项移入系统“最近删除”后调用此接口。 |
| POST | `/assets/{id}/delete` | **H1 本地源码，未部署。** body 为 `{ "version": "<gallery asset version>" }`。仅删除当前 owner 看见的一个完整资源组；asset version 必须仍匹配，映射数只能为 0 或 1，processing worker 或共享映射一律返回 409。服务端先同卷暂存、再原子删除 metadata，最终清理暂存目录；它不接收 device/local identifier，也不会触及 iPhone Photos。 |

所有 metadata 与文件查询先用 Tailscale owner 过滤 asset；不匹配的账号得到 404/空列表。响应只包含服务器生成的下载 URL，不泄露 mount 或 `storage_path`。原件数据库保留 PhotoKit 报告的 UTI；文件响应会把已知视频 UTI 转为标准 HTTP MIME（`com.apple.quicktime-movie` → `video/quicktime`，`public.mpeg-4` → `video/mp4`），以便 AVFoundation 流式播放。

## F3 已发布 — 精确内容关联摘要

`GET /assets` 和 `GET /assets/{id}` 提供两个 owner-scoped 的匿名聚合字段：

- `exactContentDeviceCount`：当前账号中，关联同一完整资源组的不同设备数量。
- `exactContentMappingCount`：当前账号中，关联该资源组的设备备份记录数量。

资源组只有在完整 manifest 的资源角色、SHA-256 与字节数都严格一致时才会关联；文件名、拍摄时间、缩略图和“看起来相近”均不能建立关联。响应不包含 fingerprint、其他设备 ID、其他设备的 local identifier 或存储路径。该摘要只解释一个 MyNAS 原件组被多条备份记录引用，**不会**合并、隐藏、删除或修改任何设备上的照片记录。

## F4 已部署实现 — 显式版本转移

`GET /assets` 和 `GET /assets/{id}` 提供两个 owner-scoped 的匿名字段：

- `previousVersionCount`：有多少条已记录的直接前序版本转移以该完整资源组为目标。
- `nextVersionCount`：有多少条已记录的直接后续版本转移以该完整资源组为来源。

转移只在**同一 owner、同一持久设备 ID、同一 PhotoKit `localIdentifier`** 已备份资源组切换到另一份完整且已校验的资源组时写入。数据库保留旧原件与转移审计记录；响应绝不返回设备 ID、local identifier、前后 fingerprint 或可用来反查设备的关系 ID。历史已有资源不会根据时间或文件名补写版本关系；Live Photo 的静态图和 paired video 必须作为同一完整组一起提交后才能形成新版本。

## 当前接口缺口与实现注意

- 上传完成的正常路径使用同卷 rename 和 SQLite transaction；断电/进程崩溃恢复协议尚未定义，见阶段 D/J。
- `changes.resetRequired` 与 cursor 保留/过期策略尚未启用；当前变更日志不裁剪。
- H0 已在 `0.8.4` 部署：capabilities 的 `features.photoDelete` 显式声明后 iOS 才启用开关。它从不复用无 owner 语义的通用文件删除，且不会向浏览 API 暴露 fingerprint、local identifier、device ID 或存储路径。iOS 必须先显示确认并默认关闭“同时永久删除 MyNAS 备份”；本机先进入系统“最近删除”，随后服务端重复验证当前本机版本、唯一 owner 映射、完整资源组和无进行中衍生 worker 后，才永久删除 MyNAS 数据。2026-07-27 已以唯一测试资源组完成 iPhone 17 Pro 模拟器验收。H1 本地代码另行定义精确映射查询、全原件下载校验与 `/assets/{id}/delete`；其图库详情还可在精确 mapping 仍可访问时选择“同时删除本机照片”，固定顺序是 PhotoKit 移入“最近删除”成功后才调用本 H0 接口，后者失败时不隐瞒本机已移入“最近删除”的结果。生产服务尚未部署 H1 endpoint，原件导入与直接删除仍不能向用户承诺。
- iOS 已在独立只读 MyNAS 图库消费列表、衍生预览、视频 Range 流和前台 change cursor；这不等于本地/远程统一时间线，也不提供原件导出或删除。
- G2 的系统后台协议正在受控部署验收：服务端 capability 默认关闭，2026-08-03 仅为真实 iOS background `URLSession` 回调、终止恢复、网络/低电量和服务重启回归而显式配置 `MYNAS_PHOTOS_BACKGROUND_TRANSFERS=1` 并回读 capability。该开关不是用户可见设置，也不自动启用。开启后的启动流程只会清理超过七天、仍处于 waiting/uploading/failed、时间戳可解析、卷在线且 `stage_dir` 精确等于该卷 `.mynas/photos-staging/<sessionID>` 的会话；陌生路径、离线卷和异常时间戳保留供人工恢复。
- iOS 包已经登记 `com.ethanzhou.MyPhotos.photo-backup-processing` 和 `processing` 背景模式。它只在已有受保护 G2 暂存记录、当前持久化账号/卷、用户策略和 capability 都仍匹配时，才可向 iOS 请求一次处理机会；它从不发现新的 PhotoKit 项目。2026-08-03 已在 iPhone 16 Pro 观察到一项 212.1 MB 真实 background `URLSession` 任务经锁屏完成并得到 MyNAS outcome；该单次路径不替代终止、条件变化和服务器重启验收。
- 同日的第二项 G2 真机传输在显示“iOS 正在处理后台传输”后被开发工具终止 App 进程；15 秒后手动打开 App 时仍为 6/7、212.1/272.4 MB，随后未点击备份即达到 7/7、272.4/272.4 MB。此结果覆盖该开发终止/重新打开的账本恢复路径，而不表示用户强制退出时 iOS 会重新唤起 App，也不替代网络/低电量中断或服务器重启验收。
- 旧版服务器和旧缓存不返回关联摘要字段；iOS 将字段缺失解释为“没有已知关联”，而不能把它当成错误或据此去重。
