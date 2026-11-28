#!/bin/bash

# tagger.sh
# 管理依赖目录下的 .depped_* 标记文件（记录“谁依赖了我”）。
# 标记文件为空文件，一个依赖者一个：
#   .depped_{名字}@{版本号}
#
# 不再区分依赖者是「包」还是「依赖」：0.1.0 起两者在布局上同构
# （Shore/<名>/<版本>，见 configpaths），而「谁依赖我」这个问题的答案与它
# 本身是什么无关。要判断某个东西是不是用户主动装的，看它的 Note.requested。
#
# 命令行用法：
#   bash tagger.sh create <标记目录> <名字> <版本号>
#   bash tagger.sh delete <标记目录> <名字> <版本号>
#   bash tagger.sh has-marks <标记目录>   # 退出码 0=还有标记，1=无标记
#
# 也可被其他脚本 source 后调用 tagger_create / tagger_delete / tagger_has_any。

set -e

# -------------------- 颜色定义 --------------------

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

# -------------------- 标记函数 --------------------

tagger_mark_name() {
    # 生成标记文件名
    local name="$1"
    local version="$2"
    echo ".depped_${name}@${version}"
}

tagger_create() {
    # 创建一个空标记文件，重复创建不报错
    local dir="$1"
    local name="$2"
    local version="$3"

    if [[ ! -d "$dir" ]]; then
        echo -e "${RED_BOLD}🌊 Error: Tag directory not found: $dir${RESET}"
        return 1
    fi

    : > "$dir/$(tagger_mark_name "$name" "$version")"
}

tagger_delete() {
    # 删除标记文件，不存在时静默跳过
    local dir="$1"
    local name="$2"
    local version="$3"

    local mark
    mark="$dir/$(tagger_mark_name "$name" "$version")"
    if [[ -e "$mark" ]]; then
        rm -f "$mark"
    fi
}

tagger_has_any() {
    # 目录内是否还存在任意 .depped_* 标记
    local dir="$1"
    local marks=("$dir"/.depped_*)

    if [[ -e "${marks[0]}" ]]; then
        return 0
    fi
    return 1
}

# -------------------- 命令行入口 --------------------

tagger_main() {
    local action="$1"

    if [[ -z "$action" ]]; then
        echo -e "${RED_BOLD}🌊 Error: No action received.${RESET}"
        exit 1
    fi

    case "$action" in
        create)
            if [[ -z "$2" || -z "$3" || -z "$4" ]]; then
                echo -e "${RED_BOLD}🌊 Error: Missing arguments for create.${RESET}"
                exit 1
            fi
            tagger_create "$2" "$3" "$4"
            ;;
        delete)
            if [[ -z "$2" || -z "$3" || -z "$4" ]]; then
                echo -e "${RED_BOLD}🌊 Error: Missing arguments for delete.${RESET}"
                exit 1
            fi
            tagger_delete "$2" "$3" "$4"
            ;;
        has-marks)
            if [[ -z "$2" ]]; then
                echo -e "${RED_BOLD}🌊 Error: Missing directory for has-marks.${RESET}"
                exit 1
            fi
            if tagger_has_any "$2"; then
                exit 0
            fi
            exit 1
            ;;
        *)
            echo -e "${RED_BOLD}🌊 Error: Unknown action '$action'.${RESET}"
            exit 1
            ;;
    esac

    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    tagger_main "$@"
fi
