# LGT-S1 功能全览与验证手册

> 适用工程：`LGT 音画同频数字标牌`，EG4S20BG256 / HX4S20C。  
> 当前待上板候选：`_flash_work/signage_readable_ui_seed23_UNVERIFIED.bit`，MD5 `71A133E684DE8065429DE27E1DD26D3F`。包含中文播放记录、中央大号无卡封面、首图后先装 WAV、手动/自动后台缓存和 12.5 MHz SPI；**尚未实卡验证**。上一候选 `signage_fast_start_seed23_UNVERIFIED.bit` 保持原样。  
> 本文以当前顶层 RTL 为功能边界。新候选 routed timing：SD/video/ext_mem 内部 setup 为 +2.160/+14.091/+0.458 ns；最差 hold -0.068 ns，全局 SDRAM 时钟输出相关路径仍为 -6.565 ns。仿真、构建通过不等于实卡验证通过；每项上板结果仍须记录。

## 1. 如何使用本文

先按第 2 节准备卡和设备，再依次做第 3 节基础功能、第 4 节官方扩展、第 5 节产品功能，最后填写第 8 节记录。第 6 节是全部按键/拨码速查表，第 7 节给出仿真和工具命令。遇到功能不符时，以当前烧录 bit 的 MD5、RTL 和板上现象为准，不把仓库中未例化的模块算作已交付功能。

赛题原文见[安路选题指南](../../../anlogic-fpga-contest/官方文件/★★2026_选题指南_安路科技(35页).pdf)第 14–15 页：四项基础要求是核心功能完整性、显示稳定性与鲁棒性、基础音频输出、系统工程规范性；五项可选扩展是图层/字幕、切图/转场、缩放、实时调节/OSD、音频可视化。扩展项按完成数量、难度、质量、稳定性和展示效果综合评价，没有单项固定分值。

### 验证级别

| 标记 | 含义 | 可用证据 |
|---|---|---|
| RTL | 已接入当前顶层和候选 bit | 顶层实例/连线、构建源码快照 |
| SIM | 对应仿真通过 | `sim/run.ps1` 输出 `ALL PASSED`，无 `FAIL`/`Fatal` |
| BOARD | 该块实物板上验证通过 | 不剪断的操作视频、屏幕照片、串口抓包 |

本文列出的当前功能已接入 RTL；`BOARD` 结果由实际测试者填写，不能仅凭本手册自动视为通过。

## 2. 验证准备

### 2.1 设备与版本

1. HDMI 接开发板 **HDMI_B**；显示器/电视需支持 HDMI 音频，或按板卡方案接可播放声音的设备。
2. 接 5V 供电；要查事件和故障时，将 USB1/CH340 串口接电脑，使用 115200、8N1。串口只发送，不接收控制命令。
3. 烧录并读回核对待测 bit；在记录表中写 MD5。`_flash_work/program.tcl` 用于板载配置 Flash，操作步骤见[运营手册第 9 节](signage-operator-guide.md)。用户参数/事件用的 W25Q64 是另一颗 Flash。
4. 先将 SW1/SW2/SW4 拨下；SW3 按要验证的手动或自动模式设置。板上 SW6 应处于 LED 物理档；本工程不驱动数码管/蜂鸣器。

候选 bit 的布局报告：LUT 17,557/19,600，BRAM 46/64，DSP 10/29；SD/video/ext_mem 功能域建立余量分别为 +0.650/+7.753/+0.184 ns。报告仍有 SDRAM 时钟输出相关的全局负路径和少量保持违例，因此口径是“功能域建立 0 违例”，不是“全局时序 0 违例”。

### 2.2 唯一一张 TF 卡

先在电脑上备份整张卡，再确认它是 FAT32。产品版只使用 FAT32 根目录中的 BMP、WAV 与 `PLAYLIST.TXT`；不依赖旧版原始扇区或 `TEXT.TXT` 回退。演示卡一次性放入四张 BMP、两段 48kHz/16-bit/双声道 WAV 和节目单。四条节目都含 `中文|ENGLISH` 双语字幕，并分别指定转场。

运行打包器后，按 `MANIFEST.TXT` 中的顺序将文件复制到**同一张卡**的根目录：640×480 图先复制，首图出现更快；随后复制其余 BMP、两段 WAV 和节目单。FPGA 使用 FAT32 目录顺序给图片编号，复制完成后重新核对节目单图片号和屏上内容。不需要第二张卡，也不要为了测试去截断唯一的演示图片。

内容预检（在仓库根目录运行）：

```powershell
python scripts/package_content.py assets/scale_demo --check-only
python scripts/check_playlist_font.py
```

前者检查 BMP/WAV/节目单并报告警告；后者检查实际绘制的字幕字形。`package_content.py` 按首图优先顺序复制四张图和最多四段 WAV，忽略旧 `TEXT.TXT`；`MANIFEST.TXT` 是离线打包清单，**FPGA 不读取它**。若要核对整张卡的 FAT32 簇链，可先制作整卡镜像，再运行 `python scripts/check_tf_image.py 整卡.img 源BMP... 源WAV...`，以 `VERIFY PASS` 为准。

## 3. 四项基础要求

| 官方要求 | 当前实现 | 上板操作与通过标准 | 对应仿真/证据 |
|---|---|---|---|
| 核心功能完整性 | TF SPI 初始化；FAT32 根目录与簇链读取；24-bit 未压缩 BMP 扫描/解析；SDRAM 帧缓存；HDMI_B 640×480@60 输出 | 插标准卡冷启动 3 次：品牌封面 → 自检状态页 → 首张完整图片。手动切图后无半帧、黑屏或错图；拍屏幕与板卡同框视频 | `tb_sd_reinit`、`tb_fat32_virtual_disk`、`tb_wav_load`、`tb_video_timing`、`tb_sdram_real` |
| 显示稳定性与鲁棒性 | 图写完且 SDRAM 整帧提交后才切显示；坏图重试/跳过；SD 读超时看门狗；拔卡重建扫描 | 连续切图 20 次无撕裂；坏图不替换已提交的完整画面；拔卡后允许回品牌封面/引导页，但不能花屏或卡死，插回后可恢复。分别录视频 | `tb_wav_load`、`tb_sd_reinit`、`tb_sdram_real`、`tb_video_transition` |
| 基础音频输出 | TF 卡 PCM WAV 载入 SDRAM，经音量/音效链和 HDMI 音频输出；48kHz/16-bit/双声道 | 标准卡播放 WAV，显示设备可听到连续音乐；S1 静音、S2/S3/S4 音量依次提高；切图时音乐不中断 | `tb_wav_load`、`tb_wav_player`、`tb_audio_sample_gain`、`tb_sdram_audio` |
| 系统工程规范性 | 时钟/复位分域、跨域同步、仿真、引脚及时序约束、可复现构建和发布 bit | 保存 RTL 版本、bit MD5、TF 内容清单、关键 testbench 输出、TD 面积/时序报告、上板记录；报告中画 TF→SDRAM→HDMI/音频通路 | `sim/`、`scripts/td_build.ps1`、`_flash_work/*_timing.rpt` |

没有 WAV 时，**当前容量版静音**：顶层测试音输出固定关闭。不能把“无卡/无 WAV 自动播放测试音”列为当前音频功能。

## 4. 五项官方扩展要求

### 4.1 图层叠加与字幕效果

- 当前画面有图片层、按需顶部状态栏、底部双语节目字幕；右上角 `n/总 A/M` 角标与照片中部三秒黑色提示条已删除。图片转场与画面特效在字幕叠加之前处理。
- 状态栏显示“分辨率”及真实 BMP 源尺寸：640×480、320×240、320×180、1024×768、1280×960。SW1 信息页、自检页、无卡封面和屏保采用四色背景与 `LGT` 字标；屏保不显示“正在读取 TF 卡”。首图只在帧边界替换封面。
- `PLAYLIST.TXT` 四条示例均支持双语字幕，中文行在 y=432–447，英文行在 y=456–471；两行各有 39 个字格（x=8–631），固定显示、不滚动，字形以外直接透出照片。S6/S7/S8 控制字形清晰度为 50/75/100%。
- 有节目单字幕时不叠加内置英文技术滚动条。单卡产品版不解析 `TEXT.TXT`；状态栏可显示“上电以来”的 `HH:MM:SS`，**不是墙钟时间**。
- **验证**：在唯一演示卡上轮到四条节目，逐条确认中英两行；拨 SW2 核对每张图的真实分辨率。S5 关闭字幕，S6/S7/S8 逐一观察 50/75/100% 字形差异；右上角与照片中部不应再出现旧角标或黑色提示条。
- **仿真**：`tb_playlist_video_path`、`tb_osd_subtitle_full`、`tb_osd_playlist`、`tb_osd_display`、`tb_video_osd`、`tb_osd_alignment`。

### 4.2 图片轮播与转场特效

- 最多扫描四张 BMP；SW3 控制自动/手动轮播，KEY2/KEY4 可切下一张/上一张；背景预加载和帧边界切换避免直接显示半张图。
- 四种转场为淡入、左揭示、右揭示、菱形溶解。未手动操作时由节目单决定转场；按 S9–S12 选择后持续使用该转场，KEY2/KEY4 和矩阵选图也会固定当前选择，后续切图不会自行变换。保存的转场从 W25Q64 恢复后同样持续生效。
- 有 WAV 且自动播放或演示模式时，统一按 WAV 样本位置产生的节拍切图；没有 WAV 时才按节目单秒数定时。`0` 秒条目在无 WAV 时沿用默认轮播周期。
- 四帧缓存容量足够时，首图先显示，随后加载 WAV 开始播放，再后台缓存其余图片；手动模式也会填满缓存。未缓存的图片仍要等待读卡，已经缓存的图片即使后台正在读另一张也能响应 KEY2/KEY4。长 WAV 无法四帧常驻时沿用双缓冲。产品顶层数据 SPI 选 12.5 MHz，初始化仍约 100 kHz。
- 数据阶段读卡速度由 `sd_card_bmp.v` 的 `SD_SPI_HIGH_SPEED_DIV` 在编译时切换：`0`=12.5 MHz、`1`≈8.33 MHz、`2`=6.25 MHz、`6`=3.125 MHz；模块默认值仍为 `2`，产品顶层显式传入 `0`。更高档位必须另编 bit 并用实卡验证连续读图与 `HEALTH`，不能仅凭仿真认定稳定。
- **验证**：同一张卡先观察自动节目单，再按 S9–S12 选择转场，连续用 KEY2、KEY4、矩阵选图切换，确认效果保持一致；等待参数写入后断电重启，再验证恢复的转场。切换期间不能出现半帧或黑帧。
- **仿真**：`tb_wav_first_lap`、`tb_wav_beat_race`、`tb_wav_load`、`tb_video_transition`、`tb_av_sync`、`tb_av_chain`。

### 4.3 图片缩放适配

| BMP 源尺寸 | 当前有效通路 | 实卡判断 |
|---|---|---|
| 640×480 | 原尺寸显示 | 没有缺行、颜色正确 |
| 320×240 | 2 倍放大 | 铺满 640×480，无乱行 |
| 320×180 | 按宽高策略拉伸铺满 | 人物/主体可见，不出现未写区域 |
| 1280×960 | 2×2 均值降到 640×480 | 全幅可见，边缘比简单抽样平滑 |
| 1024×768 | 8:5 相位抽取降到 640×480 | 全幅可见、无整行/整列错位；允许轻微锯齿 |

所有文件须是 24 位未压缩、正高度 BMP。**验证**：同一卡内的四张图覆盖 640×480、1280×960 与 1024×768；320×240/320×180 的兼容尺寸以仿真验证，不要求为此重写唯一的卡。1024×768 走 8:5 相位抽样，未启用的面积加权实现已删除。**仿真**：`tb_bmp_scale_full`、`tb_bmp_scale_2x`、`tb_bmp_downscale16`。

### 4.4 实时调节与 OSD 信息叠加

- KEY3 短按循环“正常 → 亮度 → 对比度 → 画面特效 → 音效 → 正常”；在编辑档用 KEY2 加、KEY4 减。亮度/对比度均为 0–4 档，默认 2。
- 画面特效共六档：关闭、灰度、反色、棕褐、左右镜像、边缘。棕褐使用移位近似，边缘为单像素差分，不是 Sobel。音频音效是原声、低音、明亮、低音+明亮四档预设。
- 参数变化直接反映在顶部状态栏；SW1 打开亮色产品信息页，SW2 常显状态栏；状态栏还包含音画误差 `AV xx.x MS`、帧率及健康摘要。
- **验证**：同一卡按 KEY3 进入每档，KEY2/KEY4 各调一次，记录画面/声音和 OSD 数值；特效六档逐一拍照。亮度、对比度、转场、音量稳定约半秒后写入 W25Q64；等操作完成再断电，上电应恢复。演示模式中的临时调节不写入。
- **仿真**：`tb_osd_controls`、`tb_video_color_adjust`、`tb_video_effects`、`tb_audio_dsp`、`tb_video_osd`。

### 4.5 音频可视化展示

- PCM 波形、四根频段柱 `LO/LM/HM/HI`、8 颗双色 LED 与 4 颗辅助绿灯由播放音频链驱动，不是固定装饰动画。
- **验证**：播放 `05_demo_beat.wav`，同时拍下屏幕与 LED；鼓点/高频出现时柱高、波形、灯光应变化。S1 静音和 S4 满音量分别观察变化，听感与画面不能长期脱节。音画误差可在 SW2 状态栏查看。
- **仿真**：`tb_audio_visualizer`、`tb_audio_dsp`、`tb_av_sync`、`tb_audio_sample_gain`。

## 5. 产品化与项目新增功能

| 功能 | 当前行为 | 验证方式 |
|---|---|---|
| 插卡即播与品牌封面 | HDMI 时钟就绪先显示 LGT 封面；首图完整写入后切照片，随后扫描余图和 WAV | 同一卡冷启动 3 次，拍完整过程；`tb_video_startup_screen`、`tb_wav_load` |
| RESET/PROGRAM 热复位 | FPGA 重新配置时 TF 卡不断电；SD 片选上拉，先在 CS 高电平下送初始化时钟，再清残留并重新扫描 | 保持卡插入按 RESET/PROGRAM，确认串口从 `SD_INIT` 进入 `READY`、首图重新出现；`tb_sd_reinit`、`tb_wav_warm_reset` |
| FAT32 单卡内容 | FAT32 根目录、簇链和碎片化文件可读；不支持非 FAT32 原始扇区兼容模式 | 只用这张 FAT32 卡测试 BMP/WAV；无效卷回无内容引导；`tb_single_card_mode`、`tb_fat32_virtual_disk` |
| 节目单与双语内容 | `PLAYLIST.TXT` 最多 16 条，条目含 1 起图片号、秒数、转场、两种语言字幕；每种语言最多 39 字 | 同一卡核对条目顺序、时长与字幕；错误字段由仿真验证；`tb_playlist`、`tb_playlist_video_path`、`tb_osd_subtitle_full` |
| 参数掉电恢复 | W25Q64 `0x7FE000` 单槽保存亮度、对比度、转场、音量；与事件日志共享一个 SPI store | 同一卡调参 → 等待写入 → 断电重启 → 数值恢复，LOG 仍可查；`tb_product_flash` |
| 固定转场选择 | 节目单先自动编排，手动选转场或切图后持续使用所选效果 | 在同一卡连续切图并断电恢复，效果不随图片变化；`tb_playlist_transition_preview` |
| 多首背景音乐 | FAT32 索引最多记录 4 段 WAV；上电播放第一段，KEY1 长按请求下一首 | 同一卡放两段声音明显不同的合规 WAV，长按 KEY1 后听出切换；`tb_wav_select` |
| 帧缓存与预加载 | 首图后先加载 WAV，再在自动或手动模式后台填充四帧；长 WAV 用双缓冲 | 缓存完成后每拍只切一张，缓存未完成时旧图持续显示；`tb_wav_first_lap`、`tb_wav_beat_race`、`tb_wav_load` |
| 四宫格和缩略图浏览 | KEY1 短按切单图/四宫格；KEY3 长按进浏览，KEY2 移焦点，KEY1 短按选图 | 四格各有对应内容、焦点边框跟随按键、选图进入正确照片；`tb_thumbnail_buttons`、`tb_thumbnail_cache` |
| 开机健康状态与信息页 | 无卡时中央品牌封面，卡已挂载且首图未就绪时自检；SW1 产品信息页、SW2 状态栏 | 同一卡看信息页和状态栏；无卡封面及无内容引导用仿真验证；`tb_video_startup_screen`、`tb_osd_selfcheck`、`tb_osd_guide` |
| 待机/屏保 | 只在 SW3 拨下的手动模式计时 60 秒；退出手动模式立即清零并退出屏保 | 自动模式空等 60 秒不进屏保；拨下 SW3 后计时 60 秒进入；再拨上、拨下必须重新计满 60 秒；`tb_video_standby` |
| 故障恢复 | 坏 BMP 重试一次后跳过、首图坏继续找、SD 卡拔出可重新初始化；半帧不会被提交显示 | 坏文件用仿真验证；板上只拔插**同一张卡**，观察品牌封面/引导页及恢复；`tb_wav_load`、`tb_sd_reinit` |
| 播放事件记录 | 独立 W25Q64 从 `0x700000` 起使用 16 个 4KB 槽；屏上显示最近 7 条中文事件、运行秒数和相关图号 | 连续换图并断电重启，记录仍可见；坏图/拔卡出现对应中文事件；`tb_config_event_log`、`tb_osd_log` |
| 串口状态 | USB1/CH340 只读 115200 8N1；每约一秒输出一行 190 字节可读状态，不导出事件行 | 抓包核对 `UPTIME`/`LOAD_PHASE`/`HEALTH` 与实际状态一致；`tb_uart_slim_reporter` |

“播放证明”记录的是**上电以来**的时间，没有 RTC 墙钟；可用于演示运行追溯，不宣称广告结算级绝对时间。参数记录和事件日志位于不同 W25Q64 扇区，通过唯一的 SPI store 仲裁。

## 6. 按键与拨码速查

| 控件 | 普通播放 | 其它状态/验证注意 |
|---|---|---|
| KEY1 短按 | 单图 ↔ 四宫格 | 缩略图浏览中选中焦点图 |
| KEY1 长按 | 下一首 WAV | 缩略图浏览中仅退出，不切歌 |
| KEY2 短按 | 下一张图 | 编辑档加一档；缩略图浏览移动焦点；首图前翻上一状态页 |
| KEY3 短按 | 循环编辑档 | 编辑档中的变化可在 SW2 状态栏查看 |
| KEY3 长按 | 进入/退出缩略图浏览 | 焦点只在浏览模式中出现 |
| KEY4 短按 | 上一张图 | 编辑档减一档；首图前翻下一状态页；SW1 信息页内打开 LOG 页 |
| SW1 拨上 | 整屏产品信息页 | KEY4 进入 LOG，KEY2 返回信息页；拨下返回播放 |
| SW2 拨上 | 顶部状态栏常显 | 拨下默认保留干净画面 |
| SW3 拨上/下 | 自动轮播开/关 | 有 WAV 时跟随音频节拍，无 WAV 时按节目单秒数 |
| SW4 拨上 | 临时演示模式 | 拨下恢复原参数与模式 |
| S1–S4 | 音量 0/35/70/100% | 需要有 WAV 才能听辨 |
| S5–S8 | S5 隐藏节目字幕；S6/S7/S8 分别为 50/75/100% 字形清晰度 | 中英文两行同时变化 |
| S9–S12 | 淡入/左揭示/右揭示/菱形溶解 | 选择后持续生效，并保存到 W25Q64 |
| S13–S16 | 直选第 1–4 张图 | 图未扫描到或损坏时请求被忽略；浏览模式中先退出 |

无卡时保持品牌封面；卡已挂载但首图未出现时，KEY2/KEY4 控制自检/LOG/引导页，不是切图。板载 SW5/SW6 属于物理开关，不是 FPGA 可读取的产品操作菜单。

## 7. 验证命令与执行顺序

所有命令从仓库根目录运行。`sim/run.ps1` 一次跑一个 testbench；**必须检查文字结果有 `ALL PASSED` 且没有 `FAIL`/`Fatal`**，不能只看 PowerShell 退出码。

### 7.1 先验内容和关键链路

```powershell
python scripts/package_content.py assets/scale_demo --check-only
python scripts/check_playlist_font.py
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_sd_reinit
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_fat32_virtual_disk
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_single_card_mode
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_wav_load
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_wav_first_lap
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_wav_beat_race
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_video_standby
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_sdram_real
```

### 7.2 再验五项扩展与产品链

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_video_transition
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_playlist_transition_preview
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_bmp_scale_full
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_osd_playlist
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_osd_display
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_video_effects
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_audio_dsp
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_audio_visualizer
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_av_sync
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_playlist
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_wav_select
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_thumbnail_buttons
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_osd_guide
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_osd_log
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_video_standby
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_config_event_log
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_product_flash
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_uart_slim_reporter
python scripts/test_package_content.py
```

`tb_sdram_real` 默认流量用例可作为正常回归。它的 `-GFULL_RES=1` 完整分辨率变体曾测到刷新最大间隔 47.504 µs，超过该用例的 40 µs 门槛；旧 FIFO 判断也复现同值。像素、音频和 SDRAM 协议检查通过，但**不能把该完整分辨率变体记为全绿**，应单独跟踪刷新指标。

`tb_product_flash` 用唯一 W25Q64 store 验证参数和事件并发、重启后恢复；`tb_parameter_persistence`、`tb_config_flash_single`、`tb_flash_bus_arbiter` 分别验证模块边界。实物上的掉电恢复仍要用第 7.3 节确认。单槽参数记录若在擦写中断电，可能回默认值，不能承诺保留上一次配置。

### 7.3 实卡验收顺序

1. 唯一演示卡无按键冷启动，先见首图；自动模式可继续预填四图，然后才启动 WAV。若仍停在加载页，记录 bit MD5、屏幕图片数、串口阶段码、TF 卡格式与首张图文件大小。
2. 录制首轮 1→2→3→4→1 与第二轮切换，逐个节拍核对每拍恰好一张，尤其确认第一次 3→4 不漏拍、4→1 不连跳。12.5 MHz 速度需用同一卡完成至少 3 次冷启动、3 次 RESET/PROGRAM 和 20 次连续切图；若出现坏图/重试，将产品顶层 `SD_SPI_HIGH_SPEED_DIV` 设回 2 重编 bit 复核。
3. 按第 6 节操作：查看双语字幕、四图、两首音乐；按 S9–S12 固定转场并连续切图；调亮度、对比度和音量。每个画面功能留照片，转场和音画联动留视频。
4. 调参后保持按键不动至少 2 秒，记录数值，正常断电、重新上电，确认四项参数恢复且 LOG 中旧事件仍可读。首次空 Flash 回默认值是正常现象。
5. 播放中拔出并插回**同一张卡**，确认没有花屏或死机，扫描与播放恢复。不要在唯一卡上截断文件或清空节目单；这些故障在仿真中验证。
6. 运行至少 30 分钟观察花屏、无声、卡死、异常健康位；如果报告要声称 72 小时稳定，必须真的做 72 小时连续试验并保存记录。
7. 抓串口并生成报告（将 `COM5` 换为实际端口）：

```powershell
python scripts/uart_status_monitor.py COM5 --save demo_capture.txt --report-html demo_report.html --report-csv demo_report.csv
```

### 7.4 当前状态信号的正确解释

- 自检页的“SDRAM 读写环回”当前实际取**视频缓冲是否曾读空**，不是独立的 SDRAM 写后读回测试；SDRAM 正确性还要看 `tb_sdram_real` 和实卡完整画面。
- 自检页的“HDMI 显示锁定”当前取**视频 PLL 锁定**，不是读取显示器真实锁定状态。
- “参数存档”取 W25Q64 参数记录校验结果；首次空 Flash 为红点并采用默认值，保存且下次重启读回有效记录后应变绿。绿点只证明记录有效，不替代断电恢复实测。
- 串口每秒输出带完整字段名的状态行：`UPTIME`、`IMAGE`、`AUTO_MODE`、`TF_CARD`、`WAV_AUDIO`、三项等级、`TRANSITION`、`PLAYLIST_ERRORS`、`LOAD_PHASE`、`HEALTH`。`LOAD_PHASE` 给出文字阶段，`PLAYLIST_ERRORS` 才是实际错误行数。
- 产品信息页和 LOG 页属于状态展示；其绿点/数字不能替代断电、拔卡、坏图和画面完整性的专项验收。

## 8. 上板记录格式

### 三分钟单卡演示

| 时间 | 操作 | 产品能力 |
|---|---|---|
| 0:00–0:35 | 板卡与屏幕同框，给已插好唯一 TF 卡的设备上电，拍封面、自检和首图 | 插卡即播 |
| 0:35–1:15 | 听 WAV、看双语字幕和 LED/波形；按 S9–S12 选转场并连续切两张图 | 音画同频、固定转场 |
| 1:15–1:55 | KEY3 调亮度、对比度，S1/S4 改音量；保持按键不动并等待至少 2 秒 | 现场调节与参数保存 |
| 1:55–2:30 | 正常断电、重新上电，对照重启前后的 OSD 数值和音量 | 设置记得住 |
| 2:30–3:00 | SW1 打开信息页/LOG，展示这次启动和切图记录 | 运行可追溯 |

所有动作使用同一张 FAT32 卡；坏图、空卡和非 FAT32 拒绝仅用仿真证明，不剪接成实卡功能视频。首次演示前先完整排练启动与保存时间，避免在三分钟计时中等待大图或 Flash 操作。

每一组功能记录一次；不通过时保留失败现象，不要只写“重试后通过”。

```text
日期/测试人：
bit 文件/MD5：
TF 卡编号/FAT32/内容清单或镜像哈希：
显示器及 HDMI_B、音频设备、串口号：
功能编号与操作：
预期：
实际（首图秒数、图号、音量、故障码等）：
证据（照片/视频时间点/串口日志/仿真输出）：
结果：PASS / FAIL / NOT TESTED
复测版本与结果：
```

完整现场步骤也可对照[上板功能验证单](BOARD-VALIDATION.md)。实际结论以烧录 bit 的 MD5、当前 RTL 与实板记录为准。

## 9. 代码保留但当前 bit 未启用的功能

| 项目 | 当前状态 | 何时能算“已交付” |
|---|---|---|
| 旧 `TEXT.TXT` 与非 FAT32 原始扇区回退 | 仓库保留兼容 RTL 和仿真；单卡产品顶层用编译期开关关闭，不进入当前 bit | 仅旧兼容版本可用；本产品只验 FAT32+节目单 |
| IIR 音效、独立五段增益 | `audio_eq.v`/系数 ROM 保留；容量版使用 4 档分频音效预设 | 新版本明确例化，频响、资源、音频实听验证通过 |
| 无 WAV 测试音、呼吸灯、ADC、数码管/蜂鸣器 | 当前发布版未启用或未接板 | 对应硬件和 RTL 真正接入并上板验证；不得仅凭旧 README/报名文案宣称存在 |

特别注意：参数保存逻辑已进入上述新 bit，**实卡掉电恢复尚未验证**；上一版 `signage_subtitles_seed13.bit` 不具备该功能。
