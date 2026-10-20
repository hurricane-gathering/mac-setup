#!/bin/bash
set -uo pipefail
ROOT="${HOME}/Developer/mac-setup"
[[ ! -r "${ROOT}/configs/env.zsh" ]] || source "${ROOT}/configs/env.zsh"
export PATH="/Applications/Docker.app/Contents/Resources/bin:${PATH}"
failed=0
check() { printf '\n--- %s ---\n' "$1"; shift; if "$@"; then echo PASS; else echo 'FAIL / 待处理'; failed=$((failed+1)); fi; }
for cmd in brew git node npm uv flutter dart; do check "${cmd}" "${cmd}" --version; done
check Redis redis-cli -h 127.0.0.1 ping
# Interactive password; never put it in the process command line.
check MySQL mysql --no-defaults -h 127.0.0.1 -P 3306 -u root -p -e 'SELECT VERSION(), CURRENT_USER();'
check Docker docker info
check Compose docker compose version
check ROS docker exec ros-jazzy-dev bash -lc 'source /opt/ros/jazzy/setup.bash; test "${ROS_DISTRO}" = jazzy; ros2 --help'
check Flutter flutter doctor -v
check zsh zsh -lic 'command -v brew && command -v node && command -v uv && command -v flutter && git --version'
lsof -nP -iTCP:3306 -iTCP:6379 -sTCP:LISTEN || true
printf '\n未通过检查：%s；GUI 权限、登录、Mos 滚动和终端交互仍需实际检查。\n' "${failed}"
[[ ${failed} -eq 0 ]]
