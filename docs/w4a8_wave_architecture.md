# Group 内连续波前架构

## 增量范围

新增w4a8_wave顶层，GROUP_STREAM=1默认只在group末排空。原w4a8_systolic、systolic_array、systolic_pe及其测试/报告保留。GROUP_STREAM=0恢复逐tile排空，仿真t4/t8精确复现上一轮s4/s8全部CSV字段；PE数据流仍A向右、B向下，output-stationary，4×4/8×8结构没有重新实现。

~~~mermaid
flowchart LR
    IN["模拟供数 / packed packet"] --> W["W bank 0/1"]
    IN --> A["按行全 K 激活缓存"]
    W --> READ["同步首读 / PRIME"]
    A --> READ
    READ --> RUN["RUN：注入K向量"]
    RUN --> MORE["同group仍有K tile"]
    MORE --> FREE["释放当前bank"]
    FREE --> HOLD["WAIT_TILE / PRIME：冻结波前"]
    HOLD --> RUN
    RUN --> END["group最后K向量"]
    END --> DRAIN["D=ROWS+COLS−2拍排空"]
    DRAIN --> PS["INT32 group snapshot"]
    PS --> SCALE["独立scale / INT64合并"]
    SCALE --> OUT["Q16.16输出 / 背压"]
~~~

冻结的含义是阵列advance=0；不会注入bubble或继续执行MAC。加载/post可以独立推进。

## 接缝安全性

最后一个tile输入向量在其RUN边沿已被接收：
- row0/col0直接进入首PE。
- 其余行/列进入入口skew的第一级寄存器。
- 已有向量保留在skew与PE前递寄存器中。
- 之后的乘加只依赖已捕获的数据，不再读取旧tile RAM。

因此同group非末tile可以在末注入边沿释放operand bank，consumer切换到下一个bank。producer可以把旧bank重新置LOADING并覆盖权重，阵列仍只保存已经捕获的旧token。WAIT_TILE等待READY和PRIME同步首读都不推进阵列；新tile数据返回后，下一RUN沿才继续推进并同时注入新K。

A与B共同使用同一advance序列。PE(r,c)消费逻辑历史中t−r−c的输入；墙钟等待不会增加逻辑t。输入有效维度cm_len/cn_len在同一output tile内保持不变。tile切换不clear PE、skew或valid，也不将新scale应用到仍未完成的旧group。

本轮每接缝仍需两个固定控制拍：READY的WAIT_TILE交付一拍、PRIME同步首读一拍；未实现无缝RAM预取。输入不READY时额外冻结。因此“group连续”是token序列连续，不能理解为每墙钟拍都有输入。

## group完成与scale隔离

group最后向量注入后，仍执行完整D=ROWS+COLS−2排空，所有有效MAC完成后才：
1. 捕获group的坐标、sx/sw和valid尺寸。
2. 保存RC个INT32部分和到FREE snapshot bank。
3. 将snapshot交给独立scale流水。
4. 释放末tile bank并进入下一group。

下一group首tile经CLEAR_PE清掉sum与链路valid。不同group之间不会共享未完成token或混用scale。最后一个不完整group也按相同fence执行。1×1时D=0，跳过DRAIN，跨tile只保留部分和。

数值规格不变：INT8 qx、signed INT4 qw、INT32 group sum、UQ4.12 sx/sw、signed64 Q24合并、shift8 ties-away舍入及signed32 Q16.16饱和。详情见 [数值规格](w4a8_numerics.md)。

## Buffer和同步端口

激活缓存、packed W bank、psum和Y布局沿用 [激活复用架构](w4a8_reuse_architecture.md) 与 [脉动架构](w4a8_systolic_architecture.md)。

- W每bank每列一个同步读端口、一个写端口，packet全部接受才READY。
- 阵列读只在PRIME或RUN预取，WAIT_TILE不读。
- 同group旧bank释放后可写；在途token已脱离RAM，不需要RAM第二读口。
- group末tile在DRAIN/SAVE期间保持COMPUTING，直到snapshot完成。
- 单bank也支持：释放后加载下一tile，旧token保持在阵列。
- 激活缓存保持M epoch保护，禁止下一M提前覆盖。

rst撤销任务与bank状态、清PE/valid，新任务重新加载A；RAM内容不清零。array_pause冻结RUN/DRAIN推进，load_pause独立控制输入接收，post_pause独立控制后处理。输出背压与continuous tasks合同沿用原顶层。

## 新统计

| 计数 | 定义 |
|---|---|
| tile_handoffs | 同group非末tile的早释放次数 |
| wave_hold_cycles | group_open且处于WAIT_TILE/PRIME的墙钟周期 |
| wave_input_wait_cycles | 上述WAIT_TILE中consumer bank不READY的周期 |

group_open是组尚未交付的控制标记，不保证每个保持拍都有有效token留在每个PE；尤其1×1没有在途链路。冻结计数也包括保留部分和的控制周期。

GROUP_STREAM=1：
~~~text
physical_groups = ceil(M/ROWS) * ceil(N/COLS) * ceil(K/GROUP_SIZE)
handoffs = input_tile_count - physical_groups
array_drain_cycles = D * physical_groups
wave_hold_cycles = 2 * handoffs + wave_input_wait_cycles
~~~

GROUP_STREAM=0：
~~~text
array_drain_cycles = D * input_tile_count
tile_handoffs = wave_hold_cycles = wave_input_wait_cycles = 0
~~~

wave_input_wait是既有input_wait的子集；wave_hold包含固定控制拍与input_wait，不能重复相加到总周期。其他阵列推进、暂停、有效MAC与输出计数定义不变。

## 独立验证方法

新增TB数学历史参考从原矩阵A和packed W直接构造每个注入向量，而非读取DUT乘积当golden：
- 仅array_step增加历史编号，DRAIN记录valid0，WAIT_TILE/PRIME/暂停不增加编号。
- 逐PE检查r+c延迟对应的valid和INT32累加。
- group snapshot前检查注入元素数等于当前group长度；连续模式推进数等于group长度+D。
- 所有非advance且非clear拍检查前递寄存器与sum持稳。
- 定向输入饥饿保持20拍后恢复，以及波前滞留在接缝时复位恢复。
- 记录冻结时旧bank重新装载权重的覆盖，验证早释放真实发生。

完整八配置：g4/g8、逐tile消融t4/t8、2×3/tile5/group12、8×8/tile19、单bank、1×1。量化参考与向量不变。实际结果见 [验证报告](w4a8_wave_validation.md)、[性能报告](w4a8_wave_performance.md)、[内部摘要](w4a8_wave_brief.md)。

## 当前限制

仍有两拍tile交付/首读与输入等待，只在RUN/DRAIN推进；没有WAIT期间自主排空。group末波前、RC逐槽保存/scale与output tile仍串行；尾块使用物理阵列最大D。未实现有效槽压缩、输出tile流水、Decode专用映射、NPU descriptor适配、真实DDR或完整模型。最大逻辑M/N64、K4096及未列参数未全部仿真；VCS和综合网表仿真未运行。
