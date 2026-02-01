#!/bin/bash

# 脚本信息
SCRIPT_COMMIT="initial"
SCRIPT_REPO="https://github.com/Liu-fucheng/ST_Chatelaine"

# 获取脚本本地版本
get_script_version() {
    if [[ -d "${SCRIPT_DIR}/.git" ]]; then
        git -C "${SCRIPT_DIR}" describe --tags --abbrev=0 2>/dev/null || echo "v1.0.0"
    else
        echo "v1.0.0"
    fi
}

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 临时文件追踪数组
declare -a TEMP_FILES=()

# 清理函数
cleanup() {
    echo -ne "\033[?25h"
    
    for temp_file in "${TEMP_FILES[@]}"; do
        [[ -f "$temp_file" ]] && rm -f "$temp_file"
    done
    
    if [[ -n "$1" ]]; then
        echo -e "\n${YELLOW}操作已取消，返回主菜单...${NC}"
        sleep 1
    fi
}

trap 'cleanup "interrupted"; exit 1' INT TERM HUP

# 目录
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ST_DIR="$(dirname "${SCRIPT_DIR}")/SillyTavern"

# 配置文件
CONFIG_FILE="${SCRIPT_DIR}/config.txt"

# 读取配置函数
load_config() {
    local first_run=false
    local backup_limit_set=false
    
    if [[ -f "$CONFIG_FILE" ]]; then
        while IFS='=' read -r key value; do
            case "$key" in
                ST_DIR) ST_DIR="$value" ;;
                BACKUP_LIMIT) 
                    BACKUP_LIMIT="$value"
                    backup_limit_set=true
                    ;;
                AUTOSTART) AUTOSTART="$value" ;;
            esac
        done < "$CONFIG_FILE"
    else
        first_run=true
    fi
    
    # 设置默认值
    [[ -z "$AUTOSTART" ]] && AUTOSTART="false"
    
    # 设置默认值
    [[ -z "$ST_DIR" ]] && ST_DIR="$(dirname "${SCRIPT_DIR}")/SillyTavern"
    
    # 如果是首次运行或未设置备份上限，提示用户设置
    if [[ "$first_run" == "true" ]] || [[ "$backup_limit_set" == "false" ]]; then
        FIRST_RUN_SETUP=true
        BACKUP_LIMIT=2  # 临时默认值
    else
        FIRST_RUN_SETUP=false
        # 验证备份上限
        if ! [[ "$BACKUP_LIMIT" =~ ^[0-9]+$ ]] || [[ $BACKUP_LIMIT -lt 1 ]]; then
            BACKUP_LIMIT=2
        fi
    fi
}

# 保存配置函数
save_config() {
    cat > "$CONFIG_FILE" << EOF
ST_DIR=$ST_DIR
BACKUP_LIMIT=$BACKUP_LIMIT
AUTOSTART=$AUTOSTART
EOF
}

# 加载配置
load_config

#版本号
LOCAL_VER="--"
REMOTE_VER="--"

# 自动检测并安装 pv
if ! command -v pv &> /dev/null; then
    echo "检测到未安装 pv，正在自动安装..."
    pkg install pv -y
fi

# 自动检测并安装 gum
if ! command -v gum &> /dev/null; then
    echo "检测到未安装 gum，正在自动安装..."
    pkg install gum -y
fi

# 32 位 Android 系统安装 esbuild
if [[ "$(uname -o)" == "Android" && "$(uname -m)" == "armv7l" ]]; then
    if ! command -v esbuild &> /dev/null; then
        echo -e "${YELLOW}检测到 32 位 Android 系统，未安装 esbuild，正在安装...${NC}"
        pkg install esbuild -y
    fi
fi

# 备份
backup_st() {
    local backup_type="${1:-auto}"
    local backup_dir="${SCRIPT_DIR}/backups"
    mkdir -p "$backup_dir"
    
    if [[ "$backup_type" == "auto" ]]; then
        local one_hour_ago=$(date -d "1 hour ago" +%s 2>/dev/null || date -v-1H +%s 2>/dev/null)
        local recent_backup=""
        
        for backup_file in "${backup_dir}"/ST_Backup_*.tar.gz; do
            [[ -f "$backup_file" ]] || continue
            # 跳过手动备份
            [[ "$backup_file" == *"_manual.tar.gz" ]] && continue
            
            local file_time=$(stat -c %Y "$backup_file" 2>/dev/null || stat -f %m "$backup_file" 2>/dev/null)
            if [[ $file_time -gt $one_hour_ago ]]; then
                recent_backup="$backup_file"
                break
            fi
        done
        
        if [[ -n "$recent_backup" ]]; then
            local backup_age=$(( ($(date +%s) - $(stat -c %Y "$recent_backup" 2>/dev/null || stat -f %m "$recent_backup" 2>/dev/null)) / 60 ))
            gum style --foreground 99 "检测到 ${backup_age} 分钟前已创建备份："
            gum style --foreground 245 "  $(basename "$recent_backup")"
            if ! gum confirm "是否仍要继续备份？"; then
                gum style --foreground 99 "已取消备份"
                return 0
            fi
        fi
    fi
    
    # 生成备份文件名
    if [[ "$backup_type" == "manual" ]]; then
        BACKUP_NAME="ST_Backup_$(date +%Y%m%d_%H%M%S)_manual.tar.gz"
    else
        BACKUP_NAME="ST_Backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    fi
    BACKUP_PATH="${backup_dir}/${BACKUP_NAME}"

    TARGETS=()
    [[ -f "${ST_DIR}/config.yaml" ]] && TARGETS+=("config.yaml")
    [[ -d "${ST_DIR}/data" ]] && TARGETS+=("data")
    [[ -d "${ST_DIR}/public/scripts/extensions/third-party" ]] && TARGETS+=("public/scripts/extensions/third-party")
    if [ ${#TARGETS[@]} -eq 0 ]; then
        gum style --foreground 196 --border double --padding "0 2" "错误：指定酒馆路径下未找到可备份的文件或目录。"
        return 1
    fi

    echo "正在检查文件大小..."
    local ERROR_LOG=$(mktemp)
    TEMP_FILES+=("$ERROR_LOG")

    local ABS_TARGETS=()
    for t in "${TARGETS[@]}"; do ABS_TARGETS+=("${ST_DIR}/$t"); done
    local TOTAL_SIZE=$(du -cb "${ABS_TARGETS[@]}" 2>/dev/null | tail -n1 | cut -f1)

    echo "正在打包..."
    
    if tar -czf "$BACKUP_PATH" -C "$ST_DIR" "${TARGETS[@]}" 2>"$ERROR_LOG"; then
        local EXIT_CODE=0
    else
        local EXIT_CODE=1
    fi
    
    if [[ ! -f "$BACKUP_PATH" ]] || [[ ! -s "$BACKUP_PATH" ]]; then
        EXIT_CODE=1
    fi

    if [ $EXIT_CODE -eq 0 ]; then
        local size=$(du -h "$BACKUP_PATH" | cut -f1)
        gum style \
            --foreground 212 --border-foreground 212 --border double \
            --align center --width 50 --margin "1 0" --padding "1 2" \
            "备份成功！" "" "文件: $(basename "$BACKUP_PATH")" "大小: $size"
        
        if [[ "$backup_type" == "auto" ]]; then
            cleanup_old_backups
        fi
        
        return 0
    else
        gum style --foreground 196 --bold "备份失败，请检查磁盘空间或权限。"
        return 1
    fi
}

# 清理旧的自动备份（不删除手动备份）
cleanup_old_backups() {
    local backup_dir="${SCRIPT_DIR}/backups"
    [[ ! -d "$backup_dir" ]] && return
    
    # 获取所有自动备份（不含 _manual 的）
    local auto_backups=()
    for backup_file in "${backup_dir}"/ST_Backup_*.tar.gz; do
        [[ -f "$backup_file" ]] || continue
        # 跳过手动备份
        [[ "$backup_file" == *"_manual.tar.gz" ]] && continue
        auto_backups+=("$backup_file")
    done
    
    # 按时间排序（最新的在前）
    IFS=$'\n' auto_backups=($(ls -t "${auto_backups[@]}" 2>/dev/null))
    unset IFS
    
    local total=${#auto_backups[@]}
    
    # 如果超过上限，删除旧的
    if [[ $total -gt $BACKUP_LIMIT ]]; then
        local to_delete=$((total - BACKUP_LIMIT))
        gum style --foreground 99 "自动备份数量 ($total) 超过上限 ($BACKUP_LIMIT)，正在清理..."
        
        for ((i=BACKUP_LIMIT; i<total; i++)); do
            local old_backup="${auto_backups[$i]}"
            gum style --foreground 245 "删除旧备份: $(basename "$old_backup")"
            rm -f "$old_backup"
        done
        
        gum style --foreground 212 "已清理 $to_delete 个旧备份"
    fi
}


# 解压
restore_st() {
    local backup_file=$1 

    echo "正在解压备份..."
    tar -xzf "$backup_file" -C "$ST_DIR"
    
    echo "备份还原完成。"
}

# 解压最新备份
restore_latest() {
    local backup_dir="${SCRIPT_DIR}/backups"
    
    if [[ ! -d "$backup_dir" ]]; then
        gum style --foreground 196 "错误: 备份目录不存在"
        return 1
    fi

    local latest_file=$(ls -t "${backup_dir}/"*.tar.gz 2>/dev/null | head -n 1)

    if [[ -z "$latest_file" ]]; then
        gum style --foreground 196 "未找到任何备份文件"
        return 1
    fi

    gum style --foreground 212 "找到最新备份: $(basename "$latest_file")"
    
    local total_limit=5

    local dir1="${ST_DIR}/data"
    local count1=0
    if [[ -d "$dir1" ]]; then
        count1=$(find "$dir1" -type f 2>/dev/null | wc -l)
    fi

    local dir2="${ST_DIR}/public/scripts/extensions/third-party"
    local count2=0
    if [[ -d "$dir2" ]]; then
        count2=$(find "$dir2" -type f 2>/dev/null | wc -l)
    fi

    local total_count=$((count1 + count2))

    if [[ "$total_count" -lt "$total_limit" ]]; then
        gum style --foreground 99 "检测到关键文件缺失，正在自动还原..."
        gum spin --spinner dot --title "还原备份中..." -- restore_st "$latest_file"
    else
        gum style --foreground 212 "检测到数据完整，跳过自动还原"
    fi
}

# 获取最新版本号（静默版本，失败返回空）
get_remote_version() {
    local remote_tag=$(timeout 3s git ls-remote --tags --sort='v:refname' https://github.com/SillyTavern/SillyTavern.git 2>/dev/null | tail -n1 | sed 's/.*\///; s/\^{}//')
    echo "$remote_tag"
}

# 获取脚本最新版本和commit
get_script_remote_version() {
    # 获取main分支的最新commit hash（短格式7位）
    local remote_commit=$(timeout 3s git ls-remote https://github.com/Liu-fucheng/ST_Chatelaine.git HEAD 2>/dev/null | cut -f1 | cut -c1-7)
    echo "$remote_commit"
}

# 后台预加载远程版本（SillyTavern和脚本）
preload_remote_version() {
    (
        # 加载 SillyTavern 版本
        REMOTE_VER=$(get_remote_version)
        if [[ -n "$REMOTE_VER" ]]; then
            echo "$REMOTE_VER" > "${SCRIPT_DIR}/.remote_version_cache"
            # 设置刷新标志
            touch "${SCRIPT_DIR}/.version_updated"
        fi
        
        # 加载脚本commit
        SCRIPT_REMOTE_COMMIT=$(get_script_remote_version)
        if [[ -n "$SCRIPT_REMOTE_COMMIT" ]]; then
            echo "$SCRIPT_REMOTE_COMMIT" > "${SCRIPT_DIR}/.script_version_cache"
            # 设置刷新标志
            touch "${SCRIPT_DIR}/.version_updated"
        fi
    ) &
}

# 获取本地当前版本号
get_local_version() {
    if [[ -d "${ST_DIR}/.git" ]]; then
        git -C "$ST_DIR" describe --tags --abbrev=0 2>/dev/null || echo "Unknown"
    else
        echo "未检测到 Git"
    fi
}

# 获取本地当前版本号
get_local_version() {
    if [[ -d "${ST_DIR}/.git" ]]; then
        git -C "$ST_DIR" describe --tags --abbrev=0 2>/dev/null || echo "Unknown"
    else
        echo "未检测到 Git"
    fi
}

# 比对版本号
check_version_status() {
    LOCAL_VER=$(get_local_version)
    
    # 尝试从缓存读取远程版本
    if [[ -f "${SCRIPT_DIR}/.remote_version_cache" ]]; then
        REMOTE_VER=$(cat "${SCRIPT_DIR}/.remote_version_cache")
    fi
    
    # 如果缓存为空，显示检测中
    if [[ -z "$REMOTE_VER" ]]; then
        REMOTE_VER="检测中..."
    fi

    gum style --foreground 255 "酒馆本地版本: ${LOCAL_VER}"
    gum style --foreground 255 "酒馆最新版本: ${REMOTE_VER}"

    if [[ "$LOCAL_VER" == "Unknown" ]]; then
        gum style --foreground 196 "状态: 无法识别本地 Git 版本"
    elif [[ "$REMOTE_VER" == "检测中..." ]]; then
        gum style --foreground 245 "状态: 正在检测远程版本..."
    elif [[ "$LOCAL_VER" == "$REMOTE_VER" ]]; then
        gum style --foreground 212 "状态: 已是最新版本"
    else
        gum style --foreground 99 "状态: 有新版本可用"
    fi
    
    # 显示脚本版本状态
    if [[ -f "${SCRIPT_DIR}/.script_version_cache" ]]; then
        local script_remote_commit=$(cat "${SCRIPT_DIR}/.script_version_cache")
        if [[ -n "$script_remote_commit" && "$script_remote_commit" != "$SCRIPT_COMMIT" ]]; then
            echo "----------------------------------------"
            gum style --foreground 212 "脚本更新可用"
        fi
    fi
}

update_st() {
    gum style --foreground 212 --bold "开始更新 SillyTavern"
    echo ""

    if [[ ! -d "${ST_DIR}/.git" ]]; then
        gum style --foreground 196 "错误: 目标目录不是 Git 仓库，无法更新"
        return 1
    fi

    git -C "$ST_DIR" config core.filemode false

    local CURRENT_BRANCH=$(git -C "$ST_DIR" branch --show-current)

    if [[ -z "$CURRENT_BRANCH" ]]; then
        gum style --foreground 99 "检测到当前处于特定版本锁定状态"
        gum style --foreground 99 "正在切换回 release 分支..."
        
        if ! gum spin --spinner dot --title "切换分支中..." -- \
            git -C "$ST_DIR" checkout -f release; then
            gum style --foreground 196 "切换分支失败"
            return 1
        fi
        
        CURRENT_BRANCH="release"
    fi

    if ! gum spin --spinner dot --title "正在拉取远程分支..." -- \
        git -C "$ST_DIR" fetch origin "$CURRENT_BRANCH"; then
        gum style --foreground 196 "错误: 拉取远程分支失败，请检查网络连接"
        return 1
    fi

    git -C "$ST_DIR" reset --hard "origin/$CURRENT_BRANCH"

    if gum spin --spinner dot --title "正在从 GitHub 拉取最新代码..." -- \
        git -C "$ST_DIR" pull; then
        gum style --foreground 212 "代码更新成功"

        if [[ -f "${ST_DIR}/package.json" ]]; then
            if gum spin --spinner dot --title "正在安装 npm 依赖..." -- \
                sh -c "cd '$ST_DIR' && npm install --no-audit --fund=false 2>&1"; then
                gum style --foreground 212 "依赖安装完成"
            else
                gum style --foreground 99 "警告: 依赖安装可能遇到问题，请手动检查"
            fi
        fi

        gum style \
            --foreground 212 --border-foreground 212 --border double \
            --align center --width 50 --padding "1 2" \
            "更新完成"
        return 0
    else
        gum style --foreground 196 "更新失败，请检查网络连接或手动处理冲突"
        return 1
    fi
}

select_tag_interactive() {
    gum style --foreground 212 --bold "版本选择"
    gum style --foreground 245 "提示: 输入可搜索，方向键选择，回车确认，Esc退出"
    echo ""
    
    local selected_tag=$(gum spin --spinner dot --title "正在加载版本列表..." -- \
        git -C "$ST_DIR" tag --sort=-creatordate --format='%(creatordate:short) | %(refname:short)' | \
        gum filter --placeholder="搜索版本号..." --height=15 --header="选择要切换的版本" | \
        awk '{print $NF}')
    
    if [[ -z "$selected_tag" ]]; then
        gum style --foreground 99 "已取消版本切换"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
    
    gum style --foreground 212 "已选择版本: ${selected_tag}"
    echo ""
    
    if ! gum confirm "是否备份当前数据后切换版本？"; then
        gum style --foreground 99 "已取消切换"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
    
    # 执行备份
    if ! backup_st; then
        gum style --foreground 196 "备份失败，取消切换"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
    
    if gum spin --spinner dot --title "正在切换到版本 ${selected_tag}..." -- \
        git -C "$ST_DIR" checkout -f "$selected_tag"; then
        gum style \
            --foreground 212 --border-foreground 212 --border double \
            --align center --width 50 --padding "1 2" \
            "版本切换成功" "" "当前版本: ${selected_tag}"
    else
        gum style --foreground 196 --bold "切换失败，请检查版本号或仓库状态"
    fi
    
    restore_latest
    read -n 1 -s -r -p "按任意键返回主菜单..."
    return 0
}

select_branch_interactive() {
    gum style --foreground 212 --bold "分支选择"
    gum style --foreground 245 "提示: 输入可搜索，方向键选择，回车确认，Esc退出"
    echo ""
    
    local selected_branch=$(gum spin --spinner dot --title "正在加载分支列表..." -- \
        git -C "$ST_DIR" branch -r | grep -v 'HEAD' | sed 's/origin\///' | sed 's/^[ \t]*//' | \
        gum filter --placeholder="搜索分支..." --height=15 --header="选择要切换的分支")
    
    if [[ -z "$selected_branch" ]]; then
        gum style --foreground 99 "已取消分支切换"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
    
    gum style --foreground 212 "已选择分支: ${selected_branch}"
    echo ""
    
    if ! gum confirm "是否备份当前数据后切换分支？"; then
        gum style --foreground 99 "已取消切换"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
    
    if ! gum spin --spinner globe --title "正在备份当前数据..." -- backup_st; then
        gum style --foreground 196 "备份失败，取消切换"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
    
    if gum spin --spinner dot --title "正在切换到分支 ${selected_branch}..." -- \
        git -C "$ST_DIR" checkout -f "$selected_branch"; then
        
        if gum spin --spinner dot --title "正在拉取最新代码..." -- \
            git -C "$ST_DIR" pull origin "$selected_branch"; then
            
            if [[ -f "${ST_DIR}/package.json" ]]; then
                gum spin --spinner dot --title "正在安装 npm 依赖..." -- \
                    sh -c "cd '$ST_DIR' && npm install --no-audit --fund=false 2>&1"
            fi
            
            gum style \
                --foreground 212 --border-foreground 212 --border double \
                --align center --width 50 --padding "1 2" \
                "分支切换成功" "" "当前分支: ${selected_branch}"
        else
            gum style --foreground 196 "拉取最新代码失败"
        fi
    else
        gum style --foreground 196 --bold "切换失败，请检查分支名或仓库状态"
    fi
    
    restore_latest
    read -n 1 -s -r -p "按任意键返回主菜单..."
    return 0
}

set_autostart() {
    local bashrc="${HOME}/.bashrc"
    local script_path="${SCRIPT_DIR}/$(basename "$0")"
    local autostart_line="# ST_Chatelaine Auto-start
bash \"${script_path}\""
    
    if grep -q "ST_Chatelaine Auto-start" "$bashrc" 2>/dev/null; then
        gum style --foreground 99 "当前状态: 已启用自启动"
        echo ""
        if gum confirm "是否取消自启动？"; then
            sed -i '/# ST_Chatelaine Auto-start/,+1d' "$bashrc"
            local latest_backup=$(ls -t "${bashrc}.backup."* 2>/dev/null | head -n 1)
            if [[ -n "$latest_backup" ]]; then
                gum style --foreground 99 "检测到备份文件"
                if gum confirm "是否恢复之前的 .bashrc 配置？"; then
                    cp "$latest_backup" "$bashrc"
                    if grep -q "^# " "$bashrc" 2>/dev/null; then
                        if gum confirm "检测到备份中有注释代码，是否取消注释？"; then
                            sed -i 's/^# \(.*\)$/\1/' "$bashrc"
                            gum style --foreground 212 "已恢复并取消注释"
                        else
                            gum style --foreground 212 "已恢复备份（保留注释）"
                        fi
                    else
                        gum style --foreground 212 "已恢复之前的配置"
                    fi
                fi
            fi
            
            AUTOSTART="false"
            save_config
            gum style --foreground 212 "已取消自启动设置"
        else
            gum style --foreground 99 "保持自启动设置"
        fi
    else
        gum style --foreground 99 "当前状态: 未启用自启动"
        echo ""
        
        local has_startup_code=false
        local startup_info=""
        
        local single_line_count=$(grep -cE "^(bash|sh|source|\.)" "$bashrc" 2>/dev/null || echo "0")

        local script_block_count=$(grep -cE "^(function|if |while |for |case )" "$bashrc" 2>/dev/null || echo "0")
        
        if [[ $single_line_count -gt 0 ]] || [[ $script_block_count -gt 0 ]]; then
            has_startup_code=true
            startup_info="检测到:\n"
            [[ $single_line_count -gt 0 ]] && startup_info+="  - ${single_line_count} 行启动命令\n"
            [[ $script_block_count -gt 0 ]] && startup_info+="  - ${script_block_count} 个代码块（可能是内联脚本）"
        fi
        
        if [[ "$has_startup_code" == "true" ]]; then
            gum style --foreground 99 --bold "⚠ 检测到 .bashrc 中已有启动代码："
            echo -e "$startup_info"
            echo ""
            
            gum style --foreground 99 "请选择处理方式："
            local choice=$(gum choose \
                "替换（清空 .bashrc 后仅添加此脚本）" \
                "注释（保留原代码但注释掉）" \
                "共存（保留所有代码，可能冲突）" \
                "查看后决定" \
                "取消设置")
            
            case "$choice" in
                "替换（清空 .bashrc 后仅添加此脚本）")
                    gum style --foreground 196 --bold "警告: 此操作将清空整个 .bashrc！"
                    if ! gum confirm "确认要清空并替换 .bashrc 吗？"; then
                        gum style --foreground 99 "已取消操作"
                        return
                    fi
                    
                    gum style --foreground 99 "正在备份原 .bashrc..."
                    cp "$bashrc" "${bashrc}.backup.$(date +%Y%m%d_%H%M%S)"
                    
                    # 清空并添加此脚本
                    echo "$autostart_line" > "$bashrc"
                    AUTOSTART="true"
                    save_config
                    
                    gum style --foreground 212 "✓ 已清空 .bashrc 并设置此脚本为自启动"
                    gum style --foreground 245 "原配置已备份到: ${bashrc}.backup.*"
                    ;;
                    
                "注释（保留原代码但注释掉）")
                    gum style --foreground 99 "正在备份并注释原代码..."
                    cp "$bashrc" "${bashrc}.backup.$(date +%Y%m%d_%H%M%S)"
                    
                    # 只注释启动相关的行（bash、sh、source、. 开头以及代码块）
                    sed -i -E 's/^(bash |sh |source |\. |function |if |while |for |case )/# \1/' "$bashrc"
                    
                    # 添加此脚本
                    echo "" >> "$bashrc"
                    echo "$autostart_line" >> "$bashrc"
                    AUTOSTART="true"
                    save_config
                    
                    gum style --foreground 212 "✓ 已注释原启动代码并设置此脚本为自启动"
                    gum style --foreground 245 "原配置已备份到: ${bashrc}.backup.*"
                    gum style --foreground 245 "如需恢复原代码，请手动去除注释符号"
                    ;;
                    
                "共存（保留所有代码，可能冲突）")
                    echo "" >> "$bashrc"
                    echo "$autostart_line" >> "$bashrc"
                    AUTOSTART="true"
                    save_config
                    gum style --foreground 212 "✓ 已设置为自启动（与现有代码共存）"
                    gum style --foreground 99 "注意: 多个启动脚本可能产生冲突"
                    ;;
                    
                "查看后决定")
                    gum style --foreground 99 "正在显示 .bashrc 内容..."
                    echo ""
                    cat -n "$bashrc"
                    echo ""
                    gum style --foreground 245 "查看完毕，请重新执行此选项进行设置"
                    ;;
                    
                "取消设置")
                    gum style --foreground 99 "已取消设置"
                    return
                    ;;
            esac
        else
            if gum confirm "是否设置为默认自启动？"; then
                # 添加到 .bashrc
                echo "" >> "$bashrc"
                echo "$autostart_line" >> "$bashrc"
                AUTOSTART="true"
                save_config
                gum style --foreground 212 "已设置为自启动！"
                gum style --foreground 245 "下次打开 Termux 将自动运行此脚本"
            else
                gum style --foreground 99 "已取消设置"
            fi
        fi
    fi
}

# 卸载脚本
uninstall_script() {
    clear
    gum style --foreground 196 --bold "卸载脚本"
    gum style --foreground 99 "此操作将删除："
    echo "  1. 脚本文件及目录"
    echo "  2. 配置文件 (config.txt)"
    echo "  3. 自启动设置 (如果已设置)"
    echo "  4. 版本缓存文件"
    gum style --foreground 245 "注意: 不会删除 SillyTavern 和备份文件"
    echo ""
    
    if ! gum confirm "确认要卸载脚本吗？此操作不可恢复！"; then
        gum style --foreground 99 "已取消卸载"
        return
    fi
    
    echo ""
    gum style --foreground 99 "最后确认: 真的要删除脚本吗？"
    if ! gum confirm "再次确认卸载"; then
        gum style --foreground 99 "已取消卸载"
        return
    fi
    
    echo ""
    gum style --foreground 99 "开始卸载..."
    
    local bashrc="${HOME}/.bashrc"
    if grep -q "ST_Chatelaine Auto-start" "$bashrc" 2>/dev/null; then
        sed -i '/# ST_Chatelaine Auto-start/,+1d' "$bashrc"
        gum style --foreground 212 "✓ 已移除自启动设置"
    fi
    
    rm -f "${SCRIPT_DIR}/.remote_version_cache" "${SCRIPT_DIR}/.script_version_cache" "${SCRIPT_DIR}/.version_updated"
    gum style --foreground 212 "✓ 已删除缓存文件"
    
    rm -f "$CONFIG_FILE"
    gum style --foreground 212 "✓ 已删除配置文件"
    
    gum style --foreground 245 "正在删除脚本目录: ${SCRIPT_DIR}"
    
    cat > "/tmp/uninstall_st_chatelaine.sh" << 'UNINSTALL_EOF'
#!/bin/bash
sleep 1
rm -rf "${1}"
echo "脚本已卸载完成"
rm -f "$0"
UNINSTALL_EOF
    
    chmod +x "/tmp/uninstall_st_chatelaine.sh"
    
    gum style --foreground 212 "卸载完成！感谢使用 ST_Chatelaine"
    sleep 2
    
    exec bash "/tmp/uninstall_st_chatelaine.sh" "${SCRIPT_DIR}"
}

install_st() {
    gum style --foreground 99 "开始安装酒馆..."
    echo ""
    
    if ! gum spin --spinner dot --title "更新软件包..." -- pkg update; then
        gum style --foreground 196 "软件包更新失败"
        return 1
    fi
    
    if ! gum spin --spinner dot --title "安装依赖..." -- pkg install git nodejs-lts nano -y; then
        gum style --foreground 196 "依赖安装失败"
        return 1
    fi
    
    local install_dir="$(dirname "${SCRIPT_DIR}")/SillyTavern"
    if gum spin --spinner globe --title "克隆 SillyTavern 仓库..." -- \
        git clone https://github.com/SillyTavern/SillyTavern -b release "$install_dir"; then
        ST_DIR="$install_dir"
        save_config
        gum style --foreground 212 "酒馆安装成功！路径: $ST_DIR"
        return 0
    else
        gum style --foreground 196 "安装失败，请检查网络连接"
        return 1
    fi
}

select_dir_gui() {
    if ! command -v fzf &> /dev/null; then
        echo "正在安装 fzf..."
        pkg install fzf -y
    fi

    local selected_dir
    selected_dir=$(find "$HOME" -type d -maxdepth 4 2>/dev/null | fzf \
        --query "SillyTavern$" \
        --select-1 \
        --exit-0 \
        --height 60% \
        --layout=reverse \
        --border \
        --prompt="目录搜索: " \
        --pointer="->" \
        --marker="✓" \
        --color=fg:#d0d0d0,bg:#121212,hl:#5f87af \
        --color=fg+:#ffffff,bg+:#262626,hl+:#5fd7ff \
        --info=inline \
        --preview 'ls -F --color=always {}' \
        --preview-window 'right:50%:border-left')

    if [[ -z "$selected_dir" ]]; then
        return 1
    fi

    echo "$selected_dir"
    return 0
}

main() {
    preload_remote_version
    
    if [[ "$FIRST_RUN_SETUP" == "true" ]]; then
        clear
        echo ""
        gum style \
            --foreground 212 --border-foreground 212 --border double \
            --align center --width 60 --padding "1 2" \
            "欢迎使用 ST_Chatelaine" "" "首次运行配置"
        
        echo ""
        echo ""
        
        if [[ ! -d "${ST_DIR}" ]]; then
            gum style --foreground 99 --bold "未检测到酒馆路径"
            gum style --foreground 245 "请选择操作"
            echo ""
            
            local setup_choice=$(gum choose "指定已有酒馆路径" "安装新的酒馆" "稍后在主菜单设置")
            
            case "$setup_choice" in
                "指定已有酒馆路径")
                    ST_DIR=$(select_dir_gui "${HOME}")
                    if [[ -n "$ST_DIR" ]]; then
                        gum style --foreground 212 "已设置酒馆路径: $ST_DIR"
                        save_config
                    else
                        gum style --foreground 196 "未选择路径，将在主菜单中设置"
                        FIRST_RUN_SETUP=false
                        sleep 2
                        return
                    fi
                    ;;
                "安装新的酒馆")
                    if ! install_st; then
                        FIRST_RUN_SETUP=false
                        sleep 2
                        return
                    fi
                    ;;
                "稍后在主菜单设置")
                    gum style --foreground 99 "提示: 您可以在主菜单中选择安装酒馆或指定路径"
                    FIRST_RUN_SETUP=false
                    sleep 2
                    return
                    ;;
                *)
                    FIRST_RUN_SETUP=false
                    return
                    ;;
            esac
            
            echo ""
        fi
        
        gum style --foreground 99 --bold "请设置自动备份上限"
        gum style --foreground 245 "手动备份不计入上限，建议值: 2-5 个"
        echo ""
        
        local new_limit
        while true; do
            new_limit=$(gum input --placeholder "输入 1-99" --prompt "备份上限: " --width 20 --value "2" --prompt.foreground 51)
            
            if [[ "$new_limit" =~ ^[0-9]+$ ]] && [[ $new_limit -ge 1 ]] && [[ $new_limit -le 99 ]]; then
                BACKUP_LIMIT=$new_limit
                save_config
                gum style --foreground 212 "配置完成！备份上限: $BACKUP_LIMIT"
                FIRST_RUN_SETUP=false
                sleep 1
                break
            else
                gum style --foreground 196 "无效输入，请输入 1-99 之间的数字"
                sleep 1
            fi
        done
    fi
    
    local in_main_menu=true
    
    while true; do
        if [[ "$in_main_menu" == "true" && -f "${SCRIPT_DIR}/.version_updated" ]]; then
            rm -f "${SCRIPT_DIR}/.version_updated"
            sleep 0.5
        fi
        
        in_main_menu=true
        
        if [[ -d "${ST_DIR}" ]]; then
            IS_VALID=true
        else
            IS_VALID=false
        fi

        clear
        gum style --foreground 212 --bold "ST_Chatelaine $(get_script_version)"
        gum style --foreground 245 "项目地址: ${SCRIPT_REPO}"
        echo "----------------------------------------"
        echo "脚本路径: ${SCRIPT_DIR}"
        if [[ "$IS_VALID" == "true" ]]; then
            echo "酒馆路径: ${ST_DIR}"
        else
            gum style --foreground 196 " 酒馆路径: 未指定"
        fi
        echo "----------------------------------------"

        if [[ "$IS_VALID" == "false" ]]; then
            in_main_menu=false
            echo "1. 指定酒馆路径"
            echo "2. 安装酒馆"
            echo "0. 退出"
            echo "----------------------------------------"
            read -n 1 -s -r -p "请输入: " choice
            echo ""
            
            case $choice in
                1) 
                    ST_DIR=$(select_dir_gui "${ST_DIR:-$HOME}")
                    save_config
                    echo "已指定酒馆路径为: $ST_DIR"
                    read -n 1 -s -r -p "按任意键返回主菜单..."
                    ;;
                2) 
                    install_st
                    read -n 1 -s -r -p "按任意键返回主菜单..."
                    ;;
                0) exit 0 ;;
                *) ;;
            esac
            continue
        fi

        check_version_status
        echo "----------------------------------------"
        echo "1. 启动酒馆"
        echo "2. 酒馆版本操作 (更新/切换版本/分支)"
        echo "3. 备份酒馆文件"
        echo "4. 清理备份文件"
        echo "5. 设置"
        echo "6. 更新脚本"
        if [[ "$AUTOSTART" == "true" ]]; then
            echo "7. 取消脚本自启动"
        else
            echo "7. 设置脚本自启动"
        fi
        echo "8. 卸载脚本"
        echo "0. 退出"
        echo "----------------------------------------"
        read -n 1 -s -r -p "请输入: " choice
        echo ""
        
        in_main_menu=false

        case $choice in
            1)
                trap - INT TERM HUP
                
                gum style --foreground 212 "正在启动酒馆..."
                gum style --foreground 99 "提示: 按 Ctrl+C 可返回主菜单"
                echo ""
                
                bash "${ST_DIR}/start.sh"
                
                trap 'cleanup "interrupted"; exit 1' INT TERM HUP
                
                gum style --foreground 212 "酒馆已停止"
                sleep 1
                ;;
            2)
                 while true; do
                    clear
                    echo "----------------------------------------"
                    echo " 酒馆版本操作菜单"
                    echo "----------------------------------------"
                    echo "1. 更新酒馆至最新版本 (Release)"
                    echo "2. 切换酒馆至指定版本"
                    echo "3. 切换酒馆分支"
                    echo "0. 返回主菜单"
                    echo "----------------------------------------"
                    read -p "请输入: " sub_choice

                    case $sub_choice in
                        1) 
                            if [[ "$LOCAL_VER" == "$REMOTE_VER" ]]; then
                                gum style --foreground 212 "正在检查版本信息..."

                                local CURRENT_BRANCH=$(git -C "$ST_DIR" branch --show-current)

                                if ! gum spin --spinner dot --title "拉取远程分支中..." -- \
                                    git -C "$ST_DIR" fetch origin "$CURRENT_BRANCH"; then
                                    gum style --foreground 196 "错误: 拉取远程分支失败，请检查网络连接"
                                    read -n 1 -s -r -p "按任意键返回主菜单..."
                                    continue
                                fi

                                local LOCAL_HASH=$(git -C "$ST_DIR" rev-parse --short HEAD)
                                local REMOTE_HASH=$(git -C "$ST_DIR" rev-parse --short "origin/$CURRENT_BRANCH")

                                if [[ "$LOCAL_HASH" == "$REMOTE_HASH" ]]; then
                                    gum style --foreground 212 "当前SillyTavern已是最新版本，无需更新"
                                    read -n 1 -s -r -p "按任意键返回主菜单..."
                                    continue
                                fi
                            fi
                            
                            if ! gum confirm "是否备份当前数据后更新？"; then
                                gum style --foreground 99 "已取消更新"
                                read -n 1 -s -r -p "按任意键返回主菜单..."
                                continue
                            fi
                            
                            if backup_st; then
                                gum style --foreground 212 "备份成功，开始更新..."
                            else
                                gum style --foreground 196 "备份失败，取消更新"
                                read -n 1 -s -r -p "按任意键返回主菜单..."
                                continue
                            fi
                            update_st
                            restore_latest
                            gum style --foreground 212 "更新完成"
                            read -n 1 -s -r -p "按任意键返回主菜单..."
                            break
                            ;;
                        2)
                            select_tag_interactive
                            ;;
                        3)
                            select_branch_interactive
                            ;;
                        0) break ;;
                        *) echo "无效选项" ; sleep 1 ;;
                    esac
                done
                ;;
            3)
                gum style --foreground 99 "开始手动备份..."
                if backup_st "manual"; then
                    gum style --foreground 212 "备份成功"
                else
                    gum style --foreground 196 "备份失败"
                fi
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            4)
                gum style --foreground 245 "备份管理功能开发中..."
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            5)
                while true; do
                    clear
                    echo "----------------------------------------"
                    echo " 设置菜单"
                    echo "----------------------------------------"
                    echo "1. 修改酒馆路径"
                    echo "2. 设置备份上限 (当前为: ${BACKUP_LIMIT})"
                    echo "0. 返回主菜单"
                    echo "----------------------------------------"
                    read -p "请输入: " setting_choice

                    case $setting_choice in
                        1)
                            ST_DIR=$(select_dir_gui "${ST_DIR:-$HOME}")
                            save_config
                            echo "已指定酒馆路径为: $ST_DIR"
                            read -n 1 -s -r -p "按任意键返回设置菜单..."
                            ;;
                        2)
                            gum style --foreground 212 "当前自动备份上限: ${BACKUP_LIMIT}"
                            gum style --foreground 99 "说明: 手动备份不计入上限，不会被自动清理"
                            echo ""
                            
                            new_limit=$(gum input --placeholder "输入 1-99" --prompt "备份上限: " --width 20 --value "$BACKUP_LIMIT")
                            
                            if [[ "$new_limit" =~ ^[0-9]+$ ]] && [[ $new_limit -ge 1 ]] && [[ $new_limit -le 99 ]]; then
                                BACKUP_LIMIT=$new_limit
                                save_config
                                gum style --foreground 212 "备份上限已设置为: $BACKUP_LIMIT"
                            else
                                gum style --foreground 196 "无效输入，请输入 1-99 之间的数字"
                            fi
                            read -n 1 -s -r -p "按任意键返回设置菜单..."
                            ;;
                        0) break ;;
                        *) echo "无效选项" ; sleep 1 ;;
                    esac
                done
                ;;
            6)
                gum style --foreground 212 "脚本当前版本: $(get_script_version)"
                if [[ -f "${SCRIPT_DIR}/.script_version_cache" ]]; then
                    local script_remote_commit=$(cat "${SCRIPT_DIR}/.script_version_cache")
                    if [[ -n "$script_remote_commit" ]]; then
                        if [[ "$script_remote_commit" != "$SCRIPT_COMMIT" ]]; then
                            gum style --foreground 99 "检测到新版本可用"
                            echo ""
                            if gum confirm "是否立即更新脚本？"; then
                                if gum spin --spinner dot --title "正在拉取最新代码..." -- \
                                    git -C "${SCRIPT_DIR}" pull origin main; then
                                    # 清除版本缓存
                                    rm -f "${SCRIPT_DIR}/.script_version_cache" "${SCRIPT_DIR}/.version_updated"
                                    gum style --foreground 212 "更新成功！"
                                    gum style --foreground 99 "请重启脚本以应用新版本"
                                    echo ""
                                    if gum confirm "是否立即重启脚本？"; then
                                        exec bash "$0"
                                    fi
                                else
                                    gum style --foreground 196 "更新失败，请检查网络或手动执行 git pull"
                                fi
                            fi
                        else
                            gum style --foreground 212 "已是最新版本"
                        fi
                    fi
                else
                    gum style --foreground 245 "正在检测远程版本..."
                fi
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            7)
                set_autostart
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            8)
                uninstall_script
                ;;
            0) 
                cleanup
                exit 0 
                ;;
            *) echo "无效选项" ; sleep 1 ;;
        esac
    done
}

# 启动主程序
main

# 脚本正常结束时清理
cleanup