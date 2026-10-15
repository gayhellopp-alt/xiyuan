# C/E 结构状态：2026-10-14

本轮根据“先进行结构上的补全跑通”，将FFN顺序功能闭环优先于输出FIFO和tile重叠优化。当前功能自检、两配置VU9P综合/OOC、旧基线回归、失败探针及完整交付审计均已通过，实际脚本退出0。最终证据见 [ffn_validation.md](ffn_validation.md)、[ffn_delivery.json](../build/ffn_delivery.json)，未用工具运行中的中间报告替代最终结果。

## 当前闭环

| 结构 | RTL状态 | 集成及验证范围 |
|---|---|---|
| W4A8分组线性层、局部输入缓存与双snapshot | 已完成，原w4a8_wave保留 | GEMV/GEMM、尾tile/group、背压、暂停及复位；独立器件验证 |
| group scale乘法、宽组间累加、Q16.16输出 | 已完成 | 原数值合同、位精确逐阶段比较 |
| 外部scale Q16.16→INT8 | 已完成 | 独立requant_group，非零scale、舍入、饱和、错误接口 |
| 动态absmax、scale编码和group Buffer | 已完成 | 独立requant_dynamic，group32/12，clip/sat及复位 |
| 两层线性连接 | 已跑通TB | 原tile坐标重排；早期坐标适配器为TB，未综合统一两层系统 |
| FFN gate/up坐标配对、SiLU、乘法、down动态requant | 已新增可综合RTL | ffn_bridge，有限同步RAM，任意坐标、非法/重复检测，单活动任务 |
| gate/up→SiLU×up→requant→down | 已跑通TB | 三个原4×4核心、有限packet源；group32/12；18任务/8阶段复位恢复各配置 |
| 有效槽变体 | 独立RTL与八配置自检通过 | 4×4/8×8 VU9P综合/OOC与回归完整通过；不作为FFN功能前提 |
| 输出FIFO/tile ping-pong与阶段重叠 | 未实现 | 当前顺序通路具备背压，可正确跑通；性能工作后置 |

“可综合模块”与“完整TB组合”分别列出。FFN中间通路已从原来只有TB坐标组装推进到真正的RTL；down qx/sx packet存储、统一任务图和外存完成语义仍需要队友A/D、B/F接入。原INT8队列与W4A8统一接入也不在当前FFN TB中。

## 距离Transformer block仍缺什么

| 后续结构 | C/E责任 | 与队友依赖 |
|---|---|---|
| RMSNorm及残差 | 数值合同、归约/倒平方根近似、逐元素算子 | 张量生命周期、任务调度、搬运 |
| RoPE | 位置/系数接口、定点旋转与误差验收 | 位置标签、系数存储及KV写入布局 |
| Attention QK/PV与Softmax | 动态矩阵算子、缩放、mask/归约、指数/归一化 | 队友B/F提供KV有效长度、读写和Attention接线；A/D调度 |
| 完整FFN/Transformer统一任务系统 | 提供已验证数值模块、接口和回归 | 队友A/D统一顶层/软件，B/F有限存储桥与写确认 |
| 模型与板级运行 | 真实模型数值对齐、硬件算子证据 | 模型导出、板卡、DDR/PCIe与运行时由对应队友集成 |

当前没有完整Transformer/LLM token推理闭环，不能把FFN合成矩阵通过表述为真实模型可运行。结构进度按闭环级别描述，不用无明确分母的百分比。

## 接入可直接使用的合同

W4A8共享请求和输出接口保持；新FFN输入接受带branch/row/col的Q16.16元素，输出按down row/K-group的INT8 qx和UQ4.12 sx，并区分group last、task last、中间done及最终写回确认。见 [ffn_interface.md](ffn_interface.md) 和 [ffn_numerics.md](ffn_numerics.md)。普通模块reset取消未完成任务，不清RAM，重新完整初始化有效元素后恢复。

下一轮结构优先时，先对齐队友当前统一任务/存储分支的实际接口，再选择RMSNorm/残差独立基线，之后RoPE与Attention数值通路。继续保留当前顺序FFN作为对照，输出FIFO、有效槽替换和并行gate/up安排在功能接口稳定后。
