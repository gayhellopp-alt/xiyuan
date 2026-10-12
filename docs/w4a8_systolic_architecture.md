# 4×4 / 8×8 output-stationary 脉动阵列架构

## 当前增量

新增 systolic_pe.sv、systolic_array.sv、w4a8_systolic.sv，原 mac_array/w4a8_reuse 保留。SYSTOLIC参数选择新脉动或原广播计算阵列。缓存、packed INT4供数、group scale、双部分和snapshot与输出舍入合同保持一致。

~~~mermaid
flowchart LR
    TB["模拟外存 / packed packet"] --> LOAD["原请求与加载控制"]
    LOAD --> A["按行全K A缓存"]
    LOAD --> W["双W tile bank / INT4 unpack"]
    A --> AS["行入口延迟 r"]
    W --> BS["列入口延迟 c"]
    AS --> PE["邻接PE传递 / output-stationary"]
    BS --> PE
    PE --> D["每K tile排空 fence"]
    D --> PS["双INT32 group snapshot"]
    PS --> SCALE["独立scale流水"]
    SCALE --> Y["INT64 Q24 Y RAM"]
    Y --> OUT["Q16.16舍入饱和 / 输出背压"]
~~~

这是实际相邻PE传递的脉动阵列，A向右、B向下，每跳寄存一次；与原广播阵列具有不同的局部连线及结果时序。未接DDR/DMA/PCIe或完整Transformer，没有连接到旧INT8 NPU descriptor队列。

## 元素映射与时序推导

输入向量注入的逻辑推进编号为 t：
- A_r(t)=qx[mt+r,ck+local_k]。
- B_c(t)=signed_INT4(qw[ck+local_k,nt+c])。
- A在第r行入口延迟r个advance，再向右经过c个寄存器边界。
- B在第c列入口延迟c个advance，再向下经过r个寄存器边界。
- 两者均在推进拍 t+r+c 到达PE(r,c)，所以同K乘积配对。

PE(r,c)对应psum[mt+r,g,nt+c]，采用output-stationary。乘积signed16并显式符号扩展到signed32，累加模2^32。每个PE保存A/B前递寄存器及独立valid；只有两个valid均为1且advance为1时MAC使能。无效行/列入口valid为0，不计有效MAC。

以4×4首token为例：

| 推进编号 | 消费首token的PE |
|---|---|
| t | (0,0) |
| t+1 | (0,1)、(1,0) |
| t+2 | r+c=2的PE |
| … | … |
| t+6 | (3,3) |

8×8最后PE在t+14消费。此处编号表示发生乘加的时钟边沿，结果acc在该边沿后的NBA更新完成；独立TB逐推进拍检查所有PE，非仅看最终矩阵。

## tile / group fence

本轮采用保守的每K tile完整排空：
1. WAIT_TILE取得完整READY operand bank。
2. group首tile经CLEAR_PE，其他同group K tile不clear。
3. PRIME发同步RAM读，次拍进入RUN。
4. RUN每个enabled拍注入一个K向量，同时请求下一元素。
5. 末向量注入后进入DRAIN，继续推进 D=ROWS+COLS−2 拍，inject_valid为0，不发RAM读。
6. 排空期间operand bank保持COMPUTING。最后一个有效MAC完成后，才能切bank、推进ck或保存group。
7. group结束将全部RC个acc逐槽写snapshot，再应用该group独立scale。
8. 所有group后处理完成才读取当前output tile；输出tile依然串行。

因此每tile的阵列推进数为clen+D；同一group包含多个tile时sum保留，但每tile都支付D拍。4×4的D=6，8×8的D=14；1×1的D=0并跳过DRAIN。尾块使用物理ROWS/COLS最大D，尚未按有效ml/nl缩短。此原型没有实现跨tile连续波前，不能称为已优化的脉动流水。

## 暂停与复位

新输入 array_pause：
- RUN/DRAIN时冻结阵列推进、skew、PE数据/valid/acc、run_k/drain_left和RAM预取选择。
- PRIME仍完成同步RAM首读；若随后暂停，数据保留到恢复注入。
- load_pause、post_pause分别控制加载与scale，互相独立；array暂停时加载和后处理可继续，受各自Buffer ownership限制。
- 输出背压仍由out_valid/ready处理，当前output tile被保留。
- rst清零全部PE acc、链路valid与skew valid并撤销任务/bank/post状态；RAM数据不清零，新任务重新装载首N激活。
- CLEAR_PE也清除链路与skew，发生在新group首tile且旧group已排空之后。

上层缓存接口是同步有限端口，阵列入口每行一个A、每列一个W，未增加任意RAM多端口。输入向量、RAM地址与valid共用advance节奏，不能单独暂停某个PE或某一方向链路。

## 计数与比较规则

| 计数 | 定义 |
|---|---|
| valid_macs | 每拍累计有效PE fire，实际完成的逻辑MAC；尾块零槽排除 |
| compute_cycles | RUN有效推进拍，即输入K向量注入拍数 |
| array_cycles | RUN及DRAIN有效推进拍 |
| array_drain_cycles | DRAIN有效推进拍，等于D×输入tile请求数 |
| array_pause_cycles | RUN/DRAIN被array_pause冻结的拍数 |
| array_mac_cycles | 至少一个有效PE fire的推进拍数 |
| compute_post_overlap_cycles | RUN有效推进且post活动；排空阶段重叠未纳入此旧指标 |
| overlap_cycles | RUN有效推进且接受输入beat；不含DRAIN时的加载 |

有效推进容量分母是ROWS×COLS×array_cycles，端到端容量分母是ROWS×COLS×total_cycles；不能拿compute_cycles作为脉动的完整容量分母。暂停时不增加MAC/推进计数。array_pause与input/output/psum/post等待分类互斥；其他overlap为子集，不能加总。

默认BUS_BYTES8、tile8、group32；4×4/8×8理论16/64MAC每推进拍，100MHz目标下1.6/6.4GMAC/s是理论值。真实周期及资源分别记录于验证/性能报告。

## 实际验证范围

- 独立4×4、8×8逐PE历史参考：波前、valid、INT8/INT4边界、K1、暂停全寄存器持稳、尾行列、跨段sum、在途复位。
- 整条W4A8：4×4/8×8脉动与同尺寸广播，2×3/tile5/group12，8×8/tile19，单operand bank，1×1退化。
- 原12向量保留，新增8×16×96、1×17×96、9×11×67；满足满8×8、Decode和尾块。
- 运行中RUN、输出背压、post流水及被冻结DRAIN复位恢复；输入/输出/请求持稳；cache初始化/epoch与bank所有权。
- 默认逻辑上限MAX_M/N64、MAX_K4096；最大维度未仿真。
- VCS脚本提供，编译执行未验证；仿真使用Vivado XSim。

## 实际移位存储映射

8×8脉动综合中，W bank使用320个分布式RAM LUT，另推断44个SRL16E保存部分波前移位状态；utilization报告的LUT as Memory合计364，不能全部称为LUTRAM。有效位复位/暂停协议以可观察的MAC行为为合同，综合可在valid屏蔽下优化移位数据的物理实现；仿真使用RTL，未运行综合网表仿真。

## 后续优先项

1. group内连续波前：K tile切换时保留已注入token，RAM等待可选择整体冻结或注入valid0 bubble，只group末排空；须重新验证读地址、pause和group隔离。当前D×tile数开销可望降到D×group数，但收益需实际测量。
2. RC逐槽psum保存与output tile流水；8×8每组64槽保存/scale开销可能抵消减少N/M tile数量的收益。
3. Decode N/K映射及NPU descriptor适配；M=1二维阵列仍有空闲行。更大阵列、真实DDR和完整模型属于后续计划。

现有缓存与量化合同见 [w4a8_reuse_architecture.md](w4a8_reuse_architecture.md)、[w4a8_numerics.md](w4a8_numerics.md)，实际结果见 [验证报告](w4a8_systolic_validation.md)、[性能报告](w4a8_systolic_performance.md)。
