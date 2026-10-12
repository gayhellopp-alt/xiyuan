# Group 内跨 tile 连续波前已实现

新增group末排空、非末tile早释放bank与WAIT/PRIME冻结；4×4/8×8保持同一PE结构和数值规格。实际结果见 [性能报告](w4a8_wave_performance.md)、[验证报告](w4a8_wave_validation.md)。以下三项优先讨论：

1. **有效槽psum保存与输出tile流水。** 当前仍保存/缩放全部RC槽，M=1或M=4在8×8有无效槽开销。先比较只处理ml×nl有效槽与保持固定槽布局的bank并行写，再加入输出tile双Buffer，验证有限端口、读延迟和背压下无覆盖。
2. **READY tile能否无缝首读？** 当前每group内接缝仍有WAIT_TILE交付和PRIME首读两拍，供数饥饿时额外冻结。下一轮可预读下一READY bank第一个word，需明确下一bank请求/读口所有权和暂停时返回数据保存；本轮未实现。
3. **如何选择Decode映射与统一NPU任务接口？** group末仍有D拍，M=1行利用率低；比较N并行/K归约与小阵列。再加入W4A8 descriptor的packed格式、group/scale/地址stride与完成事件，适配旧有序队列。真实DDR/DMA和完整FFN/Attention属于之后的工作。

group内连续波前不等于每墙钟拍都推进，不等于已经达到理论峰值；更多PE的收益须结合尾块、供数、保存和综合结果。以下保留历史讨论。

---

# 4×4 与 8×8 脉动原型已实现

邻接PE传递、入口错位、array暂停及每K tile排空已完成，两尺寸独立单元与八配置W4A8集成自检通过；同尺寸广播作为对照保留。实际周期见 [性能报告](w4a8_systolic_performance.md)，综合/OOC状态见 [验证报告](w4a8_systolic_validation.md)。

当前最值得讨论的三个问题：

1. **是否改为group内跨tile连续波前？** 当前4×4/8×8每tile排空6/14拍，这是连续供数下明确的额外成本。跨tile可以保留已注入A/B token，只group末排空；应明确RAM等待时整体冻结或注入bubble、valid与K对齐、group fence，沿用逐PE数学计分板验证。
2. **8×8怎样避免无效槽后处理和输出开销？** M=1/4时物理64槽仍全部保存/scale；更大阵列增加资源与尾槽工作。比较按有效槽保存、部分和并行写bank和输出tile双Buffer，记录有限端口、背压与同步读时序。满8×8任务与Decode须分别衡量。
3. **何时确定主阵列和统一NPU接口？** 依据同尺寸broadcast/systolic周期、资源与内部时序比较选择，再做Descriptor的packed格式/group/scale/地址stride/完成事件适配。Decode专用1×更多N或K归约仍需单独试验；真实DDR、完整FFN/Attention在此之后。

本轮尚未完成以上优化，未实现输出tile流水，也未接真实DDR/完整模型。以下保留历史阶段讨论。

---

# 激活跨 N tile 复用已完成

新增按行全 K 缓存与 req_activation packet 合同，数值流水沿用已验证实现；实际结果见 [内部摘要](w4a8_reuse_brief.md)、[验证/性能](w4a8_reuse_validation.md)。以下是当前最值得讨论的三项设计问题：

1. **连续供数下怎样降低控制与输出 tile 开销？** 原先代表性用例已经无输入等待，A复用不会减少算法RUN。比较更长K tile、逐槽psum保存优化和输出tile双Buffer；后者需要单端口Y RAM所有权重新设计，以及输出背压下的有限队列协议。先用当前计数分类定位占比。
2. **Decode是否改用更多 N 并行或 K 归约？** 默认4×4在M=1只有一行有效，A缓存能降低流量但不提高PE行利用率。比较相同16PE预算的1×16与K并行方案，包含tail、W bank供数、scale/归约与综合时序成本。脉动阵列应同接口实测，当前没有实现。
3. **怎样接入NPU任务与真实供数？** 为W4A8定义descriptor中的地址/stride/packed格式/group/scale编码与完成事件，并适配现有有序NPU队列。缓存当前只保留一个M epoch；是否加第二套M缓存或sx缓存，应依据本轮限带宽和M切换计数收益再决定。真实DDR控制器、AXI/DMA要在板卡确定后接入，TB带宽模型不代表板上DDR。

FFN与Attention的Q/K/V/输出投影可复用该线性层；bias、INT8 requant与scale传播合同应先定，再扩展SiLU、RMSNorm、RoPE、Softmax和KV cache。未声称可以运行完整模型或兼容AWQ。以下保留历史阶段提出问题时的证据。

---

# group 后处理解耦已完成

两组psum snapshot与独立scale流水已实现并回归：连续供数Prefill1138→775、Decode1415→931周期；七配置4725输出与13836group psum/缩放乘积逐项通过，涵盖满队列恢复和流水中途复位。见 [本轮摘要](w4a8_post_brief.md)、[验证/性能](w4a8_post_validation.md)。

当前讨论优先级：1. A跨N复用（Prefill受限供数仍1949拍等输入，流水不能消除带宽需求）；2. 输出tile层流水/更长Ktile（当前末组drain和初始化/保存/输出仍串行）；3. Decode N/K映射与NPU任务接口，脉动阵列做同接口对照。以下保留此前提出问题时的历史证据。

---

# 列对权重打包已完成

64bit跨列打包已实现，Prefill权重144→72beat，总306→234beat，padding576→0；同物理带宽预算下Decode2938→2306、Prefill3615→2823周期。见 [本轮摘要](w4a8_packed_brief.md)、[验证与性能](w4a8_packed_validation.md)。下一步优先实现group psum双buffer及独立scale流水，随后A跨N复用，再做广播/脉动阵列同接口对照。本轮尚未实现上述未来项。以下保留此前问题提出时的证据。

---

# 宽供数增量已完成

BUS_BYTES=8 与 group末tile一次scale传输已经实现并回归，见 [本轮摘要](w4a8_stream_brief.md) 和 [性能/验证](w4a8_stream_validation.md)。A跨N tile复用尚未实现。连续供数下Prefill输入等待从1417降至9拍；当前重点转向：跨列packing减少同带宽预算下padding浪费、A复用、576拍group保存/scale的流水解耦。以下保留阶段二提出问题时的证据与路线。

---

# 第二阶段后的三项优先设计讨论

## 1. 供数带宽与跨tile复用，先于扩大阵列

证据：默认Prefill连续供数2555周期，RUN仅288拍，WAIT_TILE 1417拍；单字节端口共接受2304字节，其中A=1152、W=576、scale=576。双缓冲减少23.37%总周期，但仍受输入带宽限制。

讨论：先将byte接口改为64/128-bit packet，还是先添加A跨N tile复用与每group只装一次scale？建议先做burst宽口和scale复用，明确bank写使能与包长度，再用现有供数模型做相同数值/吞吐对照。随后接AXI读DMA与DDR模拟延迟，保留ping-pong所有权协议。真正DDR吞吐需板卡和控制器确定后测量。

## 2. Decode应采用什么PE映射？

证据：4×4的M=1只用1行，连续供数下Decode 1×13×96仅1248有效MAC/2106周期，端到端利用率约3.70%；即使只看RUN，计算阶段利用率为1248/(16×384)=20.31%（含N尾块）。当前结果证明功能正确及double buffer收益，尚未解决Decode利用率。

讨论：独立1×更多N的GEMV阵列，还是共享阵列把空行映射成K并行，再做group归约？建议先比较1×16 N并行与4路K并行两种小配置，记录归约/scale成本、packed供数bank冲突和DSP利用率，而非直接扩成4×32×32 PE。

## 3. 分组后处理与调度如何解耦？

证据：每group默认16拍SAVE + 48拍scale合并；Prefill 3个N tile×3组耗576拍，且末tile bank保留到scale完成。scratch/output各只用2.78% BRAM bit容量；22DSP中5用于scale、1用于统计，量化后处理与测量开销不能忽略。

讨论：两组psum ping-pong + 独立scale流水能否让compute立即处理下一组？建议先加入带group/tag的psum队列和scale cache，保持64位数值与背压合同，测试阻塞时无覆盖，再接旧NPU队列的W4A8操作码、张量基址/stride和完成事件。部署时可将统计乘法改小宽度/逻辑，比较资源。

之后再扩展FFN的连续两层线性、bias/INT8 requant与SiLU，建立明确的张量scale传播；Attention先验证Q/K/V及output projection，随后考虑QK^T、Softmax、KV cache和AV的数据类型/容量。RoPE/RMSNorm/完整模型均为未来工作，当前不宣称可跑完整LLaMA或兼容AWQ。
