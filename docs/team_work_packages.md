# 团队工作包与接口边界

## 当前执行入口：上游复用后的三人分工

已核查 openTPU 主许可证 Apache-2.0；llama-fpga 的代码复用授权仍未明确。当前优先按 [上游复用分析与三人分工](upstream_reuse.md) 第3节推进：你 C/E，队友1 A/D，队友2先 B 后 F。下面保留工作包和验收细目作为参考；首轮以一个软件任务经内存适配器驱动现有 W4A8、写回并完成为集成目标。


本文件是可分派的工作建议；尚未向外部队友发送消息或创建工单。团队人数已明确为三人，本文件按三人包含项目发起者安排；成员姓名与技能尚未提供。A–H 表示工作包职责，当前优先实施 A–F，G 的验证责任分摊到三人，H 的板级集成留待后续。下表中的 teammate A–H 是职责槽位，不是八位实际成员，也不代表相应模块已经实现。当前已验证状态见 [项目状态](project_status.md)。

## 1. 分工总览

优先级 P0：系统线性层闭环必须完成；P1：层间/吞吐与小型 FFN；P2：Attention、完整模型与板级落地。本轮三人优先覆盖 A–F；验证作为每个工作包的验收条件，板级 H 后续排期。

| 负责人 | 工作包 | 优先级 | 首个独立交付 | 主要协作 |
|---|---|---|---|---|
| teammate A | 系统控制、W4A8 描述符、外层切分合同 | P0 | 单任务描述符适配 + 完成 fence 的自检 wrapper | B/D/G |
| teammate B | 可综合内存读写与 packet 适配 | P0 | AXI 仿真内存 → 现有 W4A8 → 内存写回 | A/C/G/H |
| teammate C | 计算/后处理/输出效率 | P1，可立即并行 | valid 槽后处理 + 输出 FIFO 的对照版本 | B/E/G |
| teammate D | 模型导出、任务编译、软件参考/运行时 | P0/P1 | 版本化 tensor 文件与任务清单，驱动仿真闭环 | A/E/F/G |
| teammate E | 层间量化桥接及 FFN/非线性 | P1 | Q16.16 → INT8/group scale 的位精确模块 | C/D/G |
| teammate F | Attention 数据路径与 KV Cache | P2，规格可先行 | 动态激活 matmul 与 KV 布局参考模型 | A/B/D/E/G |
| teammate G | 系统验证、回归与性能证据 | P0，贯穿 | 所有模块统一的自检/负测试/产物审计门禁 | 全员 |
| teammate H | 实际板卡与平台集成 | 先确认平台，后实施 | 板卡能力/约束清单及独立平台 bring-up 计划 | B/D/G |

首轮 RTL 集成只依赖 A/B/G，并使用 D 的任务和数据。C 优化版本先独立对照，E/F 不阻塞首轮闭环；当前不分配独立 H 负责人，真实 DDR/PCIe 不作为系统仿真门禁。

## 2. 共同接口先约定

以下是待共同冻结的 v0 合同，**不是当前 RTL 已提供的接口**。A 负责整理，B/D/E/F/G 评审；首次评审时选定位宽、版本和不支持状态，不必立即创建复杂通用 ISA。

| 边界 | 建议合同 | 所有权与验收 |
|---|---|---|
| D → A：任务描述符 | version、task_id、opcode、M/N/K、A/W/sx/sw/Y 地址、显式 byte stride、group_size/格式、依赖、可选宽累加工作区 | 首版仅 W4A8_LINEAR；group_size 必须与硬件配置匹配，不能因描述符有字段就宣称运行时可变 |
| A → B：张量上下文 | 任务锁存后的地址/stride/维度；req_m/n/k、req_ml/nl/kl、req_group 是局部/全局坐标须明确 | 上下文保持到所有请求及输出写回完成；越界任务启动前拒绝 |
| B → C：输入 packet | 沿用现有 req_valid/ready、in_valid/ready/data/keep、req_scale/activation；phase 顺序/packing 以当前代码为准 | valid 未接受时数据持稳；保持有限缓冲；尾部非法 byte 不产生读事务 |
| C → B：结果 | out_valid/ready、out_m/n/last、signed32 Q16.16；后续 raw Q24 工作区另立显式接口 | 单任务同一输出坐标只提交一次；out_last 接受不等于外存写回已完成 |
| B → A：传输完成 | 已提交读取/写入及待响应计数、错误码、writeback_committed | 完成记录必须等待全部写响应；发生错误不能回报成功 |
| C/D → E：层间张量 | Q16.16 布局、有效维度、sx 分组方式、INT8 饱和/舍入规则及可能需要的两遍读 | 逐步定点参考一致；不能静默把输出低8位当激活 |
| F → B：KV 请求 | layer/head/token/block 映射、有效长度、追加/读取 fence、容量/地址范围 | 完成追加写后才可供下一 Decode 读；初版先固定单序列，后加多序列 |
| G → 全员：复位/错误 | 单时钟首版；复位取消任务，明确哪些内存写已经提交、哪些输出失效 | 仿真事务可排空或标记取消；真实 AXI 不能凭内部 reset 假设外部在途响应消失 |

### 张量布局基础

- 现有逻辑 A 为 row-major INT8。
- 现有 W 为按输出通道连续的 K packed INT4：地址 n×ceil(K/2)+p，低 nibble 是偶 K，高 nibble 是奇 K。
- sx 为 m/group，sw 为 group/n；scale 编码沿用 unsigned16 UQ4.12。
- Y 为 signed32 Q16.16；byte order、外存行 stride、对齐/padding 必须写入元数据，建议首版明确 little-endian。
- B 的传输包装负责把外存布局转换成现有成对列 packet，不应直接假设全局连续矩阵就是引擎接收顺序。
- 外层 K 切分首版按 group 边界；块间保存未舍入 signed64 Q24 合并状态，最终块才舍入/饱和。若以后支持 group 跨块，先保存该组整数 psum；扩大总 K 后重新检查位宽上界。

## 3. A：系统控制与外层调度

**输入资产：** npu_top.sv 的队列/所有权经验、w4a8_wave.sv 的启动/请求/输出合同。

**任务切分：**

1. A1：冻结最小 W4A8 描述符、能力查询、非法维度/格式/group 拒绝、任务 ID/完成状态。先单活动任务、有序执行。
2. A2：实现 wrapper，将描述符任务送入现有引擎；输出被 B 写回并提交后才产生成功完成记录。
3. A3：与 D 定义超容量切分；首版由软件生成 M/N 子任务，硬件不急于实现复杂调度器。
4. A4：增加宽累加工作区/最终舍入标志后支持外层 K 切分，再考虑依赖图和多引擎。

**建议所有权：** rtl/control/、docs/interfaces/task_protocol.md、tb/control/。这些目录/文件是建议交付路径，当前不必创建空文件。整体新顶层由 A 统一接线。A 不直接修改 C 的计算内核。

**验收：**

- 两个不同地址/尺寸任务连续执行，结果/完成记录与 Python 对应，顺序和 tag 正确。
- 队列满、输出写回暂停、完成背压、非法描述符、活动任务复位都有自检。
- 内存写响应未完成时禁止 success；不得借用旧 INT8 共享驻留结果接口冒充 W4A8 任务队列。
- 超过硬件 M/N 的矩阵，软件切分后的整体输出逐元素一致；K 超容量支持作为 A4 独立门禁，未完成时明确拒绝。

## 4. B：可综合内存数据通路

**当前空白：** TB 存储模型不可综合，无真实 AXI 读写主接口。

**任务切分：**

1. B1：先单 outstanding、显式有限 FIFO 的 AXI4 读 burst 控制；协议参数固定且可记录。
2. B2：地址/stride 生成，按 A/W/scale 相位组装 existing packet，支持 unaligned/tail 或明确拒绝范围，避免越界读与无效数据污染。
3. B3：结果写回；独立跟踪 write response、写入 byte strobe、错误传播与 committed fence。
4. B4：在已通过协议验证的基础上增加 outstanding/预取窗口；与 H 连接真实控制器。

**建议所有权：** rtl/memory/、tb/memory/、docs/interfaces/memory_transport.md。仿真 AXI RAM 必须留在 tb，不能综合进入 DUT。

**验收：**

- AXI 仿真 RAM → adapter → 原 w4a8_wave → AXI RAM 的 bit-exact 全闭环。
- 4 KB 边界、尾部 byte、随机读写返回延迟、通道独立背压、有限缓冲溢出保护和非成功响应有自检。
- 验证 packed nibble/列对与 scale endian；记录有效 bytes、物理传输 bytes、burst/outstanding。
- 暂停时所有未接受 payload 稳定；复位后在途事务的取消/排空规则与 A/G 一致。
- 可独立综合；报告 FIFO/RAM 实际映射，不宣称已得到 DDR 性能。

## 5. C：内核与输出优化

**边界：** 当前脉动、双 W bank、双 psum、scale II=1 已完成。C 的任务是消除已测量开销；不要重写或移除已验证基线。

**任务切分，按顺序比较：**

1. C1：只保存/scale 有效 ml×nl 槽，保留正确坐标，优先减少 M=1/尾块开销。
2. C2：输出 FIFO/结果 tile ping-pong，明确 FREE/WRITING/READY/READING 所有权；后处理与输出/下个 output tile 重叠。
3. C3：READY tile 同步首字预取，减少两拍接缝；暂停或 bank 释放后不得消费错误 epoch。
4. C4：在相同 PE/DSP/输入带宽预算下对比 Decode 的 N 映射与 K 并行归约，原 4×4/8×8 作对照。

**建议所有权：** rtl/compute/ 新优化版本、tb/compute/、docs/compute/。当前 rtl/w4a8_wave.sv 作为参考保留，首轮其他队友使用已验证接口；统一内核变更只由 C 提交。

**验收：**

- 最新八配置回归及定向冻结/复位/背压保持通过，独立逐 PE 参考适配新时序。
- 相同任务/供数条件下报告周期、有效 MAC、bytes、stall 分类和 LUT/FF/DSP/RAM/OOC；不得只报理论峰值。
- 至少比较 1×13×96、4×12×96、8×16×96、9×11×67。
- 输出满时不覆盖有效 tile；将暂停/相同地址 RAW hazard 写成可检查断言。
- 结果完全一致是合入前提；性能变化可为负，须记录并解释。

## 6. D：模型导出、软件与任务编译

**任务切分：**

1. D1：提供版本化 tensor/metadata schema 和 reader，导出 qw/sx/sw、尺寸、布局、group、校验和与量化范围；先沿用当前对称量化，不能宣称 AWQ 兼容。
2. D2：任务编译器：软件外层 M/N 切分、地址/stride、工作区、依赖、A 的描述符；用仿真 runtime 提交并读取结果。
3. D3：读取一组经许可可使用的真实线性层张量，校准量化，比较 bit-exact/fixed-vs-quantfloat/quant-vs-originalfloat 三层误差；先记录数据来源和许可，不整仓复制。
4. D4：与 E 串联两层/FFN；与 F 提供 Prefill/Decode workload；MMIO/驱动在 H 接口冻结后再实现。

**建议所有权：** model/export/、runtime/、tests/workloads/、docs/model_format.md。D 负责上层任务切分编译，A 负责硬件描述符消费，两者不要各写一套不兼容切分器。

**验收：**

- 导出/读取 round-trip，全部 16 个 INT4 编码、奇 K、padding、group 12/32、scale 边界可复现。
- 导出值与现有整数参考逐元素一致；报告真实权重/激活误差，不能把 synthetic 结果称为真实模型准确率。
- 至少一个 M/N 超当前容量的任务列表整体正确；K 超容量在宽工作区支持前拒绝，并在文档说明。
- descriptor/payload/结果之间可通过 task_id、checksum、版本追溯。

## 7. E：层间数值桥接与 FFN/非线性

**先解决数据类型闭环：** 引擎当前输出 Q16.16；下一线性层需要 INT8 及按 row/K-group 的 sx。固定预校准 scale 与动态 scale 是不同实现，必须明确选择。动态 group scale 常需要先求 absmax，再量化第二遍读取，应纳入存储/周期模型。

**任务切分：**

1. E1：数值文档与 Python 模型：bias/residual 相加格式、requant 的 scale 计算/编码、舍入、零组、饱和和误差。
2. E2：RTL requant/scale 输出模块及同步 Buffer；先支持预先指定 scale，再按需求实现动态 group scale。
3. E3：逐元素乘与 SiLU，构成两路投影→SiLU×gate→down projection 的小型 FFN 闭环。
4. E4：分别提交 RMSNorm 与 RoPE 的参考/近似方案和独立 RTL；精度、LUT/迭代/带宽需单独验收。

**建议所有权：** rtl/vector/、model/vector/、tb/vector/、docs/numerics/。不修改现有 W4A8 数值合同；新增操作逐项版本化。

**验收：**

- INT8 ±边界、零组、不同 group scale、舍入 tie、输出饱和、暂停/复位全部 bit-exact。
- 两层串联和小 FFN 对固定点 Python 完全一致；另报告相对浮点误差，阈值在数值规格阶段冻结。
- group scale 产生/读取的次数、所需缓冲及完整周期实际测量。
- 残差通路不同格式必须明确转换；不能用隐式截断拼接算子。

## 8. F：Attention 与 KV Cache

**这是后续子系统，不与首轮线性层闭环混在一起。**

1. F1：确定 Q/K/V、score、probability、AV 的数据类型和矩阵布局，明确 mask、1/sqrt(d)、seq length、head/grouped-query 配置。先建立 Python 小序列 Prefill/逐 token Decode 参考。
2. F2：动态激活×激活矩阵乘/transpose/归约路径；评估复用 INT8 基线与新增路径，不能假定 W4 权重格式覆盖 QKᵀ/AV。
3. F3：KV 布局与地址管理，单序列 append/read/capacity/有效长度及写读 fence；独立存储 TB。
4. F4：稳定 Softmax 的行 max/sum、指数近似/归一化及误差规范；再接 QKᵀ→Softmax→AV。
5. F5：接 RoPE/QKV/O 投影并跑一个小 Transformer Attention block，随后扩展多序列/分页 KV。

**建议所有权：** rtl/attention/、model/attention/、tb/attention/、docs/attention/。F 的 KV 逻辑生成 B 的张量请求，不另写第二套 DDR 控制器。

**验收：**

- Prefill 后逐 token Decode 与参考对应；测试可变序列长、mask、尾块、缓存容量越界。
- Score/Softmax/AV 各阶段分别比较，明确 exact 固定点与浮点容差，不只检查最终 token。
- KV 未写区域不能被读取，追加写提交前不能推进有效长度；复位取消行为明确。
- 报告 SRAM/外存需求、bytes、周期；未集成实际平台时只称仿真结果。

## 9. G：验证与持续集成

**任务切分：**

1. G1：把当前基线审计/回归整理成 fast、full、EDA 三层门禁；保留非零失败探针、超时及源码 hash。
2. G2：为 A/B 创建协议 monitor、scoreboard、受限/随机延迟存储条件；负测试覆盖 malformed descriptor、AXI error、复位在途事务。
3. G3：系统/跨层 golden 比较、最大容量代表性边界、参数合法性、真实导出用例。
4. G4：产出统一性能表和资源报告；若本机具备工具再接 VCS/综合网表仿真，没有安装时标记未运行。

**建议所有权：** tests/system/、tb/system/、scripts/ci/、docs/system_validation.md。模块 owner 写局部自检，G 负责系统交叉边界，避免 G 成为所有测试代码的单点瓶颈。

**验收：**

- 单命令退出码准确；任何逐元素失败/timeout 返回非零，无旧 PASS.txt 假阳性。
- 源码与产物关联；仿真、综合、OOC、板上四类证据分开。
- 停顿原因有分类规则，重叠统计不重复相加。
- 主分支 gate 至少包含已验证内核回归和新系统闭环，EDA 在可用 Vivado runner 执行。

## 10. H：板级平台

**先需要的信息：** 实际板卡型号、VU9P part、DDR/HBM 配置、PCIe 接口、时钟/复位和可用 IP/许可证。当前 temporary part 不等于实际板卡确认。

1. H1：整理平台事实、板卡文档/许可/约束来源、容量/带宽、host 接入方法，选择板级首交付最小范围。
2. H2：独立 DDR/PCIe loopback 或内存读写自检、校准状态、reset/CDC、MMIO 地图，与 A/B/D 对齐。
3. H3：接完整系统、实现完整 XDC、生成 bitstream，板上跑 tiny golden。
4. H4：测真实时钟、传输 bytes/latency、任务周期/吞吐；对比仿真模型并更新瓶颈。

**建议所有权：** platform/<confirmed_board>/、docs/platform/、scripts/board/。不把厂商临时工程输出加入 rtl 源码目录。

**验收：**

- 平台独立自检先通过，真实 part 与 pin/clock/CDC 约束完整。
- 板上逐元素输出一致、错误/复位可恢复；实际测量报告与工具日志可追溯。
- 未确认板卡/IP/许可证时记录准确阻塞，继续接口与 testbench 工作；不冒用临时 part 宣称板上验证。

## 11. 分阶段集成门禁

| 门禁 | 集成内容 | 通过标准 | 负责人 |
|---|---|---|---|
| M0 | 接口/数值/布局 v0 | task、packet、writeback fence、reset、group、格式及不支持项有一致文档/样例 | A 主持，全员评审 |
| M1 | 可综合线性层系统 | 仿真 AXI RAM→任务队列→W4A8→RAM→完成，含连续任务/暂停/错误 | A/B/D/G |
| M2 | 大矩阵与跨层 | M/N 外层切分、requant 两层；K 切分单独通过 raw 累加/最终舍入门禁 | A/D/E/G |
| M3 | 小 FFN | gate/up/down 与 SiLU/逐元素乘逐阶段比较，记录周期/资源 | D/E/C/G |
| M4 | Attention/KV block | Prefill 和逐 token Decode，缓存/数值/依赖全部对照 | F/B/D/E/G |
| M5 | 板上闭环 | 实际平台自检、正确输出、完整时序/CDC约束及实测性能 | H + 集成组 |

M1 与 C/H 前期工作可并行；M4 可先写模型/接口，但完整集成依赖 M1/M2 及 E 的必要算子。没有给出团队可用工时，因此不预设完成日期。

## 12. 当前三人团队：先覆盖 A–F

以下按三人总共包含你来安排，成员技能未给出，采用与当前工程主线相接的职责组合。角色建议可用实际姓名替换，尚未对外发送任务。

### 12.1 你目前在做什么

当前与你持续推进的工作主要是 **C：计算核心、片上数据流与效率优化**：

- INT8/W4A8 乘加、4×4/8×8 脉动阵列、跨 K tile/group 累加与尾块。
- 权重 ping-pong、激活跨 N tile 复用、双 psum、group scale、连续波前。
- 相应的位精确参考、自检、性能计数、综合与内部 OOC 证据；这些也承担了 G 的内核验证职责。

其余工作包已有资产的边界：

| 工作包 | 已有资产 | 还未完成 |
|---|---|---|
| A | 独立 INT8 描述符 FIFO/调度/结果 fence | W4A8 任务地址/stride、统一描述符、写回完成 fence |
| B | 引擎端 packet、同步片上 Buffer、TB 供数 | 可综合 AXI 外存读写、地址生成、响应跟踪 |
| C | 当前工作的主体，已有验证与综合证据 | 有效槽优化、输出 tile 流水、首字预取、Decode 专用映射 |
| D | synthetic 数据生成、整数/浮点量化参考 | 真实模型导出、任务编译、工作区及主机运行时 |
| E | group scale 属于线性层内部后处理，可作为数值基础 | 层间 requant、动态激活 scale、bias/residual、SiLU/RMSNorm/RoPE |
| F | 已有线性投影引擎可供未来复用 | 动态 Attention matmul、Softmax、KV Cache 均未实现 |

group scale 已通过验证，并不表示层间 E 已实现；TB 能供数也不表示 B 已完成。

### 12.2 三人责任分配

| 人员 | 主责 | 首轮重点 | 后续重点 | 所有权边界 |
|---|---|---|---|---|
| 你 | C + E；内核数值与性能验收 | 固定现有 packet/输出合同；有效槽后处理与输出 FIFO 独立对照 | requant 两层/FFN；支持 Attention 的矩阵与非线性计算 | 计算内核、局部存储、scale/层间数据类型；不单独再写外存控制器 |
| 队友 1 | A + D；系统集成与任务级验证 | 描述符/上下文/written-back 完成 fence，软件数据与任务清单 | 外层 M/N/K 切分、导出/校准、模型图与参考 | 控制 wrapper、统一顶层、软件任务编译；不改内核时序 |
| 队友 2 | B + F；传输与缓存验证 | 有限缓冲 AXI 读写、packet 组装、仿真存储闭环 | KV 布局/管理、Attention 集成 | 外存 transport 与缓存地址/生命周期；复用你的计算算子和队友1的参考 |

B 与 F 是分阶段承担：队友2先打通 B，F 首轮只做数据格式、KV 布局和依赖规格；不能同时要求其完成全部 AXI 与 Attention RTL。F 内部再分：

- 队友2：KV 地址/有效长度/append-read fence、Attention 子系统接线。
- 你：动态矩阵乘所需算子、Softmax/归约数值与 RTL，E 中的 RoPE 等依需求接入。
- 队友1：Prefill/Decode 软件参考、任务依赖、张量布局与导出数据。

三人分别负责本模块自检；你保留内核回归，队友1维护系统一键集成/产物门禁，队友2提供 AXI/缓存协议检查。G 是共同交付要求，不能因本轮标签为 A–F 而省略测试。板级 H 暂不纳入本轮实现。

### 12.3 工作顺序与可并行内容

1. **接口冻结：** 三人一起确认 task/地址/stride、group/scale、packet 顺序、结果写回 fence、reset。使用当前已验证 w4a8_wave 接口作为首轮集成目标。
2. **首轮闭环：** 队友1做 A/D，队友2做 B；你提供内核接入支持并独立做 C 对照。目标为描述符→AXI仿真内存→W4A8→写回→完成记录。
3. **两层与大矩阵：** 你做 E 的 requant，队友1做外层切分/工作区，队友2完善 tensor 读写复用。K 切分必须保留未舍入结果，宽工作区未通过前明确拒绝超容量 K。
4. **FFN：** 你实现逐元素乘/SiLU 等，队友1编译投影任务及参考，队友2支持中间张量搬运。
5. **Attention/KV：** 队友2负责 F 集成与 KV，你补动态矩阵/归约/非线性算子，队友1提供序列模型与任务。先小序列单任务，再扩展多序列。
6. **板级：** A–F 系统仿真和实际板卡确认后另立 H 里程碑，不把仿真内存结果当作 DDR/板上性能。

每阶段按第11节相应门禁验收。没有已知工时，暂不承诺完成日期。

## 13. 其他人数时的备选分工


- **4 人起步：** 1=A+D（控制/软件）；2=B+H（内存/平台）；3=C（计算与输出）；4=E+G（数值桥接/系统验证）。F 的模型/规格先由 4 协助定义，完整 Attention/KV 在 M2 后单独排期，避免首轮同时承担全部模块。
- **6 人建议：** 1=A；2=B+H；3=C；4=D；5=E；6=G。F 在 M2 后交给 5，并由 1/2 支持 KV 管理/传输；若 Attention 需立即并行，增加独立 F 负责人，不能假定其工作没有额外成本。
- **8 人职责齐备：** 按 A–H 独立 owner 分派；所有人围绕 M0/M1 共用接口推进。

建议由一位集成负责人维护顶层接线、接口版本和 gate；每个工作包一次只变更一个可独立验证的功能。对共享内核、全局脚本和 config/project.json 的修改由对应 owner 合入，其他模块尽量用 wrapper/子目录扩展，减少同时编辑同一大文件。
