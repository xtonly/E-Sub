#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 基础路径与默认参数（不含任何硬编码敏感密钥）
DATA_DIR="/etc/sub-store"
FRONTEND_DIR="/etc/sub-store/frontend"
BACKUP_DIR="/etc/sub-store/backups"
VERSION_FILE="/etc/sub-store/.frontend_version"
CONF_FILE="/etc/sub-store/.e-sub.conf"
IMAGE_NAME="xream/sub-store:latest"
CONTAINER_NAME="sub-store"
DEFAULT_PORT="10551"
BIN_PATH="/usr/local/bin/e-sub"
CRON_LOG="/var/log/sub-store-update.log"

# 颜色定义
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

gen_random_path() {
    head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 32
}

save_config() {
    mkdir -p "$DATA_DIR"
    cat > "$CONF_FILE" <<CONF
HOST_PORT="${HOST_PORT}"
BACKEND_PATH="${BACKEND_PATH}"
CONF
    chmod 600 "$CONF_FILE"
}

load_or_init_config() {
    mkdir -p "$DATA_DIR"
    if [ -f "$CONF_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONF_FILE"
    fi

    # 若本地尚无配置文件，优先尝试读取已有容器配置，否则自动生成全新随机 Path
    if [ -z "${HOST_PORT:-}" ] || [ -z "${BACKEND_PATH:-}" ]; then
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
            EXISTING_PORT=$(docker inspect --format='{{(index (index .HostConfig.PortBindings "3001/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
            EXISTING_PATH=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null | grep '^SUB_STORE_FRONTEND_BACKEND_PATH=' | cut -d= -f2- || echo "")
        fi
        HOST_PORT="${EXISTING_PORT:-$DEFAULT_PORT}"
        if [ -n "${EXISTING_PATH:-}" ]; then
            BACKEND_PATH="$EXISTING_PATH"
        else
            BACKEND_PATH="/$(gen_random_path)"
        fi
        save_config
    fi
}

install_shortcut() {
    if [ -f "$0" ] && [ "$(realpath "$0" 2>/dev/null)" != "$BIN_PATH" ]; then
        cp -f "$0" "$BIN_PATH"
        chmod +x "$BIN_PATH"
        ln -sf "$BIN_PATH" /usr/local/bin/update-sub
    elif [ -f "$BIN_PATH" ]; then
        ln -sf "$BIN_PATH" /usr/local/bin/update-sub
    fi
}

check_deps() {
    for cmd in curl unzip tar; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${YELLOW}正在自动安装依赖: $cmd ...${RESET}"
            if command -v apt >/dev/null 2>&1; then apt update -y && apt install -y "$cmd"
            elif command -v yum >/dev/null 2>&1; then yum install -y "$cmd"
            elif command -v apk >/dev/null 2>&1; then apk add "$cmd"; fi
        fi
    done
    mkdir -p "$FRONTEND_DIR" "$BACKUP_DIR"
}

run_container() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker run -d \
      --name "$CONTAINER_NAME" \
      --restart=always \
      -p "${HOST_PORT}:3001" \
      -e SUB_STORE_FRONTEND_BACKEND_PATH="$BACKEND_PATH" \
      -e SUB_STORE_CORS_ALLOWED_ORIGINS=* \
      -v "${DATA_DIR}:/opt/app/data" \
      -v "${FRONTEND_DIR}:/opt/app/frontend" \
      "$IMAGE_NAME" >/dev/null
    docker image prune -f >/dev/null 2>&1 || true
}

print_access_info() {
    local ip="${PUBLIC_IP:-你的服务器IP}"
    echo -e "${CYAN}------------------------------------------------${RESET}"
    echo -e " 专属后端密钥 : ${YELLOW}${BACKEND_PATH}${RESET}"
    echo -e " 一键登录网址 : ${GREEN}http://${ip}:${HOST_PORT}?api=http://${ip}:${HOST_PORT}${BACKEND_PATH}${RESET}"
    echo -e "${CYAN}------------------------------------------------${RESET}"
}

update_frontend() {
    local force="${1:-false}"
    local latest_url
    latest_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/sub-store-org/Sub-Store-Front-End/releases/latest || echo "")
    local latest_ver="${latest_url##*/}"
    local local_ver
    local_ver=$(cat "$VERSION_FILE" 2>/dev/null || echo "未记录")

    if [ -z "$latest_ver" ] || [ "$latest_ver" = "latest" ]; then
        echo -e "${RED}[前端] ⚠️ 无法连接 GitHub 获取最新版本号，已跳过。${RESET}"
        return 1
    fi

    if [ "$force" = "true" ] || [ "$latest_ver" != "$local_ver" ] || [ ! -f "$FRONTEND_DIR/index.html" ]; then
        echo -e "${CYAN}[前端] 🚀 正在下载前端版本 ($local_ver -> $latest_ver)...${RESET}"
        if curl -fL "https://github.com/sub-store-org/Sub-Store-Front-End/releases/download/${latest_ver}/dist.zip" -o /tmp/sub-store-dist.zip; then
            rm -rf "${FRONTEND_DIR:?}"/*
            unzip -q -o /tmp/sub-store-dist.zip -d "$FRONTEND_DIR"
            if [ -d "$FRONTEND_DIR/dist" ]; then
                mv "$FRONTEND_DIR/dist"/* "$FRONTEND_DIR/"
                rmdir "$FRONTEND_DIR/dist"
            fi
            rm -f /tmp/sub-store-dist.zip
            echo "$latest_ver" > "$VERSION_FILE"
            echo -e "${GREEN}[前端] ✅ 已更新至 $latest_ver（浏览器 Ctrl+F5 强刷即可生效）！${RESET}"
        else
            echo -e "${RED}[前端] ❌ 下载失败，请检查服务器网络。${RESET}"
            return 1
        fi
    else
        echo -e "${GREEN}[前端] ✨ 当前已是最新版本 ($local_ver)，跳过下载。${RESET}"
    fi
}

update_backend() {
    local force="${1:-false}"
    echo -e "${CYAN}[后端] 正在同步 Docker Hub 镜像状态...${RESET}"
    if ! docker pull -q "$IMAGE_NAME" >/dev/null; then
        echo -e "${RED}[后端] ❌ 拉取镜像失败，请检查 Docker 状态或网络。${RESET}"
        return 1
    fi

    local latest_id running_id is_running
    latest_id=$(docker image inspect --format='{{.Id}}' "$IMAGE_NAME" 2>/dev/null || echo "none")
    running_id=$(docker inspect --format='{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo "not_running")
    is_running=$(docker inspect --format='{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo "false")

    if [ "$force" = "true" ] || [ "$latest_id" != "$running_id" ] || [ "$is_running" != "true" ]; then
        echo -e "${CYAN}[后端] 🚀 正在部署并启动容器...${RESET}"
        run_container
        echo -e "${GREEN}[后端] ✅ 容器启动完成，旧镜像已清理！${RESET}"
        print_access_info
    else
        echo -e "${GREEN}[后端] ✨ 镜像无变化且容器运行正常，无需重启。${RESET}"
    fi
}

change_secret_or_port() {
    echo -e "${CYAN}--- 密钥路径 (Path) 与端口管理 ---${RESET}"
    print_access_info
    echo -e "  ${GREEN}1.${RESET} 一键重新生成 32 位随机 Path (防泄露推荐)"
    echo -e "  ${GREEN}2.${RESET} 自定义输入 Path 密钥路径"
    echo -e "  ${GREEN}3.${RESET} 修改宿主机映射端口 (当前: ${HOST_PORT})"
    echo -e "  ${GREEN}0.${RESET} 取消并返回主菜单"
    echo -e "${CYAN}------------------------------------------------${RESET}"

    local sub_choice
    read -rp "请选择操作 [0-3]: " sub_choice
    case "$sub_choice" in
        1)
            BACKEND_PATH="/$(gen_random_path)"
            save_config
            echo -e "${GREEN}[配置] ✅ 已生成全新独享随机 Path: ${BACKEND_PATH}${RESET}"
            ;;
        2)
            local custom_path
            read -rp "请输入新的自定义 Path (无需带开头斜杠): " custom_path
            custom_path="${custom_path#/}"
            if [ -z "$custom_path" ]; then
                echo -e "${RED}[配置] ❌ Path 不能为空！${RESET}"
                return 1
            fi
            BACKEND_PATH="/${custom_path}"
            save_config
            echo -e "${GREEN}[配置] ✅ 已更新自定义 Path: ${BACKEND_PATH}${RESET}"
            ;;
        3)
            local new_port
            read -rp "请输入新的监听端口号 [1-65535]: " new_port
            if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                echo -e "${RED}[配置] ❌ 端口号无效！${RESET}"
                return 1
            fi
            HOST_PORT="$new_port"
            save_config
            echo -e "${GREEN}[配置] ✅ 已更新映射端口为: ${HOST_PORT}${RESET}"
            ;;
        *)
            echo -e "${YELLOW}已取消修改。${RESET}"
            return 0
            ;;
    esac

    if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        echo -e "${CYAN}正在重建容器以应用新配置...${RESET}"
        run_container
        echo -e "${GREEN}✅ 容器已应用新配置！请使用下方新地址访问：${RESET}"
        print_access_info
    else
        echo -e "${YELLOW}配置已保存，请执行菜单 [1] 完成首次安装。${RESET}"
    fi
}

backup_data() {
    mkdir -p "$BACKUP_DIR"
    local ts backup_file
    ts=$(date '+%Y%m%d_%H%M%S')
    backup_file="${BACKUP_DIR}/sub-store_backup_${ts}.tar.gz"
    echo -e "${CYAN}[备份] 正在打包配置数据...${RESET}"
    tar --exclude="./frontend" --exclude="frontend" \
        --exclude="./backups" --exclude="backups" \
        --exclude="./.frontend_version" --exclude=".frontend_version" \
        --exclude="./.e-sub.conf" --exclude=".e-sub.conf" \
        -czf "$backup_file" -C "$DATA_DIR" .
    echo -e "${GREEN}[备份] ✅ 数据已备份至: $backup_file${RESET}"

    # 严格保留最近 3 份备份文件
    ls -1t "${BACKUP_DIR}"/sub-store_backup_*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f
    echo -e "${YELLOW}[备份] 当前保留的备份列表 (最多保留 3 份):${RESET}"
    ls -lh "${BACKUP_DIR}"/sub-store_backup_*.tar.gz 2>/dev/null | awk '{print "  - " $9 " (" $5 ")"}'
}

restore_data() {
    mkdir -p "$BACKUP_DIR"
    mapfile -t backups < <(ls -1t "${BACKUP_DIR}"/sub-store_backup_*.tar.gz 2>/dev/null)

    if [ "${#backups[@]}" -eq 0 ]; then
        echo -e "${YELLOW}[恢复] ⚠️ 当前没有任何备份文件，请先执行选项 [4] 进行数据备份！${RESET}"
        return 0
    fi

    echo -e "${CYAN}--- 可用的历史备份列表 (按时间从新到旧排序) ---${RESET}"
    local i=1
    for b in "${backups[@]}"; do
        local b_name b_size
        b_name=$(basename "$b")
        b_size=$(du -h "$b" | awk '{print $1}')
        echo -e "  ${GREEN}${i}.${RESET} ${b_name} (${YELLOW}${b_size}${RESET})"
        ((i++))
    done
    echo -e "  ${GREEN}0.${RESET} 取消并返回主菜单"
    echo -e "${CYAN}------------------------------------------------${RESET}"

    local sel
    read -rp "请输入要恢复的备份序号 [0-$((i-1))]: " sel
    if [ "$sel" = "0" ] || [ -z "$sel" ]; then
        echo -e "${YELLOW}[恢复] 已取消恢复操作。${RESET}"
        return 0
    fi

    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#backups[@]}" ]; then
        echo -e "${RED}[恢复] ❌ 序号无效！${RESET}"
        return 1
    fi

    local target_backup="${backups[$((sel-1))]}"
    echo -e "${YELLOW}⚠️ 警告：恢复操作将覆盖当前的 Sub-Store 订阅与节点配置！${RESET}"
    echo -e "即将恢复文件: ${CYAN}$(basename "$target_backup")${RESET}"
    local confirm
    read -rp "确认继续恢复吗？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo -e "${YELLOW}[恢复] 已取消恢复操作。${RESET}"
        return 0
    fi

    echo -e "${CYAN}[恢复] 1/3 正在暂停容器防止数据写入冲突...${RESET}"
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true

    echo -e "${CYAN}[恢复] 2/3 正在清理旧配置并解压备份文件...${RESET}"
    find "$DATA_DIR" -mindepth 1 -maxdepth 1 \
        ! -name "frontend" \
        ! -name "backups" \
        ! -name ".frontend_version" \
        ! -name ".e-sub.conf" \
        -exec rm -rf {} +

    if tar --exclude="./frontend" --exclude="frontend" \
           --exclude="./backups" --exclude="backups" \
           --exclude="./.frontend_version" --exclude=".frontend_version" \
           --exclude="./.e-sub.conf" --exclude=".e-sub.conf" \
           -xzf "$target_backup" -C "$DATA_DIR"; then
        echo -e "${CYAN}[恢复] 3/3 正在启动容器重新加载配置...${RESET}"
        run_container
        echo -e "${GREEN}[恢复] ✅ 配置数据已成功从 $(basename "$target_backup") 恢复！${RESET}"
    else
        echo -e "${RED}[恢复] ❌ 解压备份失败，尝试重新启动容器...${RESET}"
        docker start "$CONTAINER_NAME" >/dev/null 2>&1 || true
        return 1
    fi
}

toggle_cron() {
    if crontab -l 2>/dev/null | grep -qE "($BIN_PATH|/usr/local/bin/update-sub) --auto"; then
        crontab -l 2>/dev/null | grep -vE "($BIN_PATH|/usr/local/bin/update-sub)" | crontab -
        echo -e "${YELLOW}[定时任务] 已关闭每日凌晨自动更新。${RESET}"
    else
        (crontab -l 2>/dev/null | grep -vE "($BIN_PATH|/usr/local/bin/update-sub)"; echo "0 4 * * * $BIN_PATH --auto >> $CRON_LOG 2>&1") | crontab -
        echo -e "${GREEN}[定时任务] ✅ 已开启每日 04:00 自动静默更新（日志: $CRON_LOG）。${RESET}"
    fi
}

show_status() {
    echo -e "${CYAN}--- 容器运行状态 ---${RESET}"
    docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    print_access_info
    echo -e "\n${CYAN}--- 最近 25 行运行日志 ---${RESET}"
    docker logs --tail 25 "$CONTAINER_NAME" 2>&1 || echo "容器未创建"
}

# 初始化依赖与唯一配置
check_deps
load_or_init_config
install_shortcut

# 兼容 Crontab 后台静默调用: e-sub --auto
if [ "${1:-}" = "--auto" ]; then
    echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] 自动检测更新开始 ==="
    update_frontend false
    update_backend false
    echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] 自动检测更新结束 ==="
    exit 0
fi

# 获取一次公网 IP 用于展示连接地址（超时保护不卡面板）
PUBLIC_IP=$(curl -4fsSL --max-time 2 https://api.ipify.org 2>/dev/null || curl -4fsSL --max-time 2 https://ifconfig.me 2>/dev/null || echo "你的服务器IP")

# 交互式主菜单循环
while true; do
    clear
    FE_VER=$(cat "$VERSION_FILE" 2>/dev/null || echo "未安装")
    if [ "$(docker inspect --format='{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]; then
        STATUS_STR="${GREEN}运行中 (端口: ${HOST_PORT})${RESET}"
    else
        STATUS_STR="${RED}未运行 (预设端口: ${HOST_PORT})${RESET}"
    fi
    if crontab -l 2>/dev/null | grep -qE "($BIN_PATH|/usr/local/bin/update-sub) --auto"; then
        CRON_STR="${GREEN}已开启 (每日 04:00)${RESET}"
    else
        CRON_STR="${YELLOW}未开启${RESET}"
    fi

    echo -e "${CYAN}================================================${RESET}"
    echo -e "          E-Sub (Sub-Store) 交互式管理面板       "
    echo -e "${CYAN}================================================${RESET}"
    echo -e " 容器状态 : ${STATUS_STR}"
    echo -e " 前端版本 : ${GREEN}${FE_VER}${RESET}"
    echo -e " 自动更新 : ${CRON_STR}"
    echo -e " 后端密钥 : ${YELLOW}${BACKEND_PATH}${RESET}"
    echo -e " 登录地址 : ${GREEN}http://${PUBLIC_IP}:${HOST_PORT}?api=http://${PUBLIC_IP}:${HOST_PORT}${BACKEND_PATH}${RESET}"
    echo -e "${CYAN}------------------------------------------------${RESET}"
    echo -e "  ${GREEN}1.${RESET} 安装 / 智能增量更新前后端 (推荐)"
    echo -e "  ${GREEN}2.${RESET} 仅强制重下并热更新前端"
    echo -e "  ${GREEN}3.${RESET} 强制拉取镜像并重建后端容器"
    echo -e "  ${GREEN}4.${RESET} 备份订阅配置数据 (自动保留最近 3 份)"
    echo -e "  ${GREEN}5.${RESET} 查看容器状态与实时日志"
    echo -e "  ${GREEN}6.${RESET} 开启 / 关闭每日凌晨自动更新"
    echo -e "  ${GREEN}7.${RESET} 从备份文件恢复配置数据"
    echo -e "  ${GREEN}8.${RESET} 重置随机 Path 密钥 / 修改端口"
    echo -e "  ${GREEN}0.${RESET} 退出脚本"
    echo -e "${CYAN}================================================${RESET}"
    read -rp "请输入选项数字 [0-8]: " choice
    echo ""

    case "$choice" in
        1)
            update_frontend false
            echo ""
            update_backend false
            ;;
        2)
            update_frontend true
            ;;
        3)
            update_frontend true
            echo ""
            update_backend true
            ;;
        4)
            backup_data
            ;;
        5)
            show_status
            ;;
        6)
            toggle_cron
            ;;
        7)
            restore_data
            ;;
        8)
            change_secret_or_port
            ;;
        0)
            echo -e "${GREEN}已退出管理面板（随时输入 e-sub 可再次打开）。${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}输入无效，请输入 0 到 8 之间的数字！${RESET}"
            ;;
    esac
    echo ""
    read -rp "按回车键返回主菜单..." _
done
