# MyNAS Photos — 产品需求与完整性约定

## 产品边界

MyNAS Photos 是一款 iOS 照片管理与备份应用，目标体验类似 Google Photos，但数据路径不同：照片和视频默认保存在用户自己拥有的 MyNAS 中，访问通过其 tailnet 完成。产品不建立中心化照片云，不把照片上传到第三方照片服务，也不在树莓派上运行大型 AI 模型。

应用可以展示用户允许访问的 iPhone Photos，也可以浏览同一用户 MyNAS 上已完成派生处理的照片。主照片页已提供“全部 / 本机”切换：只有当前设备、当前 PhotoKit 源版本与服务端已确认映射严格一致的项目才会合并；其余项目明确显示为仅本机或仅 MyNAS，绝不按文件名、时间或缩略图猜测同一项目。阶段与当前完成度以 [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) 为唯一依据。

## 用户承诺

- 只读取用户在 Photos 权限中允许的项目；Limited 权限必须直说“仅部分照片”，不得暗示已访问完整图库。
- 网格缩略图不隐式从 iCloud 下载完整资源。显式的用户备份动作可以下载所选 asset 的原始 PhotoKit 资源，并必须展示等待/失败原因。
- 每个账号、请求、后台任务、缓存文件和服务端记录均以 `serverID + userID`（或 `accountID`）隔离。切换账号不能复用另一账号的缓存或上传会话。
- 所有类似 UI 组件优先使用公开的 iOS 原生 Liquid Glass 能力；系统不支持时使用系统 Material/控件回退，不仿制私有 API。
- 用户可以随时停留在“仅本地图库”模式；连接 MyNAS 不是读取本地图库的前提。

## 备份完整性：asset，而不是 JPEG

备份单位是一个 PhotoKit asset，不是单张导出的 JPEG。客户端必须导出 `PHAssetResource.assetResources(for:)` 返回的全部原始资源，并保留每个资源的字节、原始文件名、UTI/content type、resource role、大小和 SHA-256。

这意味着：

- Live Photo 的静态照片与 `pairedVideo`/`fullSizePairedVideo` 是一个组；任何一个缺失都不能完成该 asset。
- HDR、ProRAW、RAW、DNG、alternate photo、adjustment/base/full-size 资源和原始视频必须保留原字节，不得以普通 JPEG 代替。
- 客户端和服务端都以 manifest fingerprint、资源 SHA-256、owner 和 volume 做准确性/去重判断；文件名只能显示，不能单独判重。
- 服务器必须校验每个分片和完整文件 SHA-256，并仅在整组资源满足条件后写入 asset/resource/设备映射元数据。

## 三层备份语义

为避免误导删除决策，产品文案、数据库状态和测试必须区分：

| 语义 | 必需条件 | 当前情况 |
| --- | --- | --- |
| 原始资源已安全上传 | 全部资源导出；服务端完整 SHA-256；同卷原子文件提交和元数据写入；按 owner/volume 去重 | 阶段 D 已实现首版 |
| 完整可浏览备份 | 原始资源安全上传，且本版本规定的 tiny/grid/preview 成功并可授权读取 | 阶段 E（E1–E4）已交付；只有该 asset 的 `derivative_state = ready` 才可形成 `browseReady` |
| 本机删除与 MyNAS 删除的受限配对流程 | 当前本机源版本有已提交映射；服务端再次验证完整资源组、唯一映射和派生状态；用户经 PhotoKit 系统确认 | H0 已部署并完成回归：默认仅将本机移入 iOS“最近删除”，可选的 MyNAS 永久删除默认关闭。它不等于原件导出、MyNAS 回收站或灾难恢复级的“仅保留 MyNAS 后删除本机”承诺 |

兼容字段 `photo_assets.backup_state = "backedUp"` 和队列 `completed` 仍只表示第一行。E1 已加入 source/derivative 状态并把用户文案改为“原件已安全上传”；即使 E1–E4 已完成，也只有 `derivative_state = ready` 才能形成 `browseReady`。H0 的删除候选还必须是当前 PhotoKit 源版本、`sourceCommitted` 且有服务端确认的 asset ID，服务端会重复校验；不能仅凭 `backedUp` 或队列 `completed` 判断。

## 当前已交付的用户能力

- 本地照片和视频的日期倒序分页网格、方形居中裁剪缩略图、详情、长按/选择、多列捏合缩放（2–10 列）和基础本地类型/日期搜索。
- Photos 权限、Limited 管理、iCloud-only 缩略图状态和无可访问项目状态。
- iOS 原生底栏、iOS 26+ Liquid Glass 选中/重点控件与低版本系统回退。
- Tailscale `*.ts.net` 地址连接、二维码配对、稳定账号/卷选择、多账号切换和缓存命名空间。
- 用户手动启动的原始资源备份队列：多资源导出、SHA-256、4 MiB 分片、前台网络重试/重开续传、服务端校验与去重。
- 已完成派生处理的 MyNAS 项目可在独立只读图库中分页浏览；grid/preview 缓存按 `serverID + userID` 隔离并校验服务器 SHA-256，详情可显示 preview、视频或 Live Photo 配对视频的 Range 播放，以及原件资源清单。前台 `/changes` 只提示远端更新，不在已有分页中强制跳动。远端图库加载失败时，次要提示固定为“请检查 Tailscale 连接”，并保留原生“重试”操作。H1 本地代码已接通逐资源大小/SHA-256 校验后导入 Photos、本机已有同一确认映射时的二次确认、version-bound 的 MyNAS-only 删除，以及一个仅在精确 mapping 仍可访问时出现的“同时删除本机照片”选项：该选项先由 PhotoKit 移入系统“最近删除”，再调用受限 H0 删除 MyNAS；后者失败时会明确保留 MyNAS 项目并提示从“最近删除”恢复本机。2026-08-05，包含 H1 endpoint 的后端已原子部署并回读 `photoDelete=true`，但当前 iOS 实现尚未完成真实媒体下载、临时文件清理、MyNAS-only 删除或删除后的手动重传验收；在逐项通过前，该图库仍不能向用户承诺这些能力。
- 版本与部署快照（2026-08-05）：当前树莓派部署为 MyNAS `0.8.6`（release `20260805T013621Z`）；health 与 capabilities 均回读 `0.8.6`，并明确 `photoDelete=true`、`backgroundTransfers=true`。`backgroundTransfers` 只表示受控系统传输验收的服务端开关已打开，不把未验收的后台保证或 H1 的真实媒体下载／删除宣称为完成。
- 主照片页可在“设置 > 照片显示”开启统一时间线；它严格合并当前设备的已确认映射，并保留仅本机、仅 MyNAS、上传中、失败、原件已安全上传和“已备份 · 可浏览”等可解释状态。它只改变显示，跨设备的严格相同内容仅显示匿名关联摘要，不会被静默合并、隐藏、上传、下载或删除。Limited Photos 的“当前仅可访问部分图片”说明和管理入口同样位于设置，不长期占据照片页。
- H0 提供本机多选删除：默认由 iOS PhotoKit 将项目移至“最近删除”；用户可在明确确认后选择同时永久删除符合严格条件的 MyNAS 资源组。删除后从系统“最近删除”恢复本机项目，会经正常备份管线创建新的 MyNAS 资源组，不复用已删除映射。
- G1 的前台自动发现：每个 MyNAS 账号默认关闭；用户开启后可选仅 Wi‑Fi 或允许蜂窝数据，并可在低电量模式暂停。图库变化、账号切换和回到 active scene 时才会检查并启动现有前台队列；自动请求只随当前查看账号运行，切换后旧账号不再取下一项目；服务器支持设备映射读取时，自动上传必须先成功核验此设备已有备份，请求失败保持暂停而不能降级为空映射；策略、状态和队列来源按账号隔离。

可对用户承诺的完整系统后台自动备份、原件导出、缓存容量/LRU 管理、AI 和灾难恢复仍不是当前用户能力。G1 不保证锁屏、退出 App 或系统回收后继续上传，且不能被称为 BGTask/background URLSession 能力；G2 在创建/续接系统传输前会复核用户的低电量暂停策略，并已在受控 iPhone 上完成一次锁屏系统传输、一次开发工具终止进程后手动重新打开的恢复完成，以及一次传输中低电量暂停、关闭低电量后自动续传并完成的路径；Wi‑Fi 中断后的最终完成、服务重启和其余边界仍待验收，故尚不能成为完整用户承诺；H0 也不能被描述为已有可导出、可演练灾难恢复的“仅保留 MyNAS”删除方案。

当用户正停留在备份页且 G2 的系统 callback 已得到 MyNAS-confirmed outcome 时，状态卡必须无需离开再进入页面即可更新。该要求只呈现已持久化的最终状态；iOS 接管中的字节进度并不承诺逐字节实时刷新。

当 iOS 为当前已登记的上传 task 提供发送字节时，卡片应可展示该分片的临时进度，并标注“等待 MyNAS 确认”。此显示不改变“原件已安全上传”的含义，不持久化到下次 App 启动，也不承诺系统回调的频率或后台调度时间。2026-08-04 的首轮真机一度只在结束时跳到 100%，但同一实际传输随后确认完成前可实时更新；因此该可见行为已通过观察，仍不扩大为系统保证的回调频率。

## 平台与安全限制

- PhotoKit 不允许第三方 App 拦截用户在 Apple Photos 或其他 App 中的删除；应用只能从变化通知中发现变化。
- 公开 PhotoKit API 对某些编辑后的资源导出存在系统限制。若无法取得所需资源，必须明确失败并保留本机项目，不能降级伪装为完整备份。
- App 不实现 Tailscale 登录、不保存 Tailscale 密码或 OAuth token；认证由官方 Tailscale App、tailnet ACL 和 Tailscale Serve 完成。
- 如果未来支持应用层凭据，它们必须进入 Keychain，不能写入账号 JSON、缓存、日志或二维码。
