#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 基础路径与默认参数（无任何硬编码敏感密钥）
SCRIPT_VER="v1.1"
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
BOLD="\033[1m"
RESET="\033[0m"

# 动态边框绘制工具函数
repeat_char() {
    local char="$1" count="$2"
    printf "%${count}s" "" | tr ' ' "$char"
}

gen_random_path() {
    head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 24
}

# 规范化域名输入（自动补全 https:// 并去除末尾斜杠）
normalize_domain() {
    local input="$1"
    input="${input%/}"
    if [ -z "$input" ]; then
        echo ""
        return
    fi
    if [[ ! "$input" =~ ^https?:// ]]; then
        input="https://${input}"
    fi
    echo "$input"
}

save_config() {
    mkdir -p "$DATA_DIR"
    cat > "$CONF_FILE" <<CONF
HOST_PORT="${HOST_PORT}"
BACKEND_PATH="${BACKEND_PATH}"
CUSTOM_DOMAIN="${CUSTOM_DOMAIN}"
CONF
    chmod 600 "$CONF_FILE"
}

# 首次运行初始化向导
init_wizard() {
    clear
    local init_line
    init_line="${CYAN}$(repeat_char '=' 68)${RESET}"
    echo -e "$init_line"
    echo -e "               ${BOLD}欢迎使用 E-Sub 首次安装初始化向导${RESET}"
    echo -e "$init_line"

    local exist_port="" exist_path=""
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        exist_port=$(docker inspect --format='{{(index (index .HostConfig.PortBindings "3001/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
        exist_path=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null | grep '^SUB_STORE_FRONTEND_BACKEND_PATH=' | cut -d= -f2- || echo "")
    fi

    local def_port="${exist_port:-$DEFAULT_PORT}"
    read -rp "1. 请输入宿主机映射端口 [直接回车默认: ${def_port}]: " input_port
    if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then
        HOST_PORT="$input_port"
    else
        HOST_PORT="$def_port"
    fi

    echo ""
    echo -e "2. 反代域名设置 (例如: ${CYAN}sub.example.com${RESET} 或 ${CYAN}http://sub.example.com${RESET})"
    read -rp "   请输入反代域名 [若无域名直接回车使用 IP+端口]: " input_domain
    if [ "$input_domain" = "0" ] || [ -z "$input_domain" ]; then
        CUSTOM_DOMAIN=""
    else
        CUSTOM_DOMAIN=$(normalize_domain "$input_domain")
    fi

    if [ -n "$exist_path" ]; then
        BACKEND_PATH="$exist_path"
    else
        BACKEND_PATH="/$(gen_random_path)"
    fi

    save_config
    echo ""
    echo -e "${GREEN}✅ 初始化配置已保存！专属随机密钥已生成: ${YELLOW}${BACKEND_PATH}${RESET}"
    sleep 1
}

load_or_init_config() {
    mkdir -p "$DATA_DIR"
    if [ -f "$CONF_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONF_FILE"
        HOST_PORT="${HOST_PORT:-$DEFAULT_PORT}"
        BACKEND_PATH="${BACKEND_PATH:-/$(gen_random_path)}"
        CUSTOM_DOMAIN="${CUSTOM_DOMAIN:-}"
    else
        if [ "${1:-}" = "--auto" ]; then
            HOST_PORT="$DEFAULT_PORT"
            BACKEND_PATH="/$(gen_random_path)"
            CUSTOM_DOMAIN=""
            save_config
        else
            init_wizard
        fi
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

get_base_url() {
    if [ -n "${CUSTOM_DOMAIN:-}" ]; then
        echo "${CUSTOM_DOMAIN}"
    else
        local ip="${PUBLIC_IP:-你的服务器IP}"
        echo "http://${ip}:${HOST_PORT}"
    fi
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

show_login_links() {
    local base_url full_url w line
    base_url=$(get_base_url)
    full_url="${base_url}?api=${base_url}${BACKEND_PATH}"
    w=$(( ${#full_url} + 4 ))
    [ "$w" -lt 68 ] && w=68
    line="${CYAN}$(repeat_char '-' "$w")${RESET}"

    echo -e "$line"
    echo -e " ${CYAN}✦ 免填参数一键登录地址 (请复制下方完整链接在浏览器打开):${RESET}"
    echo -e " ${GREEN}${BOLD}${full_url}${RESET}"
    if [ -n "${CUSTOM_DOMAIN:-}" ]; then
        echo -e " ${YELLOW}提示: 请确保反向代理已将 ${CUSTOM_DOMAIN} 转发至 http://127.0.0.1:${HOST_PORT}${RESET}"
    fi
    echo -e "$line"
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
        show_login_links
    else
        echo -e "${GREEN}[后端] ✨ 镜像无变化且容器运行正常，无需重启。${RESET}"
    fi
}

manage_config() {
    while true; do
        clear
        local cfg_line cfg_sub domain_display
        cfg_line="${CYAN}$(repeat_char '=' 68)${RESET}"
        cfg_sub="${CYAN}$(repeat_char '-' 68)${RESET}"
        domain_display="${CUSTOM_DOMAIN:-未设置 (当前使用 IP:${HOST_PORT})}"

        echo -e "$cfg_line"
        echo -e "                ${BOLD}配置管理 (反代域名 / Path / 端口)${RESET}"
        echo -e "$cfg_line"
        echo -e " 当前反代域名 : ${GREEN}${domain_display}${RESET}"
        echo -e " 当前后端密钥 : ${YELLOW}${BACKEND_PATH}${RESET}"
        echo -e " 本地监听端口 : ${CYAN}${HOST_PORT}${RESET}"
        echo -e "$cfg_sub"
        echo -e "  ${GREEN}1.${RESET} 设置 / 修改反代域名"
        echo -e "  ${GREEN}2.${RESET} 清除反代域名 (恢复默认 IP+端口 显示)"
        echo -e "  ${GREEN}3.${RESET} 一键重新生成随机 Path 密钥 (防泄露推荐)"
        echo -e "  ${GREEN}4.${RESET} 自定义输入 Path 密钥路径"
        echo -e "  ${GREEN}5.${RESET} 修改宿主机映射端口"
        echo -e "  ${GREEN}0.${RESET} 返回主菜单"
        echo -e "$cfg_line"

        local sub_choice need_restart="false"
        read -rp "请选择操作 [0-5]: " sub_choice
        echo ""

        case "$sub_choice" in
            1)
                echo -e "示例: 输入 ${CYAN}sub.yourdomain.com${RESET} 默认按 https 处理；如需 http 请输入 ${CYAN}http://...${RESET}"
                local new_domain
                read -rp "请输入反代域名 (输入 0 取消): " new_domain
                if [ "$new_domain" = "0" ] || [ -z "$new_domain" ]; then
                    echo -e "${YELLOW}已取消域名修改。${RESET}"
                else
                    CUSTOM_DOMAIN=$(normalize_domain "$new_domain")
                    save_config
                    echo -e "${GREEN}[配置] ✅ 反代域名已更新为: ${CUSTOM_DOMAIN}${RESET}"
                    show_login_links
                fi
                ;;
            2)
                CUSTOM_DOMAIN=""
                save_config
                echo -e "${GREEN}[配置] ✅ 已清除反代域名，恢复 IP+端口 模式。${RESET}"
                ;;
            3)
                local confirm_gen
                read -rp "确认重新生成随机 Path 吗？旧链接将立即失效 [y/N (输入 0 取消)]: " confirm_gen
                if [[ "$confirm_gen" =~ ^[yY]$ ]]; then
                    BACKEND_PATH="/$(gen_random_path)"
                    save_config
                    need_restart="true"
                    echo -e "${GREEN}[配置] ✅ 已生成全新随机 Path: ${BACKEND_PATH}${RESET}"
                else
                    echo -e "${YELLOW}已取消重置随机 Path。${RESET}"
                fi
                ;;
            4)
                local custom_path
                read -rp "请输入新的自定义 Path，无需带开头斜杠 (输入 0 取消): " custom_path
                if [ "$custom_path" = "0" ] || [ -z "$custom_path" ]; then
                    echo -e "${YELLOW}已取消自定义 Path 修改。${RESET}"
                else
                    custom_path="${custom_path#/}"
                    if [ -z "$custom_path" ] || [ "$custom_path" = "0" ]; then
                        echo -e "${YELLOW}已取消自定义 Path 修改。${RESET}"
                    else
                        BACKEND_PATH="/${custom_path}"
                        save_config
                        need_restart="true"
                        echo -e "${GREEN}[配置] ✅ 已更新自定义 Path: ${BACKEND_PATH}${RESET}"
                    fi
                fi
                ;;
            5)
                local new_port
                read -rp "请输入新的宿主机映射端口 [1-65535] (输入 0 取消): " new_port
                if [ "$new_port" = "0" ] || [ -z "$new_port" ]; then
                    echo -e "${YELLOW}已取消端口修改。${RESET}"
                elif ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                    echo -e "${RED}[配置] ❌ 端口号无效！${RESET}"
                else
                    HOST_PORT="$new_port"
                    save_config
                    need_restart="true"
                    echo -e "${GREEN}[配置] ✅ 已更新映射端口为: ${HOST_PORT}${RESET}"
                fi
                ;;
            0)
                return 0
                ;;
            *)
                echo -e "${RED}输入无效，请输入 0 到 5 之间的数字！${RESET}"
                ;;
        esac

        if [ "$need_restart" = "true" ]; then
            if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
                echo -e "${CYAN}正在重建容器以应用新配置...${RESET}"
                run_container
                echo -e "${GREEN}✅ 容器已重建生效！最新连接信息如下：${RESET}"
                show_login_links
            else
                echo -e "${YELLOW}配置已保存，请返回主菜单执行 [1] 完成首次安装。${RESET}"
            fi
        fi

        echo ""
        read -rp "按回车键继续..." _
    done
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
    echo -e "${CYAN}$(repeat_char '-' 56)${RESET}"

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
    read -rp "确认继续恢复吗？[y/N (输入 0 取消)]: " confirm
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
    show_login_links
    echo -e "\n${CYAN}--- 最近 25 行运行日志 ---${RESET}"
    docker logs --tail 25 "$CONTAINER_NAME" 2>&1 || echo "容器未创建"
}

# 1. 初始化环境与配置
check_deps
load_or_init_config "${1:-}"
install_shortcut

# 2. 兼容 Crontab 后台静默调用: e-sub --auto
if [ "${1:-}" = "--auto" ]; then
    echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] 自动检测更新开始 ==="
    update_frontend false
    update_backend false
    echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] 自动检测更新结束 ==="
    exit 0
fi

# 3. 仅在未设置反代域名时才探测公网 IP
PUBLIC_IP=""
if [ -z "${CUSTOM_DOMAIN:-}" ]; then
    PUBLIC_IP=$(curl -4fsSL --max-time 2 https://api.ipify.org 2>/dev/null || curl -4fsSL --max-time 2 https://ifconfig.me 2>/dev/null || echo "你的服务器IP")
fi

# 4. 交互式主菜单循环（自适应动态宽度美化版）
while true; do
    if [ -z "${CUSTOM_DOMAIN:-}" ] && [ -z "$PUBLIC_IP" ]; then
        PUBLIC_IP=$(curl -4fsSL --max-time 2 https://api.ipify.org 2>/dev/null || echo "你的服务器IP")
    fi
    BASE_URL=$(get_base_url)
    FULL_LOGIN_URL="${BASE_URL}?api=${BASE_URL}${BACKEND_PATH}"

    # 根据完整 URL 长度动态计算边框宽度（最小宽度 72，确保完整包裹 URL 不溢出）
    BOX_WIDTH=$(( ${#FULL_LOGIN_URL} + 3 ))
    [ "$BOX_WIDTH" -lt 72 ] && BOX_WIDTH=72
    DYNAMIC_LINE="${CYAN}$(repeat_char '=' "$BOX_WIDTH")${RESET}"
    DYNAMIC_SUB="${CYAN}$(repeat_char '-' "$BOX_WIDTH")${RESET}"

    # 计算标题居中填充空格（标题视觉显示宽度约 36 列）
    TITLE_PAD=$(( (BOX_WIDTH - 36) / 2 ))
    [ "$TITLE_PAD" -lt 2 ] && TITLE_PAD=2
    TITLE_SPACES=$(printf "%${TITLE_PAD}s" "")

    clear
    FE_VER=$(cat "$VERSION_FILE" 2>/dev/null || echo "未安装")
    if [ "$(docker inspect --format='{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]; then
        STATUS_STR="${GREEN}● 运行中${RESET} (本地端口: ${CYAN}${HOST_PORT}${RESET})"
    else
        STATUS_STR="${RED}○ 未运行${RESET} (预设端口: ${CYAN}${HOST_PORT}${RESET})"
    fi
    if crontab -l 2>/dev/null | grep -qE "($BIN_PATH|/usr/local/bin/update-sub) --auto"; then
        CRON_STR="${GREEN}已开启 (每日 04:00)${RESET}"
    else
        CRON_STR="${YELLOW}未开启${RESET}"
    fi
    if [ -n "${CUSTOM_DOMAIN:-}" ]; then
        MODE_STR="${GREEN}反代域名 (${CUSTOM_DOMAIN})${RESET}"
    else
        MODE_STR="${YELLOW}IP 直连 (${PUBLIC_IP}:${HOST_PORT})${RESET}"
    fi

    echo -e "$DYNAMIC_LINE"
    echo -e "${TITLE_SPACES}${BOLD}E-Sub (Sub-Store) 交互式管理面板 ${SCRIPT_VER}${RESET}"
    echo -e "$DYNAMIC_LINE"
    echo -e " 容器状态 : ${STATUS_STR}    自动更新 : ${CRON_STR}"
    echo -e " 前端版本 : ${GREEN}${FE_VER}${RESET}                    访问模式 : ${MODE_STR}"
    echo -e " 后端密钥 : ${YELLOW}${BACKEND_PATH}${RESET}"
    echo -e "$DYNAMIC_SUB"
    echo -e " ${CYAN}✦ 免填参数一键登录完整地址 (直接复制打开，自动绑定后端 API):${RESET}"
    echo -e " ${GREEN}${BOLD}${FULL_LOGIN_URL}${RESET}"
    echo -e "$DYNAMIC_SUB"
    echo -e "  ${GREEN}1.${RESET} 安装 / 智能增量更新前后端 (推荐)"
    echo -e "  ${GREEN}2.${RESET} 仅强制重下并热更新前端"
    echo -e "  ${GREEN}3.${RESET} 强制拉取镜像并重建后端容器"
    echo -e "  ${GREEN}4.${RESET} 备份订阅配置数据 (自动保留最近 3 份)"
    echo -e "  ${GREEN}5.${RESET} 查看容器状态与实时日志"
    echo -e "  ${GREEN}6.${RESET} 开启 / 关闭每日凌晨自动更新"
    echo -e "  ${GREEN}7.${RESET} 从备份文件恢复配置数据"
    echo -e "  ${GREEN}8.${RESET} 配置管理 (反代域名 / Path 密钥 / 端口)"
    echo -e "  ${GREEN}0.${RESET} 退出脚本"
    echo -e "$DYNAMIC_LINE"
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
            manage_config
            continue
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
