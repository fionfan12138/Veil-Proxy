# Core 目录

这里放置 mihomo（Clash.Meta）内核二进制。

- 在「步骤 0.2」中，本目录会存放 `mihomo` 可执行文件（Apple Silicon = arm64 / Intel = amd64）。
- 构建阶段会把该二进制拷入 App（`.app/Contents/Resources`），运行时由 App 从 `Bundle.main` 定位。
- 当前（步骤 0.1）尚未放置二进制，仅作占位说明。
