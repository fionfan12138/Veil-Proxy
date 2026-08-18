# Veil Core

本目录保存 v1.0 构建时内置的 mihomo 与 GeoIP 运行资源：

- `mihomo`：Apple Silicon arm64 可执行文件。
- `geoip.metadb`：规则模式使用的 GeoIP 数据库。

Xcode 构建阶段会将两项资源复制到：

```text
Veil.app/Contents/Resources/
```

运行时 `CoreManager` 优先使用 `~/Library/Application Support/Veil/` 中由 Veil 更新管理的 mihomo；若不存在，则回退到 App Resources 内置版本。

## 更新约束

- 替换 `mihomo` 后确认文件为 arm64 Mach-O 且具有执行权限。
- 更新内核或 GeoIP 后必须完成实际启动和控制接口健康检查。
- 不在此目录放用户配置、节点、订阅或 mihomo 运行日志。
- Intel 或 Universal 构建不属于 v1.0 范围，需要在后续版本单独设计资源选择与发布流程。

当前内置内核版本可通过以下命令确认：

```bash
./Veil/Core/mihomo -v
```
