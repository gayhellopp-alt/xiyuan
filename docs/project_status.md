# 当前项目状态

2026-10-15：当前主系统为 **llm_top / ABI v2**。三方模块已形成统一任务入口、共享 AXI 所有权及完成路由。完整外存 FFN、事务式 KV 和有界 Attention 已形成真实 RTL 闭环，并通过当前源码仿真；汇合顶层 OOC 最终 WNS=+0.321 ns、WHS=+0.010 ns。

## 已实现

- 64 位主地址通路与 32 位兼容模式，65 位范围/回绕检查。
- LINEAR、FFN、ATTENTION、KV_CONFIG、KV_COMMAND 五类任务与统一完成反压。
- gate/up 外存写确认 → FFN DMA → 原 SiLU/dynamic requant → qx/sx 外存写确认 → down。
- KV 分 layer/head 提交长度、append/read/clear；Attention 读取已提交前缀，QK/Softmax/AV 后真实写回 Y。
- 同一顶层跨引擎连续任务与出错恢复，统一软件 API、profile、source manifest、test/implement/status/legacy 入口。

## 当前工程范围

默认 FFN 中间元素上限 512、Attention 维度上限 64、可见前缀上限 16；一个任务顺序执行。Q 通过量化流输入。当前完整的是这些算子事务，不是完整 Transformer/LLM token 生成。

## 后续工作

1. 连接 Q/K/V/O 投影后的量化和 Q 流 DMA，加入 RoPE、RMSNorm、残差及整张 Transformer 任务图。
2. 扩展 Attention 序列/维度容量、GQA、分页/滑窗与 mask，并针对真实模型校准数值和精度。
3. 在当前 fence 合同下增加更高效的 burst、多 outstanding、输出 FIFO 与阶段重叠，保持本版顺序路径作为回归基线。
4. 确定板卡后加入真实 DDR/PCIe、CDC/复位、引脚及 I/O delay 约束，开展板级和真实模型验证。

详见[架构](system_architecture.md)、[数值](system_numerics.md)、[验证](system_validation.md)。原项目状态保留在 [history](history/project_status_pre_system_v2.md)。
