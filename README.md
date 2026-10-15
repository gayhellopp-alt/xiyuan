# 当前 C/E：先跑通小型 FFN 结构

新增可综合 `ffn_bridge`：两个有限同步RAM按坐标组装gate/up，执行Q16.16 SiLU近似与逐元素乘法，再按down的row/K-group进行动态requant，输出INT8 qx及UQ4.12 sx。原W4A8投影和requant/dynamic数值保留；完整gate/up→SiLU×up→requant→down通过三投影TB逐阶段自检，group32/12各18完整任务及8阶段复位恢复。最终四配置自检/探针、两配置VU9P综合/OOC、原requant/dynamic/W4A8回归与完整交付审计均退出0。

```powershell
# 完整重现：参考、四配置自检、失败探针、两配置VU9P综合/OOC、旧基线回归
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_ffn.ps1 -Implement -Regression

# 独立完整功能自检及探针，不依赖器件流程已完成
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_ffn.ps1 -SimOnly

# 已有功能产物后仅跑器件/回归；或仅审计
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_ffn.ps1 -SynthOnly -Implement -Regression
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_ffn.ps1 -AuditOnly
```

[结构状态与后续缺口](docs/ce_structural_status.md) · [FFN数值](docs/ffn_numerics.md) · [输入/输出与团队接入](docs/ffn_interface.md) · [实际验证](docs/ffn_validation.md) · [接续记录](docs/session_handoff_ce_ffn.md)

完整三投影的packet供数/回填与阶段调度是有限TB适配；本轮新增综合顶层为ffn_bridge，统一任务系统/外存写回仍由队友集成。输出FIFO、tile重叠和完整Transformer其余算子为后续工作。

有效槽独立变体 `w4a8_valid` 保留原接口/数值，八配置自检、4×4/8×8 VU9P综合/OOC及原基线回归已完整退出0；FFN功能基线使用原w4a8_wave。入口 `run_w4a8_valid.ps1 -Implement -Regression`，文档 [有效槽架构](docs/w4a8_valid_architecture.md)、[验证](docs/w4a8_valid_validation.md)、[性能对照](docs/w4a8_valid_performance.md)、[收尾接续](docs/session_handoff_ce_valid.md)。

# 历史提示词2：动态 scale 与两层 W4A8 验证

新增独立 `requant_dynamic`：有限同步group Buffer收集Q16.16、absmax、非零UQ4.12 scale编码、复用已验证scalar量化。超过scale范围时钳位并报告scale_clipped及独立饱和状态。两层TB按第一层tile输出坐标写入512×32同步适配存储，再按第二层row/K-group读出，分别验证qx/sx及第二层独立sw；原W4A8和外部scale基线保留。

~~~powershell
# 四配置自检/两层复位恢复、失败非零探针、两配置VU9P综合/OOC、旧requant与W4A8回归
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_dynamic.ps1 -Implement -Regression

# 重新运行四配置与探针；或仅审计已有产物
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_dynamic.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_dynamic.ps1 -AuditOnly
~~~

[动态数值合同](docs/dynamic_numerics.md) · [接口/Buffer/两层边界](docs/dynamic_interface.md) · [实际验证与误差](docs/dynamic_validation.md) · [下一轮接续](docs/session_handoff_ce_dynamic.md)

两层适配属于TB验证，本轮综合顶层为requant_dynamic；没有宣称统一两层DMA/任务系统已综合。FFN、有效槽压缩和输出tile流水尚未实现。下面保留外部scale基线与历史计算主线入口。

# 外部 scale 层间 requant 基线

新增独立 `requant_group`：signed32 Q16.16 → signed8 INT8，外部非零 unsigned16 UQ4.12 scale，最近/tie远离零舍入与饱和；单活动 row/K-group、有效尾长度、标签/scale/握手、错误和饱和状态。原 W4A8 RTL/数值/接口保留。

~~~powershell
# 实际参考、自检、错误/超时非零探针、两配置 VU9P 综合/OOC和原W4A8八配置回归
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_requant.ps1 -Implement -Regression

# 仅重新仿真与探针；审计当前已有EDA（如存在）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_requant.ps1

# 只审计已有产物，不当作新功能仿真
python .\scripts\summarize_requant.py
~~~

已实际通过798组/10062输出，最小输出接受延迟34拍、同组输入II35拍；group32/12综合分别258/282 LUT、均188 FF，无DSP/RAM/latch/blackbox。10ns内部OOC WNS +7.047/+6.970ns，板卡未确认。

[数值合同](docs/requant_numerics.md) · [接口与上游组装边界](docs/requant_interface.md) · [实际验证](docs/requant_validation.md) · [下一轮接续及命令/修复记录](docs/session_handoff_ce_requant.md)

本轮没有动态scale或坐标重组，两层串联尚未完成；原引擎按tile输出，接入时需要上游按第二层row/K-group顺序组装。下一轮仅执行交接提示词2。以下保留原计算主线和历史实现入口。

# 当前计算主线：group 内跨 K tile 连续脉动波前

## 整体项目盘点与团队分工

[已完成模块、待完善项与结构空白](docs/project_status.md) · [队友工作包、接口与验收条件](docs/team_work_packages.md)


新增w4a8_wave：同group的tile末输入全部捕获后立即释放权重bank，WAIT_TILE/PRIME冻结在途token，新tile恢复后沿同一逻辑advance序列继续；只group末排空。4×4/8×8原脉动与广播基线保留，GROUP_STREAM=0为逐tile消融。新增独立逐PE原矩阵历史参考、输入饥饿接缝恢复/复位和bank重写覆盖。

~~~powershell
Set-Location E:\speed-up

# 八配置、自检失败探针与流量/周期/源码审计
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_wave.ps1

# 全回归 + 两尺寸VU9P综合及内部OOC
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_wave.ps1 -Synthesize
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_wave.ps1 -Implement

# 已有当前源码完整回归，仅器件工具；默认串行g4/g8
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_wave.ps1 -SynthOnly -Implement
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_wave.ps1 -SynthOnly -Implement -EdaConfig g8

# 定向 / 审计 / 故障注入（最后一项预期退出1）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_wave.ps1 -Directed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_wave.ps1 -AuditOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_wave.ps1 -SingleConfig -CorruptExpected
~~~

默认VivadoBin=E:\AMDDesignTools\2025.2\Vivado\bin，可用-VivadoBin/-Python覆盖；PowerShell通过 & 调用bat，无全局环境修改。缺少原基线时自动复现，缺少器件选择时查询本机VU9P；part继续为xcvu9p-flga2104-2L-e临时评估选择。10ns约束仅内部OOC，不是板上频率。

[协议与接缝安全性](docs/w4a8_wave_architecture.md) · [实际验证/资源/时序](docs/w4a8_wave_validation.md) · [周期对照](docs/w4a8_wave_performance.md) · [内部摘要](docs/w4a8_wave_brief.md)

结果位于build/sim_w4a8_wave_*、build/synth_w4a8_wave_*、build/w4a8_wave_summary.json与delivery清单。VCS脚本run_w4a8_wave_vcs.sh可配置已有Linux工具路径，编译/运行未验证。源码使用原systolic_pe/array和原W4A8参考向量；不将TB供数或历史参考综合进DUT。本轮没有无缝tile首读、输出tile流水、有效槽保存、DDR或完整模型。

以下保留各历史阶段的实现与命令。

---

# 当前增量：4×4 与 8×8 脉动阵列对照

新增真正相邻PE传递A/B及valid的output-stationary阵列，接入已有W4A8全K激活缓存、双W bank、双group psum、scale流水与输出背压。原广播基线保留，SYSTOLIC=0做同尺寸对照；本轮保守每K tile排空6/14推进拍。功能通过不等于周期更快，见实际性能报告。

~~~powershell
Set-Location E:\speed-up

# 独立4×4/8×8数学波前单元
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_systolic_unit.ps1

# 一键：上述单元 + 八配置W4A8回归 + 非零失败探针 + 源码/向量/流量/周期审计
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_systolic.ps1

# 全回归及四配置综合；Implement额外对s4/s8执行内部OOC
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_systolic.ps1 -Synthesize
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_systolic.ps1 -Implement

# 已有当前源码完整回归时，仅器件工具；默认串行四配置
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_systolic.ps1 -SynthOnly -Implement

# 定向 / 审计 / 单个EDA配置；b4/b8只综合，s4/s8可OOC
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_systolic.ps1 -Directed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_systolic.ps1 -AuditOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_systolic.ps1 -SynthOnly -Implement -EdaConfig s8

# 故障探针，预期退出1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_systolic.ps1 -SingleConfig -CorruptExpected
~~~

默认工具E:\AMDDesignTools\2025.2\Vivado\bin，可通过-VivadoBin/-Python配置；PowerShell用 & 调用bat。part沿用xcvu9p-flga2104-2L-e临时评估，Tcl每次核查本机可用性；10ns内部时钟目标，不设板级管脚/I/O delay。所有输出在build。若旧广播基线产物缺失，一键脚本会先复现该基线；若器件选择产物缺失，会查询本机VU9P支持。VCS入口run_w4a8_systolic_vcs.sh可配置已有Linux VCS_BIN/PYTHON/TB_TOP/GROUP_SIZE；编译执行未验证，未安装工具或申请许可证。

[结构与波前时序](docs/w4a8_systolic_architecture.md) · [实际验证/资源/内部时序](docs/w4a8_systolic_validation.md) · [同尺寸性能对照](docs/w4a8_systolic_performance.md) · [内部摘要](docs/w4a8_systolic_brief.md)

新增向量保留原12用例，并包含满8×8 Prefill、Decode17与8×8尾块；没有修改数值合同。新增array_pause与实际PE firing/推进/排空/暂停计数。原w4a8_reuse等历史顶层/测试/报告保留；本轮未做输出tile流水、group内连续波前、DDR或统一NPU队列适配。

以下为历史各阶段入口，当前结果以本节及最新报告为准。

---

# 当前增量：激活跨 N tile 复用

新增 w4a8_reuse：首 N tile 装载当前 M tile 的全部 K 激活，后续 N tile 使用按行同步缓存，只传 packed INT4 权重与 scale。保留已验证的 w4a8_post、w4a8_packed、INT8 GEMM/GEMV 和 NPU 基线；数值规则、双权重Buffer、双group psum与独立scale流水沿用。A_REUSE=0可进行原流量/周期消融。

~~~powershell
Set-Location E:\speed-up

# 七种配置完整回归，并从实际CSV/日志生成验证和性能报告
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_reuse.ps1

# 完整回归 + VU9P综合；-Implement还执行内部OOC布局布线
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_reuse.ps1 -Synthesize
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_reuse.ps1 -Implement

# 已有当前源码全部回归产物时，仅综合/OOC
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_reuse.ps1 -SynthOnly -Implement

# 定向自检 / 审计现有产物 / 故障探针（最后一项预期非零）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_reuse.ps1 -Directed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_reuse.ps1 -AuditOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_reuse.ps1 -SingleConfig -CorruptExpected
~~~

默认 VivadoBin=E:\AMDDesignTools\2025.2\Vivado\bin；PowerShell通过 & 调用bat，无全局环境改动；可通过 -VivadoBin/-Python覆盖可执行程序。part沿用 xcvu9p-flga2104-2L-e 临时评估选择，板卡未确认。所有输出在build，不将仿真外存模型加入综合。VCS入口 scripts/run_w4a8_reuse_vcs.sh 可配置VCS_BIN/PYTHON/TB_TOP/GROUP_SIZE，要求已有Linux安装和许可证；本机编译/运行未验证，不安装VCS。

[架构与缓存布局](docs/w4a8_reuse_architecture.md) · [实际验证/周期/资源](docs/w4a8_reuse_validation.md) · [内部交流摘要](docs/w4a8_reuse_brief.md) · [性能分类](docs/w4a8_reuse_performance.md) · [下一步讨论](docs/w4a8_next_steps.md)

最新产物：build/sim_w4a8_reuse_*、build/synth_w4a8_reuse、build/w4a8_reuse_summary.json。默认4×4/tile8/group32/BUS_BYTES8/A_REUSE1用于器件综合；其他测试配置不冒充已综合。req_activation是新增packet合同，供数端必须匹配；首N之后不再传A。qx缓存有M epoch fence，sx仍跨N重传，没有跨M预取。当前仍为广播阵列，无真实DDR/DMA、完整LLM或新的NPU任务队列连接。

以下段落保留各已完成阶段的命令与历史限制，当前状态以本节及最新报告为准。

---

# 当前增量：group 部分和双缓冲与独立 scale 流水

新增w4a8_post：两组同步INT32 psum RAM、每组scale/坐标snapshot、可暂停独立定点流水，下一group计算可与上一group缩放合并重叠。原w4a8_packed及其测试/报告保留；输入列对packet和数值不变。post_pause用于暂停后处理，队列满时保护PE sum和bank所有权。

~~~powershell
Set-Location E:\speed-up

# 七组消融/参数/压力/复位回归与报告
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_post.ps1

# 回归加VU9P综合；-Implement包含内部OOC实现
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_post.ps1 -Synthesize
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_post.ps1 -Implement

# 已有当前源码七组回归时，仅综合/实现
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_post.ps1 -SynthOnly -Implement

# 定向 / 已有结果审计 / 故障注入（预期退出1）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_post.ps1 -Directed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_post.ps1 -AuditOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_post.ps1 -SingleConfig -CorruptExpected
~~~

[生命周期与流水时序](docs/w4a8_post_architecture.md)、[实际验证/性能/资源](docs/w4a8_post_validation.md)、[内部摘要](docs/w4a8_post_brief.md)。
产物在build/sim_w4a8_post_*、build/synth_w4a8_post、build/w4a8_post_summary.json。
仅默认4×4/group32/双输入bank/流水重叠做器件综合，其余组合仅仿真。
run_w4a8_post_vcs.sh提供Linux/WSL入口，VCS编译执行未运行；工具路径选项与下文一致。
当前仍为广播阵列，无真实DDR、A跨N复用、输出tile重叠或NPU任务队列适配。

---

# 当前增量：W4A8 列对权重打包

新增w4a8_packed：一个64bit权重beat最多写两个32bit列bank，支持非连续keep、奇列/奇K起点/尾word，原w4a8_stream和w4a8_linear保留。仅数据包和权重RAM字宽改变，数值与group后处理不变。

~~~powershell
Set-Location E:\speed-up

# 六配置回归、流量/周期审计与报告
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_packed.ps1

# 上述回归加VU9P综合及可选内部OOC实现
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_packed.ps1 -Synthesize
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_packed.ps1 -Implement

# 当前源码已有六配置回归时，仅重跑综合/实现
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_packed.ps1 -SynthOnly -Implement

# 定向 / 审计已有结果
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_packed.ps1 -Directed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_packed.ps1 -AuditOnly

# 故障注入，预期退出1，只修改独立 negative 目录
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_packed.ps1 -SingleConfig -CorruptExpected
~~~

[列对架构和keep合同](docs/w4a8_packed_architecture.md)、[实际验证/性能/资源](docs/w4a8_packed_validation.md)、[内部摘要](docs/w4a8_packed_brief.md)。
产物：build/sim_w4a8_packed_*、build/synth_w4a8_packed、build/w4a8_packed_summary.json。
Vivado工具路径与-VivadoBin/-Python选项沿用下文；临时评估part仍为xcvu9p-flga2104-2L-e。
PACK_COLS=0可恢复旧packet行为，主机必须匹配编译布局；PACK_COLS1仅在BUS_BYTES8启用列对。
只有默认4×4/tile8/group32/64bit/scale-once/列对配置做器件综合，其余仅仿真。
run_w4a8_packed_vcs.sh提供Linux/WSL可配置入口，Bash语法检查通过，VCS编译执行未运行。
当前仍为广播MAC阵列，未实现psum/scale解耦、A跨N复用、NPU队列适配或真实DDR。

---

# 当前增量：64-bit W4A8 供数优化

新增独立顶层 w4a8_stream：可配置输入beat（已验证1/8字节）、keep尾掩码、每group末tile一次scale装载、A/B双缓冲，以及有效字节/beat/padding统计。原w4a8_linear和其测试报告保留，数值合同不变。A跨N tile复用及跨列packing仍未实现。

~~~powershell
Set-Location E:\speed-up

# 七组消融/参数/背压/复位回归和周期报告
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_stream.ps1

# 回归加VU9P综合；-Implement包含综合和内部OOC布局布线
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_stream.ps1 -Synthesize
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_stream.ps1 -Implement

# 已有七组回归时，只重跑综合/实现；审计会要求当前源码匹配
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_stream.ps1 -SynthOnly -Implement

# 仅默认定向 / 审计已有结果
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_stream.ps1 -Directed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_stream.ps1 -AuditOnly
~~~

[宽接口架构](docs/w4a8_stream_architecture.md)、[实际验证和性能](docs/w4a8_stream_validation.md)、[本轮交流摘要](docs/w4a8_stream_brief.md)。
新产物：build/sim_w4a8_stream_*、build/synth_w4a8_stream、build/w4a8_stream_summary.json。
模式0扩大名义输入带宽；模式1按相同物理字节预算限制供数，padding也占带宽，不能将连续供数收益直接推广到DDR。
本轮仅默认4×4/tile8/group32/BUS_BYTES8/SCALE_ONCE1做器件综合，其他组合仅仿真。
新入口不自动调用旧run_phase2；完整旧基线仍可用下文入口复现。
新增 scripts/run_w4a8_stream_vcs.sh 为 Linux/WSL 可配置七组VCS入口；仅Bash语法检查通过，VCS编译执行未运行。

---

# 阶段二交付：流式 W4A8 分组量化线性层

在原INT8矩阵核心与NPU队列基线基础上新增 w4a8_linear。默认4×4、K tile8、group32；另验证2×3、tile5、group12；权重/激活均支持ping-pong加载计算重叠，外部8-bit握手供数、分组INT32部分和、UQ4.12 scale、INT64组间合并、Q16.16输出及背压。旧顶层和回归保留，新W4A8顶层尚未接入旧任务队列。

## Windows PowerShell 从零复现

~~~powershell
Set-Location E:\speed-up

# 完整阶段二一键：既有基线 + W4A8定向 + 三配置回归 + VU9P综合 + 报告
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_phase2.ps1

# 可选追加内部 OOC 布局布线（不含板级管脚）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_phase2.ps1 -Implement

# 仅阶段二：三配置/三供数模式，生成验证/性能报告
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8.ps1

# 上述回归加综合；-Implement 同时包含综合与OOC
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8.ps1 -Synthesize
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8.ps1 -Implement

# 数值路径定向验证 / 审计已有结果
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8.ps1 -Directed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8.ps1 -AuditOnly

# 单独生成参考数据，不需要NumPy
python .\model\w4a8_reference.py --out .\build\w4a8_vectors

# 故障注入，预期非零退出1；独立 *_negative 目录
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8.ps1 -SingleConfig -CorruptExpected
~~~

Vivado默认路径 E:\AMDDesignTools\2025.2\Vivado\bin，可用 -VivadoBin 和 -Python 覆盖。所有Windows .bat经PowerShell &执行，Tcl使用正斜杠。脚本不修改全局变量，所有产物在build/。100 MHz只是初步评估目标；继续使用已确认安装的临时评估part xcvu9p-flga2104-2L-e，不代表确认板卡/最终封装/速度等级。synth_w4a8.tcl拒绝把其他器件作为本阶段结果。

## 交付与实际证据

| 内容 | 文件 |
|---|---|
| 可综合顶层与INT4解包 | rtl/w4a8_linear.sv、rtl/w4_unpack.sv |
| 位精确参考与B/C数值比较 | model/w4a8_reference.py、docs/w4a8_numerics.md |
| 自检TB与独立存储供数模型 | tb/tb_w4a8.sv、tb/w4a8_memory_model.sv |
| 综合/实现Tcl | scripts/synth_w4a8.tcl |
| 来源、流量、计数与EDA报告审计 | scripts/summarize_w4a8.py |
| [架构与接口](docs/w4a8_architecture.md) | bank生命周期、元素/地址映射、时序 |
| [实际验证](docs/w4a8_validation.md) | 114任务、1863输出、6456分组比较；工具/资源/时序限制 |
| [性能报告](docs/w4a8_performance.md) | GEMV/GEMM、供数条件、单/双缓冲对比 |
| [内部交流摘要](docs/w4a8_internal_brief.md) | 模块、任务示例、结果与讨论问题 |
| [阶段二后续计划](docs/w4a8_next_steps.md) | 基于证据的三项设计讨论 |

日志/命令/源文件SHA256：build/sim_w4a8_*/；原始周期CSV：results.csv；
综合/OOC报告与DCP：build/synth_w4a8/；完整汇总：build/w4a8_summary.json。
验证/性能文档由汇总脚本根据真实产物更新，无报告时明确标未完成。

## VCS（本机未发现，执行未验证）

Windows PATH及WSL Ubuntu探查未发现VCS。提供Linux/WSL可配置脚本；已做bash语法检查，未执行VCS编译或申请许可证。未来已有Linux VCS环境时，可从PowerShell调用：

~~~powershell
# 按已有安装修改Linux可执行路径，不能填Windows .bat路径
wsl.exe -d Ubuntu --exec env VCS_BIN=/opt/synopsys/vcs/bin/vcs PYTHON=python3 bash /mnt/e/speed-up/scripts/run_w4a8_vcs.sh
~~~

原生Linux：VCS_BIN=/实际路径/vcs bash scripts/run_w4a8_vcs.sh。
可配置 TB_TOP=tb_w4a8_alt GROUP_SIZE=12 只运行备用组合。
该脚本不安装软件；现有XSim结果不代表VCS已经通过。

## 阶段边界

W4A8是自主对称量化基线，无zero-point，不宣称AWQ兼容。逻辑M/N≤64、K≤4096；本次小型代表性任务最大K=96，最大逻辑容量未实测。完整LLM需要外存地址、调度、量化导入和算子链。本阶段不含真实DDR/PCIe/DMA或完整Transformer；OOC不能证明板上频率、token/s或功耗。

---

# 既有 INT8 / NPU 基线记录

以下保留原阶段的说明、复现入口与历史资源数字；其中“量化后处理为后续阶段”等表述属于当时的旧顶层范围。本阶段新顶层的当前状态以以上入口和W4A8文档为准。

# FPGA INT8 NPU / Transformer / LLM 计算基线

已在当前 Windows 工作目录创建并实际运行的小型参数化 SystemVerilog GEMM 工程。默认 B tile 双缓冲、output-stationary 4×4 阵列、K tile=8，片上容量 M≤16、N≤16、K≤32；第二种 2×3、K tile=5 阵列也通过逐元素自检；两种阵列均覆盖 OPTIMIZED=1 优化模式与 OPTIMIZED=0 原始模式。输入 INT8，部分和及输出 INT32，溢出采用模 2^32 回绕。支持跨 K tile 累加、所有维度尾块和 M=1 GEMV。

本机 VU9P 器件已安装，评估 part 为 **xcvu9p-flga2104-2L-e**。板卡、最终封装和速度等级尚未确认，此 part 仅用于资源与内部时序评估。无 DDR、PCIe、DMA 或完整 Transformer；Softmax、RoPE、KV Cache、RMSNorm、SiLU 均为后续计划。

## 当前 NPU 方向：有序任务队列

新增顶层 npu_top：默认深度 4 的任务描述符 FIFO、任务 ID/尺寸/操作码、自动启动双缓冲 GEMM/GEMV 核心、完成背压和结果所有权保护。所有排队任务共享一份驻留 A/B，成功结果必须读完并确认后才启动下一任务。当前仅支持 GEMM 操作码；独立张量地址、量化后处理和多算子链属于下一阶段。

~~~powershell
# 两种 NPU 队列/阵列配置的逐元素自检
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_npu.ps1

# 加上 VU9P 器件级综合；-Implement 可追加内部 OOC 布局布线
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_npu.ps1 -Synthesize -Implement
~~~

带 -Synthesize/Implement 的完整 NPU 流程会自动审计并更新 NPU 验证文档；原 run_all.ps1 现也包含 NPU 前端测试与综合。

NPU 输出在 build/sim_npu_*、build/synth_npu、build/npu_summary.json。接口和限制见 [NPU 架构](docs/npu_architecture.md)，实际检查结果见 [NPU 验证](docs/npu_validation.md)。原 matmul_top 和其单独复现脚本继续作为矩阵核心基线；下文既有资源数字均指该核心，NPU 完整顶层资源另见新报告。

## 从零复现：Windows PowerShell

本次实际使用 PowerShell 5.1、Python 3.13.5、Vivado 2025.2（Build 6299465）。Vivado 工具安装路径如下，未修改全局环境变量或安装依赖。Python 参考模型使用标准整数，若 NumPy 可导入则额外用 INT64 矩阵乘法交叉检查；本机 NumPy 2.2.6 已通过检查。

在 PowerShell 中运行：

```powershell
Set-Location E:\speed-up

# 一键验证八组矩阵核心配置和两组 NPU 前端配置、综合两个顶层并审计实际报告
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_all.ps1

# 加上不含板级管脚约束的 OOC 布局布线
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_all.ps1 -Implement
```

ExecutionPolicy Bypass 只用于本次子进程，不修改系统执行策略。完成时一键脚本打印 PROJECT_VALIDATION_PASS；异常会返回非零退出码。首次运行会生成 build/，所有仿真、综合和实现输出都留在该目录。Vivado 在大型 VU9P 上加载器件、综合和布局布线可能需要数分钟。

分步命令：

```powershell
# 可单独生成参考文件；不需要安装 NumPy
python .\model\generate_vectors.py --out .\build\vectors

# 全部八组仿真；-SingleConfig 仅跑默认 4×4 双缓冲
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_sim.ps1

# 查询本机 VU9P 后进行器件级 OOC 综合并导出报告
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_synth.ps1

# 可选内部 OOC 实现
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_synth.ps1 -Implement

# 审计八组配置的 PASS、矩阵数量、实测周期和资源；写 build/summary.json
python .\scripts\summarize.py
python .\scripts\report_double_buffer.py
```

自定义工具路径、Python 路径：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_all.ps1 `
  -VivadoBin "E:\AMDDesignTools\2025.2\Vivado\bin" `
  -Python "C:\ProgramData\anaconda3\python.exe"
```

脚本通过 PowerShell 的调用运算符 & 调用 .bat，并把传给 Tcl 的路径转换为正斜杠。实际工具调用保存在各 build 子目录的 commands.txt（当前矩阵核心双缓冲综合目录为 build/synth_db，NPU 为 build/synth_npu）。备选阵列和原始模式使用显式 TB wrapper，避免 Windows CMD 将未引用的等号参数拆开。本次在 Windows PowerShell 执行，未使用 WSL；不能将 Windows .bat 路径直接作为 Linux 可执行文件。

### 恢复报告与故障注入

如果已有由本工程生成的 synthesized.dcp，且 **RTL、参数和时钟 XDC 从综合后没有改变**，可仅恢复报告与实现：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_synth.ps1 -ResumeReports -Implement
```

此恢复选项不重新综合；现在会检查 source_inputs.json 中的 RTL/XDC SHA256 和模式，源码或模式不匹配时拒绝恢复，要求完整综合。没有来源记录的旧 checkpoint 也要求完整综合。默认一键流程始终完整综合。

验证失败退出行为的专用命令：

```powershell
# 预期失败并返回 1；仅篡改独立 *_negative 目录中的一个期望值
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_sim.ps1 -SingleConfig -CorruptExpected
```

此命令不作为正常通过步骤。一些 xsim 的 $fatal 仍可能让工具进程返回 0；脚本额外检查 ALL_TESTS_PASS 及 Fatal/MISMATCH 标记，确保上层不会假成功。本次故障注入实际验证了非零退出。仿真具备每任务 100000 周期 watchdog、全局 20 ms 仿真时间 watchdog，以及 Tcl run 20 ms 上限。

## 项目内容

```text
rtl/              完整可综合 RTL：PE、阵列、RAM、tile Buffer、控制器与顶层
tb/               自检式 SV testbench；八组配置：三种阵列，双缓冲压力及两种对照模式
model/            固定种子、INT32 回绕参考模型与数据生成器
scripts/          PowerShell 一键脚本、Vivado Tcl、实际报告审计
constraints/      10 ns 时钟评估约束，无板级管脚分配
config/           默认容量、评估 part 方向、时钟及备选仿真配置
docs/             架构、验证证据、未来工作
build/            生成向量、仿真日志、CSV、Vivado checkpoint 与报告
```

配置文件是默认参数的说明，RTL 参数和 build/selected_part.txt 是实际执行值。若本机没有任何 VU9P part，查询脚本返回 2，不下载器件或替换其它器件；仍可独立运行仿真。

| 文档 | 内容 |
|---|---|
| [docs/architecture.md](docs/architecture.md) | 元素映射、每周期读写、部分和策略、接口、复位与背压合同 |
| [docs/validation.md](docs/validation.md) | 实际测试、器件、资源、时序、警告与验证范围 |
| [docs/next_steps.md](docs/next_steps.md) | 带宽优化、DDR 双缓冲、Decode GEMV、FFN、Attention 的优先级 |

## 使用边界

任务启动前，调用方必须完整写入有效 A/B 元素；硬件不跟踪输入有效位。接口使用同步 valid/ready 和 start/status，单次只能提交一种命令。reset 中止任务并使旧结果无效，但不会清空物理 RAM。新任务重新初始化每个输出 tile 的 PE 部分和。结果可用后通过同步坐标读接口读取 INT32。

默认阵列理论峰值为每周期 16 MAC，在假设 100 MHz 下为 1.6 GMAC/s（按乘、加分别计数为 3.2 GOPS）。这只是计算阶段的理论上限。16×16×32 的双缓冲 RTL 实测耗时 2856 个有效 busy 周期，单缓冲 3540、原始模式 9872，含 tile 装载与保存，且不包括主机写入/读回；板上频率、功耗、带宽和 token/s 尚未测量。第一轮原始模式综合为 750 LUT、225 FF、16 DSP、3 RAMB18，OOC 为 738 LUT、内部 WNS +5.272 ns；上一轮单缓冲综合为 954 LUT、225 FF，OOC 为 940 LUT；当前双缓冲实际综合为 1149 LUT、443 FF、16 DSP、3 RAMB18、0 URAM、0 latch，OOC 为 1121 LUT、内部 WNS +4.713 ns、WHS +0.008 ns，完整证据见双缓冲验证文档。OOC 边界仍有警告、显式 gap 和未定义的接口延迟，不能视为板级签核。所有详细数字与限制以验证文档和原始报告为准。

工程自主实现，没有下载或复制给出的参考仓库/论文代码，因此未引入其许可证依赖。后续采用第三方代码时应先核查许可和具体索引/时序。


## 上一轮单缓冲优化记录与基线复现

单缓冲 OPTIMIZED=1、DOUBLE_BUFFER=0：同步源 RAM 装载首拍后每周期一个标量，同一 M 块的完整 A 行 cache 跨 N 块复用，仅最后 K tile 写结果。A/B 源 RAM 仍各一个同步读端口；未引入 DDR 或双缓冲。详见 [优化验证记录](docs/optimization.md)。

- 优化仿真：build/sim_4x4_k8_opt、build/sim_2x3_k5_opt。
- 原始模式仿真：build/sim_4x4_k8、build/sim_2x3_k5。
- 优化综合/实现：build/synth_opt；第一轮原始综合/实现保留在 build/synth。
- 第一轮源文件、文档和 summary 已归档到 build/baseline_v1，生成文件均在 build 中。

```powershell
# 默认完整综合双缓冲模式；前述 run_all 同样使用双缓冲
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_synth.ps1 -Implement

# 可选重新综合当前 RTL 的原始模式，会更新 build/synth 中的原始模式报告
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_synth.ps1 -Baseline
```

-ResumeReports 默认恢复 build/synth_db；加 -SingleBuffer 恢复 build/synth_opt，加 -Baseline 恢复 build/synth。脚本会检查 RTL/XDC 指纹和模式；参数或工程脚本有其它改变时仍应完整综合。

## 当前默认：B tile 双缓冲

详见 [双缓冲验证报告](docs/double_buffer.md)。DOUBLE_BUFFER=1、OPTIMIZED=1 启用两组 B tile 与独立预取；A 使用完整行 cache。B 装载可与 A 装载或 MAC 并发，银行通过 EMPTY/FILLING/READY/COMPUTING 管理。B_LOAD_GAP=0 是默认；非零值仅为装载间隔压力配置，没有接 DDR。

八组回归包括 4×4/K8 双缓冲、2×3/K5 双缓冲、2×3/K5 的 GAP=3 慢装载、2×1/K3 快装载，以及上一轮两组单缓冲和两组原始模式。每组 13 矩阵、480 输出，合计 3840 个逐元素结果比较。正常仿真还运行独立装载器单元自检；可加 -UnitOnly 仅执行该单元测试。

~~~powershell
# 上一轮单缓冲模式可单独重新综合
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_synth.ps1 -SingleBuffer

# 生成审计与本轮文档（普通 run_all 已包含）
python .\scripts\summarize.py
python .\scripts\report_double_buffer.py
~~~

双缓冲仿真目录为 build/sim_4x4_k8_db、build/sim_2x3_k5_db；压力配置为 *_db_gap3 和 sim_2x1_k3_db。当前综合为 build/synth_db。上一轮源码、文档、机器审计归档到 build/optimized_v2，上一轮综合保留在 build/synth_opt。当前恢复脚本也会核对 DOUBLE_BUFFER 模式与 RTL/XDC 指纹。
