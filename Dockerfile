FROM zmkfirmware/zmk-build-arm:stable

WORKDIR /workspace

# 只复制依赖定义文件（keymap 通过 volume 挂载，无需重建镜像）
COPY config/west.yml /workspace/config/west.yml
COPY zephyr/module.yml /workspace/zephyr/module.yml

# 初始化并拉取全部依赖（带重试，适配不稳定网络）
RUN west init -l config && \
    for i in 1 2 3 4 5; do \
        echo "=== west update 尝试 $i/5 ===" && \
        west update && echo "=== 依赖更新成功 ===" && break; \
        echo "失败，10秒后重试..."; \
        sleep 10; \
    done

# 清理 git 大对象减小体积
RUN find /workspace -type d -name '.git' -exec sh -c 'cd {} && git gc --aggressive --prune=now' \;
