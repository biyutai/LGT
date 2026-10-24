#!/usr/bin/env bash
# ModelSim 命令行仿真
# 用法：sim/run.sh <testbench 名> [+参数 ...]      例：sim/run.sh tb_reset、sim/run.sh tb_sdram_audio +LAT=10
# 编译 sim/<名>.v 和 sim/<名>.f 里列出的源文件（相对仓库根目录），在 sim/work_<名>/ 下运行
# .f 里也可以写 +incdir+<目录>（同样相对仓库根目录），给 `include 找文件用
set -euo pipefail

MS=D:/Shop/ModelSim/win64

tb="${1:?用法：sim/run.sh <testbench 名> [+参数 ...]}"
shift
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

[[ -f "sim/$tb.v" ]] || { echo "找不到 sim/$tb.v" >&2; exit 1; }
srcs=()
if [[ -f "sim/$tb.f" ]]; then
    while read -r line; do
        line="${line%%#*}"
        line="$(echo "$line" | xargs)"
        [[ -z "$line" ]] && continue
        if [[ "$line" == +incdir+* ]]; then
            srcs+=("+incdir+../../${line#+incdir+}")
        else
            srcs+=("../../$line")
        fi
    done < "sim/$tb.f"
fi

wd="sim/work_$tb"
rm -rf "$wd"
mkdir -p "$wd"
cd "$wd"

"$MS/vlib.exe" work > /dev/null
"$MS/vlog.exe" -quiet -work work "${srcs[@]}" "../$tb.v"

# 只保留仿真输出：去掉 ModelSim 的版权横幅和 $finish 提示
"$MS/vsim.exe" -c -quiet -do "run -all; quit -f" "work.$tb" "$@" \
    | sed -n 's/^# //p' \
    | sed -n '/^run -all/,$p' \
    | grep -v -e '^run -all' -e '^quit -f' -e 'Note: \$finish' -e '^   Time: ' \
    || true
