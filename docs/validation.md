# 阶段二 W4A8 当前入口

现已新增独立流式分组量化顶层，原 INT8/NPU 实现与历史报告保留。当前规格及实际结果见 [W4A8 架构](w4a8_architecture.md)、[数值规格](w4a8_numerics.md)、[验证](w4a8_validation.md)、[性能](w4a8_performance.md)、[后续计划](w4a8_next_steps.md)。以下为既有基线记录，资源数字不代表新 W4A8 顶层。

---

> NPU 有序任务前端的当前综合与测试结果见 [npu_validation.md](npu_validation.md)。本文保留原矩阵核心验证记录；各顶层资源分别报告。

> 当前默认已更新为 B tile 双缓冲；本轮八组仿真和 synth_db 报告见 [double_buffer.md](double_buffer.md)。本页保留第一轮结果，optimization.md 保留上一轮单缓冲结果。

# 实际验证记录

> 本页下文保留第一轮原始模式（OPTIMIZED=0）的实际结果。当前默认已切换为优化模式 OPTIMIZED=1；本轮四组回归、优化周期和新综合/实现结果见 [optimization.md](optimization.md)。两轮原始报告分别保存在 build/synth 和 build/synth_opt，不能混用。

本页记录 2026-10-11 在 E:\speed-up 的实际执行结果。源码、脚本与报告分离；没有用理论值代替工具结果。当前工作目录初始为空，已检查目录及父目录，没有发现适用的 AGENTS.md。全部 RTL 与模型自主实现，未下载或复制参考项目。

## 环境与执行证据

| 项目 | 实际值 |
|---|---|
| 终端 | Windows PowerShell 5.1.26100.9444 |
| Vivado / xsim | 2025.2，SW Build 6299465 |
| Python | 3.13.5，C:\ProgramData\anaconda3\python.exe |
| NumPy 独立交叉检查 | 2.2.6，全部 13 组 INT64 矩阵乘法与回绕参考一致 |
| 随机种子 | 20261011 |
| 实际器件 | xcvu9p-flga2104-2L-e，未确认板卡 |
| 时钟约束 | core_clk，10.000 ns（100 MHz 初步评估目标） |
| OOC 虚拟时钟源 | HD.CLK_SRC=BUFGCE_X0Y0，评估假设，非已确认的上层 BUFG |

Vivado 安装目录中的 vivado.bat、xvlog.bat、xelab.bat、xsim.bat 均存在。get_parts *vu9p* 查询成功，完整清单在 [installed_vu9p.txt](../build/installed_vu9p.txt)，实际选择在 [selected_part.txt](../build/selected_part.txt)。Synthesis 与 Implementation 许可在工具日志中成功取得，没有器件或许可阻塞，也没有下载/安装依赖。

实际执行入口包括：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_sim.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_synth.ps1 -Implement
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_synth.ps1 -ResumeReports -Implement
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_sim.ps1 -SingleConfig -CorruptExpected
python scripts/summarize.py
```

每个仿真目录的 commands.txt 记录了实际 xvlog、xelab、xsim 命令及参数，综合目录的 commands.txt 记录最后一次入口，commands_initial_failed.txt 保留首次入口。工具日志、CSV 与 checkpoint 是直接执行生成的原始证据。[build/summary.json](../build/summary.json) 汇总资源、约束、周期和源码 SHA256，summarize.py 会检查 PASS、每个任务的周期与报告字段。

## RTL 与参考模型通过结果

| 配置 | 矩阵数 | 逐元素输出比较 | 独立 PE 向量 | 断言/检查次数 | 最终状态 |
|---|---:|---:|---:|---:|---|
| ROWS=4, COLS=4, TILE_K=8 | 13 | 480 | 8 | 87340 | ALL_TESTS_PASS |
| ROWS=2, COLS=3, TILE_K=5 | 13 | 480 | 8 | 133555 | ALL_TESTS_PASS |

最终正式仿真脚本返回 0。原始结果在 [4×4 日志](../build/sim_4x4_k8/run.log)、[4×4 CSV](../build/sim_4x4_k8/results.csv)、[2×3 日志](../build/sim_2x3_k5/run.log)、[2×3 CSV](../build/sim_2x3_k5/results.csv)。下面列出实际有效 busy 周期，不包含 host 加载、结果读取和 pause 周期：

| 用例 | M,N,K | 输出数 | 4×4/K8 周期 | 2×3/K5 周期 | 逐元素检查 |
|---|---|---:|---:|---:|---|
| 0 zero | 4, 4, 8 | 16 | 155 | 500 | PASS / PASS |
| 1 signed | 4, 4, 4 | 16 | 151 | 252 | PASS / PASS |
| 2 int8_bounds | 4, 4, 8 | 16 | 155 | 500 | PASS / PASS |
| 3 random_rect | 3, 7, 6 | 21 | 306 | 738 | PASS / PASS |
| 4 cross_k | 4, 4, 19 | 16 | 458 | 1008 | PASS / PASS |
| 5 all_tails | 7, 9, 13 | 63 | 1836 | 2256 | PASS / PASS |
| 6 gemv | 1, 9, 17 | 9 | 1368 | 750 | PASS / PASS |
| 7 consecutive_nonzero | 5, 3, 11 | 15 | 608 | 558 | PASS / PASS |
| 8 consecutive_zero | 5, 3, 11 | 15 | 608 | 558 | PASS / PASS |
| 9 minimal | 1, 1, 1 | 1 | 148 | 60 | PASS / PASS |
| 10 full_capacity | 16, 16, 32 | 256 | 9872 | 21072 | PASS / PASS |
| 11 tall_rect | 13, 2, 9 | 26 | 1208 | 882 | PASS / PASS |
| 12 resume_after_reset | 2, 5, 7 | 10 | 308 | 248 | PASS / PASS |

覆盖零矩阵、正负混合、INT8 −128/127、固定随机矩阵、矩形矩阵、K 跨 tile、三维尾块、M=1 GEMV 和最大容量。相同尺寸的 consecutive_nonzero → consecutive_zero 连续任务之间没有 reset，结果验证旧部分和已清除。整个用例序列也不依赖任务间复位。

所有未使用容量先填非零 poison，再写本任务有效 A/B，防止尾块误读恰好遇到零而假通过。白盒断言同时检查 A/B 读和 P 写的物理容量地址及逻辑 M/N/K 边界。运行中逐次独立提交写、start、读请求，确认 busy 时均被拒绝且不污染任务。奇数编号任务以固定周期模式暂停/恢复，计数器满足 elapsed=active+stall；例如 all_tails 默认配置 1836 有效周期、246 暂停周期、2082 总周期。空闲输入请求和完成后的结果请求保持跨 pause，再在恢复时握手，也已通过。

复位验证包括初始复位、运行中装载阶段、RUN 阶段、SAVE 阶段中止，以及保留 A/B RAM 后重新启动并逐元素比较。复位清除状态、PE 与计数器，RAM 不做整片清零。done 的单周期行为、非法零尺寸、超容量尺寸、非法输入/结果坐标也已检查。

PE 的 8 组独立向量检查符号乘法、最大/最小输入、正溢出、负溢出、seed 加载、enable 保持与复位。Python 还执行了 K=131073 的自然溢出点积自检；默认矩阵 K≤32 无法自然产生 INT32 溢出，因此不声称做过超容量矩阵的 RTL 溢出压力测试。

最终版本的故障注入把第一个期望值从 0 改为 1，仅写入独立 sim_4x4_k8_negative 目录。在恢复结果读时触发 Fatal: CHECK_FAILED: resumed read result；上层 PowerShell 实际退出码为 **1**，且没有 PASS.txt。此前同一故障也在主输出逐元素检查触发 MISMATCH。正式向量未被篡改；[负向测试日志](../build/sim_4x4_k8_negative/run.log) 与 observed_exit_code.txt 保留证据。xsim 原生进程在 $fatal 后可返回 0，所以脚本必须同时验证成功/失败标记。本次确实检查了这一行为。

## 器件级综合资源与存储

仅默认 4×4/K8 配置进行了器件综合和额外实现，备选 2×3/K5 只做 RTL 仿真。默认容量为 16×16×32。

| 资源 | 综合实际使用 |
|---|---:|
| CLB LUT 总数 | 750（含 LUT combining 调整） |
| LUT as Logic | 686 |
| LUT as Distributed RAM | 64 |
| CLB FF | 225 |
| DSP48E2 | 16 |
| RAMB18E2 | 3 |
| RAMB36 | 0 |
| Block RAM Tile 等效值 | 1.5 |
| URAM | 0 |
| Latch | 0 |
| Black box | 0 |

证据：[完整资源报告](../build/synth/utilization_synth.rpt)、[层级资源报告](../build/synth/utilization_hier_synth.rpt)、[原语计数](../build/synth/primitive_counts.txt)、[RAM 报告](../build/synth/ram_synth.rpt)、[首次综合日志](../build/synth/synth.log)。原语计数中的 DSP_ALU/DSP_MULTIPLIER 等是 DSP48E2 的工具内部拆分视图，不能作为额外 DSP 累加；物理 DSP 数为 16。

A 与 B 矩阵分别为 512×8，同步 1R1W，每个映射一个 RAMB18E2；P 为 256×32，同步 1R1W，映射一个 RAMB18E2。8 个 tile 银行各为 8×8，共映射 8 个 RAM32M16（64 LUT），没有把整个矩阵展开成任意多端口寄存器阵列。PE 的乘法、累加和部分和寄存器被吸收进 16 个 DSP48E2，日志包含 A/B Size=8、P Size=32、MREG=0、PREG=1。225 个 CLB FF 不包含 DSP 内部 P 寄存器。当前窄小 BRAM 与 tile LUTRAM 的空间利用率较低，是小型基线与独立银行端口预算的结果。未出现 latch、未解析黑盒或异常大规模存储寄存器化。

核心 synth_design 完成时报告 **0 errors、0 critical warnings、0 warnings**。INFO Synth 8-7052 指出三个 BRAM 未吸收可选输出寄存器；当前单周期同步读满足已验证 FSM，额外 BRAM 输出寄存器会改变延迟合同，需要一起修改控制器与测试。

## 综合时序与未约束路径

补齐虚拟 OOC 时钟源后的综合内部结果：WNS **+7.192 ns**、TNS **0 ns**、WHS **+0.071 ns**、THS **0 ns**，setup/hold 失败端点均为 0。这是综合后估算，不是板上频率或完整实现签核。

| check_timing 项目 | 综合检查数量 |
|---|---:|
| no_clock | 0 |
| unconstrained_internal_endpoints | 0 |
| multiple_clock / loops / latch_loops | 均为 0 |
| no_input_delay | 126 |
| no_output_delay | 104 |

126 个输入和 104 个输出缺少接口延迟，属于尚未集成上层/板级接口的已知限制；没有用 false path 隐藏这些端口。不能据“所有已声明约束满足”声称全部路径已约束。证据：[综合时序汇总](../build/synth/timing_synth.rpt)、[内部路径明细](../build/synth/internal_timing_synth.rpt)、[check_timing](../build/synth/check_timing_synth.rpt)。

## 执行中修复

Windows .bat 启动器拆分等号参数的问题通过显式备选 TB wrapper 修复；xsim 生成 Tcl 时的 Windows 反斜杠转义问题通过正斜杠路径修复。首次 synth_design 成功并写出 synthesized.dcp，但报告脚本使用了不受支持的 redirect 命令；查询本机 check_timing 帮助后改为 -file。随后从该有效 checkpoint 恢复报告与 OOC 实现，RTL 与时钟 XDC 没有变化。首次 OOC 时钟源缺失警告 Timing 38-242 通过记录并应用 HD.CLK_SRC 评估假设修复。首次失败日志保留，修复后的入口默认可从 RTL 完整综合。

终端沙箱初始化曾出现基础设施故障，后续经自动审批的本地工具执行完成；没有修改全局环境。Python 汇总脚本也修复了 PowerShell Tee-Object 的 UTF-16 日志识别。核心检查均实际执行，未把这些执行异常描述成成功。

## 额外 OOC 布局布线结果

已实际执行 opt_design → place_design → route_design，恢复入口最终返回 **0**，并生成 [routed_ooc.dcp](../build/synth/routed_ooc.dcp)。这次没有板级管脚约束，时钟源使用前述虚拟 OOC 假设。

| 项目 | OOC 实际结果 |
|---|---:|
| CLB LUT（含 64 LUTRAM） | 738 |
| CLB FF | 225 |
| DSP48E2 | 16 |
| RAMB18E2 / URAM | 3 / 0 |
| 内部 setup WNS / TNS | +5.272 ns / 0 ns |
| 内部 hold WHS / THS | +0.044 ns / 0 ns |
| setup / hold 失败端点 | 0 / 0 |
| no_clock / 未约束内部端点 | 0 / 0 |
| 可路由网络 / fully routed 网络 | 1270 / 1270 |
| routing errors | 0 |
| explicit gap | 1 |

以上时序数值来自执行结束后的 report_timing_summary，不是路由器途中打印的估计数值。布局约 10 分钟，route_design 约 72 秒；VU9P 规模较大，即使逻辑很小仍有器件加载与布局开销。证据：[OOC 资源报告](../build/synth/utilization_ooc.rpt)、[OOC 时序汇总](../build/synth/timing_ooc.rpt)、[内部路径明细](../build/synth/internal_timing_ooc.rpt)、[route status](../build/synth/route_status_ooc.rpt)、[OOC DRC](../build/synth/drc_ooc.rpt)、[完整恢复/实现日志](../build/synth/resume_reports.log)。

**OOC 边界尚未完成上层集成。** 资源/时序报告生成时的设计状态为 Routed；最终 DRC 报告状态为 Partially Routed，存在 RTSTAT-10 Warning：37 条输出网络没有可路由负载（busy/done/error、32 位结果数据、rd_ready/rd_valid）。route status 还记录 1 个显式 gap。不能把 1270 条可路由网络完成描述为完整板级所有网络布线成功。

Route 35-198 警告指出未设置 HD.PARTPIN_LOCS，外部边界路径不能得到完整局部布线与可靠 I/O 时序。DRC 23-814 说明 OOC 模式未运行全部连接性 DRC；这些警告保留在日志中，没有静默降级或伪造接口位置来消除它们。route_design 自身报告 103 Warnings、0 Critical Warnings、0 Errors。内部数据路径的约束结果可用于本阶段评估，完整时钟/边界路由、外部延迟、板卡管脚与全部 DRC 需要在上层设计确认后完成。

## 理论峰值与实际周期

默认计算阶段每个 RUN 周期最多 16 MAC。假设 100 MHz，可计算理论上限 1.6 GMAC/s 或 3.2 GOPS（乘、加各算一次）。这不包括搬运、尾块、checkpoint 或主机接口。

16×16×32 测试有 8192 个有用 MAC，实际有效 busy 周期为 9872，RUN 共 512 周期，计算占比约 **5.19%**。按 TB 的 10 ns 时钟折算 busy 时间为 98.72 微秒；这是 RTL 仿真周期对应时间，且不包含 A/B 输入加载和结果读取。备选 2×3/K5 的同一任务为 21072 周期。GEMV 1×9×17 默认配置为 1368 周期，能够正确运行，但利用率较低。尚无板上频率、功耗、内存带宽、token/s 或端到端 LLM 性能数据。

## 验证范围与剩余限制

| 类别 | 内容 |
|---|---|
| 已实现并验证 | 默认和备选阵列的 INT8 GEMM/GEMV、跨 K tile、尾块屏蔽、最终结果、连续任务清零、运行中复位、请求背压、pause 恢复、计数公式、PE INT32 回绕 |
| 已实现并由综合检查 | 默认配置的 DSP 乘加映射、单端口预算、BRAM/LUTRAM 推断、无 latch、内部时钟和约束；额外 OOC 内部时序评估 |
| 已实现但尚未单独验证 | 所有可能的参数/容量组合、备选阵列的综合/实现、连续每周期结果读取吞吐、每个中间 K checkpoint 的外部逐元素读验、超过默认 K 容量的矩阵溢出压力测试 |
| 尚未执行 | 综合/实现网表功能仿真或等价检查、板级完整时序/DRC 签核、bitstream、上板测试与实测性能 |
| 未来计划 | DDR/HBM 双缓冲、PCIe/DMA/AXI 集成、Decode 专用调度、量化后处理、FFN、Attention、Softmax/RoPE/KV Cache/RMSNorm/SiLU、完整 Transformer |

硬件不检测输入是否全部装载；启动前写入有效范围由调用方保证。INT32 算术为回绕而非饱和，若后续数值契约要求 saturation 或 requantization，必须修改 RTL 和参考模型。当前输出 tile 处理时 PE 保留整个 K 维部分和，不支持上下文换出/重读恢复。没有板卡、真实外存或完整 LLM 任务；最值得先做的是测量并优化 tile 装载，再实现有严格端口预算的片上银行和双缓冲。完整优先级见 [next_steps.md](next_steps.md)。

所有必需的首版仿真与器件综合检查已完成；OOC 内部评估也已执行并明确记录边界限制。
