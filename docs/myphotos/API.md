# MyNAS Photos — API 契约

当前已部署 MyNAS `0.8.2` 使用 API version `v1`，包含 E1 状态字段、E2 服务端派生任务、E3 受控远程读取接口和 F2 同设备映射恢复。路由以 `/api/v1/photos` 为前缀，不改变 MyNAS 的通用 `health`、`files`、`uploads`、`trash` 等 API；后者不是 Photos 授权或完整性协议的替代品。通用 `GET /api/v1/health` 在 Linux thermal zone 可读时返回 `system.temperatureC`，不可读时省略该字段。

## 共同安全规则

- 生产 Go API 只监听 loopback，并由 Tailscale Serve 注入可信 `Tailscale-User-*` 身份头。每个 Photos handler 从该身份取得 owner。
- 非 GET/HEAD 请求需要 `X-MyNAS-Request: 1`。iOS 原生客户端没有 CORS 限制，但 web 客户端必须通过受限 Origin 的预检。
- 客户端只接受标准根地址 `https://<machine>.<tailnet>.ts.net`；不可使用 HTTP、端口、path、query 或局域网地址。
- 资源访问阶段实现后，缓存键必须包括 server/user/account，且服务端必须先验证 asset owner。不得把 URL 单独作为跨账户缓存键。

## 当前已实现：连接与身份

| Method | Path | 成功响应 / 约束 |
| --- | --- | --- |
| GET | `/capabilities` | `serverID`、`apiVersion`、`serverVersion`、`minimumClientVersion`、`backupStateModelVersion=1`、`derivativePolicyVersion=photos-browse-v1`、`features`、`derivativeRecipes`、`supportsVolumes`。当前部署在启动时找到 FFmpeg processor 后列出三项 recipe；工具不可用时保持空数组，不能虚报支持。 |
| GET | `/pairing` | `mynas-photos-pairing` v1 的 `serverURL` 和 `serverID`；仅在服务器配置了根 `https://*.ts.net` private origin 时可用。二维码不含 token/password。 |
| GET | `/me` | 稳定 `userID`、`authenticationIdentity`、显示名、头像版本和 `serverID`。 |
| GET | `/volumes` | 当前用户可选择的卷 ID/名称/在线状态/总量/可用量/default；不得暴露 mount/device/path。 |

iOS 必须依序调用 capabilities → me → volumes，并验证 capabilities 与 me 的 `serverID`（及二维码期望 ID）一致后才保存账号。

## 当前已实现：原始资源上传

| Method | Path | 行为 |
| --- | --- | --- |
| POST | `/upload-sessions` | 提交一个 asset 的完整 manifest；返回新/既有可续传 session，或返回 `status=duplicate` 的已有 asset。 |
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
| GET/HEAD | `/device-asset-mappings?deviceID=` | 仅返回当前 owner 且该持久设备 ID 的 `localIdentifier ↔ assetID` 已验证映射；按更新时间稳定分页，最大 200 项。响应不含 fingerprint、storage path 或其他设备记录。 |
| GET/HEAD | `/assets/{id}` | 单 asset 的来源、状态、版本、资源、衍生文件和 `browseReady`。 |
| GET/HEAD | `/assets/{id}/{tiny|grid|preview}` | 仅返回当前 recipe 的 ready 衍生文件；支持 ETag 与 `If-None-Match`。 |
| GET/HEAD | `/assets/{id}/original?resourceID=` | 读取一个原始资源；多资源 Live Photo/调整资源通过 resource ID 选择，支持 ETag、Range/206。 |

所有 metadata 与文件查询先用 Tailscale owner 过滤 asset；不匹配的账号得到 404/空列表。响应只包含服务器生成的下载 URL，不泄露 mount 或 `storage_path`。原件数据库保留 PhotoKit 报告的 UTI；文件响应会把已知视频 UTI 转为标准 HTTP MIME（`com.apple.quicktime-movie` → `video/quicktime`，`public.mpeg-4` → `video/mp4`），以便 AVFoundation 流式播放。

## 当前接口缺口与实现注意

- 上传完成的正常路径使用同卷 rename 和 SQLite transaction；断电/进程崩溃恢复协议尚未定义，见阶段 D/J。
- `changes.resetRequired` 与 cursor 保留/过期策略尚未启用；当前变更日志不裁剪。
- `POST /assets/{id}/trash`、`/restore` 尚未实现，只能在阶段 H 的确认、恢复与审计策略完成后开放。
- iOS 已在独立只读 MyNAS 图库消费列表、衍生预览、视频 Range 流和前台 change cursor；这不等于本地/远程统一时间线，也不提供原件导出或删除。
