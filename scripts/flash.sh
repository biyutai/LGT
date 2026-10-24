#!/usr/bin/env bash
# 把比特流固化进板上配置 Flash（W25Q16，2MB）：断电不丢，上电 FPGA 自动从 Flash 加载
# 用法：scripts/flash.sh [比特流]            烧写 + 回读校验，默认用 scripts/td_build.sh 的产物
#       scripts/flash.sh --backup <输出.bin>  整片 2MB 读出备份（分 16 块，每块读到连续两次一致为止）
# 下载器同一时刻只能被一个程序占用：先关掉 TD 里的 BitWriter / 下载界面
# 只想临时调试（掉电丢失）就还是用 TD 的 Program SRAM，比烧 Flash 快
set -euo pipefail

BW=D:/Shop/Bin/bw_commands_prompt.exe
PRJ=HDMI1.4b_Transmitter_v1.0
SPD=6                       # 与 TD 界面默认一致
FLASH_BYTES=2097152
CHUNK=131072                # 一次读整片会报 USB 读失败，分块读

# 在临时目录里跑 bw：它不认 Git Bash 的 D:/... 路径，文件一律用相对路径
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

bw() {   # bw <tcl 命令>：成功返回 0，失败打印 ERROR 行
    printf '%s\n' "$1" > "$work/cmd.tcl"
    ( cd "$work" && timeout 600 "$BW" cmd.tcl < /dev/null > bw.log 2>&1 ) || true
    if grep -q "ERROR" "$work/bw.log"; then
        grep "ERROR" "$work/bw.log" | head -3
        return 1
    fi
}

if [[ "${1:-}" == "--backup" ]]; then
    out="${2:?用法：scripts/flash.sh --backup <输出.bin>}"
    : > "$work/all.bin"
    for ((i = 0; i < FLASH_BYTES / CHUNK; i++)); do
        addr=$(printf '0x%X' $((i * CHUNK)))
        ok=0
        for try in 1 2 3 4 5; do
            rm -f "$work/a.bin" "$work/b.bin"
            if bw "download -mode rdbk_spi -start_addr $addr -data_length $CHUNK -rdbk a.bin -spd $SPD -cable 0" &&
               bw "download -mode rdbk_spi -start_addr $addr -data_length $CHUNK -rdbk b.bin -spd $SPD -cable 0" &&
               cmp -s "$work/a.bin" "$work/b.bin"; then
                ok=1; break
            fi
            sleep 15        # USB 读失败后下载器要十几秒才能重新打开
        done
        if [[ $ok == 1 ]]; then
            echo "  $addr 一致"
        else
            echo "  $addr 5 次都没读到连续两次一致，保存最后一次（这块内容不可靠）"
            [[ -f "$work/a.bin" ]] || { echo "读失败，放弃"; exit 1; }
        fi
        cat "$work/a.bin" >> "$work/all.bin"
    done
    cp "$work/all.bin" "$out"
    echo "== 备份：$out"
    exit 0
fi

bit="${1:-/tmp/td_build/td_project/${PRJ}_Runs/phy_1/${PRJ}.bit}"
[[ -f "$bit" ]] || { echo "找不到比特流 $bit（先跑 scripts/td_build.sh）" >&2; exit 1; }
cp "$bit" "$work/top.bit"
echo "== 比特流：$bit（$(date -r "$bit" '+%F %T')）"

echo "== 烧写 Flash（约 1 分钟）"
bw "download -bit top.bit -mode program_spi -spd $SPD -cable 0" || { echo "== 烧写失败"; exit 1; }
echo "== 回读校验"
bw "download -bit top.bit -mode verify_spi -spd $SPD -cable 0" || { echo "== 校验失败"; exit 1; }
grep -E "PRG-[0-9]+ :" "$work/bw.log" | tail -3 || true
echo "== 完成：断电再上电，FPGA 会从 Flash 自动加载"
