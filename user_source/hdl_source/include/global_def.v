


`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

// 第 5b 步修复（官方 bug）：原来写成 `define SDR_CLK_PERIOD 1000000000/125000000 没加括号，
// SELF_REFRESH_INTERVAL 展开成 64000000/1000000000/125000000/2048 = 0（整数除法从左往右），
// sdr_init_ref 的刷新计数器卡在 0，SDRAM 从来不刷新。显示缓冲每秒被读 60 次所以画面没事，
// 音频区一轮才读一次，电荷漏掉的位会翻转，播出来是"滴答"声。
// 刷新间隔按 sdr_init_ref 注释"64ms 内 4096 次"取 15.625us = 1953 拍（原公式按 2048 行算是 3906 拍）
`define	  SDR_CLK_PERIOD				(1000000000/125000000)
`define   SELF_REFRESH_INTERVAL			(64000000/`SDR_CLK_PERIOD/4096)

