# 新 Mac 开发环境初始化

适用于 Apple Silicon / Intel 的原生 macOS 终端。脚本兼容系统 Bash 3.2，不依赖预装 Python。建议受当前 Homebrew、Docker Desktop、Flutter 支持的较新 macOS，至少预留 40GB；Xcode 与模拟器可能需要更多空间。

## 执行

在新 Mac 的终端先克隆仓库：

```bash
git clone https://github.com/hurricane-gathering/mac-setup.git
```

然后在同一目录执行下面这一条命令：

```bash
bash mac-setup/scripts/setup.sh auto
```

无需先 `cd`，不要在命令前加 `sudo`。脚本会把运行所需文件、日志和备份整理到 `~/Developer/mac-setup/`。若克隆后已经进入仓库目录，则执行 `bash scripts/setup.sh auto`。

全新 Mac 如果尚无 Git/Command Line Tools，`git clone` 会提示安装开发工具：按提示完成；也可先执行 `xcode-select --install`，安装完成后再运行上面两步。GitHub 无法访问时，先配置可用的网络或代理。

- `auto`：官方源、可信国内源并行小请求测速；Flutter SDK 额外抽样大文件吞吐量再选下载源。
- `cn`：优先使用探测通过的国内源；探测失败保留官方源。
- `global`：本次选择官方源，清除本进程对应镜像覆盖。

脚本可重复运行，结果保存在 `~/Developer/mac-setup/`。不要使用 `sudo bash`，不要通过 curl 管道执行。Homebrew 安装和部分 Cask 可能自行请求 sudo，输入时不会回显密码。

首次全新 Mac 缺 CLT 时会触发安装弹窗并退出；完成后重跑即可。Homebrew 是 Cask 安装依赖，因此会先安装它，再按阶段处理应用和工具。

网络受限时，可在运行前设置已有可信代理（端口按你实际代理设置修改）：

```bash
export HTTPS_PROXY=http://127.0.0.1:7890
export HTTP_PROXY="$HTTPS_PROXY"
export ALL_PROXY="$HTTPS_PROXY"
bash mac-setup/scripts/setup.sh auto
```

代理不会被脚本写入配置。Docker Engine 拉镜像需要单独在 Docker Desktop > Settings > Resources > Proxies 配置代理；终端代理不能替代。没有有效外网或代理时，Docker Hub、Google Android 下载、部分应用下载仍可能失败，任何脚本都无法保证在所有国内外网络中完成。脚本不会添加不可追溯的公共 Docker 加速站，也不会关闭 TLS 校验、Gatekeeper 或 SIP。

## 默认启用依赖驱动的并行调度

上面的 `auto` 命令已经使用并行方案；`auto` 仍表示自动选源，无需额外添加并行开关。

| 工作 | 并行与依赖关系 |
|---|---|
| Homebrew 公式/依赖、Docker Desktop、其他桌面应用 | 三组并行预下载，复用 Homebrew 缓存及校验机制 |
| Docker / ROS | Docker 安装后立即启动，拉镜像和容器验证与其余工作重叠 |
| Flutter SDK / Web | Python 就绪即启动；已有 Python 时不等其他公式装完；下载、校验、解压、Web 构建与其他任务重叠 |
| uv / Python、Redis、MySQL | 各自依赖就绪后独立后台运行 |
| Flutter macOS / Android 配置与 doctor | 等待 Flutter SDK/Web 任务结束，并等待 CocoaPods 和 Android Studio 安装完成，避免依赖和 SDK 锁冲突 |
| Homebrew 安装、shell 配置落盘 | 由主进程串行处理；预下载不与同组安装争用下载锁；所有 worker 结束后才合并环境配置 |

默认根据硬件选择并发预算：CPU 少于 4 线程时为 2；其他机器内存不足 12GiB 为 4；内存至少 12GiB 为 6。预算包含一个前台安装位置，其余用于后台任务。并发不等于同时启动多个 Homebrew 安装。

高速网络、内存充裕时，可用这一条命令提高上限（仍保留安装锁）：

```bash
MAC_SETUP_JOBS=8 MAC_SETUP_DOWNLOADS=8 bash mac-setup/scripts/setup.sh auto
```

`MAC_SETUP_JOBS` 和 `MAC_SETUP_DOWNLOADS` 均接受 1–8。前者限制阶段任务并发，设为 1 即串行兼容模式；后者默认 4，用于 Homebrew 下载队列，并分摊给三组预下载，每组至少一个连接。Docker、Flutter 测速等有独立的连接，因此它不是整个系统的 TCP 连接总上限。增大并发只在带宽/CPU 尚未饱和时有收益。

每个任务独立写入 `logs/<本轮标识>-jobs/<任务>.log`、`.tsv` 和 `.env`；主日志显示启动/完成/失败，主进程合并结果。`timeline.tsv` 记录开始、结束及退出码。任一任务失败不丢弃其他任务结果，最终仍返回失败；缺少依赖的后续步骤会标注未执行。按 Ctrl-C 会终止受管后台任务及其下载子进程，并释放运行锁；已经完成的安装/服务不自动卸载。

## 自动完成的范围

- 检查系统、架构、磁盘、工具和已有 shell 文件；拒绝 Rosetta 终端和 root 用户。
- 安装或复用 Cursor、Chrome、微信、飞书、Docker Desktop、Mos、Android Studio；读取应用版本并请求启动。请求启动不代表完成登录和 GUI 功能验收。
- Homebrew 使用预编译 bottle；公式和依赖、Docker Desktop、其他 Cask 分组并行预下载，安装始终由前台单个进程执行。已安装公式不自动升级；预下载失败不阻断其他任务，前台公式安装最多切回官方源重试一次。
- 默认选 Node 24 LTS、MySQL 8.4 LTS；Node 路径独立，不删除其他版本。未安装版本管理器；项目需多版本时另行选用 fnm 等工具。npm registry 不修改。
- uv 自身和 Python 3.13 通过 Homebrew 安装，避免把 PyPI 镜像错误地当成 Python 解释器下载镜像。建立独立 Python 测试项目和虚拟环境，安装并导入 packaging。已有 uv 配置保留；无已有用户配置时写入本工具的环境文件。
- 全新数据库使用独立数据目录和配置，Redis/MySQL 只绑定 127.0.0.1，MySQL 关闭 X Protocol。检测到已有数据、CLI 或占用端口时保留并报告人工处理，不重置旧 root 密码。MySQL 使用默认现代认证，不降级认证插件；旧客户端可能需要升级。
- 新建 MySQL 采用原任务要求的本地弱口令；仅适用于隔离的本地开发，严禁生产或端口转发。SQL 通过后重启再验证 TCP 认证。Homebrew 初始化的默认数据库不作为本脚本服务使用，勿再运行 `brew services start mysql@8.4` 启动另一套实例。
- ROS 使用原生多架构官方 `ros:jazzy-ros-base`，`ros-jazzy-dev` 长期容器运行 `sleep infinity`，自动重启策略 `unless-stopped`；仅挂载 `~/Developer/ros2_ws`。不映射端口，不启用 privileged 或 host 网络。验证 ROS 命令、环境和停止/启动后的持久性，再用可删除的临时验证容器读取同一文件。
- Flutter stable 从发行元数据选择架构，并校验 SHA256；校验值来自所选发行源，选择镜像意味着信任镜像维护方。保留已有可用 Flutter。安装到 `~/Developer/flutter`；实际创建测试项目并构建 Web，具备完整 Xcode 时尝试 macOS 构建。
- zsh 使用 autosuggestions、fzf、starship、syntax-highlighting；本工具加载块中语法高亮最后加载。既有第三方插件可能仍需手工检查。修改前备份、source 行不重复、zsh PATH 去重；不改默认 shell。

## 必须人工完成的步骤

1. 登录桌面应用；Docker 首次许可和权限，随后重跑 setup。
2. App Store 安装并首次启动完整 Xcode，安装所需 iOS 平台/模拟器。仓库提供：

   ```bash
   bash ~/Developer/mac-setup/scripts/finish-platforms.sh apple
   ```

   此命令说明并通过 sudo 切换 Xcode 路径，展示许可供本人阅读接受，执行首次组件配置，尝试 macOS 与 iOS 模拟器构建。缺模拟器运行时需在 Xcode Settings > Components 安装；真机签名需账号。
3. Android Studio 首次 Setup Wizard。在 SDK Manager 安装 Command-line Tools (latest)；再执行：

   ```bash
   bash ~/Developer/mac-setup/scripts/finish-platforms.sh android
   ```

   会使用 Studio 自带 JDK，让本人阅读接受 SDK 许可，解析已装 Flutter 要求的 compile SDK 并下载安装，尝试 APK 构建。若 Build Tools/NDK 下载受限，依据 doctor/构建日志在 SDK Manager 补齐；脚本不盲目勾选许可。Android 不以“安装了 Studio”判定成功。
4. Mos：系统设置 > 隐私与安全性 > 辅助功能，授予权限；在 Mos 中调整鼠标反向选项并与系统触控板自然滚动配合，亲手分别测试鼠标/触控板，按个人习惯决定开关。设置登录启动。退出 Mos 即恢复系统处理；脚本不猜测 GUI 私有配置键。
5. 新开终端检查灰色自动建议、右方向键接受、上下键历史搜索、Ctrl-R 模糊搜索、语法高亮和 Git 分支/脏状态。非 zsh 默认 shell 可自行 `chsh -s /bin/zsh`，脚本不自动切换。
6. Windows/Linux 原生 Flutter 构建使用对应操作系统。ROS 基础镜像不包含完整桌面、RViz 或 Mac GUI/DDS 跨宿主机通信配置。

## 文件、状态与日志

`configs/env.zsh` 为工具源和 PATH；`configs/terminal.zsh` 为终端插件；`configs/mysql.cnf`、`redis.conf` 为受管数据库配置；`state/` 包含数据库、测试项目和管理标记；`backups/` 保存修改前备份；`logs/时间.tsv` 为本轮状态，配套 `.log` 和 `-versions.txt`。

成功表示该项列出的检查已执行通过；部分完成/待人工操作不等于可用性全部验收。后台任务遇关键失败会在独立日志记录行号，其他独立任务继续；主进程汇总所有结果后以非零状态退出。引导阶段失败会立即退出。检查日志、修复网络或权限后重跑；失败不代表自动回滚安装过的软件。不要删除 state 中的数据库或管理标记来“修复”。已在现有 Mac 完成系统 Bash 3.2 隔离回归及 uv、Redis、ROS、MySQL 隔离引擎、Flutter Web 真实集成测试；未完成全新 Mac 端到端实装。详见 TEST_REPORT.md，最终以目标机报告为准。

可正常处理的中断会自动清理任务与运行锁；断电或 SIGKILL 仍可能留下 `state/lock`；确认没有另一个安装进程后用 `rmdir ~/Developer/mac-setup/state/lock` 清除。不要同时运行两份脚本。

## 常用命令

```bash
brew search redis
brew info mysql@8.4
brew install <公式名称>
node --version; npm --version; npm config get registry
redis-cli -h 127.0.0.1 ping
mysql -h 127.0.0.1 -P 3306 -u root -p
# MySQL/Redis 服务由本用户 LaunchAgent 管理，以下把 mysql 换成 redis 即管理 Redis
launchctl print gui/$(id -u)/local.macsetup.mysql
launchctl kickstart -k gui/$(id -u)/local.macsetup.mysql
# 停止并取消当前用户登录启动
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/local.macsetup.mysql.plist
# 启动并恢复当前用户登录启动
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.macsetup.mysql.plist
bash ~/Developer/mac-setup/docker/ros.sh enter
bash ~/Developer/mac-setup/docker/ros.sh stop
bash ~/Developer/mac-setup/docker/ros.sh start
bash ~/Developer/mac-setup/docker/ros.sh logs
flutter --version; dart --version; flutter doctor -v
uv init example
cd example
uv venv
uv pip install packaging
exec zsh -l
bash ~/Developer/mac-setup/scripts/verify.sh
```

ROS 手工重建：先确认宿主目录备份，`docker stop ros-jazzy-dev`，`docker rm ros-jazzy-dev`，再执行 `bash ~/Developer/mac-setup/docker/ros.sh create`。只把代码存在挂载目录；容器内其他改动会随删除丢失。需要重复初始化系统依赖时编写 Dockerfile，不在本脚本自动删除开发容器。

## 恢复官方源与回滚

先备份 `configs/env.zsh`，删除其中 `HOMEBREW_API_DOMAIN`、`HOMEBREW_BOTTLE_DOMAIN`、`HOMEBREW_BREW_GIT_REMOTE`、`UV_DEFAULT_INDEX`、`PUB_HOSTED_URL`、`FLUTTER_STORAGE_BASE_URL` 对应 export 行；保留 PATH、brew shellenv。当前终端执行：

```bash
unset HOMEBREW_API_DOMAIN HOMEBREW_BOTTLE_DOMAIN HOMEBREW_BREW_GIT_REMOTE
unset UV_DEFAULT_INDEX PUB_HOSTED_URL FLUTTER_STORAGE_BASE_URL
exec zsh -l
```

脚本不修改现有 Homebrew Git origin；已有 shell 里的旧镜像、npmrc、uv 用户/项目文件可能仍生效，需查看这些原有文件，不能通过本工具环境文件撤销。`global` 模式重跑也会重新生成官方环境文件，但不会删除既有用户配置。

撤销终端配置：从 `.zprofile`、`.zshrc` 删除本工具增加的 source 行，或审阅 `backups/` 后恢复文件。服务回滚先 bootout；数据和应用不自动删除。不要用覆盖备份的方式丢弃后续个人改动。

## 来源

- [Homebrew 官方安装](https://docs.brew.sh/Installation)、[清华 Homebrew 镜像](https://mirrors.tuna.tsinghua.edu.cn/help/homebrew/)
- [Node 24 Homebrew 公式](https://formulae.brew.sh/formula/node@24)、[MySQL 8.4 公式](https://formulae.brew.sh/formula/mysql@8.4)
- [uv 环境变量与 Python 下载源](https://docs.astral.sh/uv/configuration/environment/)
- [Flutter 官方国内镜像说明](https://docs.flutter.dev/community/china)
- [Docker Desktop Cask](https://formulae.brew.sh/cask/docker-desktop)

镜像探测只是执行当时的小请求可用性；不能证明所有大文件均可下载。Homebrew 的 Git、API、bottle 分别配置，Cask 的厂商下载通常不会被 bottle 镜像加速。Flutter SDK/存储和 Dart Pub 单独配置，Python 包索引不会改变解释器分发来源。

本机测试记录、修复清单和时间估算见 [TEST_REPORT.md](TEST_REPORT.md)。以本机网络抽样推算，新机自动阶段建议预留 45–90 分钟，包含 Xcode/Android 组件和人工步骤约 2–4 小时；这不是完整首装实测耗时。
