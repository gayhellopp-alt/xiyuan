# C/E 主线：新会话接续提示词

2026-10-14 最新指示是“先进行结构上的补全跑通”。小型FFN顺序功能基线、两配置VU9P综合/OOC、旧基线回归与完整交付审计已经实际退出0；有效槽提示词3的器件与回归也已完整收尾。先读 [FFN接续记录](session_handoff_ce_ffn.md)、[当前结构状态](ce_structural_status.md)、[FFN实际验证](ffn_validation.md) 及 [有效槽接续](session_handoff_ce_valid.md)。输出FIFO/重叠暂后置，下一轮结构可从RMSNorm/残差开始并对齐队友统一任务/存储接口。下面任务提示词/历史快照保留，原“仅做一个任务、按3→4→5”的推进建议须结合用户本轮结构优先指示理解。

后续更新：提示词2的动态scale、有限同步group Buffer和两层W4A8 TB验证已完成，完整仿真/失败探针/VU9P综合OOC/旧requant及W4A8回归流程退出0。下一轮按提示词3执行，先读取 [动态接续记录](session_handoff_ce_dynamic.md) 与 [动态实际验证](dynamic_validation.md)。下文原始提示词与先前快照保留。

2026-10-13 更新：提示词1已交付独立外部scale requant，并实际完成自检、VU9P综合/OOC和原W4A8回归。下一轮执行提示词2前，请先读取 [本轮接续记录](session_handoff_ce_requant.md) 与 [实际验证](requant_validation.md)。下文保留原始提示词及历史快照。

用法：先发送“提示词 0”，再发送一个任务提示词。建议按 1→2→3→4 推进，FFN 留到前述基础通过后。以下任务尚未实现；历史结果仅为交接快照，新会话必须核对当前文件。

## 提示词 0：通用交接背景

~~~text
请在 E:\speed-up 的现有 FPGA Transformer/LLM 加速器工程中继续工作。保留已验证实现，实际创建/修改文件、执行工具并修复问题，不重新搭建工程，也不只给方案。

先核实环境、读取适用 AGENTS.md，检查当前文件与队友变更。
Windows/PowerShell；Vivado 2025.2：E:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat。
PowerShell 用 & 调用 .bat；若实际在 WSL，经 Windows 命令解释器处理路径。
不要改全局环境或安装大型依赖；所有文件和输出留在项目中。
part 沿用 xcvu9p-flga2104-2L-e，先核实本机支持。它只是临时评估part，板卡未确认。
时钟目标10ns，OOC内部时序与板上频率分开。之前没有发现VCS安装，有脚本但未验证，不假定工具/许可证存在。

必读：
README.md、config/project.json
docs/team_work_packages.md、project_status.md、upstream_reuse.md
docs/w4a8_numerics.md
docs/w4a8_wave_architecture.md、w4a8_wave_validation.md、w4a8_wave_performance.md
rtl/w4a8_wave.sv、systolic_array.sv、systolic_pe.sv、sync_sdp_ram.sv
tb/tb_w4a8_wave.sv、tb/w4a8_reuse_memory.sv
model/w4a8_reference.py、w4a8_systolic_vectors.py
scripts/run_w4a8_wave.ps1、synth_w4a8_wave.tcl
build/w4a8_wave_delivery.json、w4a8_wave_summary.json
同一行未重复目录前缀的文件属于该行列出的目录。

当前主线 w4a8_wave：
4×4/8×8 output-stationary 脉动阵列，A向右/B向下；packed INT4权重双bank；
单M epoch全K激活缓存并跨N复用、双group psum、独立scale流水。
同group跨K tile保留波前，WAIT_TILE/PRIME冻结，只group末排空。
已验证GEMV/GEMM、尾块、不完整group、暂停、输出背压、连续任务和复位。
每接缝仍有两拍；按全部物理RC槽保存/后处理；尚无层间requant、输出tile流水或FFN。
matmul_top/npu_top是独立INT8基线；INT8队列尚未接W4A8。
外存供数是TB模型，无真实DDR/PCIe或统一W4A8任务地址系统。

数值合同：
qx signed8[-128,127]；qw signed4[-8,7]，无zero-point。
W按输出通道连续K，偶K低nibble、奇K高nibble。
sx按row/K-group，sw按group/output channel，unsigned16 UQ4.12。
group psum signed32按模2^32累加；group完成后乘scale。
组间signed64 Q24合并，最终shift8最近舍入、tie远离零，饱和为signed32 Q16.16。
默认MAX_M/N=64、MAX_K=4096、group32，另验证group12。容量边界未全部仿真。

历史证据须核对源码：
409任务、11715输出、37773组psum/scaled检查；失败探针退出1。
4×4综合2686LUT/2437FF/21DSP/5RAMB36+2RAMB18；
8×8综合4278LUT/3908FF/69DSP/9RAMB36+2RAMB18。
10ns内部OOC WNS为+4.128/+4.129ns，无板上验证。
连续供数8×16×96用例4×4为2209周期、8×8为1403周期。

现有入口：
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_wave.ps1 -AuditOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_wave.ps1 -Directed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_wave.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_wave.ps1 -Implement
AuditOnly只审计已有产物，不能算作新增RTL的仿真。

三人分工：
我负责C/E：计算、片上数据流、后处理、数值、层间转换。
队友1负责A/D：控制、软件、模型导出、统一系统集成。
队友2先B后F：存储适配，再KV/Attention集成。
本会话聚焦C/E，不接管完整DMA/运行时或队友统一顶层；协同接口写清。

openTPU与llama-fpga只是外部参考及可选来源，目前没有代码接入。
openTPU主许可证Apache-2.0，但有单独GPLv3的ASIC目录；
llama-fpga授权未明确，当前仅作架构参考。
核查副本在build/upstream_review，不直接作为生产依赖。
FP4/FP32、AWQ/zero-point不能直接替换当前INT4/定点格式。

只完成随后指定的一个任务。先简短说明实际现状，然后执行。
保留历史基线，避免覆盖无关内容。明确同步RAM延迟、有限端口、握手/背压和Buffer所有权。
用Python位精确参考、SV自检、超时和非零失败探针验证，不修改golden掩盖失败。
新模块定向通过后跑相关回归、实际VU9P综合，条件允许OOC。
源码/参数与结果可追溯；实际通过、未运行、阻塞与资源/周期据实记录。
普通可逆工作无需逐项确认。
~~~

## 提示词 1：层间 requant 最小基线（建议先做）

~~~text
请实际实现Q16.16→INT8激活及row/K-group scale的独立可综合模块。
本轮先支持外部指定unsigned16 UQ4.12 scale，动态scale放下一轮。

输入signed32 Q16.16编码T，scale编码S；非零S时：
qx = saturate_int8(round(T/(16*S)))。
最近舍入、tie远离零。先规定S=0、INT32_MIN、饱和及非法group行为，
建立逐步位精确Python参考，不能截取输出低8位。

定义单活动row/group同步接口，含有效长度、组标识、scale、握手及状态。
原引擎按tile输出；若本轮不做坐标组装，明确需要上游提供group顺序，不能宣称直接连线。

覆盖group32/12、尾组、不同scale、零/正负/边界、tie、最小非零scale、饱和、
输入暂停、输出背压、连续group和运行中复位。INT32_MIN取绝对值须扩展位宽。
采用除法或倒数均须报告实际资源与周期。

新模块优先放rtl/vector、model/vector、tb/vector。
交付参考模型、SV自检、超时、失败非零探针、一键PowerShell脚本、数值/接口/验证文档。
实际仿真及VU9P综合，检查存储/DSP/latch/警告，记录延迟/吞吐。
原W4A8数值和接口保留。明确动态scale、两层串联尚未完成。
~~~

## 提示词 2：动态 scale 与两层连接

~~~text
先检查上轮requant是否实际通过，缺失则先完成。
增加row/K-group动态scale：统计absmax、编码UQ4.12 scale、量化并输出qx/sx。
使用有限同步group Buffer，明确收集、求scale、输出、释放生命周期；支持group32/12和尾组。

规定全零组、最小非零scale、舍入、饱和、INT32_MIN及错误行为。
UQ4.12最大scale不能覆盖全部Q16.16范围，必须选择并验证明确的饱和/状态或拒绝策略，
不得静默扩大格式。

模块通过后，用独立TB存储/组装适配器验证：
第一层W4A8输出→按第二层K分组requant/sx→第二层W4A8。
第一层输出按tile排列，必须按坐标组装，不能假定group连续。
第二层sw独立提供，group编号和scale不能混用。

逐阶段比较RTL与位精确参考，另报量化/定点相对浮点误差。
用小型固定种子矩阵，覆盖多个group、尾块、暂停、背压、连续任务和复位。
真实DMA/运行时由队友负责，本轮用TB适配器供数。

实际跑模块/两层自检及受影响基线回归，VU9P综合，条件允许OOC。
记录Buffer映射、周期、流量、scale范围和饱和数，更新数值、接口和验证文档。
~~~

## 提示词 3：只处理有效槽的计算优化

~~~text
在w4a8_wave基础上创建独立优化版本，只保存/后处理有效ml×nl槽，减少M=1和尾块开销。
保留原顶层、golden、测试与报告作对照，数值逐元素不变。

验证slot坐标、同步psum/Y读延迟、sx/sw索引、双snapshot所有权、组间RAW hazard、
post_pause、输出背压、连续波前和复位。
按新时序更新周期闭式与统计并独立审计，重叠计数不重复相加。

至少验证4×4、8×8、2×3/group12和1×1。
对照1×13×96、4×12×96、8×16×96、9×11×67，覆盖连续/受限供数。
保留位精确、逐PE/冻结、失败非零和超时检查。

实际回归、VU9P综合，条件允许OOC；报告周期变化、资源代价、存储/DSP/latch/警告。
性能下降也据实记录。本轮不同时改Decode映射或加输出tile流水，只交付一个独立优化。
~~~

## 提示词 4：输出 FIFO / tile 双缓冲

~~~text
在实际通过的计算版本上增加输出FIFO或结果tile ping-pong，
使后处理/输出与下一output tile计算重叠。先说明方案、深度和生命周期。

现有Y仅保存一个tile的INT64合并结果；下一tile的INIT_Y不得覆盖未接收输出，
空间不足必须反压。保持out_m/n/data/last合同、舍入/饱和时点，不能先舍入各group。
存储采用有限同步端口。

测试长期背压、满→恢复、同拍读写、尾tile、最后元素、连续两任务和活动复位；
独立scoreboard逐元素比较，超时/失败非零，跑相关多配置回归。

对照连续/受限供数及输出受限条件，测实际重叠、等待和总周期；
实际VU9P综合/OOC评估资源与内部时序。外存写回由队友负责，
说明out_last与writeback_committed区别，以及缓冲容量/反压行为。
~~~

## 提示词 5：后续小型 FFN（基础模块通过后）

~~~text
在已验证W4A8与requant基础上实现小型SwiGLU FFN：
gate/up投影→SiLU(gate)×up→requant→down投影。

核对依赖，规定SiLU近似、逐元素乘及格式转换的位宽、舍入、饱和与误差阈值；
Python参考→独立RTL自检→小FFN集成。
可参考openTPU，数值以本项目为准；不引入llama-fpga未明确授权源码。

用小型尾块矩阵和不同group scale，逐阶段比较位精确参考，另报浮点误差，
覆盖暂停、背压和复位。用TB适配器提供任务/供数，不接管队友DMA/运行时。
实际仿真、VU9P综合，记录各阶段周期/资源，并明确中间张量和任务接口。
~~~

## 每轮完成后保留接续信息

最终报告应给出：推荐顶层、修改文件、实际命令/退出码/产物、源码/参数身份、
正确性/误差/周期/资源/时序证据、未运行与阻塞项、需与队友对齐的接口，
以及下一轮对应提示词。
