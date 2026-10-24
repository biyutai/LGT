# LGT 音画同频数字标牌（LGT-S1）

第九届（2026）嵌入式大赛 FPGA 赛道 · 安路选题一。

基于安路 EG4S20BG256 / HX4S20C 开发板的 TF 卡 HDMI 数字标牌，使用 Verilog 实现图片播放、WAV 音频、音画同步、节目单、双语字幕、OSD、画面效果、音频均衡和 Flash 参数保存。

## 工程内容

| 目录 | 内容 |
| --- | --- |
| `user_source/hdl_source/` | 顶层、视频、音频、TF/SD、SDRAM、Flash、公共模块及 IP |
| `user_source/constraints_source/` | 引脚与时序约束 |
| `td_project/` | 安路 TD 工程 |
| `sim/` | 仿真 testbench、文件列表、器件模型及运行脚本 |
| `scripts/` | 编译、烧录、素材生成、内容打包、校验和报告生成脚本 |
| `assets/` | 仿真及演示使用的 BMP、WAV 和节目单 |
| `doc/`、`docs/` | 架构、操作、功能说明与验证记录 |

## 打开与运行

开发环境：安路 TD 6.2.1、ModelSim、Python 3、Windows PowerShell / Git Bash。

在 TD 中打开 `td_project/HDMI1.4b_Transmitter_v1.0.al`，顶层模块为 `top`。
工程位置已调整为本次导出目录 `LGT/td_project`，源文件引用保留相对路径。
克隆到其他位置后，请检查 TD 的工程位置设置。

在仓库根目录运行：

```powershell
# 复位与同步逻辑仿真
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 tb_reset

# 命令行综合、布局布线及比特流生成
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/td_build.ps1

# 演示卡内容打包
python scripts/package_content.py assets/scale_demo --out build/card_demo
```

工具安装路径保留原工程配置：TD 为 `D:/Shop`，ModelSim 为 `D:/Shop/ModelSim/win64`；其他电脑请调整对应运行脚本中的路径。
Python 脚本按用途使用 `numpy`、`Pillow`、`python-docx`、`pyserial` 等依赖。
素材生成脚本依赖 Windows 字体；应急语音转换需提供原始语音 WAV；报告生成需另备官方 Word 模板。
这些辅助输入的原机路径可在对应脚本中修改。已生成的演示 BMP/WAV 已随仓库提供。

## 阅读入口

- [系统架构与数据通路](doc/系统架构与数据通路.md)
- [操作手册](docs/signage-operator-guide.md)
- [功能与验证记录](docs/FUNCTIONS-AND-VALIDATION.md)
- [上板验证记录](docs/BOARD-VALIDATION.md)
- [原工作区 README 快照](docs/ORIGINAL-README.md)

## 导出说明与来源

本仓库是从 GAME 当前磁盘文件提取的独立代码快照，包含导出时尚未提交的代码修改。
未复制原 Git 历史、编译输出、比特流、波形、缓存、TF 卡备份和助手配置。
`SOURCE-MANIFEST.json` 记录提取文件的 SHA-256；除 TD 工程位置及忽略规则外，复制的源文件按原始字节保存。
原 README 与文档中的历史 tag、旧路径、构建记录及本地比特流引用仅供追溯，相关历史与产物保留在原工作区。
此快照的提交与上传不代表新增的综合、时序收敛或上板验证结论；硬件验证状态以随附记录为准。

工程基于官方设计参考例程 5；HDMI 与 SDRAM 等加密 IP 保留原始文件及其声明。
当前仓库设为私有，比赛结束后可由仓库所有者在 GitHub Settings → General → Danger Zone → Change repository visibility 中改为 Public。
