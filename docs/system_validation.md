# 当前系统验证（2026-10-15）

本页来自当前源码重新执行的结果。入口为 `python scripts/project.py test`、`implement`、`status`、`legacy`。汇合顶层是 llm_top，未把先前 accelerator_top 或单核综合结果当作本顶层证据。

软件 19 项测试通过。新系统 8 个配置合计 141 条完成记录，包含正常执行、非法计划、故障注入、写确认反压和恢复；逐字节比较 3,211,264 个字节。完整 image 包括 gate/up、qx/sx、最终 Y、输入、padding 和保护区。

| 配置 | group | 地址位宽 | 完成记录 | 比较字节 |
|---|---:|---:|---:|---:|
| tb_accelerator | 32 | 64 | 18 | 458752 |
| tb_accelerator12 | 12 | 64 | 18 | 458752 |
| tb_accelerator32 | 32 | 32 | 18 | 458752 |
| tb_system_mixed | 混合 | 64 | 11 | 单独数值/路由断言 |
| tb_attention | 4 | 64 | 19 | 458752 |
| tb_attention3 | 3 | 64 | 19 | 458752 |
| tb_attention32 | 4 | 32 | 19 | 458752 |
| tb_attention_default | 32 | 64 | 19 | 458752 |

同一 llm_top 上的混合测试执行 LINEAR → KV 配置/追加 → Attention → LINEAR → Attention，检查 KV 元数据跨任务保留；Attention 读错误后，另一引擎及 Attention 本身均能恢复。仿真实际访问高于 4 GiB 的 64 位地址，另有 32 位兼容配置，并拒绝跨越 2^64 的区域。

Attention 参考为独立整数算法与浮点算法；固定精度 RTL 对整数结果逐字节一致。本组合成用例最大 Softmax 概率绝对误差为 0.00279270905，最大 Attention 输出绝对误差为 0.0442295411。测试维度为 9，前缀长度 1/3/7，group32/4/3；默认硬件容量的全部边界组合和真实模型精度未做穷举验证。

golden 破坏与强制超时探针都由校验器判为失败，不能仅凭 XSim 原进程退出码判断成功。所有测试入口在开始执行时使旧 PASS 失效；`status` 核对当前 RTL、模型、软件、配置与运行脚本的 SHA256。

## 物理实现

默认 profile：64 位地址、GROUP_SIZE=32、4×4/TILE_K=8、FFN MAX_H=64/CAPACITY=512、Attention MAX_DIM=64/MAX_TOKENS=16，临时评估器件 xcvu9p-flga2104-2L-e，10 ns 内部时钟。

当前 llm_top 已实际执行 OOC 综合、opt、place、phys_opt、route 和必要的 hold 修复。最终 WNS=+0.321 ns、WHS=+0.010 ns；内部 setup/hold 均非负。可路由网络 56725，完整路由 56725，路由错误 0。流程拒绝 latch/blackbox；DCP、时序、资源、DRC 与完整日志保存在 `build/project_v2/implementation/`。

布局布线后资源：{"FF": 17686, "DSP": 361, "RAMB36": 5, "RAMB18": 7, "URAM": 0, "LUT": 30396}。这些是当前配置的实现值，不能外推到更大的 Attention 容量或其他器件。

这解决了初次整合时仅有综合估计、WHS=-0.066 ns 的问题。没有通过 RTL 延迟或放松数值要求掩盖 hold；判据来自布局布线后的结果。当前是内部 OOC 实现，未指定板级 pin/外部 I/O delay、DDR/PCIe 或真实板卡，不能作为板上运行频率保证。

## 兼容回归与证据

原 software/team/ad/memory/kv/ce/valid 七类回归全部通过，C/E 原计算 RTL、参考模型和 TB 与 bff0f50 保持一致。PowerShell 子任务统一跟随当前 shell，修复了跨版本模块路径和日志编码造成的入口问题。

主摘要为 `build/project_v2/summary.json`。逐配置结果、编译/仿真日志和来源哈希位于 `build/system_v2/` 与 `build/attention_v2/`；兼容回归为 `build/project_v2/legacy.log`。历史 build 不能替代当前源码校验。
