#!/bin/bash
# macOS system Bash 3.2 compatible. Run as your normal user, never sudo bash.
set -Eeuo pipefail
umask 077
MODE=${1:-auto}
case "${MODE}" in auto|cn|global) ;; *) echo 'Usage: bash setup.sh [auto|cn|global]'; exit 2;; esac
[[ $(uname -s) == Darwin && ${EUID} -ne 0 ]] || { echo '请在 macOS 上以普通用户运行'; exit 2; }
[[ $(sysctl -in sysctl.proc_translated 2>/dev/null || true) != 1 ]] || { echo '请关闭 Rosetta 终端并用原生终端运行'; exit 2; }
# Bounds apply to stage workers; brew has its own bounded download queue.
CORES=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
MEMORY=$(sysctl -n hw.memsize 2>/dev/null || echo 8589934592)
[[ ${CORES} =~ ^[0-9]+$ ]] || CORES=4
[[ ${MEMORY} =~ ^[0-9]+$ ]] || MEMORY=8589934592
AUTO_JOBS=6
[[ ${MEMORY} -ge 12884901888 ]] || AUTO_JOBS=4
[[ ${CORES} -ge 4 ]] || AUTO_JOBS=2
MAX_JOBS=${MAC_SETUP_JOBS:-${AUTO_JOBS}}
DOWNLOADS=${MAC_SETUP_DOWNLOADS:-4}
[[ ${MAX_JOBS} =~ ^[1-8]$ && ${DOWNLOADS} =~ ^[1-8]$ ]] || { echo 'MAC_SETUP_JOBS / MAC_SETUP_DOWNLOADS 必须为 1–8'; exit 2; }
JOB_NAMES=() JOB_PIDS=() JOB_DONE=() JOB_STATUS=()
stop_tree() {
  local pid="$1" child
  for child in $(pgrep -P "${pid}" 2>/dev/null || true); do stop_tree "${child}"; done
  kill -TERM "${pid}" 2>/dev/null || true
}
cleanup() {
  local rc=$? j
  trap - EXIT INT TERM
  for ((j=0;j<${#JOB_PIDS[@]};j++)); do
    if [[ ${JOB_DONE[j]} == 0 ]]; then
      stop_tree "${JOB_PIDS[j]}"
      wait "${JOB_PIDS[j]}" 2>/dev/null || true
    fi
  done
  [[ -z ${TMP:-} ]] || rm -rf "${TMP}"
  rmdir "${ROOT}/state/lock" 2>/dev/null || true
  exit "${rc}"
}
ROOT="${HOME}/Developer/mac-setup"
mkdir -p "${ROOT}"/{scripts,configs,logs,backups,state,docker} "${HOME}/Developer"
# Prevent concurrent runs; stale locks are deliberately not deleted automatically.
mkdir "${ROOT}/state/lock" 2>/dev/null || { echo "已有运行或残留锁：${ROOT}/state/lock；确认无安装进程后再 rmdir"; exit 2; }
TMP=$(mktemp -d)
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Keep the entry script so subsequent runs use the same reviewed file.
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
PACKAGE_DIR=$(cd "${SELF_DIR}/.." && pwd)
if [[ "${SELF_DIR}/setup.sh" != "${ROOT}/scripts/setup.sh" ]]; then cp "$0" "${ROOT}/scripts/setup.sh"; fi
for asset in README.md TEST_REPORT.md docker/ros.sh scripts/verify.sh scripts/finish-platforms.sh; do
  [[ ! -f "${SELF_DIR}/../${asset}" || "${PACKAGE_DIR}" == "${ROOT}" ]] || cp "${SELF_DIR}/../${asset}" "${ROOT}/${asset}"
done
STAMP=$(date +%Y%m%d-%H%M%S)-$$
LOG="${ROOT}/logs/${STAMP}.log"
REPORT="${ROOT}/logs/${STAMP}.tsv"
printf '项目\t状态\t说明\n' > "${REPORT}"
exec > >(tee -a "${LOG}") 2>&1
note() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "${REPORT}"; }
trap 'record 脚本 失败 "第 ${LINENO} 行终止；参见日志"' ERR
backup() { [[ ! -e "$1" ]] || cp -p "$1" "${ROOT}/backups/$(basename "$1").${STAMP}"; }
fetch() { curl --fail --location --connect-timeout 10 --speed-limit 1024 --speed-time 30 --max-time 1800 --retry 1 --retry-delay 2 "$1" -o "$2"; }
# Concurrent small GET probes, choose shortest response time, not IP geolocation.
choose() {
  local path="$1" official="$2" mirror="$3" a b chosen pa pb
  if [[ ${MODE} == global ]]; then printf '%s' "${official}"; return; fi
  a="${TMP}/probe-a"; b="${TMP}/probe-b"
  (curl -fLs --connect-timeout 4 --max-time 9 -o /dev/null -w '%{time_total}' "${official}${path}" > "${a}" || echo 999 > "${a}") &
  pa=$!
  (curl -fLs --connect-timeout 4 --max-time 9 -o /dev/null -w '%{time_total}' "${mirror}${path}" > "${b}" || echo 999 > "${b}") &
  pb=$!
  wait "${pa}"; wait "${pb}"
  chosen=$(awk -v a="$(cat "${a}")" -v b="$(cat "${b}")" 'BEGIN {if(b<999 && (b<a || ENVIRON["MODE"]=="cn")) print "mirror"; else print "official"}')
  if [[ ${MODE} == cn && $(cat "${b}") != 999 ]]; then chosen=mirror; fi
  if [[ ${chosen} == mirror ]]; then printf '%s' "${mirror}"; else printf '%s' "${official}"; fi
}
# SDK archives are large: test real ranged throughput, not just small-JSON latency.
choose_transfer() {
  local route="$1" official="$2" mirror="$3" sa sb pa pb
  if [[ ${MODE} == global ]]; then printf '%s' "${official}"; return; fi
  (curl -Ls --range 0-524287 --max-filesize 1048576 --connect-timeout 4 --max-time 8 -o /dev/null -w '%{speed_download}' "${official}${route}" > "${TMP}/speed-a" || true) &
  pa=$!
  (curl -Ls --range 0-524287 --max-filesize 1048576 --connect-timeout 4 --max-time 8 -o /dev/null -w '%{speed_download}' "${mirror}${route}" > "${TMP}/speed-b" || true) &
  pb=$!
  wait "${pa}"; wait "${pb}"
  sa=$(cat "${TMP}/speed-a"); sb=$(cat "${TMP}/speed-b")
  if awk -v a="${sa}" -v b="${sb}" -v mode="${MODE}" 'BEGIN {exit !(b>1024 && (b>a || mode=="cn"))}'; then printf '%s' "${mirror}"; else printf '%s' "${official}"; fi
}

runcheck() { local label="$1"; shift; if "$@"; then record "${label}" 成功 '实际命令通过'; else record "${label}" 失败 '查看日志；修复后重跑'; fi; }
# Scoped environment, never rewrite existing registry/uv/project settings.
FINAL_ENVFILE="${ROOT}/configs/env.zsh"
ENVFILE="${TMP}/env.zsh"
: > "${ENVFILE}"
printf '[[ -z ${ZSH_VERSION:-} ]] || typeset -U path\n' >> "${ENVFILE}"
persist() { printf 'export %s=%q\n' "$1" "$2" >> "${ENVFILE}"; export "$1=$2"; }
note '阶段 1：检查环境'
sw_vers; uname -m; sysctl -n machdep.cpu.brand_string; df -h "${HOME}"
printf '用户=%s shell=%s terminal=%s\n' "$(id -un)" "${SHELL:-unknown}" "${TERM_PROGRAM:-unknown}"
for cmd in git brew docker mysql redis-cli node npm uv python3 flutter dart; do command -v "${cmd}" || true; done
printf 'PATH=%s\n' "${PATH}"
for file in .zprofile .zshrc .bash_profile .npmrc .config/uv/uv.toml; do [[ ! -f "${HOME}/${file}" ]] || printf '已有配置：%s\n' "${HOME}/${file}"; done
note "并行预算 ${MAX_JOBS}（含前台安装）；下载队列 ${DOWNLOADS}。大型 SDK/应用建议至少 40GB，可能请求 sudo。数据库仅本机监听，保留已有数据库。"
FREE=$(df -Pk "${HOME}" | awk 'END{print $4}')
[[ ${FREE} -ge 20971520 ]] || { echo '剩余不足 20GiB，释放空间后重跑'; exit 1; }
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find clang >/dev/null 2>&1; then
  xcode-select --install || true
  record CLT 待人工操作 '在系统弹窗完成命令行工具安装后重跑'
  echo '完成 CLT 安装后重新执行本脚本。'; exit 3
fi
# Remove only this script's previously exported public mirror values before re-probing.
for v in HOMEBREW_API_DOMAIN HOMEBREW_BOTTLE_DOMAIN HOMEBREW_BREW_GIT_REMOTE UV_DEFAULT_INDEX PUB_HOSTED_URL FLUTTER_STORAGE_BASE_URL; do
  case "${!v:-}" in
    https://mirrors.tuna.tsinghua.edu.cn/*|https://pub.flutter-io.cn|https://storage.flutter-io.cn) unset "${v}";;
  esac
done
if [[ ${MODE} == global ]]; then
  unset HOMEBREW_API_DOMAIN HOMEBREW_BOTTLE_DOMAIN HOMEBREW_BREW_GIT_REMOTE UV_DEFAULT_INDEX PUB_HOSTED_URL FLUTTER_STORAGE_BASE_URL
fi
note 'Homebrew 是后续应用安装的依赖，因此先引导安装'
BREW_API=$(choose /formula/git.json https://formulae.brew.sh/api https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/api)
if [[ ${BREW_API} != https://formulae.brew.sh/api ]]; then
  persist HOMEBREW_API_DOMAIN "${BREW_API}"
  persist HOMEBREW_BOTTLE_DOMAIN https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles
  # Test Git repository separately; API/bottle availability does not imply Git availability.
  if git -c http.connectTimeout=5 -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=10 ls-remote https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/brew.git HEAD > "${TMP}/git-probe" 2>/dev/null; then
    persist HOMEBREW_BREW_GIT_REMOTE https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/brew.git
  fi
fi
if [[ $(uname -m) == arm64 ]]; then PREFIX=/opt/homebrew; else PREFIX=/usr/local; fi
if [[ -x "${PREFIX}/bin/brew" ]]; then
  eval "$("${PREFIX}/bin/brew" shellenv)"
elif command -v brew >/dev/null; then
  PREFIX=$(brew --prefix)
else
  if fetch https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh "${TMP}/install.sh"; then
    /bin/bash "${TMP}/install.sh"
  else
    git clone --depth=1 https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/install.git "${TMP}/brew-install"
    /bin/bash "${TMP}/brew-install/install.sh"
  fi
  eval "$("${PREFIX}/bin/brew" shellenv)"
fi
printf 'eval "$(%q shellenv)"\n' "${PREFIX}/bin/brew" >> "${ENVFILE}"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_CURL_RETRIES=2 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_DOWNLOAD_CONCURRENCY=${DOWNLOADS}
ensure_formula() {
  local f="$1"
  brew list --formula "${f}" >/dev/null 2>&1 && return 0
  if brew install "${f}"; then return 0; fi
  note "${f} 安装失败；移除本次镜像覆盖后用官方源重试一次"
  if env -u HOMEBREW_API_DOMAIN -u HOMEBREW_BOTTLE_DOMAIN -u HOMEBREW_BREW_GIT_REMOTE brew install "${f}"; then return 0; fi
  record "${f}" 失败 '镜像与官方源安装均失败，检查日志和代理'; return 1
}

RUN_DIR="${ROOT}/logs/${STAMP}-jobs"
mkdir -p "${RUN_DIR}"
printf 'task\tstart_epoch\tend_epoch\texit_code\n' > "${RUN_DIR}/timeline.tsv"
collect_job() {
  local n="$1" code=0 label
  [[ ${JOB_DONE[n]} == 0 ]] || return 0
  label=${JOB_NAMES[n]}
  if wait "${JOB_PIDS[n]}"; then code=0; else code=$?; fi
  JOB_DONE[n]=1; JOB_STATUS[n]=${code}
  [[ ! -f "${RUN_DIR}/${label}.tsv" ]] || cat "${RUN_DIR}/${label}.tsv" >> "${REPORT}"
  [[ ! -f "${RUN_DIR}/${label}.timing" ]] || cat "${RUN_DIR}/${label}.timing" >> "${RUN_DIR}/timeline.tsv"
  if [[ ${code} -eq 0 ]]; then note "并行任务完成：${label}"; else
    record "任务 ${label}" 失败 "退出码 ${code}；${RUN_DIR}/${label}.log"
    note "并行任务失败：${label}；其他任务继续，详情 ${RUN_DIR}/${label}.log"
    tail -n 8 "${RUN_DIR}/${label}.log"
  fi
}
reap_finished() {
  local n
  for ((n=0;n<${#JOB_PIDS[@]};n++)); do
    if [[ ${JOB_DONE[n]} == 0 ]] && ! kill -0 "${JOB_PIDS[n]}" 2>/dev/null; then collect_job "${n}"; fi
  done
}
active_jobs() {
  local n count=0
  for ((n=0;n<${#JOB_PIDS[@]};n++)); do [[ ${JOB_DONE[n]} != 0 ]] || count=$((count+1)); done
  printf '%s' "${count}"
}
start_job() {
  local label="$1" n budget
  shift
  budget=$((MAX_JOBS-1)); [[ ${budget} -ge 1 ]] || budget=1
  reap_finished
  while [[ $(active_jobs) -ge ${budget} ]]; do sleep 0.2; reap_finished; done
  n=${#JOB_PIDS[@]}
  note "并行启动：${label}；日志 ${RUN_DIR}/${label}.log"
  (
    # Reset inherited parent EXIT trap: workers must not release the global lock.
    trap - EXIT INT TERM
    set -Eeuo pipefail
    REPORT="${RUN_DIR}/${label}.tsv"
    ENVFILE="${RUN_DIR}/${label}.env"
    TMP="${TMP}/${label}"; mkdir -p "${TMP}"
    : > "${REPORT}"; : > "${ENVFILE}"
    started=$(date +%s)
    trap 'rc=$?; printf "%s\t%s\t%s\t%s\n" "${label}" "${started}" "$(date +%s)" "${rc}" > "${RUN_DIR}/${label}.timing"' EXIT
    trap 'record "任务 ${label}" 失败 "第 ${LINENO} 行执行失败"' ERR
    "$@"
  ) > "${RUN_DIR}/${label}.log" 2>&1 &
  JOB_NAMES[n]=${label}; JOB_PIDS[n]=$!; JOB_DONE[n]=0; JOB_STATUS[n]=0
  if [[ ${MAX_JOBS} -eq 1 ]]; then collect_job "${n}"; fi
}
wait_job() {
  local label="$1" n
  for ((n=0;n<${#JOB_PIDS[@]};n++)); do
    if [[ ${JOB_NAMES[n]} == "${label}" ]]; then collect_job "${n}"; return 0; fi
  done
}
job_ok() {
  local n
  for ((n=0;n<${#JOB_PIDS[@]};n++)); do
    if [[ ${JOB_NAMES[n]} == "$1" ]]; then [[ ${JOB_DONE[n]} == 1 && ${JOB_STATUS[n]} == 0 ]]; return; fi
  done
  return 1
}
prefetch() {
  local kind="$1" concurrency=${FETCH_CONNECTIONS}; shift
  if [[ ${kind} == formula ]]; then concurrency=${FORMULA_CONNECTIONS}; fi
  [[ $# -gt 0 ]] || return 0
  # Download only. Installs always stay in the foreground, one process at a time.
  # Formula prefetch is joined before any formula install to avoid cache locks.
  if [[ ${kind} == formula ]]; then
    if HOMEBREW_DOWNLOAD_CONCURRENCY=${concurrency} brew fetch --deps --formula "$@"; then return 0; fi
  else
    if HOMEBREW_DOWNLOAD_CONCURRENCY=${concurrency} brew fetch --cask "$@"; then return 0; fi
  fi
  record "预下载 ${kind}" 部分完成 '部分下载失败；前台安装将检查缓存并按既有回退策略重试'
}
install_cask() {
  local cask="$1" app="$2" apppath version
  apppath="/Applications/${app}.app"
  if [[ ! -d "${apppath}" && ! -d "${HOME}/Applications/${app}.app" ]]; then
    if ! brew install --cask "${cask}"; then record "${app}" 失败 '下载/安装失败，查看主日志，配置网络后重跑'; return 0; fi
  fi
  [[ -d "${apppath}" ]] || apppath="${HOME}/Applications/${app}.app"
  version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${apppath}/Contents/Info.plist" 2>/dev/null || echo unknown)
  if open "${apppath}"; then record "${app}" 部分完成 "版本 ${version}；${apppath}；已请求启动，登录/权限需人工验收"; else record "${app}" 部分完成 "版本 ${version}；启动失败，检查兼容性"; fi
}

launch_service() {
  local name="$1" binary="$2" config="$3" label="local.macsetup.$1" plist="${HOME}/Library/LaunchAgents/local.macsetup.$1.plist"
  mkdir -p "${HOME}/Library/LaunchAgents"
  "${PY}" - "${plist}" "${label}" "${binary}" "${config}" "${ROOT}/logs/${name}-service.log" <<'PY'
import plistlib,sys
path,label,binary,conf,log=sys.argv[1:]
args=[binary, '--defaults-file='+conf] if label.endswith('mysql') else [binary,conf]
with open(path,'wb') as f: plistlib.dump(dict(Label=label,ProgramArguments=args,RunAtLoad=True,KeepAlive=True,StandardOutPath=log,StandardErrorPath=log),f)
PY
  launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1 || launchctl bootstrap "gui/$(id -u)" "${plist}"
}

stage_uv() {
INDEX=$(choose /simple/packaging/ https://pypi.org https://mirrors.tuna.tsinghua.edu.cn/pypi/web)
record 'Python 索引' 部分完成 "测试候选 ${INDEX}/simple/；仅用于本次验证，不覆盖已有 uv 配置"
if [[ -z ${UV_DEFAULT_INDEX:-} && ! -f "${HOME}/.config/uv/uv.toml" && ! -f "${HOME}/Library/Application Support/uv/uv.toml" ]]; then
  persist UV_DEFAULT_INDEX "${INDEX}/simple/"
fi
if command -v uv >/dev/null; then
  mkdir -p "${ROOT}/state/python-smoke"
  (cd "${ROOT}/state/python-smoke" && { [[ -f pyproject.toml ]] || uv init --bare --python "${PY}"; } && { [[ -x .venv/bin/python ]] || uv venv --python "${PY}" .venv; } && uv pip install --python .venv/bin/python --index-url "${INDEX}/simple/" packaging && .venv/bin/python -c 'import packaging; print(packaging.__version__)') && record uv工作流 成功 '建项目、虚拟环境、安装和导入依赖通过' || record uv工作流 失败 '查看日志'
fi

}

stage_redis() {
if [[ -x "${PREFIX}/opt/redis/bin/redis-server" ]]; then
  if [[ -f "${ROOT}/state/redis-owned" ]] || { [[ ! -f "${ROOT}/state/redis-preexisting" ]] && ! lsof -nP -iTCP:6379 -sTCP:LISTEN >/dev/null 2>&1 && ! brew services list | awk '$1=="redis"&&$2=="started"{found=1} END{exit !found}'; }; then
    mkdir -p "${ROOT}/state/redis"
    cat > "${ROOT}/configs/redis.conf" <<EOF
bind 127.0.0.1
protected-mode yes
port 6379
dir "${ROOT}/state/redis"
appendonly yes
daemonize no
EOF
    touch "${ROOT}/state/redis-owned"
    launch_service redis "${PREFIX}/opt/redis/bin/redis-server" "${ROOT}/configs/redis.conf"
    sleep 2
    if [[ $(redis-cli -h 127.0.0.1 ping) == PONG ]]; then record Redis 成功 '127.0.0.1:6379，PONG'; else record Redis 失败 '查看服务日志'; fi
  else record Redis 部分完成 '发现已有服务，未修改配置；请核查绑定地址'; fi
fi

}

stage_mysql() {
if [[ -x "${PREFIX}/opt/mysql@8.4/bin/mysqld" ]]; then
  # Homebrew initializes prefix/var/mysql on install, so distinguish newly installed from preexisting data by checking before install (see snapshot).
  if [[ -f "${ROOT}/state/mysql-owned" ]]; then own_mysql=yes
  elif [[ -f "${ROOT}/state/mysql-preexisting" ]] || lsof -nP -iTCP:3306 -sTCP:LISTEN >/dev/null 2>&1; then own_mysql=no
  else own_mysql=yes; fi
  if [[ ${own_mysql} == yes ]]; then
    mkdir -p "${ROOT}/state/mysql"
    cat > "${ROOT}/configs/mysql.cnf" <<EOF
[mysqld]
basedir=${PREFIX}/opt/mysql@8.4
datadir=${ROOT}/state/mysql
bind-address=127.0.0.1
port=3306
mysqlx=0
socket=${ROOT}/state/mysql.sock
pid-file=${ROOT}/state/mysql.pid
EOF
    if [[ ! -d "${ROOT}/state/mysql/mysql" ]]; then
      "${PREFIX}/opt/mysql@8.4/bin/mysqld" --defaults-file="${ROOT}/configs/mysql.cnf" --initialize-insecure
      touch "${ROOT}/state/mysql-initializing"
    fi
    touch "${ROOT}/state/mysql-owned"
    launch_service mysql "${PREFIX}/opt/mysql@8.4/bin/mysqld" "${ROOT}/configs/mysql.cnf"
    for ((i=0;i<40;i++)); do [[ ! -S "${ROOT}/state/mysql.sock" ]] || break; sleep 1; done
    if [[ -f "${ROOT}/state/mysql-initializing" ]]; then
      if mysql --no-defaults --protocol=socket --socket="${ROOT}/state/mysql.sock" -u root <<'SQL'
ALTER USER 'root'@'localhost' IDENTIFIED BY 'root';
SQL
      then rm "${ROOT}/state/mysql-initializing"; fi
    fi
    # MYSQL_PWD is process-local here; never print credentials or use shell tracing.
    if MYSQL_PWD=root mysql --no-defaults --protocol=tcp -h 127.0.0.1 -u root -Nse 'SELECT VERSION(),CURRENT_USER();'; then
      launchctl kickstart -k "gui/$(id -u)/local.macsetup.mysql"
      for ((i=0;i<30;i++)); do if MYSQL_PWD=root mysql --no-defaults --protocol=tcp -h 127.0.0.1 -u root -Nse 'SELECT 1'; then record MySQL 成功 'SQL 和服务重启后 TCP 认证通过；仅回环监听'; break; fi; sleep 1; done
      [[ ${i} -lt 30 ]] || record MySQL 失败 '重启后连接失败'
    else record MySQL 失败 '初始化/认证未通过；不会尝试重置已有密码'; fi
  else record MySQL 待人工操作 '发现已有数据/3306 监听，保留；用 mysql -u root -p 检查后人工处理'; fi
fi

}

stage_ros() {
note '阶段 5：Docker / ROS 2'
export PATH="/Applications/Docker.app/Contents/Resources/bin:${PATH}"
if command -v docker >/dev/null; then
  open -a Docker || true
  for ((i=0;i<30;i++)); do docker info >/dev/null 2>&1 && break; sleep 2; done
  if docker info >/dev/null 2>&1; then
    runcheck Compose docker compose version
    if docker image inspect ros:jazzy-ros-base >/dev/null 2>&1 || docker pull ros:jazzy-ros-base; then
      image_arch=$(docker image inspect ros:jazzy-ros-base --format '{{.Architecture}}')
      if [[ $(uname -m) == arm64 ]]; then native_arch=arm64; else native_arch=amd64; fi
      if [[ ${image_arch} != "${native_arch}" ]]; then
        record ROS架构 失败 "已有镜像架构 ${image_arch}，与宿主 ${native_arch} 不同；请手工检查并拉取原生架构"
      else
      record ROS架构 成功 "linux/${image_arch}，与宿主匹配"
      mkdir -p "${HOME}/Developer/ros2_ws"
      if ! docker container inspect ros-jazzy-dev >/dev/null 2>&1; then
        docker run -dit --name ros-jazzy-dev --restart unless-stopped --mount "type=bind,source=${HOME}/Developer/ros2_ws,target=/workspace/ros2_ws" -w /workspace/ros2_ws ros:jazzy-ros-base sleep infinity
        touch "${ROOT}/state/ros-owned"
      fi
      if [[ -f "${ROOT}/state/ros-owned" ]] && docker inspect ros-jazzy-dev --format '{{range .Mounts}}{{println .Source .Destination}}{{end}}' | grep -F "${HOME}/Developer/ros2_ws /workspace/ros2_ws" >/dev/null; then
        docker start ros-jazzy-dev >/dev/null
        token="macsetup-${STAMP}"
        printf '%s' "${token}" > "${HOME}/Developer/ros2_ws/.macsetup-persistence"
        runcheck ROS环境 docker exec ros-jazzy-dev bash -lc 'source /opt/ros/jazzy/setup.bash; ros2 --help; test "${ROS_DISTRO}" = jazzy'
        docker stop ros-jazzy-dev >/dev/null; docker start ros-jazzy-dev >/dev/null
        if [[ $(docker exec ros-jazzy-dev cat /workspace/ros2_ws/.macsetup-persistence) == "${token}" ]]; then record ROS持久化 成功 '专用 bind 挂载和停止/启动后文件验证通过'; else record ROS持久化 失败 '文件内容不匹配'; fi
        # Recreate a disposable verification container, never delete the long-lived dev container.
        runcheck ROS重建持久化 docker run --rm --mount "type=bind,source=${HOME}/Developer/ros2_ws,target=/workspace/ros2_ws" ros:jazzy-ros-base bash -lc 'test -s /workspace/ros2_ws/.macsetup-persistence'
      else record ROS容器 待人工操作 '同名容器非本脚本管理或挂载不同；保留不修改'; fi
      fi
    else record ROS镜像 失败 'Docker Hub 不可达；在 Docker Desktop 设置代理后重跑；不自动信任第三方镜像'; fi
  else record Docker 待人工操作 '完成首次协议/系统授权，再重跑；终端代理不自动配置 Docker Engine'; fi
else record Docker 失败 'CLI 不存在'; fi

}

stage_flutter_web() {
STORAGE=$(choose /flutter_infra_release/releases/releases_macos.json https://storage.googleapis.com https://storage.flutter-io.cn)
PUB=$(choose /api/packages/collection https://pub.dev https://pub.flutter-io.cn)
record Flutter源 部分完成 "SDK/存储=${STORAGE}；Pub=${PUB}；实际编译检查见后续"
[[ ${STORAGE} == https://storage.googleapis.com ]] || export FLUTTER_STORAGE_BASE_URL="${STORAGE}"
[[ ${PUB} == https://pub.dev ]] || persist PUB_HOSTED_URL "${PUB}"
if ! command -v flutter >/dev/null && [[ ! -x "${HOME}/Developer/flutter/bin/flutter" ]]; then
  fetch "${STORAGE}/flutter_infra_release/releases/releases_macos.json" "${TMP}/releases.json"
  "${PY}" - "${TMP}/releases.json" "$(uname -m)" > "${TMP}/flutter-release" <<'PY'
import json,sys
j=json.load(open(sys.argv[1])); arch='arm64' if sys.argv[2]=='arm64' else 'x64'
r=next(r for r in j['releases'] if r['hash']==j['current_release']['stable'] and r.get('dart_sdk_arch','x64')==arch)
print(r['archive']); print(r['sha256'])
PY
  archive=$(sed -n '1p' "${TMP}/flutter-release"); sha=$(sed -n '2p' "${TMP}/flutter-release")
  STORAGE=$(choose_transfer "/flutter_infra_release/releases/${archive}" https://storage.googleapis.com https://storage.flutter-io.cn)
  if [[ ${STORAGE} != https://storage.googleapis.com ]]; then export FLUTTER_STORAGE_BASE_URL="${STORAGE}"; else unset FLUTTER_STORAGE_BASE_URL; fi
  record Flutter归档测速 部分完成 "大文件抽样选择 ${STORAGE}；随后验证完整 SHA256"
  if ! fetch "${STORAGE}/flutter_infra_release/releases/${archive}" "${TMP}/flutter.zip"; then
    if [[ ${STORAGE} == https://storage.googleapis.com ]]; then STORAGE=https://storage.flutter-io.cn; else STORAGE=https://storage.googleapis.com; fi
    fetch "${STORAGE}/flutter_infra_release/releases/${archive}" "${TMP}/flutter.zip"
  fi
  printf '%s  %s\n' "${sha}" "${TMP}/flutter.zip" | shasum -a 256 -c -
  [[ ! -e "${HOME}/Developer/flutter" ]] || { echo 'Flutter 目录已有内容，保留并停止；请先检查'; exit 1; }
  /usr/bin/ditto -xk "${TMP}/flutter.zip" "${HOME}/Developer"
fi
if [[ ${STORAGE} == https://storage.googleapis.com ]]; then unset FLUTTER_STORAGE_BASE_URL; else persist FLUTTER_STORAGE_BASE_URL "${STORAGE}"; fi
[[ ! -x "${HOME}/Developer/flutter/bin/flutter" ]] || export PATH="${HOME}/Developer/flutter/bin:${PATH}"
printf 'export PATH="${HOME}/Developer/flutter/bin:${PATH}"\n' >> "${ENVFILE}"
if command -v flutter >/dev/null; then
  runcheck Flutter flutter --version; runcheck Dart dart --version
  flutter config --enable-web --enable-macos-desktop
  if [[ ! -d "${ROOT}/state/flutter_smoke" ]]; then flutter create --platforms=web,android,ios,macos "${ROOT}/state/flutter_smoke"; fi
  (cd "${ROOT}/state/flutter_smoke"; flutter build web) && record Flutter网页构建 成功 '实际编译通过' || record Flutter网页构建 失败 '查看日志'
fi

}

stage_flutter_platforms() {
if command -v flutter >/dev/null; then
  if [[ -d /Applications/Xcode.app ]]; then
    (cd "${ROOT}/state/flutter_smoke"; flutter build macos --debug) && record Flutter桌面构建 成功 'macOS debug 实际编译通过' || record Flutter桌面构建 待人工操作 '检查 Xcode 选择、许可证、平台组件和 doctor'
  else record Xcode 待人工操作 'App Store 安装完整 Xcode，首次启动完成组件和许可，再 sudo xcode-select -s /Applications/Xcode.app/Contents/Developer'; fi
  STUDIO='/Applications/Android Studio.app/Contents/jbr/Contents/Home'
  [[ ! -d "${STUDIO}" ]] || flutter config --jdk-dir "${STUDIO}"
  SDK="${HOME}/Library/Android/sdk"
  if [[ -d "${SDK}/cmdline-tools" ]]; then
    flutter config --android-sdk "${SDK}"
    record Android 待人工操作 '执行 flutter doctor --android-licenses 阅读许可；在 Android Studio SDK Manager 补齐 doctor 要求的 SDK/Build Tools，再 flutter build apk --debug'
  else record Android 待人工操作 '启动 Android Studio，完成 Setup Wizard，在 SDK Manager 安装 Command-line Tools/latest、SDK Platform、Build Tools；然后 flutter doctor --android-licenses'; fi
  if flutter doctor -v; then record 'Flutter doctor' 部分完成 '诊断已执行；具体平台以构建/许可状态为准'; else record 'Flutter doctor' 待人工操作 '检查诊断日志中的平台依赖/许可'; fi
  record iOS 待人工操作 '安装 Xcode/iOS Platform/模拟器后 flutter build ios --simulator；真机签名需 Apple 账号'
fi

}

record "Homebrew 源" 部分完成 "API=${BREW_API}；bottle=${HOMEBREW_BOTTLE_DOMAIN:-官方}"
runcheck Homebrew brew --version
# Snapshot BEFORE Homebrew's MySQL post-install creates default data.
if [[ ! -f "${ROOT}/state/mysql-owned" ]]; then
  if [[ -d "${PREFIX}/var/mysql/mysql" ]] || command -v mysql >/dev/null || [[ -d /usr/local/mysql/data ]]; then
    touch "${ROOT}/state/mysql-preexisting"
  fi
fi
if [[ ! -f "${ROOT}/state/redis-owned" ]] && brew list --formula redis >/dev/null 2>&1; then
  touch "${ROOT}/state/redis-preexisting"
fi

# Capture the dependency graph before any installs. Prepend stable tool locations once.
export PATH="${HOME}/Developer/flutter/bin:/Applications/Docker.app/Contents/Resources/bin:${PREFIX}/opt/node@24/bin:${PREFIX}/opt/mysql@8.4/bin:${PREFIX}/opt/python@3.13/bin:${PATH}"
printf 'export PATH="${HOME}/Developer/flutter/bin:/Applications/Docker.app/Contents/Resources/bin":%q:%q:%q:${PATH}\n' "${PREFIX}/opt/node@24/bin" "${PREFIX}/opt/mysql@8.4/bin" "${PREFIX}/opt/python@3.13/bin" >> "${ENVFILE}"
PY="${PREFIX}/opt/python@3.13/bin/python3.13"
FORMULAE=(python@3.13 uv redis mysql@8.4 git node@24 fzf starship zsh-autosuggestions zsh-syntax-highlighting cocoapods)
MISSING_FORMULAE=(); MISSING_APPS=(); MISSING_DOCKER=()
for f in "${FORMULAE[@]}"; do brew list --formula "${f}" >/dev/null 2>&1 || MISSING_FORMULAE[${#MISSING_FORMULAE[@]}]=${f}; done
APP_ENTRIES=('android-studio|Android Studio' 'cursor|Cursor' 'google-chrome|Google Chrome' 'wechat|WeChat' 'feishu|Feishu' 'mos|Mos')
for entry in "${APP_ENTRIES[@]}"; do
  cask=${entry%%|*}; app=${entry#*|}
  if [[ ! -d "/Applications/${app}.app" && ! -d "${HOME}/Applications/${app}.app" ]]; then MISSING_APPS[${#MISSING_APPS[@]}]=${cask}; fi
done
if [[ ! -d /Applications/Docker.app && ! -d "${HOME}/Applications/Docker.app" ]]; then MISSING_DOCKER=(docker-desktop); fi
FETCH_CONNECTIONS=$((DOWNLOADS/3)); [[ ${FETCH_CONNECTIONS} -ge 1 ]] || FETCH_CONNECTIONS=1
FORMULA_CONNECTIONS=$((DOWNLOADS-2*FETCH_CONNECTIONS)); [[ ${FORMULA_CONNECTIONS} -ge 1 ]] || FORMULA_CONNECTIONS=1
FLUTTER_STARTED=no; PYTHON_STARTED=no
note '并行预下载：公式及依赖、Docker Desktop、其余桌面应用；Homebrew 安装保持单写者'
start_job fetch-docker prefetch cask ${MISSING_DOCKER[@]+"${MISSING_DOCKER[@]}"}
start_job fetch-formulae prefetch formula ${MISSING_FORMULAE[@]+"${MISSING_FORMULAE[@]}"}
start_job fetch-apps prefetch cask ${MISSING_APPS[@]+"${MISSING_APPS[@]}"}
wait_job fetch-docker
install_cask docker-desktop Docker
start_job ros stage_ros
if [[ -x ${PY} ]]; then start_job flutter-web stage_flutter_web; FLUTTER_STARTED=yes; fi
if [[ -x ${PY} ]] && command -v uv >/dev/null; then start_job python stage_uv; PYTHON_STARTED=yes; fi
# All formula cache writes finish before formula installation, avoiding download locks.
wait_job fetch-formulae
ensure_formula python@3.13 || true
if [[ ${FLUTTER_STARTED} == no && -x ${PY} ]]; then start_job flutter-web stage_flutter_web; FLUTTER_STARTED=yes; fi
if [[ ! -x ${PY} ]]; then record Flutter 失败 'Python 引导失败，未启动 SDK 流程'; fi
ensure_formula uv || true
if [[ ${PYTHON_STARTED} == no && -x ${PY} ]] && command -v uv >/dev/null; then start_job python stage_uv; PYTHON_STARTED=yes; fi
if [[ ${PYTHON_STARTED} == no ]]; then record uv工作流 失败 '缺少 Python/uv，未启动验证'; fi
ensure_formula redis || true
if [[ -x ${PY} ]]; then start_job redis stage_redis; fi
ensure_formula mysql@8.4 || true
if [[ -x ${PY} ]]; then start_job mysql stage_mysql; fi
for f in git node@24 fzf starship zsh-autosuggestions zsh-syntax-highlighting cocoapods; do ensure_formula "${f}" || true; done
# One foreground installer; the downloads have been overlapping ROS/Flutter/SQL/Python.
wait_job fetch-apps
for entry in "${APP_ENTRIES[@]}"; do install_cask "${entry%%|*}" "${entry#*|}"; done
for cmd in git uv node npm; do runcheck "${cmd} 版本" "${cmd}" --version; done
# Read-only diagnostics run once installs are complete, so transient installs don't mislead doctor.
start_job brew-check runcheck 'Homebrew doctor（警告也会返回非零）' brew doctor
runcheck 'Homebrew 查询' brew info git
wait_job flutter-web
if job_ok flutter-web; then
  source "${RUN_DIR}/flutter-web.env"
  start_job flutter-platforms stage_flutter_platforms
else record Flutter平台 未执行 '依赖的 Flutter SDK/Web 任务失败，未启动后续构建'; fi
for ((j=0;j<${#JOB_PIDS[@]};j++)); do collect_job "${j}"; done
# Merge only after all workers finish; no concurrent append to shell configuration.
for ((j=0;j<${#JOB_PIDS[@]};j++)); do
  fragment="${RUN_DIR}/${JOB_NAMES[j]}.env"
  if [[ ${JOB_STATUS[j]} == 0 && -f ${fragment} ]]; then cat "${fragment}" >> "${ENVFILE}"; fi
done
record 'Windows/Linux 原生构建' 未执行 '分别需要 Windows/Linux 环境；Mac 安装 SDK 不等于具备本机构建能力'
note '阶段 7/8：Mos 和终端'
record Mos 待人工操作 '在系统设置授予辅助功能；Mos 设置中让鼠标与触控板方向一致；亲手滚动验证后启用登录启动'
# Small sourced files, no framework, syntax highlighting always last within our block.
cat > "${ROOT}/configs/terminal.zsh" <<'ZSH'
[[ -o interactive ]] || return
[[ -z ${MAC_SETUP_TERMINAL_LOADED:-} ]] || return
MAC_SETUP_TERMINAL_LOADED=1
HISTFILE=${HISTFILE:-${HOME}/.zsh_history}
HISTSIZE=50000
SAVEHIST=50000
setopt APPEND_HISTORY SHARE_HISTORY HIST_IGNORE_SPACE HIST_IGNORE_DUPS
bindkey '^[[A' up-line-or-search
bindkey '^[[B' down-line-or-search
alias ll='ls -lah'
alias gs='git status -sb'
alias dc='docker compose'
(( ! $+commands[fzf] )) || source <(fzf --zsh)
(( ! $+commands[starship] )) || eval "$(starship init zsh)"
ZSH
printf '[[ ! -r %q ]] || source %q\n[[ ! -r %q ]] || source %q\n' "${PREFIX}/share/zsh-autosuggestions/zsh-autosuggestions.zsh" "${PREFIX}/share/zsh-autosuggestions/zsh-autosuggestions.zsh" "${PREFIX}/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" "${PREFIX}/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" >> "${ROOT}/configs/terminal.zsh"
add_source() {
  local target="$1" sourcefile="$2" line
  printf -v line '[[ ! -r %q ]] || source %q' "${sourcefile}" "${sourcefile}"
  if ! grep -Fqx "${line}" "${target}" 2>/dev/null; then backup "${target}"; printf '\n%s\n' "${line}" >> "${target}"; fi
}
if job_ok flutter-web && [[ -x ${PY} ]]; then
  backup "${FINAL_ENVFILE}"
  mv "${ENVFILE}" "${FINAL_ENVFILE}"
else record 环境配置 部分完成 '关键任务失败，保留原生效环境文件'; fi
ENVFILE="${FINAL_ENVFILE}"
add_source "${HOME}/.zprofile" "${ENVFILE}"
add_source "${HOME}/.zshrc" "${ENVFILE}"
add_source "${HOME}/.zshrc" "${ROOT}/configs/terminal.zsh"
runcheck 'zsh 语法' zsh -n "${HOME}/.zshrc"
runcheck 'zsh 新会话' zsh -lic 'command -v brew && command -v node && command -v uv && command -v flutter && git --version'
record '终端交互验收' 待人工操作 '新开终端检查灰色建议/右键接受、方向键、Ctrl-R、Git目录提示符；非zsh用户需自行切换shell'
if [[ ! -f "${ROOT}/README.md" ]]; then
cat > "${ROOT}/README.md" <<'DOC'
# Mac 初始化结果
验收结果与版本清单在 logs/，备份在 backups/。失败或待人工操作项目不能视为完成。
重新执行：bash ~/Developer/mac-setup/scripts/setup.sh auto
环境配置：configs/env.zsh；终端插件：configs/terminal.zsh。
恢复官方源：备份后从 configs/env.zsh 删除 HOMEBREW_*、UV_DEFAULT_INDEX、PUB_HOSTED_URL、FLUTTER_STORAGE_BASE_URL 对应 export 行，新开终端；不要删除 brew shellenv/PATH。
当前会话还需 unset HOMEBREW_API_DOMAIN HOMEBREW_BOTTLE_DOMAIN HOMEBREW_BREW_GIT_REMOTE UV_DEFAULT_INDEX PUB_HOSTED_URL FLUTTER_STORAGE_BASE_URL。
本脚本不改 Homebrew Git origin、npm registry 或已有 uv 配置；镜像仅影响本工具生成的环境文件。
MySQL：mysql -h 127.0.0.1 -P 3306 -u root -p；只在新建的受管数据库设置任务要求的弱口令；不要用于生产。
Redis：redis-cli -h 127.0.0.1 ping。
服务管理：launchctl print gui/$(id -u)/local.macsetup.mysql（Redis 把 mysql 换成 redis）。
重启：launchctl kickstart -k gui/$(id -u)/local.macsetup.mysql。
停止且取消登录启动：launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/local.macsetup.mysql.plist。
启动并恢复登录启动：launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.macsetup.mysql.plist。
这些服务不使用 brew services 管理，避免同时启动另一套默认数据库。
ROS：docker start/stop ros-jazzy-dev；docker exec -it ros-jazzy-dev bash。
进入后 source /opt/ros/jazzy/setup.bash；挂载 ~/Developer/ros2_ws 到 /workspace/ros2_ws。
Docker Desktop 的 Engine 代理须在其设置里配置；终端 HTTPS_PROXY 不能替代。
Flutter：flutter doctor -v；dart --version；测试项目在 state/flutter_smoke。
Android：Studio Setup Wizard + SDK Manager 安装平台、Build Tools、Command-line Tools；flutter doctor --android-licenses 后构建 APK。
iOS/macOS：完整 Xcode + 平台组件 + 许可；Windows/Linux 原生构建需对应操作系统。
Mos：授予辅助功能权限，设置方向，分别实际滚动鼠标和触控板；在 Mos 设置登录启动或退出恢复系统行为。
终端：Ctrl-R 搜索历史；右方向键接受建议；上下键历史搜索。检查 Git 分支提示和语法高亮需实际新开终端。
回滚：从 .zprofile/.zshrc 删除本工具 source 行，或根据 backups/ 手工恢复对应文件；不自动删除数据库、SDK 或容器。
DOC
fi
note '最终服务监听（请检查非回环地址）'
lsof -nP -iTCP:3306 -iTCP:6379 -sTCP:LISTEN || true
brew list --versions > "${ROOT}/logs/${STAMP}-versions.txt"
brew list --cask --versions >> "${ROOT}/logs/${STAMP}-versions.txt"
note "完成。报告：${REPORT}；日志：${LOG}；备份：${ROOT}/backups"
cat "${REPORT}"
note "并行任务日志与时间线：${RUN_DIR}"
printf '本轮自动阶段耗时：%s 秒（不含之前运行和人工步骤）。\n' "${SECONDS}"
echo '重新打开终端加载配置。失败/待人工操作项完成后重跑同一命令。数据库 root/root 仅限隔离本地开发。'

if awk -F '\t' 'NR>1 && $2=="失败" {found=1} END {exit !found}' "${REPORT}"; then
  echo '存在失败项：请查看报告；未宣告全部完成。'
  exit 1
fi
