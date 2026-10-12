# NPU 任务前端：驻留矩阵与有序完成

## 已实现的范围

新增可综合顶层 [npu_top.sv](../rtl/npu_top.sv)。它包装现有 [matmul_top.sv](../rtl/matmul_top.sv)，增加任务描述符 FIFO、自动发起计算、完成记录和结果所有权保护。计算引擎仍为 INT8×INT8、INT32 回绕累加的 output-stationary 阵列，默认 4×4/K8，B tile 双缓冲；原始核心接口保持可单独使用。

这是 NPU 的任务控制前端。当前只有 GEMM 一个操作码，M=1 使用同一路径实现 GEMV。尚无通用指令处理器、多算子执行、任务独立地址、主机硬件驱动或外部内存。

~~~mermaid
flowchart LR
  H[主机同步接口] --> Q[72 bit 描述符 FIFO]
  Q --> S[有序调度 FSM]
  H --> AB[驻留 A/B Buffer]
  S --> E[INT8 GEMM 引擎]
  AB --> E
  E --> P[INT32 结果 RAM]
  E --> C[完成记录与周期计数]
  P --> H
  C --> H
  H -->|完成确认| S
~~~

## 描述符与 FIFO

默认 QUEUE_DEPTH=4，只计等待任务，不包含一个活动/待确认任务；最大同时持有 5 个描述符。FIFO 使用明确的寄存器数组，每拍最多一个写入、一个读出，原始存储为 4×72=288 bit。小深度不占用额外 BRAM，实际映射以综合报告为准。指针显式回绕，支持非 2 次幂深度；已实际验证深度 3 和 4。参数必须为正整数；其他深度未验证。

| 字段 | 位数 | 当前合同 |
|---|---:|---|
| opcode | 8 | 1 为 signed INT8 GEMM；其余返回不支持状态 |
| tag | 16 | 主机任务 ID，按接受顺序回传；允许重复，不用于硬件查重 |
| m/n/k | 各 16 | A/B 左上角子矩阵尺寸，1..MAX_M/N/K |

打包顺序为 {opcode,tag,m,n,k}，总计 72 bit。所有接受的描述符均按序给出一个完成记录，包括非法描述符。非法命令不会启动核心，也不会暴露旧结果。操作码检查优先于尺寸检查。

| completion_status | 含义 | 验证情况 |
|---:|---|---|
| 0 | 计算成功，允许读结果 | 已验证 |
| 1 | 尺寸为 0 或超过容量 | 已验证 |
| 2 | 不支持的操作码 | 已验证 |
| 3 | 核心报告错误 | RTL 已实现，正常前端检查使此路径不可达；未注入验证 |

## 接口与仲裁

所有接口使用同一真实 clk；rst 为同步高有效。具体端口宽度见 RTL。

| 接口 | 接受条件及行为 |
|---|---|
| wr_valid/wr_ready + matrix,row,col,data | 延续核心 INT8 坐标写接口；只有队列为空且调度器 IDLE 时允许写，pause 阻止写 |
| cmd_valid/cmd_ready + opcode,tag,m,n,k | 上升沿两者为 1 才入队；队列满、rst、pause 时 ready=0；主机等待时保持字段稳定 |
| completion_valid/completion_ready | valid 及 tag/status/dimensions/counters 保持到确认；可在 pause 期间确认 |
| rd_req/rd_ready + row,col | 只允许读取当前成功完成记录所属结果；同步响应 rd_valid/rd_data，不提供响应端背压 |
| busy | 仅 LAUNCH/RUN 为 1；等待完成确认时为 0，不能将 busy=0 当成可重新加载 |
| buffers_locked | 有等待、活动或待确认任务即为 1；加载应检查 wr_ready |
| queued_count | 等待任务数量，不包含活动/完成记录 |
| result_available | 只有成功且尚未确认的完成记录为 1；非法任务不会复用上一结果 |

仲裁规则：

- 描述符提交优先于同拍输入写；即使原来空闲，cmd_valid=1 时 wr_ready=0。
- FIFO 满时不提供同拍 pop 的组合旁路，cmd_ready=0；下一拍恢复，因此可能有一个入队气泡。
- 完成确认优先于同拍新结果读，completion_ready=1 时 rd_ready=0。主机应先接收全部 rd_valid 响应，再确认。
- 已接受的同步读响应继续转发；不因完成确认撤销它。读响应必须被主机及时采样。
- 未加载元素没有硬件有效位；主机必须初始化所有任务会读取的 A/B 元素。

## 存储所有权

当前所有排队描述符使用同一份驻留 A/B：A 地址 row×MAX_K+col，B 地址 row×MAX_N+col。不同任务可以改变尺寸，但无法选择独立矩阵、偏移或 stride。描述符入队后，A/B 锁定到队列和完成记录全部排空。下一组输入需要等待 buffers_locked=0 并按 wr_ready 写入。

INT32 P RAM 只有一个结果集合，因此调度器在 COMPLETE 保持结果，直到主机确认才调度下个任务。它支持提前提交任务，尚不支持无需主机确认的算子流水线。确认后上个结果的所有权消失；即使 RAM 尚有残留，也不可继续读取。

计算和 tile Buffer 仍具有明确同步读延迟和有限端口；详见 [原核心架构](architecture.md) 及 [双缓冲合同](double_buffer.md)。新增前端没有改变 B 源 RAM 每拍一个标量的带宽。

## 周期行为

调度器状态为 IDLE → LAUNCH → RUN → COMPLETE → IDLE。

1. 空队列接受描述符的边沿只执行入队，不进行空 FIFO 旁路。
2. 下一可用边沿从 FIFO 取出头部，锁存任务字段、清零该记录周期值。非法命令直接进入 COMPLETE；合法命令进入 LAUNCH。
3. LAUNCH 在核心 start_ready 且未暂停时发 start，进入 RUN。
4. 核心的 done/error 为一个周期事件。RUN 无论此刻 pause 是否为 1 都捕获事件，避免最后计算边沿之后暂停造成完成丢失。
5. COMPLETE 保持全部字段和结果；主机读取后确认。确认可在暂停中完成，下一任务的取出仍要等待 pause=0。

completion_cycles/active_cycles 直接记录核心 busy 的总周期/未暂停周期；不包含 FIFO 等待、前端启动/捕获、主机装载或结果读取。当前满容量 16×16×32 的核心活动周期仍为 2856，调度前端不宣称提高 MAC 利用率。FIFO 的价值是提前提交与明确所有权。理论 16 MAC/拍与 100 MHz 换算继续只是评估上限，不能用它推导完整 NPU 或板上吞吐。

## 复位

rst 取消活动任务、排队任务与完成记录，清零 FIFO 指针/计数和完成元数据；不产生逐条取消完成通知。A/B/P 物理 RAM 不清空；旧结果失效，新的合法任务重建 PE 部分和及 tile 状态。主机负责清理本地待完成列表，随后可复用已完整初始化的驻留 A/B。已有测试覆盖计算中带非空队列复位、持有完成结果带非空队列复位，以及无需重新写 RAM 的恢复计算。

## 主机使用顺序

1. 复位；等待 wr_ready，加载本批任务使用的全部 A/B 数据。
2. 按 cmd_ready 提交描述符，遇到满队列保持 valid/字段直到接受。
3. 看到 completion_valid 后核对 tag、status、尺寸和周期。成功时按坐标读完所有 INT32 输出。
4. 最后一条响应已接收后给 completion_ready；失败任务直接确认。持续重复直到全部任务完成。
5. 队列和完成记录排空后可加载另一批数据。

参考数据生成器与自检 TB 是这个同步协议的可执行示例：[generate_npu_vectors.py](../model/generate_npu_vectors.py)、[tb_npu.sv](../tb/tb_npu.sv)。实际工具结果见 [npu_validation.md](npu_validation.md)。
