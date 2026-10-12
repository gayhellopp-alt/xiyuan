# 项目整体状态与结构空白

本次盘点基于当前 RTL、testbench、参考模型、脚本及 build 中的工具产物。实际重新运行了 scripts/run_w4a8_wave.ps1 -AuditOnly，退出码 0，得到 W4A8_WAVE_ARTIFACT_AUDIT_PASS。本次未重新运行全套仿真或 EDA；下列仿真、综合和 OOC 数值来自通过本次审计的已有执行产物。

## 1. 项目处于哪个阶段

当前已有可仿真、可综合、可测量的 **W4A8 分组量化线性层子系统**，以及独立保留的 INT8 GEMM/GEMV 和 INT8 NPU 任务队列基线。已完成计算、局部存储、量化后处理和性能验证这一层。

面向完整 LLM 的系统控制、可综合外存传输、层间数值转换、模型运行时和 Attention/KV Cache 尚未贯通。不能用“线性层计算正确”推导“已经能执行完整 LLM”。

下图中的状态描述实际实现；计划模块没有被创建成空壳 RTL。

~~~mermaid
flowchart TD
    H["空白：模型导出 / 主机运行时"] --> S["部分：统一任务调度<br/>INT8队列已实现，W4A8未接入"]
    S --> M["空白：可综合外存读写 / 张量地址生成"]
    SIM["已验证：TB供数模型<br/>仅用于仿真"] --> BUF
    M --> BUF["已验证：权重双bank / 激活缓存"]
    BUF --> PE["已验证：4×4 / 8×8脉动阵列"]
    PE --> P["已验证：双group psum / 定点scale合并"]
    P --> O["已验证：Q16.16输出握手<br/>空白：深FIFO / 多tile输出流水"]
    O --> M
    O --> B["空白：requant / bias / residual / 逐元素算子"]
    B --> PE
    B --> AT["空白：Attention / KV Cache / 完整算子图"]
    M --> BOARD["空白：实际板卡 / DDR IP / PCIe / 板级约束"]
~~~

## 2. 已完成并有验证证据的部分

| 层级 | 实现与入口 | 已验证内容 | 目前边界 |
|---|---|---|---|
| INT8 基线 | rtl/matmul_top.sv、mac_pe.sv、mac_array.sv | signed INT8 GEMM/GEMV、INT32 回绕、K 跨 tile 累加、尾块、连续任务与复位；保留 XSim/综合/OOC 报告 | 广播式 output-stationary；独立历史基线 |
| INT8 控制前端 | rtl/npu_top.sv | 描述符 FIFO、有序调度、非法命令完成记录、结果确认 fence、复位恢复 | 只有 INT8 GEMM 操作码；共享驻留 A/B；没有任务独立地址；未接 W4A8 |
| W4 权重与输入 | rtl/w4_unpack.sv、w4a8_wave.sv | 所有 INT4 编码、负数符号扩展、packed nibble、64-bit/keep 传输、尾块、输入暂停 | 当前 packet 协议；外存供数由 TB 完成 |
| 同步片上存储 | sync_sdp_ram.sv 及顶层实例 | 有限同步读写端口、实际综合映射、权重双bank生命周期、激活跨 N tile 复用 | 激活缓存只有一个 M epoch；下一 M 不能提前覆盖 |
| 计算阵列 | systolic_pe.sv、systolic_array.sv | 4×4/8×8 相邻 PE 的 A 向右/B 向下传递、skew/valid、每拍独立数学参考、暂停冻结 | Decode M=1 功能通过，尚未优化阵列利用率 |
| 连续波前 | rtl/w4a8_wave.sv | 同 group 跨 K tile 保留 token 与部分和、仅 group 末排空、bank 提前释放/重写、接缝饥饿恢复与复位 | 每个接缝仍有 WAIT_TILE/PRIME 两个固定周期 |
| 分组量化后处理 | 顶层双 group snapshot、独立 scale 流水 | INT32 group sum、每组不同 sx/sw、跨 tile 组累加、最后不完整 group、signed64 合并、舍入/饱和 | 每个物理 RC 槽均经过保存/后处理；未压缩无效槽 |
| 输出与任务边界 | w4a8_wave 输出 valid/ready | 逐元素输出、背压持稳、连续任务、运行中复位、非法尺寸 | 一个持稳输出寄存器；无深输出 FIFO，无多结果 tile 并行 |
| 验证与工具 | model/、tb/、scripts/、docs/、build/ | 位精确参考、浮点误差报告、超时、非零失败探针、周期/流量审计、两种阵列/多参数 | 合成数据而非真实模型精度；VCS/综合网表/板上验证未运行 |

### 最新 W4A8 证据

- 八配置累计：409 个任务、11715 个输出、37773 个 group psum/scaled 检查、33038740 项自检；预期失败探针实际退出 1。
- 覆盖 group size 32/12、4×4/8×8、2×3、1×1、单/双权重 bank、不整除 tile/group、零/边界/混合/随机数据、暂停、背压和复位。
- Vivado 2025.2；临时评估 part 为 xcvu9p-flga2104-2L-e，尚未确认实际板卡。
- 下表资源为综合值；WNS/WHS 为实际内部 OOC 布局布线结果。约束为 10 ns，无板级管脚或外部 I/O delay。

| 配置 | LUT | FF | DSP | RAMB36 | RAMB18 | URAM | OOC WNS/ns | OOC WHS/ns |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 4×4 | 2686 | 2437 | 21 | 5 | 2 | 0 | +4.128 | +0.012 |
| 8×8 | 4278 | 3908 | 69 | 9 | 2 | 0 | +4.129 | +0.010 |

无 latch/blackbox；内部 setup/hold 失败端点为 0。存在 DSP 输入/输出流水优化建议及 OOC 边界无 routable loads 警告；报告设计状态为 Partially Routed，所有可路由内部网络已路由，不能据此声明板级设计完成或真实板上频率。

证据入口：[验证报告](w4a8_wave_validation.md)、[性能报告](w4a8_wave_performance.md)、[交付清单](../build/w4a8_wave_delivery.json)、[INT8 NPU 架构](npu_architecture.md)。具体命令见 [README](../README.md)。

## 3. 已实现，但还需要完善的部分

### 3.1 算法规模与硬件 tile 规模分离

阵列 4×4/8×8 不是只能算一次 4×4/8×8：当前控制器已经把合法任务的 M/N/K 切成硬件 tile，并处理跨 tile 累加和尾块。

但逻辑任务仍受编译容量限制：默认 MAX_M=64、MAX_N=64、MAX_K=4096。当前测试矩阵最大 K 为 96，未完整验证全部容量边界。超过这些上限的完整 LLM 矩阵还需要外层张量切分和调度。

外层 M/N 切分可以产生独立输出区域；外层 K 切分需要保留未舍入累加结果。不能把各 K 块已经舍入、饱和后的 Q16.16 输出直接相加后宣称等价。优先按量化 group 边界切 K，保存 signed64 Q24 合并状态，最后统一舍入；若一个 group 跨外层块，还须先完成该 group 的 INT32 部分和再缩放。扩展总 K 后应重新证明累加位宽上界。

### 3.2 性能有具体瓶颈

| 代表性任务/条件 | 4×4 连续波前周期 | 8×8 连续波前周期 | 说明 |
|---|---:|---:|---|
| Decode 1×13×96，连续供数 | 1003 | 1139 | 更大阵列没有自动改善 M=1 |
| Prefill 8×16×96，连续供数 | 2209 | 1403 | 更多行列有效，8×8 有收益 |
| Prefill 8×16×96，受限供数 | 4463 | 3252 | 等输入占据大量周期 |

8×8 满阵列用例连续供数时，1403 周期 = 固定控制/保存/输出开销 957 + 注入 192 + 排空 84 + 等输入 34 + post drain 136。受限供数时等输入为 1883/3252 周期。应优先改善后处理/输出开销、供数和 Decode 映射，随后再讨论阵列扩展。

### 3.3 进一步完善清单

- valid 槽保存/scale、输出 tile 双缓冲/FIFO，使计算、后处理、输出可重叠。
- READY tile 首字预取，减少固定接缝；保留同步 RAM、暂停和 bank 所有权合同。
- Decode 的 N/K 映射与归约实验，在相同 DSP/带宽预算下比较。
- 激活下一 M epoch 预取、sx 跨 N 缓存、实际负载下的带宽/布局优化。
- 容量边界、数值边界、接口异常和系统级复位覆盖；参数合法范围逐项明确。
- 选择长期集成顶层；保持各历史版本作为可复现基线，避免队友分别修改同一大顶层。

## 4. 整体结构中的空白

| 空白 | 目前缺少什么 | 对完整系统的影响 | 工作包 |
|---|---|---|---|
| 统一 W4A8 调度与地址 | 带源/目的地址、stride、group、格式、依赖的描述符；完成/写回 fence | 无法从主机排队执行独立张量任务 | A |
| 可综合外存传输 | 读 burst、有限 outstanding、返回缓冲、packet 打包、输出写回和响应检查 | TB 供数模型不能放进 FPGA 作为真实内存接口 | B |
| 外层张量/工作区调度 | 超容量 M/N/K 切分、global group ID、宽累加工作区、生命周期 | 大模型矩阵无法完整映射到当前局部资源 | A + D |
| 模型导出与运行时 | 真实权重/scale 打包、量化校准、元数据版本、任务编译、运行/错误管理 | 尚无真实模型准确率或端到端执行 | D |
| 层间数值桥接 | Q16.16 → INT8 及按行/group sx；bias、residual、逐元素运算 | 当前输出不能直接作为下一 W4A8 层输入 | E |
| FFN/非线性 | SiLU/SwiGLU、RMSNorm、RoPE 的数值规格与硬件 | 线性层外的 Transformer 路径缺失 | E |
| Attention/KV | 动态激活矩阵乘、transpose、mask/Softmax、KV 写入/追加/读取 | 尚不能执行 Attention 或持续 Decode | F |
| 系统验证与回归管理 | AXI/描述符协议验证、跨层参考、真实模型用例、统一回归门禁 | 单引擎正确尚不足以验证整个 NPU | G |
| 板级平台 | 实际板卡、DDR/PCIe IP、时钟/复位/CDC、完整 XDC、bitstream/驱动 | 尚无板上数据和真实外存性能 | H |

W4A8 适合静态权重的 Q/K/V/O 和 FFN 线性投影。Attention 的 QKᵀ 与 AV 两侧都是动态数据，需要另行规定数据类型与计算路径；不能直接把 INT4 权重接口当作整个 Attention 引擎。

## 5. 已实现但未验证 / 尚未运行

- 其他未列阵列、最大 M/N/K 容量组合：参数支持不等于已验证。
- INT8 NPU completion_status=3：逻辑存在，正常前端过滤使其不可达，未注入该路径。
- VCS：有可配置脚本；未发现本机安装，实际编译/运行未验证。
- 综合网表仿真、板上执行、真实 DDR 带宽、完整模型准确率：未运行。
- 统一 W4A8 描述符、AXI 外存、完整 FFN/Attention/KV/主机运行时：尚未实现。

## 6. 接下来先完成什么

第一交付目标是 **描述符 → 可综合内存适配器 → 现有 W4A8 引擎 → 写回 → 完成记录** 的系统仿真闭环。先用独立的 AXI 仿真存储替代当前直接 packet 供数，不依赖实际板卡。

第二目标是两层串联及一个小型 FFN：加入明确的量化桥接、真实导出张量与工作区管理。第三目标是 Attention/KV 和完整 Transformer block。当前三人团队优先实施 A–F：你承接 C/E，队友1承接 A/D，队友2先 B 后 F，验证由三人共同承担。板级 H 留待后续，DDR/PCIe IP 选择以实际板卡为依据。

队友任务、目录所有权、接口和验收见 [团队工作包](team_work_packages.md)。
