#!/bin/bash

# 终端标题
printf "ST_Chatelaine"

# 脚本信息
SCRIPT_DIR_INIT="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_COMMIT=$(git -C "${SCRIPT_DIR_INIT}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
SCRIPT_REPO="https://github.com/Liu-fucheng/ST_Chatelaine"

# 获取脚本本地版本
get_script_version() {
    if [[ -d "${SCRIPT_DIR_INIT}/.git" ]]; then
        git -C "${SCRIPT_DIR_INIT}" describe --tags --abbrev=0 2>/dev/null || echo "v1.0.0"
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

trap 'cleanup "interrupted"; cd "$HOME"; exit 1' INT TERM HUP

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
                HIGH_PERFORMANCE) HIGH_PERFORMANCE="$value" ;;
                CUSTOM_SCRIPT_NAME) CUSTOM_SCRIPT_NAME="$value" ;;
                CUSTOM_SCRIPT_PATH) CUSTOM_SCRIPT_PATH="$value" ;;
                CUSTOM_SCRIPT_TYPE) CUSTOM_SCRIPT_TYPE="$value" ;;
            esac
        done < "$CONFIG_FILE"
    else
        first_run=true
    fi
    
    # 设置默认值
    [[ -z "$AUTOSTART" ]] && AUTOSTART="false"
    [[ -z "$HIGH_PERFORMANCE" ]] && HIGH_PERFORMANCE="false"
    
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
HIGH_PERFORMANCE=$HIGH_PERFORMANCE
EOF
    
    # 保存自定义脚本配置（如果存在）
    if [[ -n "$CUSTOM_SCRIPT_NAME" ]] && [[ -n "$CUSTOM_SCRIPT_PATH" ]]; then
        echo "CUSTOM_SCRIPT_NAME=$CUSTOM_SCRIPT_NAME" >> "$CONFIG_FILE"
        echo "CUSTOM_SCRIPT_PATH=$CUSTOM_SCRIPT_PATH" >> "$CONFIG_FILE"
        echo "CUSTOM_SCRIPT_TYPE=$CUSTOM_SCRIPT_TYPE" >> "$CONFIG_FILE"
    fi
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
        # 查找最新的备份文件（不限时间）
        local latest_backup=""
        local latest_time=0
        
        for backup_file in "${backup_dir}"/ST_Backup_*.tar.gz; do
            [[ -f "$backup_file" ]] || continue
            # 跳过手动备份
            [[ "$backup_file" == *"_manual.tar.gz" ]] && continue
            
            local file_time=$(stat -c %Y "$backup_file" 2>/dev/null || stat -f %m "$backup_file" 2>/dev/null)
            if [[ $file_time -gt $latest_time ]]; then
                latest_time=$file_time
                latest_backup="$backup_file"
            fi
        done
        
        if [[ -n "$latest_backup" ]]; then
            local now=$(date +%s)
            local age_seconds=$(( now - latest_time ))
            local age_minutes=$(( age_seconds / 60 ))
            local age_hours=$(( age_seconds / 3600 ))
            local age_days=$(( age_seconds / 86400 ))
            
            # 格式化时间显示
            local time_display=""
            if [[ $age_days -gt 0 ]]; then
                time_display="${age_days} 天"
            elif [[ $age_hours -gt 0 ]]; then
                time_display="${age_hours} 小时"
            else
                time_display="${age_minutes} 分钟"
            fi
            
            gum style --foreground 99 "检测到 ${time_display} 前备份的文件："
            gum style --foreground 245 "  $(basename "$latest_backup")"
            
            if ! gum confirm "是否继续备份？"; then
                # 如果备份超过3天，再次确认
                if [[ $age_days -ge 3 ]]; then
                    gum style --foreground 196 --bold "警告: 上次备份已超过 ${age_days} 天"
                    if ! gum confirm "确认不进行备份吗？"; then
                        gum style --foreground 99 "开始备份..."
                    else
                        gum style --foreground 99 "已取消备份"
                        return 0
                    fi
                else
                    gum style --foreground 99 "已取消备份"
                    return 0
                fi
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

    # 检查是否安装了 pv
    if command -v pv &> /dev/null && [[ -n "$TOTAL_SIZE" ]] && [[ $TOTAL_SIZE -gt 0 ]]; then
        # 使用 pv 显示详细进度
        local TOTAL_SIZE_MB=$(echo "scale=2; $TOTAL_SIZE / 1048576" | bc)
        gum style --foreground 212 "数据大小: ${TOTAL_SIZE_MB} MB"
        gum style --foreground 99 "开始打包..."
        echo ""
        
        if tar -c -C "$ST_DIR" "${TARGETS[@]}" 2>"$ERROR_LOG" | \
            pv -s "$TOTAL_SIZE" -p -t -e -r -b -N "打包进度" | \
            gzip > "$BACKUP_PATH"; then
            local EXIT_CODE=0
        else
            local EXIT_CODE=$?
        fi
    else
        # 如果没有 pv，使用原来的方式
        if [[ ! $(command -v pv) ]]; then
            gum style --foreground 245 "提示: 安装 pv 可显示详细进度 (pkg install pv)"
        fi
        
        (tar -czf "$BACKUP_PATH" -C "$ST_DIR" "${TARGETS[@]}" 2>"$ERROR_LOG") &
        local tar_pid=$!
        
        gum spin --spinner dot --title "正在打包数据，请稍候..." -- sh -c "while kill -0 $tar_pid 2>/dev/null; do sleep 0.1; done"
        
        wait $tar_pid
        local EXIT_CODE=$?
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


# 清理备份文件（多选删除）
manage_backups_interactive() {
    local backup_dir="${SCRIPT_DIR}/backups"
    
    if [[ ! -d "$backup_dir" ]]; then
        gum style --foreground 196 "错误: 备份目录不存在"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
    
    local all_backups=()
    for backup_file in "${backup_dir}"/ST_Backup_*.tar.gz; do
        [[ -f "$backup_file" ]] || continue
        all_backups+=("$backup_file")
    done
    
    if [[ ${#all_backups[@]} -eq 0 ]]; then
        gum style --foreground 196 "当前没有备份文件"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
    
    # 按时间排序（最新的在前）
    IFS=$'\n' all_backups=($(ls -t "${all_backups[@]}" 2>/dev/null))
    unset IFS
    
    gum style --foreground 212 --bold "备份文件列表"
    gum style --foreground 245 "提示: 空格键多选，回车确认删除，Esc取消"
    echo ""
    
    # 格式化备份列表显示
    local backup_list=$(mktemp)
    TEMP_FILES+=("$backup_list")
    
    for backup_file in "${all_backups[@]}"; do
        local filename=$(basename "$backup_file")
        local size=$(du -h "$backup_file" | cut -f1)
        local file_time=$(stat -c %Y "$backup_file" 2>/dev/null || stat -f %m "$backup_file" 2>/dev/null)
        local date_str=$(date -d "@$file_time" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$file_time" '+%Y-%m-%d %H:%M' 2>/dev/null)
        
        local type_tag="[自动]"
        [[ "$filename" == *"_manual.tar.gz" ]] && type_tag="[手动]"
        
        echo "${date_str} | ${size} | ${type_tag} ${filename}" >> "$backup_list"
    done
    
    local selected_lines=$(cat "$backup_list" | gum choose --no-limit --height=15 --header="选择要删除的备份文件（可多选）")
    
    if [[ -z "$selected_lines" ]]; then
        gum style --foreground 99 "已取消删除"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 0
    fi
    
    # 提取文件名并确认删除
    local delete_count=0
    local delete_files=()
    
    while IFS= read -r line; do
        local filename=$(echo "$line" | awk -F' \\| ' '{print $NF}' | sed 's/^\[.*\] //')
        delete_files+=("${backup_dir}/${filename}")
        ((delete_count++))
    done <<< "$selected_lines"
    
    echo ""
    gum style --foreground 196 --bold "即将删除 ${delete_count} 个备份文件"
    if ! gum confirm "确认删除这些备份文件吗？"; then
        gum style --foreground 99 "已取消删除"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 0
    fi
    
    # 执行删除
    for file in "${delete_files[@]}"; do
        if [[ -f "$file" ]]; then
            gum style --foreground 245 "删除: $(basename "$file")"
            rm -f "$file"
        fi
    done
    
    gum style --foreground 212 "已删除 ${delete_count} 个备份文件"
    read -n 1 -s -r -p "按任意键返回主菜单..."
    return 0
}

# 还原备份文件
restore_backup_interactive() {
    local backup_dir="${SCRIPT_DIR}/backups"
    
    if [[ ! -d "$backup_dir" ]]; then
        gum style --foreground 196 "错误: 备份目录不存在"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
    
    local all_backups=()
    for backup_file in "${backup_dir}"/ST_Backup_*.tar.gz; do
        [[ -f "$backup_file" ]] || continue
        all_backups+=("$backup_file")
    done
    
    if [[ ${#all_backups[@]} -eq 0 ]]; then
        gum style --foreground 196 "当前没有备份文件"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
    
    # 按时间排序（最新的在前）
    IFS=$'\n' all_backups=($(ls -t "${all_backups[@]}" 2>/dev/null))
    unset IFS
    
    local latest_backup="${all_backups[0]}"
    local selected_backup=""
    
    # 询问是否还原最新备份
    gum style --foreground 212 "最新备份文件: $(basename "$latest_backup")"
    local size=$(du -h "$latest_backup" | cut -f1)
    local file_time=$(stat -c %Y "$latest_backup" 2>/dev/null || stat -f %m "$latest_backup" 2>/dev/null)
    local date_str=$(date -d "@$file_time" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$file_time" '+%Y-%m-%d %H:%M' 2>/dev/null)
    gum style --foreground 245 "创建时间: ${date_str} | 大小: ${size}"
    echo ""
    
    if gum confirm "是否还原此备份文件？"; then
        selected_backup="$latest_backup"
    else
        # 显示备份列表供选择
        gum style --foreground 212 --bold "备份文件列表"
        gum style --foreground 245 "提示: 回车选择，Esc取消"
        echo ""
        
        local backup_list=$(mktemp)
        TEMP_FILES+=("$backup_list")
        
        for backup_file in "${all_backups[@]}"; do
            local filename=$(basename "$backup_file")
            local size=$(du -h "$backup_file" | cut -f1)
            local file_time=$(stat -c %Y "$backup_file" 2>/dev/null || stat -f %m "$backup_file" 2>/dev/null)
            local date_str=$(date -d "@$file_time" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$file_time" '+%Y-%m-%d %H:%M' 2>/dev/null)
            
            local type_tag="[自动]"
            [[ "$filename" == *"_manual.tar.gz" ]] && type_tag="[手动]"
            
            echo "${date_str} | ${size} | ${type_tag} ${filename}" >> "$backup_list"
        done
        
        local selected_line=$(cat "$backup_list" | gum filter --placeholder="搜索备份..." --height=15 --header="选择要还原的备份文件")
        
        if [[ -z "$selected_line" ]]; then
            gum style --foreground 99 "已取消还原"
            read -n 1 -s -r -p "按任意键返回主菜单..."
            return 0
        fi
        
        local filename=$(echo "$selected_line" | awk -F' \\| ' '{print $NF}' | sed 's/^\[.*\] //')
        selected_backup="${backup_dir}/${filename}"
    fi
    
    # 检查目标路径数据
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
    
    # 如果目标路径有数据，警告可能冲突
    if [[ $total_count -ge $total_limit ]]; then
        echo ""
        gum style --foreground 99 --bold "检测到酒馆存在用户数据 (${total_count} 个文件)"
        gum style --foreground 245 "还原备份将与现有数据合并，可能覆盖同名文件"
        echo ""
        if ! gum confirm "是否确认合并还原？"; then
            gum style --foreground 99 "已取消还原"
            read -n 1 -s -r -p "按任意键返回主菜单..."
            return 0
        fi
    fi
    
    # 执行还原
    echo ""
    gum style --foreground 99 "正在还原备份..."
    if tar -xzf "$selected_backup" -C "$ST_DIR" 2>/dev/null; then
        gum style --foreground 212 "备份还原完成！"
    else
        gum style --foreground 196 "还原失败，请检查备份文件完整性"
    fi
    
    read -n 1 -s -r -p "按任意键返回主菜单..."
    return 0
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
    
    if [[ -z "$remote_tag" ]]; then
        remote_tag=$(timeout 3s git ls-remote --tags --sort='v:refname' https://hk.gh-proxy.org/https://github.com/SillyTavern/SillyTavern.git 2>/dev/null | tail -n1 | sed 's/.*\///; s/\^{}//')
    fi
    
    echo "$remote_tag"
}

# 获取脚本最新版本和commit
get_script_remote_version() {
    local remote_commit=$(timeout 3s git ls-remote https://github.com/Liu-fucheng/ST_Chatelaine.git HEAD 2>/dev/null | cut -f1 | cut -c1-7)
    
    if [[ -z "$remote_commit" ]]; then
        remote_commit=$(timeout 3s git ls-remote https://hk.gh-proxy.org/https://github.com/Liu-fucheng/ST_Chatelaine.git HEAD 2>/dev/null | cut -f1 | cut -c1-7)
    fi
    
    echo "$remote_commit"
}

# 设置 Git 远程仓库地址（优先直连，失败后使用镜像）
setup_git_remote() {
    local repo_path="$1"
    local original_url="$2"
    local mirror_url="https://hk.gh-proxy.org/$original_url"
    
    # 尝试直连
    if timeout 3s git ls-remote "$original_url" HEAD &>/dev/null; then
        git -C "$repo_path" remote set-url origin "$original_url" 2>/dev/null || true
        return 0
    else
        # 使用镜像源
        git -C "$repo_path" remote set-url origin "$mirror_url" 2>/dev/null || true
        gum style --foreground 99 "网络不佳，已切换至镜像源"
        return 1
    fi
}

# 后台预加载远程版本（SillyTavern和脚本）
preload_remote_version() {
    (
        # 加载 SillyTavern 版本
        REMOTE_VER=$(get_remote_version)
        if [[ -n "$REMOTE_VER" ]]; then
            echo "$REMOTE_VER" > "${SCRIPT_DIR}/.remote_version_cache"

            touch "${SCRIPT_DIR}/.version_updated"
        fi
        
        # 加载脚本commit
        SCRIPT_REMOTE_COMMIT=$(get_script_remote_version)
        if [[ -n "$SCRIPT_REMOTE_COMMIT" ]]; then
            echo "$SCRIPT_REMOTE_COMMIT" > "${SCRIPT_DIR}/.script_version_cache"
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
    
    local current_branch=""
    if [[ -d "${ST_DIR}/.git" ]]; then
        current_branch=$(git -C "$ST_DIR" branch --show-current 2>/dev/null)
    fi
    
    if [[ -f "${SCRIPT_DIR}/.remote_version_cache" ]]; then
        REMOTE_VER=$(cat "${SCRIPT_DIR}/.remote_version_cache")
    fi

    if [[ -z "$REMOTE_VER" ]]; then
        REMOTE_VER="检测中..."
    fi

    if [[ -n "$current_branch" && "$current_branch" != "release" ]]; then
        gum style --foreground 255 "酒馆本地版本: ${LOCAL_VER} (${current_branch})"
        gum style --foreground 255 "酒馆最新版本: ${REMOTE_VER} (Release)"
    else
        gum style --foreground 255 "酒馆本地版本: ${LOCAL_VER}"
        gum style --foreground 255 "酒馆最新版本: ${REMOTE_VER}"
    fi
    

    if [[ "$LOCAL_VER" == "Unknown" ]]; then
        gum style --foreground 196 "状态: 无法识别本地 Git 版本"
    elif [[ "$REMOTE_VER" == "检测中..." ]] || [[ "$REMOTE_VER" == "--" ]]; then
        gum style --foreground 245 "状态: 正在检测远程版本..."
    elif [[ "$LOCAL_VER" == "$REMOTE_VER" ]]; then
        gum style --foreground 212 "状态: 已是最新版本"
    else
        gum style --foreground 99 "状态: 有新版本可用"
    fi
    
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
    
    # 设置远程仓库地址
    setup_git_remote "$ST_DIR" "https://github.com/SillyTavern/SillyTavern.git"

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
    
    # 检测当前分支
    local current_branch=$(git -C "$ST_DIR" branch --show-current 2>/dev/null)
    if [[ -n "$current_branch" ]]; then
        gum style --foreground 99 "当前分支: ${current_branch}"
    fi
    echo ""
    
    # 获取所有tags并标注所属分支
    gum style --foreground 245 "正在加载版本列表..."
    local tag_list=$(mktemp)
    TEMP_FILES+=("$tag_list")
    
    # 获取所有tags及其日期
    git -C "$ST_DIR" tag --sort=-creatordate --format='%(creatordate:short)|%(refname:short)' > "$tag_list"
    
    # 为每个tag标注所属分支
    local formatted_tags=$(mktemp)
    TEMP_FILES+=("$formatted_tags")
    
    while IFS='|' read -r date tag; do
        # 检查tag属于哪些分支
        local all_branches=$(git -C "$ST_DIR" branch -r --contains "$tag" 2>/dev/null | grep -v HEAD | sed 's/origin\///' | sed 's/^[ \t]*//')
        
        if [[ -z "$all_branches" ]]; then
            echo "${date} | ${tag} | (未合并)"
            continue
        fi
        
        local display_branches=""
        if [[ "$current_branch" == "release" ]] || [[ -z "$current_branch" ]]; then
            if echo "$all_branches" | grep -q "^release$"; then
                echo "${date} | ${tag}"
            fi
        else
            local filtered_branches=""
            while IFS= read -r branch; do
                if [[ "$branch" == "release" ]] || [[ "$branch" == "$current_branch" ]]; then
                    if [[ -z "$filtered_branches" ]]; then
                        filtered_branches="$branch"
                    else
                        filtered_branches="${filtered_branches},${branch}"
                    fi
                fi
            done <<< "$all_branches"
            
            if [[ -n "$filtered_branches" ]]; then
                echo "${date} | ${tag} | (${filtered_branches})"
            fi
        fi
    done < "$tag_list" > "$formatted_tags"
    
    local selected_line=$(cat "$formatted_tags" | gum filter --placeholder="搜索版本号..." --height=15 --header="选择要切换的版本")
    
    if [[ -z "$selected_line" ]]; then
        gum style --foreground 99 "已取消版本切换"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
    
    # 提取tag名称（第二列）
    local selected_tag=$(echo "$selected_line" | awk -F' \\| ' '{print $2}')
    
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
    
    if ! backup_st; then
        gum style --foreground 196 "备份失败，取消切换"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
    
    # 设置远程仓库地址
    setup_git_remote "$ST_DIR" "https://github.com/SillyTavern/SillyTavern.git"
    
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
                    
                    # 找到系统默认内容的结束标记（bash_completion 之后）
                    # 匹配可能有或没有 # 的情况
                    local marker_line=$(grep -n "enable programmable completion features" "$bashrc" | tail -1 | cut -d: -f1)
                    
                    if [[ -n "$marker_line" ]]; then
                        # 找到标记后的 fi 或 #fi 行（允许前后有空格）
                        local end_line=$(tail -n +$((marker_line)) "$bashrc" | grep -n "^[ \t]*#\?fi[ \t]*$" | head -1 | cut -d: -f1)
                        if [[ -n "$end_line" ]]; then
                            end_line=$((marker_line + end_line))
                        else
                            end_line=$marker_line
                        fi
                        
                        # 创建临时文件
                        local temp_file=$(mktemp)
                        
                        # 保留前面的系统默认内容
                        head -n $end_line "$bashrc" > "$temp_file"
                        
                        # 注释用户添加的所有非空行和非纯注释行
                        # 保留已经是注释的行，保留空行
                        tail -n +$((end_line + 1)) "$bashrc" | sed -E '
                            # 跳过空行
                            /^[ \t]*$/b
                            # 跳过已经是注释的行
                            /^[ \t]*#/b
                            # 其他所有行都在行首（保留缩进后）添加 #
                            s/^([ \t]*)(.+)$/\1# \2/
                        ' >> "$temp_file"
                        
                        # 替换原文件
                        mv "$temp_file" "$bashrc"
                    else
                        # 如果找不到标记，使用旧方法但更谨慎
                        gum style --foreground 196 "警告: 无法识别系统默认内容边界"
                        gum style --foreground 99 "建议选择'查看后决定'或'共存'选项"
                        return
                    fi
                    
                    # 添加此脚本
                    echo "" >> "$bashrc"
                    echo "$autostart_line" >> "$bashrc"
                    AUTOSTART="true"
                    save_config
                    
                    gum style --foreground 212 "✓ 已注释用户启动代码并设置此脚本为自启动"
                    gum style --foreground 245 "原配置已备份到: ${bashrc}.backup.*"
                    gum style --foreground 99 "提示: 系统默认的 .bashrc 内容已保留"
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
    

    local uninstall_script="${HOME}/.uninstall_st_chatelaine.sh"
    
    cat > "$uninstall_script" << 'UNINSTALL_EOF'
#!/bin/bash
sleep 1
if [[ -d "${1}" ]]; then
    rm -rf "${1}"
    echo "✓ 脚本目录已删除: ${1}"
else
    echo "✓ 目录已不存在: ${1}"
fi
echo "脚本已卸载完成！"
sleep 2
rm -f "$0"
UNINSTALL_EOF
    
    chmod +x "$uninstall_script"
    
    gum style --foreground 212 "卸载完成！感谢使用 ST_Chatelaine"
    sleep 1
    
    exec bash "$uninstall_script" "${SCRIPT_DIR}"
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
    
    # 先尝试直连克隆
    if gum spin --spinner globe --title "克隆 SillyTavern 仓库..." -- \
        git clone https://github.com/SillyTavern/SillyTavern -b release "$install_dir" 2>/dev/null; then
        ST_DIR="$install_dir"
        save_config
        gum style --foreground 212 "酒馆安装成功！路径: $ST_DIR"
        return 0
    else
        # 直连失败，尝试镜像源
        gum style --foreground 99 "直连失败，尝试使用镜像源..."
        if gum spin --spinner globe --title "使用镜像源克隆..." -- \
            git clone https://hk.gh-proxy.org/https://github.com/SillyTavern/SillyTavern -b release "$install_dir"; then
            ST_DIR="$install_dir"
            save_config
            gum style --foreground 212 "酒馆安装成功！路径: $ST_DIR"
            return 0
        else
            gum style --foreground 196 "安装失败，请检查网络连接"
            return 1
        fi
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
        gum style --foreground 245 "作者: 柳拂城"
        gum style --foreground 245 "GitHub地址: ${SCRIPT_REPO}"
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
                0) cd "$HOME"; exit 0 ;;
                *) ;;
            esac
            continue
        fi

        check_version_status
        echo "----------------------------------------"
        echo "1. 启动酒馆"
        echo "2. 酒馆版本操作 (更新/切换版本/分支)"
        echo "3. 安装/重装酒馆依赖"
        echo "4. 备份相关"
        echo "5. 脚本相关"
        echo "6. 设置"
        if [[ -n "$CUSTOM_SCRIPT_NAME" ]] && [[ -n "$CUSTOM_SCRIPT_PATH" ]]; then
            echo "7. $CUSTOM_SCRIPT_NAME"
        fi
        echo "0. 退出"
        echo "----------------------------------------"
        read -n 1 -s -r -p "请输入: " choice
        echo ""
        
        in_main_menu=false

        case $choice in
            1)
                trap - INT TERM HUP
                
                gum style --foreground 212 "正在启动酒馆..."
                if [[ "$HIGH_PERFORMANCE" == "true" ]]; then
                    gum style --foreground 99 "高性能模式: 已启用 (8GB 内存上限)"
                fi
                gum style --foreground 99 "提示: 按 Ctrl+C 可返回主菜单"
                echo ""
                
                if [[ "$HIGH_PERFORMANCE" == "true" ]]; then
                    cd "${ST_DIR}" && NODE_OPTIONS="--max-old-space-size=8192" node server.js
                    local exit_code=$?
                else
                    bash "${ST_DIR}/start.sh"
                    local exit_code=$?
                fi
                
                trap 'cleanup "interrupted"; cd "$HOME"; exit 1' INT TERM HUP
                
                gum style --foreground 212 "酒馆已停止"
                
                # 检测内存泄漏错误码
                if [[ $exit_code -eq 134 ]] || [[ $exit_code -eq 137 ]]; then
                    if [[ "$HIGH_PERFORMANCE" != "true" ]]; then
                        echo ""
                        gum style --foreground 196 --bold "检测到内存不足错误 (退出码: $exit_code)"
                        gum style --foreground 99 "建议启用高性能模式以分配更多内存"
                        echo ""
                        if gum confirm "是否立即启用高性能模式？"; then
                            HIGH_PERFORMANCE="true"
                            save_config
                            gum style --foreground 212 "已启用高性能模式，下次启动将自动应用"
                            echo ""
                            if gum confirm "是否立即重启酒馆？"; then
                                continue
                            fi
                        fi
                    else
                        gum style --foreground 196 "警告: 即使在高性能模式下仍遇到内存问题 (退出码: $exit_code)"
                    fi
                fi
                
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
                    read -n 1 -s -r -p "请输入: " sub_choice
                    echo ""
                    
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
                gum style --foreground 212 "开始安装/重装酒馆依赖..."
                echo ""
                
                if [[ ! -d "$ST_DIR" ]]; then
                    gum style --foreground 196 "错误: 酒馆目录不存在 ($ST_DIR)"
                    read -n 1 -s -r -p "按任意键返回主菜单..."
                    continue
                fi
                
                cd "$ST_DIR" || {
                    gum style --foreground 196 "错误: 无法进入酒馆目录"
                    read -n 1 -s -r -p "按任意键返回主菜单..."
                    continue
                }
                
                if [[ ! -f "package.json" ]]; then
                    gum style --foreground 196 "错误: 未找到 package.json 文件"
                    read -n 1 -s -r -p "按任意键返回主菜单..."
                    continue
                fi
                
                if ! command -v npm &> /dev/null; then
                    gum style --foreground 196 "错误: npm 未安装，请先安装 Node.js"
                    read -n 1 -s -r -p "按任意键返回主菜单..."
                    continue
                fi
                
                gum style --foreground 99 "当前工作目录: $ST_DIR"
                echo ""
                
                if [[ -d "node_modules" ]]; then
                    if gum confirm "检测到已有依赖，是否清理后重新安装？"; then
                        gum style --foreground 212 "正在清理旧依赖..."
                        if gum spin --spinner dot --title "删除 node_modules..." -- \
                            rm -rf node_modules package-lock.json; then
                            gum style --foreground 212 "清理成功"
                        else
                            gum style --foreground 196 "清理失败，将尝试直接更新依赖"
                        fi
                        echo ""
                    fi
                fi
                
                # 安装依赖
                gum style --foreground 212 "正在安装 npm 依赖..."
                echo ""
                echo "----------------------------------------"
                
                if npm install; then
                    echo "----------------------------------------"
                    echo ""
                    gum style --foreground 212 "✓ 依赖安装成功！"
                else
                    echo "----------------------------------------"
                    echo ""
                    gum style --foreground 196 "✗ 依赖安装失败"
                    gum style --foreground 99 "请检查网络连接或手动执行 'cd $ST_DIR && npm install'"
                fi
                
                echo ""
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            4)
                while true; do
                    clear
                    echo "----------------------------------------"
                    echo " 备份相关菜单"
                    echo "----------------------------------------"
                    echo "1. 手动备份酒馆文件"
                    echo "2. 清理备份文件"
                    echo "3. 还原备份文件"
                    echo "0. 返回主菜单"
                    echo "----------------------------------------"
                    read -n 1 -s -r -p "请输入: " backup_choice
                    echo ""
                    
                    case $backup_choice in
                        1)
                            gum style --foreground 99 "开始手动备份..."
                            if backup_st "manual"; then
                                gum style --foreground 212 "备份成功"
                            else
                                gum style --foreground 196 "备份失败"
                            fi
                            read -n 1 -s -r -p "按任意键返回备份菜单..."
                            ;;
                        2)
                            manage_backups_interactive
                            ;;
                        3)
                            restore_backup_interactive
                            ;;
                        0) break ;;
                        *) echo "无效选项" ; sleep 1 ;;
                    esac
                done
                ;;
            5)
                while true; do
                    clear
                    echo "----------------------------------------"
                    echo " 脚本相关菜单"
                    echo "----------------------------------------"
                    echo "1. 更新脚本"
                    if [[ "$AUTOSTART" == "true" ]]; then
                        echo "2. 取消脚本自启动"
                    else
                        echo "2. 设置脚本自启动"
                    fi
                    echo "3. 卸载脚本"
                    echo "0. 返回主菜单"
                    echo "----------------------------------------"
                    read -n 1 -s -r -p "请输入: " script_choice
                    echo ""
                    
                    case $script_choice in
                        1)
                            gum style --foreground 212 "脚本当前版本: $(get_script_version)"
                            if [[ -f "${SCRIPT_DIR}/.script_version_cache" ]]; then
                                local script_remote_commit=$(cat "${SCRIPT_DIR}/.script_version_cache")
                                if [[ -n "$script_remote_commit" ]]; then
                                    if [[ "$script_remote_commit" != "$SCRIPT_COMMIT" ]]; then
                                        gum style --foreground 99 "检测到新版本可用"
                                        echo ""
                                        if gum confirm "是否立即更新脚本？"; then
                                            # 设置远程仓库地址
                                            setup_git_remote "${SCRIPT_DIR}" "https://github.com/Liu-fucheng/ST_Chatelaine.git"
                                            
                                            if gum spin --spinner dot --title "正在拉取最新代码..." -- \
                                                git -C "${SCRIPT_DIR}" pull origin main; then
                                                rm -f "${SCRIPT_DIR}/.script_version_cache" "${SCRIPT_DIR}/.version_updated"
                                                gum style --foreground 212 "更新成功！"
                                                gum style --foreground 99 "请重启脚本以应用新版本"
                                                echo ""
                                                if gum confirm "是否立即重启脚本？"; then
                                                    exec bash "${SCRIPT_DIR}/$(basename "$0")"
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
                                sleep 2
                                
                                local remote_commit=$(get_script_remote_version)
                                if [[ -n "$remote_commit" ]]; then
                                    echo "$remote_commit" > "${SCRIPT_DIR}/.script_version_cache"
                                    if [[ "$remote_commit" != "$SCRIPT_COMMIT" ]]; then
                                        gum style --foreground 99 "检测到新版本可用"
                                        echo ""
                                        if gum confirm "是否立即更新脚本？"; then
                                            # 设置远程仓库地址
                                            setup_git_remote "${SCRIPT_DIR}" "https://github.com/Liu-fucheng/ST_Chatelaine.git"
                                            
                                            if gum spin --spinner dot --title "正在拉取最新代码..." -- \
                                                git -C "${SCRIPT_DIR}" pull origin main; then
                                                rm -f "${SCRIPT_DIR}/.script_version_cache" "${SCRIPT_DIR}/.version_updated"
                                                gum style --foreground 212 "更新成功！"
                                                gum style --foreground 99 "请重启脚本以应用新版本"
                                                echo ""
                                                if gum confirm "是否立即重启脚本？"; then
                                                    exec bash "${SCRIPT_DIR}/$(basename "$0")"
                                                fi
                                            else
                                                gum style --foreground 196 "更新失败，请检查网络或手动执行 git pull"
                                            fi
                                        fi
                                    else
                                        gum style --foreground 212 "已是最新版本"
                                    fi
                                else
                                    gum style --foreground 196 "网络连接失败，无法检测远程版本"
                                fi
                            fi
                            read -n 1 -s -r -p "按任意键返回脚本菜单..."
                            ;;
                        2)
                            set_autostart
                            read -n 1 -s -r -p "按任意键返回脚本菜单..."
                            ;;
                        3)
                            uninstall_script
                            ;;
                        0) break ;;
                        *) echo "无效选项" ; sleep 1 ;;
                    esac
                done
                ;;
            6)
                while true; do
                    clear
                    echo "----------------------------------------"
                    echo " 设置菜单"
                    echo "----------------------------------------"
                    echo "1. 修改酒馆路径"
                    echo "2. 酒馆高性能模式启动 (防止内存泄漏)"
                    echo "3. 设置备份上限 (当前为: ${BACKUP_LIMIT})"
                    echo "4. 添加其它脚本启动方式至主菜单"
                    echo "0. 返回主菜单"
                    echo "----------------------------------------"
                    read -n 1 -s -r -p  "请输入: " setting_choice
                    echo ""

                    case $setting_choice in
                        1)
                            ST_DIR=$(select_dir_gui "${ST_DIR:-$HOME}")
                            save_config
                            echo "已指定酒馆路径为: $ST_DIR"
                            read -n 1 -s -r -p "按任意键返回设置菜单..."
                            ;;
                        2)
                            if [[ "$HIGH_PERFORMANCE" == "true" ]]; then
                                gum style --foreground 99 "当前状态: 已启用高性能模式"
                                echo ""
                                if gum confirm "是否关闭高性能模式？"; then
                                    HIGH_PERFORMANCE="false"
                                    save_config
                                    gum style --foreground 212 "已关闭高性能模式"
                                else
                                    gum style --foreground 99 "保持高性能模式"
                                fi
                            else
                                gum style --foreground 99 "当前状态: 未启用高性能模式"
                                gum style --foreground 245 "说明: 启用后将使用 8GB 内存上限，可防止内存泄漏"
                                echo ""
                                if gum confirm "是否启用高性能模式？"; then
                                    HIGH_PERFORMANCE="true"
                                    save_config
                                    gum style --foreground 212 "已启用高性能模式"
                                else
                                    gum style --foreground 99 "保持默认模式"
                                fi
                            fi
                            read -n 1 -s -r -p "按任意键返回设置菜单..."
                            ;;
                        3)
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
                        4)
                            gum style --foreground 212 --bold "添加其它脚本启动方式至主菜单"
                            echo ""
                            gum style --foreground 245 "说明: 将自定义脚本或命令添加到主菜单，方便快速启动"
                            echo ""
                            
                            local script_name=$(gum input --placeholder "输入脚本显示名称" --prompt "名称: " --width 40)
                            if [[ -z "$script_name" ]]; then
                                gum style --foreground 99 "已取消添加"
                                read -n 1 -s -r -p "按任意键返回设置菜单..."
                                continue
                            fi
                            
                            # 选择类型
                            local script_type=$(gum choose "脚本文件 (需要bash执行)" "可执行命令 (如syncthing)" --header="选择类型")
                            
                            if [[ "$script_type" == "脚本文件 (需要bash执行)" ]]; then
                                local script_path=$(gum input --placeholder "输入脚本完整路径" --prompt "路径: " --width 60)
                                if [[ -z "$script_path" ]]; then
                                    gum style --foreground 99 "已取消添加"
                                    read -n 1 -s -r -p "按任意键返回设置菜单..."
                                    continue
                                fi
                                
                                # 验证路径是否存在
                                if [[ ! -f "$script_path" ]]; then
                                    gum style --foreground 196 "错误: 脚本文件不存在"
                                    read -n 1 -s -r -p "按任意键返回设置菜单..."
                                    continue
                                fi
                                
                                CUSTOM_SCRIPT_TYPE="file"
                            else
                                local script_path=$(gum input --placeholder "输入命令名称 (如syncthing)" --prompt "命令: " --width 40)
                                if [[ -z "$script_path" ]]; then
                                    gum style --foreground 99 "已取消添加"
                                    read -n 1 -s -r -p "按任意键返回设置菜单..."
                                    continue
                                fi
                                
                                CUSTOM_SCRIPT_TYPE="command"
                            fi
                            
                            # 保存到配置文件
                            CUSTOM_SCRIPT_NAME="$script_name"
                            CUSTOM_SCRIPT_PATH="$script_path"
                            save_config
                            
                            gum style --foreground 212 "已添加自定义脚本: $script_name"
                            gum style --foreground 99 "提示: 请重启脚本以在主菜单中看到此选项"
                            read -n 1 -s -r -p "按任意键返回设置菜单..."
                            ;;
                        0) break ;;
                        *) echo "无效选项" ; sleep 1 ;;
                    esac
                done
                ;;
            7)
                if [[ -n "$CUSTOM_SCRIPT_NAME" ]] && [[ -n "$CUSTOM_SCRIPT_PATH" ]]; then
                    gum style --foreground 212 "正在启动: $CUSTOM_SCRIPT_NAME"
                    echo ""
                    
                    if [[ "$CUSTOM_SCRIPT_TYPE" == "command" ]]; then
                        # 直接执行命令
                        $CUSTOM_SCRIPT_PATH
                    else
                        # 执行脚本文件
                        if [[ -f "$CUSTOM_SCRIPT_PATH" ]]; then
                            bash "$CUSTOM_SCRIPT_PATH"
                        else
                            gum style --foreground 196 "错误: 脚本文件不存在"
                            gum style --foreground 99 "路径: $CUSTOM_SCRIPT_PATH"
                        fi
                    fi
                    
                    read -n 1 -s -r -p "按任意键返回主菜单..."
                else
                    gum style --foreground 196 "未配置自定义脚本"
                    read -n 1 -s -r -p "按任意键返回主菜单..."
                fi
                ;;
            0) 
                cd "$HOME"
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
cd "$HOME"
cleanup