# MNN runtime lock

This directory contains the static MNN runtime required by the local Qwen3-VL
embedding engine. It is linked only for arm64 iPhone builds and arm64 Apple
Silicon Simulator builds. Intel (`x86_64`) Simulator intentionally builds the
app's no-runtime fallback, because it is not an iPhone delivery target.

| field | value |
| --- | --- |
| upstream repository | `https://github.com/alibaba/MNN` |
| source revision | `75e53afe568f7b6fabb1adc34894fe9f331d52f8` |
| framework API version | `3.6.1` |
| deployment target | iOS 18.0 |
| execution policy | CPU, four threads; Metal is not selected at runtime |
| artifact | `MNN-75e53afe.xcframework` |

The framework is a 21 MB development artifact containing two static slices:
`ios-arm64` and `ios-arm64-simulator`. It is separate from the 2.2 GB Qwen
model package, which is user-downloaded and hash-verified before activation.

`LocalMNNRuntimeAvailabilityTests` proves this boundary in the app test host:
arm64 must report a linked runtime, while an Intel Simulator must report the
safe no-runtime fallback. It intentionally does not import a 2.2 GB model
package during ordinary test runs.

MNN is licensed under Apache-2.0. `LICENSE.txt` is the unmodified upstream
license text. Before any external release, retain all applicable third-party
notices alongside this binary.
