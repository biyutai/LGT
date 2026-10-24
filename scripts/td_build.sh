#!/usr/bin/env bash
# 命令行编译（不开 TD 界面）：把当前工作区复制到临时目录，跑 综合 → 布局布线 → 生成比特流
# 用法：scripts/td_build.sh [输出目录，默认 /tmp/td_build] [布局种子，可选]
# 产物：<输出目录>/td_project/HDMI1.4b_Transmitter_v1.0_Runs/phy_1/ 下的 .bit、final_timing.rpt、*_phy.area
# 不会碰 TD 界面正在用的 td_project/*_Runs/
set -euo pipefail

TD=D:/Shop/Bin/td_commands_prompt.exe
FLOW=D:/Shop/doc/scripts/DefaultFlow.tcl
PRJ=HDMI1.4b_Transmitter_v1.0

repo="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-/tmp/td_build}"
seed="${2:-}"
[[ -z "$seed" || "$seed" =~ ^[0-9]+$ ]] || { echo "布局种子必须是非负整数" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out"
cp -r "$repo/td_project" "$repo/user_source" "$out/"
rm -rf "$out/td_project/${PRJ}_Runs" "$out/td_project/log" "$out/td_project/.lock.f"

runs="$out/td_project/${PRJ}_Runs"
mkdir -p "$runs/syn_1" "$runs/phy_1"

# .prj = .al 的副本，源文件路径多退两级（Runs/syn_1 比 td_project 深两层）
sed 's#Path="\.\./#Path="../../../#g; s#Path="al_ip/#Path="../../al_ip/#g' \
    "$out/td_project/$PRJ.al" > "$runs/syn_1/$PRJ.prj"
cp "$runs/syn_1/$PRJ.prj" "$runs/phy_1/$PRJ.prj"

common='set ADCList {"../../../user_source/constraints_source/pin.adc"}
set IpSDCList { rfifo_32_32_512 ../../../user_source/hdl_source/ip/afifo_32_16_256.tcl wfifo_32_32_512 ../../../user_source/hdl_source/ip/afifo_16_32_256.tcl }
set SDCList {"../../../user_source/constraints_source/timing.sdc"}
set area_option -packarea
set device_name eagle_s20.db
set package_name EG4S20BG256
set prj_name {'"$PRJ"'}
set top_model_name {top}'

printf '%s\nset end_step opt_gate\nset run_type syn\nset start_step read_design\n' "$common" > "$runs/syn_1/settings.cfg"
printf '%s\nset arr_filter false\nset drHoldFix on\nset end_step bitgen\nset parent ../syn_1\nset run_type phy\nset start_step opt_place\n' "$common" > "$runs/phy_1/settings.cfg"

# 试过官方 AreaOptimizeHigh 的 `{gate map_mode area_prior}`：LUT 确实从 16,800 掉到
# 15,534（79.3%）且 hold 归零，但逻辑层数变深，100MHz 域反而更差（clk1 −1.12ns），
# 同一种子还出现布线拥塞（PHY-8023）。所以默认仍用时序优先映射，不设 wild param。
# 注意 TD 的 settings.cfg 一行只认一组 wild param，写成多组会被拼成一次 set_param 报 RUN-8001。

# 面积优先映射：省约 1200 LUT。早先在 SD 域还是 100MHz 时否掉过；第 7 步把 SD 域降到
# 50MHz 后时序压力小得多，而 OSD 产品化（产品信息页 + 品牌封面）在时序优先映射下会把
# mslice 顶到 5033 > 4900（PHY-9009）导致编译失败 —— 所以**默认打开**，不带任何开关
# 直接 `scripts/td_build.sh <输出目录> <种子>` 就能出比特流（实测 mslice 4542 / 4900）。
# 想回到时序优先：TD_AREA=0 scripts/td_build.sh <输出目录> <种子>
if [[ "${TD_AREA:-1}" == "1" ]]; then
    printf 'set synWildParams {gate map_mode area_prior}\n' >> "$runs/syn_1/settings.cfg"
    echo "== 综合策略：面积优先"
fi

if [[ -n "$seed" ]]; then
    printf 'set phyWildParams {place seed %s}\n' "$seed" >> "$runs/phy_1/settings.cfg"
    echo "== 布局种子：$seed"
fi

for step in syn_1 phy_1; do
    echo "== $step"
    # TD 的 Tcl 会吃掉反斜杠，路径必须用正斜杠（D:/...）
    # 跑完流程后 td_commands_prompt 会停在 "td >" 等键盘输入，stdin 必须接 /dev/null 让它退出；
    # 再加 20 分钟超时兜底，防止卡住
    ( cd "$runs/$step" && timeout 1200 "$TD" "$(cygpath -m "$FLOW")" < /dev/null > run.log 2>&1 ) || true
    done_mark="$runs/$step/.$( [[ $step == syn_1 ]] && echo opt_gate || echo bitgen ).end.f"
    if [[ ! -f "$done_mark" ]] || grep -q -i -E "ERROR|couldn't read|no such file" "$runs/$step/run.log"; then
        # grep 找不到匹配会返回 1，配合 set -e 会让脚本在打印下面这行之前静默退出
        grep -i -E "ERROR|couldn't read|no such file" "$runs/$step/run.log" | head -20 || true
        tail -5 "$runs/$step/run.log"
        echo "== $step 失败，完整日志：$runs/$step/run.log"
        exit 1
    fi
done

phy="$runs/phy_1"
[[ -f "$phy/$PRJ.bit" ]] || { echo "没有生成比特流，见 $phy/run.log"; exit 1; }
echo "== 比特流：$phy/$PRJ.bit"
sed -n '/^Timing Status/,/^Clock Summary/p' "$phy/final_timing.rpt" | grep -E "WNS"
grep -E "^#(lut|reg|bram|pll) " "$phy/${PRJ}_phy.area"
