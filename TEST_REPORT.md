# 本机测试报告（2026-10-20）

结论：已修复测试发现的脚本错误，32 项系统 Bash 3.2/隔离回归检查与五项真实集成检查通过。没有把全新安装脚本直接用于当前用户，因此不能宣称已经验证全新 macOS 的每一个安装/授权分支，也不能保证其他网络/系统下绝无错误。

## 本机条件和测试范围

- macOS 26.6.2，Apple Silicon，系统 Bash 3.2.57；测试开始时磁盘可用约 27GiB。
- 已有 Homebrew、Docker Desktop/Engine、Flutter 3.47.1/Dart 3.13.1、Xcode、Android Studio、Redis、uv。
- Flutter doctor 的主要待处理项是 Android 许可未全部接受。测试没有代为接受许可证。
- 全流程安装控制逻辑在临时 HOME、假安装前缀和外部命令替身中运行，实际执行 Bash、Python、zsh、SHA256 和 ditto 解压；真实集成测试使用工作区项目、临时 Redis Unix socket、临时 Docker 容器/专用卷，结束后关闭并清理临时服务。
- 未改写当前用户 shell 文件、数据库或 ROS 开发容器，未安装/升级大型应用。

## 修复内容

1. Flutter JSON 和 SDK 下载 URL 的目录错误：正确前缀是 `/flutter_infra_release/releases/`，官方和 CFUG 镜像均实际返回有效元数据。
2. macOS Bash 3.2 中未加花括号的变量紧跟中文标点可能被误解析，引发 unbound variable；统一使用 `${变量}`。
3. 原环境文件在依赖检查前被清空；改为临时生成，完成后才替换，失败保留生效配置。
4. Python 工作流原有条件列表可能在依赖安装失败后仍执行后续命令；改为显式失败传播，并复用已有测试虚拟环境。
5. 新 shell 检查原有分号可能掩盖前面工具缺失；改为逐项 `&&`。
6. 未安装的可选 zsh 插件不再无条件 source；修复 fzf/starship 命令可用性判断。
7. 主流程报告存在失败项时返回非零；日志/备份文件名包含 PID，减少同秒重跑覆盖。
8. Flutter 大归档增加并行吞吐量抽样和下载失败换源，避免小 JSON 快而 SDK 大文件慢。完整 SDK 仍验证 SHA256。
9. Android 收尾脚本解析 Flutter SDK 根目录前先解析符号链接。
10. ROS 选择架构和持久化失败有显式报告；增加本轮自动阶段耗时输出。

## 真实测试

| 项目 | 结果 | 观察耗时与限制 |
|---|---|---|
| uv 项目、venv、安装并导入 packaging | 通过 | 首次约 8.28 秒；复用后约 0.10 秒 |
| Redis 原生进程 | 通过 | 约 0.16–0.24 秒；临时 Unix socket，PONG，不抢占 6379 |
| ROS Jazzy | 通过 | 约 3.5–4.0 秒；已有 arm64 镜像，验证命令、环境、停启和容器重建后挂载持久性 |
| MySQL 8.4 | 通过 | 约 7.94 秒；已有镜像，隔离 Docker 实例 TCP 认证、SQL、重启后认证；不等于验证 Homebrew 原生服务 |
| Flutter Web release 构建 | 通过 | 新建测试项目总约 16 秒；编译约 13.8 秒；使用已有 SDK/部分缓存 |

详细原始结果在 `tests/live-results.json`，隔离回归输出在 `tests/mock-results.txt`。launchd plist 生成和字段已通过模拟检查；原生 MySQL 初始化、真实 launchd 注册、Homebrew 引导安装、所有 Cask 首装、GUI 权限与滚动方向、完整 Xcode/Android 平台构建未做端到端实装。

## 网络与预计时间

本机对官方/清华 Homebrew API、官方/清华 Python 索引做了实际请求，均可达；Docker Registry `/v2/` 返回 401 是正常认证挑战，不是拉取镜像完整性验证。

Flutter arm64 stable SDK 大文件抽样结果：

- CFUG 镜像：16MiB / 5.63 秒，约 2.98 MB/s。
- Google 官方：25 秒内收到约 2.01 MB，约 80 KB/s，样本请求超时。

测速原始结果见 `tests/network-speed.json`。这只是测试时段吞吐量，不代表其他应用、Docker Hub、Android 或 App Store 的速度；并行抽样也会受到共享带宽影响。

针对全新 Mac 的粗略规划（不是已测得的完整安装时长）：

| 范围 | 建议预留时间 |
|---|---|
| 该主脚本的自动安装与验证，网络顺畅、能用预编译包 | 45–90 分钟；弱网时可能超过 2 小时 |
| 额外安装完整 Xcode、Android SDK/模拟器并完成人工授权 | 总体约 2–4 小时；组件多/网络差会更久 |
| 全部工具和下载缓存已齐全，仅重复验证 | 通常 5–20 分钟，取决于 doctor、构建和服务启动 |

下载时间可按“总下载大小 / 实际吞吐量”估计：例如 8GiB 在持续 3MB/s 时纯下载就约 48 分钟，另加解压、安装、首次编译和人工操作。大件下载最影响整体耗时，无法用本机十几秒的缓存构建代替新机耗时。

## 复现

```bash
# 在克隆的仓库根目录执行
# 完整隔离回归；不安装软件、不修改真实用户配置
python3 tests/test_setup.py
# 可选真实测试；要求已有 brew Python/Redis、uv、Flutter 和运行中的 Docker
# 需要本地缓存 ros:jazzy-ros-base 和 mysql:8.4，否则可能尝试拉镜像
python3 tests/live_smoke.py
```

真实测试项目位于 `tests/live/`，未放入交付压缩包。测试记录保留在脚本包中。
