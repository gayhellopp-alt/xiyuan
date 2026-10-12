# W4A8 激活跨 N tile 复用架构

## 增量与数据流

w4a8_reuse 保留 w4a8_post 的广播外积 PE、双权重 tile bank、双 INT32 group snapshot 与独立定点 scale 流水；数值规格沿用 [w4a8_numerics.md](w4a8_numerics.md)。A_REUSE=0 保留原每个 N tile 重传激活的行为。A_REUSE=1 缓存当前 M tile 全部 K，沿 N 复用。默认 ROWS/COLS=4、TILE_K=8、GROUP_SIZE=32、MAX_K=4096、BUS_BYTES=8。

~~~mermaid
flowchart LR
    MEM["TB 存储供数模型"] --> W["列对 packed INT4 / 双 W tile bank"]
    MEM --> A["首 N tile：按行全 K 激活缓存"]
    MEM --> S["sx/sw scale FF"]
    A --> PE["广播外积 INT8×INT4 MAC"]
    W --> U["INT4 符号扩展"]
    U --> PE
    PE --> PS["双 INT32 group snapshot"]
    S --> PS
    PS --> SCALE["独立 scale 流水"]
    SCALE --> Y["INT64 Q24 Y累加 RAM"]
    Y --> OUT["舍入饱和 Q16.16 / valid-ready"]
~~~

PE不是严格脉动阵列：每拍一个有效K，A按行广播、W按列广播；没有邻接PE的A/B传递和波前。group结束先完整保存整数部分和，跨K tile累加后才应用不同group的scale。

## 接口与 packet

继承 start/start_ready、尺寸、busy/done/error、req_valid/ready、in_valid/ready/data/keep、out_valid/ready/m/n/last/data、load_pause/post_pause 与性能计数器。新增请求输出 **req_activation**，请求被接受时与尺寸一起锁存：

- A_REUSE=0：始终1。
- A_REUSE=1：req_n==0时为1，其他N tile为0。
- req_scale与旧版相同，SCALE_ONCE=1时只有每group末K tile传scale。

每packet顺序：列对权重beat → 可选激活行word → 可选sx → 可选sw。若无A和scale，末权重beat接受即READY。keep、低/高nibble顺序与 [w4a8_packed_architecture.md](w4a8_packed_architecture.md) 一致，W每beat最多两个独立列bank各写一个32bit word；A每beat只写一个行bank的一个word。sx仍在每N tile末group重传，未缓存scale。

请求/输入/输出在valid&&!ready时保持payload稳定；暂停禁止接收但不能丢失pending word；post暂停冻结scale流水；busy拒绝新start，非法尺寸在idle start时返回error；done为一拍脉冲。复位撤销所有ownership、pending输入与输出，RAM内容不清零，新任务必须重新加载首N tile。

## 激活缓存地址

先定义：

- AD=ceil(TILE_K/BUS_BYTES)，一个K tile预留的word数。
- CACHE_TILES=ceil(GROUP_SIZE/TILE_K)，一个group预留的K tile数。
- CACHE_GROUPS=ceil(MAX_K/GROUP_SIZE)。
- CACHE_DEPTH=CACHE_GROUPS×CACHE_TILES×AD，每个行bank的word深度。

当前全局K tile起点q、local word位置p，对应：
~~~text
group = floor(q / GROUP_SIZE)
tile_in_group = floor((q % GROUP_SIZE) / TILE_K)
cache_word = (group * CACHE_TILES + tile_in_group) * AD
             + floor(p / BUS_BYTES)
cache_row = local m row
byte_selector = local k % BUS_BYTES
~~~

这是按请求tile留槽的布局，外部仍是正常A[m,k]。tile5/group12与tile19/group32不做跨word拼接，每个tile自己的word从低byte开始；完整缓存里的padding不会作为K元素参与计算。因此每beat只需一个word写端口，也无需read-modify-write。代价是非整齐参数的存储padding：默认depth512，每行64bit×512=4KiB，四行16KiB；2行/tile5/group12时每行depth1026×64bit，虽有效K最多4096字节，物理位容量约两倍。容量由MAX_K编译时确定，不随任务K缩小。

每行缓存一个sync_sdp_ram，单写端口与单同步读端口。PRIME发出首元素word读；次拍RUN消费返回word对应byte；RUN同时请求下个K word。与旧tile RAM相同的一拍读延迟，读一次返回完整word，但每拍仅取一个INT8元素；重复读相同word是当前简单实现。缓存读取禁止超过有效K或无效行。无效行A强制0；尾wordpoison可存但不会选中。

其他地址不变：W按local列/word，group snapshot按r×COLS+c，Y同样槽索引；详细周期见 [w4a8_post_architecture.md](w4a8_post_architecture.md)。

## 生命周期与竞争约束

全K缓存是一个M epoch，未额外实现第二套M cache：

1. legal start建立M=0 epoch；旧RAM内容无效。
2. 首N tile的A逐word装载；该tile对应W bank只有packet完整后才READY，故计算不会读取未加载A。
3. 首N全部K packet都加载完成后producer才能请求下一个N tile；A全K就绪，之后N复用只读。
4. producer允许提前请求相同M的后续N/K，W仍ping-pong。
5. req_valid额外受producer M==consumer M约束。producer走到下一M时暂缓，直到consumer完成旧M全部N及输出握手后更新mt。
6. 下一M epoch覆盖相同行cache地址。consumer已经不再读旧M；新M首N完整word重新加载后才能消费。
7. reset与连续任务重新建立epoch，旧值不能复用。

第一次N计算与未来K加载可以同时读写缓存，但地址不同；TB显式检查同地址读写禁止，避免依赖BRAM的碰撞语义。无逐wordvalid RAM硬件：安全性由请求顺序、完整packet READY fence和M epoch gate保证，TB维护影子valid数组审计该合同。影子数组和模拟外存均仅在testbench，未纳入综合。

W bank仍FREE→LOADING→READY→COMPUTING→FREE；group snapshot仍FREE→WRITING→READY→SCALING→FREE，post_pause导致满队列时保留PE和W bank，不覆写。Y初始化/scale读写/输出读的单端口仲裁不变。

## 性能与存储解释

有效A传输从M×K×ceil(N/COLS)变为M×K；W/scale字节、有效MAC=M×N×K、RUN=ceil(M/ROWS)×ceil(N/COLS)×K不变。既有统计仍按实际接受keep计数，输入beat与padding单列；MAC利用率分母ROWS×COLS×总周期，尾块填零不计有效MAC。没有新增统计DSP；缓存命中/写/epoch覆盖由TB记录。

默认16MAC/拍、100MHz=1.6GMAC/s仅理论容量；实际周期见 [w4a8_reuse_validation.md](w4a8_reuse_validation.md)。缓存STYLE=block只是推断要求，实际BRAM/LUTRAM/FF必须以build/synth_w4a8_reuse/ram_synth.rpt为准。暂不接DDR/DMA/PCIe、完整模型或NPU descriptor queue。

## 当前限制与后续选择

单M缓存禁止下一M预取，权重加载/计算可重叠但不跨M epoch。增加第二套全K缓存之前，应测M切换等待占比和容量成本。当前只缓存qx、不缓存sx；输出tile仍顺序完成；没有深输出FIFO。GROUP_SIZE与TILE_K须为正，MAX_K<=4096，参数合法边界沿用先前设计；实际仿真组合见验证报告，未测全部最大维度。
