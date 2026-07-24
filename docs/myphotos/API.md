# MyNAS Photos — API 契约

当前已部署 MyNAS `0.7.0` 使用 API version `v1`，包含 E1 状态字段和 E2 服务端派生任务；远程读取接口仍未实现。路由以 `/api/v1/photos` 为前缀，不改变 MyNAS 的通用 `health`、`files`、`uploads`、`trash` 等 API；后者不是 Photos 授权或完整性协议的替代品。通用 `GET /api/v1/health` 在 Linux thermal zone 可读时返回 `system.temperatureC`，不可读时省略该字段。

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

响应包含 session/asset ID、`waiting|uploading|completed|failed|duplicate`、fingerprint、总/已接收字节和资源状态。完成或去重响应还包含 `sourceState`、`derivativeState` 和 `browseReady`。上传完成的即时结果通常是 `sourceCommitted + pending + false`；E2 worker 只有在 required outputs 均完成后才把 asset 变为 ready。E3 读取 API 上线前，客户端仍不能仅凭 ready 浏览远端内容。

## 当前接口缺口与实现注意

- E1/E2 已部署持久化 job、状态契约和执行 worker，但仍没有 `GET /assets`、`/changes`、asset metadata、tiny/grid/preview/original 下载、trash 或 restore 路由；任何文档将这些读取/删除路由写成“当前可调用 API”都是错误的。
- middleware 当前 CORS allow-list 中保留的是旧 `X-Chunk-Checksum`，而 Photos 分片实际验证 `X-Chunk-SHA256`。原生 iOS 上传不受此影响；阶段 E 若增加 web Photos 客户端，必须先更正 allow-list 并以预检测试锁定它。
- 上传完成的正常路径使用同卷 rename 和 SQLite transaction；断电/进程崩溃恢复协议尚未定义，见阶段 D/J。

## 阶段 E 以后保留的 API（未实现）

| Method | Path | 目标 |
| --- | --- | --- |
| GET | `/assets?cursor=&limit=` | owner-scoped、按捕获时间分页的远程 metadata 与 next cursor/version。 |
| GET | `/changes?cursor=` | 增量变更；过期 cursor 应返回受控的全量重建信号。 |
| GET | `/assets/{id}` | 单 asset 的版本、来源、原件/派生/回收站状态。 |
| GET | `/assets/{id}/{tiny|grid|preview|original}` | owner 授权、ETag/条件请求；original 支持 Range。 |
| POST | `/assets/{id}/trash`、`/restore` | owner-scoped 软删除和恢复；只在阶段 H 的确认策略完成后开放。 |

这些端点落地前必须定义 derivative recipe/version、状态机、错误码、cursor 过期语义、ETag 和 Range 测试；不得仅因上传成功而提前暴露原始路径。
