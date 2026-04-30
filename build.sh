#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")" && pwd)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if ! command -v docker &> /dev/null; then
    echo -e "${RED}错误: 未找到 docker，请先安装 Docker${NC}"
    exit 1
fi

OFFICIAL_IMAGE="zmkfirmware/zmk-build-arm:stable"
LOCAL_IMAGE="zmk-pskeeb5"

# 优先使用本地预构建镜像（已包含 west 依赖，无需网络）
if docker image inspect "$LOCAL_IMAGE" &>/dev/null; then
    DOCKER_IMAGE="$LOCAL_IMAGE"
    echo -e "${YELLOW}使用本地预构建镜像: $DOCKER_IMAGE${NC}"
else
    DOCKER_IMAGE="$OFFICIAL_IMAGE"
    echo -e "${YELLOW}使用官方镜像: $DOCKER_IMAGE${NC}"
    echo -e "${YELLOW}提示: 运行 'docker build -t $LOCAL_IMAGE .' 构建本地预配置镜像，可加速后续编译${NC}"
fi

echo -e "${YELLOW}使用镜像: $DOCKER_IMAGE${NC}"

# 如果使用本地预构建镜像且本地缺少依赖，从镜像复制预置依赖
if [ "$DOCKER_IMAGE" = "$LOCAL_IMAGE" ] && [ ! -d "$REPO_ROOT/.west" ]; then
    echo -e "${YELLOW}从预构建镜像复制依赖到本地...${NC}"
    # 创建临时容器（不挂载 volume，以访问镜像内预置内容）
    TEMP_CONTAINER=$(docker create "$LOCAL_IMAGE")
    # 复制依赖目录
    for dir in .west zmk zephyr modules; do
        if docker cp "$TEMP_CONTAINER:/workspace/$dir" "$REPO_ROOT/" 2>/dev/null; then
            echo "  复制: $dir"
        fi
    done
    # 清理临时容器
    docker rm "$TEMP_CONTAINER" >/dev/null
    echo -e "${GREEN}依赖复制完成 ✓${NC}"
fi

# 初始化 west workspace（仅在缺少时执行）
if [ ! -d "$REPO_ROOT/.west" ]; then
    echo -e "${YELLOW}初始化 west workspace...${NC}"
    docker run --rm \
        -v "$REPO_ROOT:/workspace" \
        -w /workspace \
        "$DOCKER_IMAGE" \
        west init -l config
    echo -e "${YELLOW}更新 west 依赖...${NC}"
    for i in 1 2 3; do
        docker run --rm \
            -v "$REPO_ROOT:/workspace" \
            -w /workspace \
            "$DOCKER_IMAGE" \
            west update && break
        echo -e "${RED}west update 失败，5秒后重试 ($i/3)...${NC}"
        sleep 5
    done
else
    echo -e "${GREEN}使用本地已存在的 west 依赖${NC}"
fi

# 应用 ZMK 补丁（修复条件层兼容性）
PATCH_FILE="$REPO_ROOT/patches/conditional_layer.c"
ZMK_TARGET="$REPO_ROOT/zmk/app/src/conditional_layer.c"
if [ -f "$PATCH_FILE" ] && [ -f "$ZMK_TARGET" ]; then
    echo -e "${YELLOW}应用 ZMK 条件层补丁...${NC}"
    cp "$PATCH_FILE" "$ZMK_TARGET"
    echo -e "${GREEN}补丁应用完成 ✓${NC}"
fi

# 定义构建任务: name|board|shield|snippet
declare -a BUILDS=(
    "left|nice_nano_v2|pskeeb5_left|"
    "right|nice_nano_v2|pskeeb5_right|studio-rpc-usb-uart"
    "settings_reset|nice_nano_v2|settings_reset|"
)

for build in "${BUILDS[@]}"; do
    IFS='|' read -r name board shield snippet <<< "$build"

    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}构建: $name${NC}"
    echo -e "${YELLOW}  board:  $board${NC}"
    echo -e "${YELLOW}  shield: $shield${NC}"
    [ -n "$snippet" ] && echo -e "${YELLOW}  snippet: $snippet${NC}"

    EXTRA_ARGS="-DZMK_CONFIG=/workspace/config"
    [ -n "$shield" ] && EXTRA_ARGS="$EXTRA_ARGS -DSHIELD=$shield"
    [ -n "$snippet" ] && EXTRA_ARGS="$EXTRA_ARGS -DSNIPPET=$snippet"

    docker run --rm \
        -v "$REPO_ROOT:/workspace" \
        -w /workspace \
        -e ZEPHYR_BASE=/workspace/zephyr \
        -e Zephyr_DIR=/workspace/zephyr/share/zephyr-package/cmake \
        "$DOCKER_IMAGE" \
        west build -s zmk/app -d "build/$name" -b "$board" -- $EXTRA_ARGS

    echo -e "${GREEN}$name 构建完成 ✓${NC}"
done

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}全部构建完成!${NC}"
echo ""

# 复制固件到 dist 目录
DIST_DIR="$REPO_ROOT/dist"
mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR"/*.uf2 "$DIST_DIR"/*.hex "$DIST_DIR"/*.bin

echo -e "${YELLOW}复制固件到 dist 目录...${NC}"
for build in "${BUILDS[@]}"; do
    IFS='|' read -r name board shield snippet <<< "$build"
    SRC_UF2="$REPO_ROOT/build/$name/zephyr/zmk.uf2"
    if [ -f "$SRC_UF2" ]; then
        cp "$SRC_UF2" "$DIST_DIR/$name.uf2"
        echo -e "  ${GREEN}✓${NC} $name.uf2"
    fi
done

echo ""
echo "固件文件:"
find "$REPO_ROOT/build" -name "zmk.uf2" -o -name "zmk.hex" -o -name "zmk.bin" | while read -r f; do
    echo "  $(du -h "$f" | cut -f1)  $f"
done
echo ""
echo "dist 目录:"
ls -lh "$DIST_DIR"/*.* 2>/dev/null || echo "  (空)"
