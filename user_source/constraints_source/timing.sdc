
# ============================================================
# merged_top_tf_hdmi_audio.sdc
# 用于：TF 图片轮播 + HDMI(视频+音频) 整合工程
#
# 合并原则：
# 1) 保留 top.sdc 里的系统主时钟与 derive_clocks
# 2) 把 timing(2).sdc 里的 pixel/serial 时钟改成整合工程实际名字
# 3) 增加 hdmi_5x_clk 的命名（音频 PLL 已在第 5 步删除，音频改在 video_clk 域产生）
# 4) 不再对内部 net 直接 create_clock，避免和 derive_clocks 重复
# ============================================================

# ------------------------------------------------------------
# 1. 板级输入主时钟
#    你的原 top.sdc 里 clk=50MHz，所以这里仍然用 20ns
# ------------------------------------------------------------
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

# ------------------------------------------------------------
# 2. 自动推导 PLL 输出时钟
# ------------------------------------------------------------
derive_clocks

# ------------------------------------------------------------
# 3. 给关键 PLL 输出命名
#    下面这些路径是按你当前工程实例名写的：
#      sys_pll      -> sys_pll_m0
#      video_pll    -> video_pll_m0
#
#    如果综合后实例路径略有不同，就按 Timing Analyzer 里的实际 pin 路径改。
# ------------------------------------------------------------
rename_clock -name {sd_card_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {ext_mem_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {video_clk}   -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[1]}]

# ------------------------------------------------------------
# 4. 从原 timing(2).sdc 迁移过来的 HDMI 像素/串行时钟约束
#
#    原文件是：
#      create_clock -name pixel_clk  ... [get_nets {S_pixel_clk}]
#      create_clock -name serial_clk ... [get_nets {S_serial_clk}]
#      set_clock_groups -exclusive ...
#
#    在整合工程里，这两个时钟已经由 video_pll 产生，并通过 derive_clocks 建出来了，
#    所以这里只保留“组关系”，不再重复 create_clock。
#
#    这里沿用原作者的写法，把 video_clk 和 hdmi_5x_clk 设成 exclusive。
#    如果后面 Timing Analyzer 明确显示两者之间需要做同步时序分析，再把这一条去掉。
# ------------------------------------------------------------
set_clock_groups -exclusive \
    -group [get_clocks {video_clk}] \
    -group [get_clocks {hdmi_5x_clk}]

# ------------------------------------------------------------
# 5. （已删除）音频 I2S 跨域：第 5 步起音频直接在 video_clk 域产生，不再有 audio_mclk
# ------------------------------------------------------------

# ------------------------------------------------------------
# 6. 视频时钟与其他时钟异步（第 6b 步打开）
#
#    第 6b 步像素时钟改为 25.2MHz（60Hz），video_pll 改成 No compensation 模式（VCO 直接反馈）：
#    - 25.2 和 100 / 125MHz 不再成整数比，按同步时钟分析时两个时钟沿最近只差 0.02ns，跨域路径全报假违例
#    - No compensation 不补偿时钟树延迟，video_clk 与 50MHz 输入之间相位不确定，按同步分析没有意义
#    视频时钟和其他时钟之间的跨域已逐个核对，全部经过同步器 / 异步 FIFO 或是准静态信号：
#      video → mem   read_req（frame_fifo_read 打 3 拍）
#      mem → video   read_req_ack、cur_read_index（sync_2ff）、读 FIFO 复位（FIFO 内部同步）
#      双向          像素读 FIFO、音频 FIFO（异步 FIFO）
#      video → sd    beat_toggle（sd_card_bmp 打 3 拍）
#      sd → video    wav_ready、display_valid（sync_2ff）；img_found_count、wav_words（准静态，见第 8 节）
#      video → clk   LED 输出（两拍同步）
#    sd_card_clk / ext_mem_clk 之间仍按同步时钟分析（同一个 sys_pll，100 / 125MHz），不在这里放开。
#    video_clk / hdmi_5x_clk 之间沿用第 4 节的 exclusive。
# ------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks {video_clk hdmi_5x_clk}] \
    -group [get_clocks {clk sd_card_clk ext_mem_clk sys_pll_m0/pll_inst.clkc[2]}]

# ------------------------------------------------------------
# 7. 复位同步器的异步输入
#
#    rst_sys（clk 50MHz 域）进各时钟域 rst_sync 的异步置位端，
#    置位本来就是异步的，撤销由 rst_sync 内部的同步链保证，这段路径不需要分析。
#    各域 rst_sync 输出之后到本域寄存器的恢复/移除检查照常进行。
#    按目标时钟写而不按寄存器名写：TD 会因扇出复制 rst_sync 的末级寄存器并改名，
#    按寄存器名匹配会漏掉复制品。rst_sys 到 clk 域的路径仍正常分析。
# ------------------------------------------------------------
set_false_path -from [get_regs {u_sys_reset/rst}] -to [get_clocks {sd_card_clk ext_mem_clk video_clk}]

# ------------------------------------------------------------
# 8. WAV 参数跨域（第 5 步）
#
#    wav_words（WAV 字数）和 write_is_wav（本次写是 WAV）在 sd_card_clk 域产生，进 ext_mem_clk 域使用：
#    - wav_words 扫卡时定下后不再变；音频读口只在 wav_ready（经 2 级同步）之前采样它
#    - 两者都在 write_req 发出之前就已稳定，frame_fifo_write 把 write_req 打 3 拍后才锁存写长度
#    这两条是准静态路径，不需要按 100MHz → 125MHz 的 2ns 预算检查。
# ------------------------------------------------------------
set_false_path -from [get_regs {sd_card_bmp_m0/bmp_read_m0/wav_words*}] -to [get_clocks {ext_mem_clk video_clk}]
set_false_path -from [get_regs {sd_card_bmp_m0/write_is_wav*}] -to [get_clocks {ext_mem_clk}]

# ------------------------------------------------------------
# 8b. 音画同步（第 5c 步）
#
#    img_found_count（图片张数）扫卡时定下后不再变，av_sync 在 WAV 开始播放时才采样（video_clk），准静态。
# ------------------------------------------------------------
set_false_path -from [get_regs {sd_card_bmp_m0/img_found_count*}] -to [get_clocks {video_clk}]

# ------------------------------------------------------------
# 9. 其余 Input/Output delay 先保持空白
#    你当前两个原始 sdc 也都没有写这部分。
# ------------------------------------------------------------
