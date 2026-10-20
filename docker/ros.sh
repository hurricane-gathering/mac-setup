#!/bin/bash
set -euo pipefail
export PATH="/Applications/Docker.app/Contents/Resources/bin:${PATH}"
name=ros-jazzy-dev
ws="${HOME}/Developer/ros2_ws"
case "${1:-enter}" in
  create)
    mkdir -p "${ws}"
    if docker container inspect "${name}" >/dev/null 2>&1; then echo '容器已存在；保留现有配置。'; exit 0; fi
    docker run -dit --name "${name}" --restart unless-stopped --mount "type=bind,source=${ws},target=/workspace/ros2_ws" -w /workspace/ros2_ws ros:jazzy-ros-base sleep infinity;;
  start|stop) docker "$1" "${name}";;
  enter) docker start "${name}" >/dev/null; docker exec -it "${name}" bash -ic 'source /opt/ros/jazzy/setup.bash; exec bash';;
  logs) docker logs --tail 100 "${name}";;
  *) echo 'Usage: bash ros.sh [create|start|stop|enter|logs]'; exit 2;;
esac
