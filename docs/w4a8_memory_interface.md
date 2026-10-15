# 工作包 B：存储侧接口 v1

本实现独立于控制顶层，新增 `w4a8_memory_bridge`，不修改 `w4a8_wave`、数值路径、阵列或 `npu_top`。源码基线为 main `2e56af8bbee1fe6e806217e6f729a4984d8cb262`。该版本未提供队友1的公共 W4A8 描述符，故提供最小存储侧合同 `w4a8_memory_pkg::memory_task_t`，由控制 owner 映射其软件格式，不把这个 packed struct 当作主机 ABI。

## 1. 接入合同

- 同一时钟域，单活动任务。`task_valid/task_ready` 接受整个 `task_desc`；桥在接受沿锁存，之后修改提交端字段不影响任务。
- `completion_valid/completion_ready` 接受 `{completion_task_id,completion_status}`；背压期间持稳，完成记录接受前不接收下一任务。
- 桥的 `core_start` 接核心 `start`，`core_start_ready/core_done/core_error` 接核心同名语义的端口；`cfg_m/n/k` 接核心配置。
- 核心 `rst = system_rst | bridge.core_reset`。`core_reset` 在 idle、校验、错误排空和完成记录持有期间置位，撤销失败任务的内部 bank、流水和输出；不清核心 RAM。
- `req_valid/ready,m/n/k,ml/nl/kl,group,scale,activation`、`in_valid/ready/data/keep` 和 `out_valid/ready/m/n/last/data` 原样连接。桥锁存全部请求字段，一次只服务一个 packet 请求。核心保持原 M epoch fence，桥不自主预取下一 M。
- 核心须编译为 `BUS_BYTES=8,PACK_COLS=1`，ROWS/COLS/TILE_K/GROUP_SIZE/MAX_* 与桥一致；A_REUSE/SCALE_ONCE 的取舍通过请求标志体现。bridge 没有运行时切换 group 的能力。
- `load_pause/post_pause/array_pause` 由控制或测试连接核心。桥根据 `in_ready/out_valid` 自然处理暂停，无需修改核心端口。

综合源清单（按顺序）：`w4a8_memory_pkg.sv`, `w4a8_memory_validate.sv`, `w4a8_axi_read.sv`, `w4a8_axi_write.sv`, `w4a8_memory_packet.sv`, `w4a8_memory_bridge.sv`。真实核心另加其既有综合源。`tb/w4a8_axi_memory.sv` 和全部 TB 不能进入综合列表。本轮没有新增统一产品顶层；真实核心接线示例在 `tb/tb_w4a8_memory.sv`。

## 2. 描述符、布局及范围

| 字段 | 位宽 | 单位/含义 |
|---|---:|---|
| task_id | 32 | 不透明任务 ID，原样返回 |
| m/n/k | 各16 | 正整数逻辑维度，默认 M/N≤64、K≤4096，受编译 MAX_* 限制 |
| format_id | 16 | 仅 `MEMORY_FORMAT_V1=1`：signed INT8 / signed packed INT4 / UQ4.12 / Q16.16 |
| group_size | 16 | 必须等于硬件 GROUP_SIZE，不能运行时改变 |
| a/w/sx/sw/y_base | 各32 | 字节地址，32-bit AXI 地址空间 |
| a/w/sx/sw/y_stride | 各32 | 字节步长，分别为 A 行、W 输出通道、sx 行、sw group、Y 行 |
| a/w/sx/sw/y_bytes | 各32 | 各张量允许访问的独立分配范围，半开区间 `[base,base+bytes)` |

令 `G=ceil(K/GROUP_SIZE)`，全部字节序为 little endian：

```text
A[m,k] byte        = a_base + m*a_stride + k
W[n,k] byte        = w_base + n*w_stride + floor(k/2)
                     偶数 k 用低 nibble，奇数 k 用高 nibble，signed INT4
sx[m,g] uint16     = sx_base + m*sx_stride + 2*g
sw[g,n] uint16     = sw_base + g*sw_stride + 2*n
Y[m,n] signed32    = y_base + m*y_stride + 4*n
```

每 W 通道有效字节 `ceil(K/2)`，奇数 K 的末高 nibble 不参与计算。sx/sw 为 unsigned16 UQ4.12，Y 为 signed32 Q16.16，数值规则完全沿用 `w4a8_numerics.md`。

启动前要求：A stride≥K；W stride≥ceil(K/2)；sx stride≥2G；sw stride≥2N；Y stride≥4N。A/W 基址和 stride 允许任意字节对齐；sx/sw 基址及 stride 为2字节对齐；Y 基址及 stride 为4字节对齐。最小分配长度分别为 `(M-1)*a_stride+K`, `(N-1)*w_stride+ceil(K/2)`, `(M-1)*sx_stride+2G`, `(G-1)*sw_stride+2N`, `(M-1)*y_stride+4N`。

校验用64位无符号运算，在合法16位尺寸/32位 stride 下不会溢出64位；每个 `base+bytes≤2^32`，实际 extent≤bytes。尺寸0、超容量 K、超 M/N、未知格式、group 不匹配、stride 过短/未对齐、地址环绕、区域过短全部在 core start 和任何 AXI 请求之前拒绝。Y 分配区不得与任何输入分配区重叠，禁止未验证的原地计算。只读区域可共享。调用方保证这些分配区是真实可访问的内存且任务运行时不修改输入；总线错误不能通过元数据预防。

## 3. tile → packet

接受请求时额外检查尺寸非0、ml/nl/kl 不超过硬件 tile、全局范围及 group 一致且不跨 group。顺序严格为 W → 可选 A → 可选 sx → 可选 sw。`req_activation=0` 完全跳过 A；`req_scale=0` 完全跳过两段 scale。

```text
wspan = (req_k%2 + req_kl + 1)/2
权重：先列对 c=0,2,...，再每列 word p=0,4,...
keep[j] = (c+j/4 < req_nl) && (p+j%4 < wspan)
byte[j] = W_base + (req_n+c+j/4)*W_stride + req_k/2 + p+j%4
```

每 beat 低32位和高32位属于两个不同列，不能视作同列连续8字节。两列各1/3字节产生 `keep=0x11/0x77`，奇尾列只使用低槽。A 按每行每8字节独立 beat；sx/sw 各为独立段，在低字节起顺序放置，行之间的 sx stride 由 gather 隐藏。无效槽填 `0xA5` 且 keep=0，不向外存读 padding。奇数 req_k/奇数 K、跨 group 截断、末不完整 group、M/N 尾块均依赖接受的实际字段。

一个64-bit packet 寄存器，最多8个有效字节。只对有效槽发读，每个返回被存入保留槽后才推进。一个 beat 全部字节就绪后才置 in_valid；背压期间不读取下一 beat，data/keep 持稳。没有下一任务输入 FIFO，也没有额外 A/sx 缓存策略。

## 4. 最小 AXI4 master 子集

64-bit R/W 数据、32-bit 地址、4-bit ID（固定0）。仅 INCR、非独占、单 beat（ARLEN/AWLEN=0）；读 ARSIZE=0（1字节），写 AWSIZE=2（4字节）。长度1是本轮支持的 burst 长度上限；不宣称支持多 beat 合并。平台需支持合法 AXI narrow transfers。未导出的 LOCK/CACHE/PROT/QOS/REGION 由接入层按平台合同固定为普通内存的合法值；不支持一致性、原子操作或 CDC。

每方向最多一个在途事务，读写方向可并行。发 AR 前已经独占一个 byte response 槽，返回空间无需依赖核心 ready；读响应寄存器接受后再交 packet。AR payload 持稳至握手，RRESP、RID 和 RLAST 检查后才交付；若首 beat 未带 RLAST，标错并排空到 RLAST。总线永远不发送越界尾读：一次精确读1字节，不向下对齐后读取整个64位。由于每次读1字节、每次写4字节且地址4字节对齐，事务天然不跨4KiB边界。A 测试基址4093跨页，拆分为独立事务。

每输出占一个32-bit写寄存器。AW 和 W 各自持有 pending 位并独立握手，任意先后顺序均合法；只有二者接受后才置 BREADY。地址来自 `out_m/out_n`，不依赖输出遍历次序。W data 在对应64-bit lane 移位；`WSTRB=0x0F << (addr%8)`，只更新4字节，保护另一半总线字和行 padding。仅成功 BRESP=OKAY、BID=0 计入成功路径；EXOKAY 在此非独占子集也作为错误。

## 5. fence、错误和复位

成功需同时满足：core done 已观察；out_last 已接受；接受的输出数等于 M*N；收到的写响应数等于输出数且没有错误；读写引擎和 packet 全部空闲。最后 out_last、最后 W 或 core done 都只是条件之一。成功记录会比最后 B 握手晚若干控制拍，不允许提前。

| 状态 | 数值 | 行为 |
|---|---:|---|
| MEM_OK | 0 | 所有 fence 成立 |
| MEM_BAD_TASK | 1 | 描述符拒绝，没有核心/总线访问 |
| MEM_READ_ERROR | 2 | RRESP、RID 或 RLAST 异常 |
| MEM_WRITE_ERROR | 3 | BRESP 或 BID 异常 |
| MEM_CORE_ERROR | 4 | 核心 error |
| MEM_PROTOCOL_ERROR | 5 | 请求范围错误、非法输出坐标/计数/last、核心过早 done |

首个检测到的错误按读、写、核心、协议的固定优先级锁存。停止新请求及输出接受，置 core_reset 撤销内部计算，保持已经发出的 AR/AW/W，并消费 R/B；所有在途事务排空后返回错误记录。已经写入的 Y 可能部分更新，不能当作有效结果；错误响应不能保证内存没写入，调用方须重新提交/处理整个任务。若 slave 永不响应或一直没有 RLAST，桥保持排空而不接受下一任务；本轮硬件不内建超时，控制 owner 应有系统 watchdog。自检每任务/全局 watchdog 使脚本非零失败。

本轮 **只支持桥、核心和 AXI fabric/仿真内存共同同步复位**。复位撤销事务、任务、记录和内部有效位；不清 core RAM 或仿真内存数组，新任务必须重新装载首 N 的 A。AXI memory 复位须撤销所有旧 R/B、AW/W 捕获和延迟队列。错误后的内部 core_reset 不复位 AXI 引擎，而是先排空，允许下一任务无系统复位恢复。

**不支持带在途事务的桥单独复位后直接重启。** 固定 ID 不提供跨复位 epoch 标识，桥复位会丢失在途所有权；控制侧必须同时复位/隔离并冲刷 fabric，确认旧响应不再可见后才解除系统复位。不能将旧 R/B 与新任务混用。外部 DDR/互连若不能共同复位，需要后续加 quiesce/drain 或 ID epoch wrapper；本轮未验证这一场景，也没有声称桥单独复位安全。

## 6. 统计及边界

所有计数32位，任务接受时清零，完成后保持：cycles 从 CHECK 到完成 fence 前；read_bytes/write_bytes 按 AR/W 握手累计有效1/4字节；read_bus_bytes/write_bus_bytes 按对应总线 beat×8计物理lane容量（不代表DDR命令流量）；packet_bytes 按接受keep计数，packet_bus_bytes 按输入beat×8。read_wait/write_wait 为对应引擎占用周期，包括地址、数据和响应等待；input_wait 是 in_valid&&!in_ready，output_wait 是运行中 out_valid&&!out_ready。等待计数可重叠，不能加总作总周期。packet_high_water 是 packet 寄存器中有效字节峰值；write_high_water 为写槽是否曾占用。

首轮吞吐优先级低于协议正确性：每字节一个读事务，stride 地址乘法组合生成，可能耗费较多 DSP/LUT；资源以实际综合为准。无板级 DDR/PCIe、无多任务、无更大的 K 分解、无 KV/Attention（工作包 F 留待后续），无多 beat burst/coalescing。未引用上游源码；openTPU 仅是已有文档的可选参考。

## 7. 给队友1

1. 导入 package 并映射任务 ID、尺寸、5个 base、5个 byte stride、5个允许范围长度、format=1、匹配硬件的 group_size；软件 ABI 由你维护。
2. 仅在 task_ready 时提交，保持全部字段到握手；为每个任务分配互不与 Y 重叠的源/目的区域，禁止超容量 K 和运行中输入修改。
3. 按第1节原样接核心及 reset；在 completion_valid 时读取 ID/status，提供 ready。只有 status=0 时消费 Y；其他状态废弃整片结果。
4. AXI 接口需支持1字节读和4字节写；按平台补齐固定属性，安排共同 reset 与 watchdog，不将仿真 memory 纳入 FPGA。
5. 直接复用 `tb_w4a8_memory` 的真实核心接线作为最小集成示例；统一控制顶层仍由你维护，不需要修改计算核心。
