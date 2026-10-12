# 第二阶段：流式分组 W4A8 线性层

本阶段新增独立可综合顶层 w4a8_linear，复用已验证 mac_array/mac_pe 与同步单写单读 RAM。原 matmul_top、b_pingpong、npu_top 和原回归保留。新顶层没有接到旧 NPU 描述符队列；数值与供数合同不同，下一阶段再加入张量地址/操作码适配。

## 数据流

~~~mermaid
flowchart LR
  E["仿真外部存储<br/>仅 TB"] -->|req + 字节 valid/ready| P["producer<br/>权重/激活/scale 加载"]
  P --> B0["operand bank 0"]
  P --> B1["operand bank 1"]
  B0 --> U["同步读取<br/>INT4 解包/符号扩展"]
  B1 --> U
  U --> A["output stationary<br/>ROWS × COLS MAC"]
  A --> G["group INT32 scratch"]
  G --> S["sx × sw<br/>psum × factor"]
  S --> Y["INT64 Q24 output accumulator"]
  Y --> R["舍入/饱和<br/>单输出寄存器 valid/ready"]
~~~

默认4×4、K tile8、group32；备用2×3、tile5、group12。每拍向阵列广播 ROWS 个激活与 COLS 个权重，第(r,c)个PE计算 qx[mt+r,ck+t]×qw[ck+t,nt+c]。每组开始清PE，在多个K tile间保持INT32部分和；组完成后保存所有物理槽位，再逐个scale并合并到64位输出累加RAM。所有group合并后输出当前M/N tile，随后处理下一tile。

tile请求长度 min(TILE_K,K-k0,GROUP_SIZE-k0%GROUP_SIZE)，不会跨组；M/N有效数 min(ROWS,M-m0)/min(COLS,N-n0)。物理阵列不限制逻辑整层尺寸：运行时M/N≤64、K≤4096，数据按请求一块块装载，无整层驻留RAM。已实测K=96；完整LLM形状需增加维度边界、张量地址及外存适配，目前尚未验证超上限任务。

## 接口合同（同一时钟、上升沿握手）

| 接口 | 行为 |
|---|---|
| rst | 同步高有效，丢弃当前任务、请求、bank状态、输出、统计；不清物理RAM |
| start/start_ready | 仅idle且非reset接受；cfg_m/n/k仅接受拍采样，合法正尺寸进入busy，非法尺寸error一拍 |
| busy/done/error | busy覆盖整个任务；busy时start忽略；done成功完成一拍；error非法配置一拍 |
| req_valid/req_ready | 一次只允许一个未完成数据包，坐标/长度/group在未接受期间保持稳定 |
| req_m/n/k | tile的全局起始行/列/K |
| req_ml/nl/kl/group | 有效行列/K数量和floor(k/GROUP_SIZE) |
| in_valid/in_ready/in_data | 8-bit无符号传输容器，数据包严格按下述顺序；valid且ready才接受 |
| load_pause | 外部可暂停输入ready，compute与输出继续；未接受输入必须保持valid/data |
| out_valid/out_ready | 当前结果未接受时坐标/data/last保持；输出受阻可继续预取到空bank |
| out_m/n/data/last | 全局输出坐标，signed32 Q16.16；last仅最后一个有效元素 |
| statistics | 同步可直接读取的32-bit输出端口；done后保持，下一合法start清零 |

调用者在最后数据包结束前不能改变数据源；数据包没有中止/长度校验通道，短包会等待到系统watchdog，长包必须遵守ready。sx/sw在同group不同K tile传入的值必须一致，当前DUT不检查这个源合同。连续任务需等done/idle后start；上一任务所有有效输出接受后才done。reset后外部模型也必须reset，不能向新请求交付旧响应。未连接跨时钟CDC。

## 外部地址、数据包与片上布局

| 外部张量 | 地址 |
|---|---|
| qx[m,k] | m*K+k，INT8一字节 |
| packed qw[k,n] | n*ceil(K/2)+floor(k/2)，列优先沿K打包；偶k低nibble、奇k高nibble |
| sx[m,g] | m*ceil(K/group)+g，每值unsigned16低字节在前 |
| sw[g,n] | g*N+n，同上 |
| 输出期望 y[m,n] | m*N+n；硬件按tile顺序输出，使用坐标重建 |

每个已接受请求：(1) 每有效列传 ceil((k0%2+kl)/2) 个原始权重字节，自floor(k0/2)开始；(2) 每有效行传kl个激活；(3) 每有效行2字节sx；(4) 每有效列2字节sw。最后一个scale字节接受后bank才READY。边界字节可能含tile外nibble，只在合法t上选用；全局K奇数最后high nibble是poison填充，不能参加计算。请求不触及任何矩阵范围外地址。

片上每operand bank包含 ROWS 个8×TILE_K激活bank、COLS个8×floor((TILE_K+2)/2) packed权重bank；每个bank一个同步读端口、一个写端口，源端每拍最多写一个字节，计算每拍各bank读一个字节。同步read的数据下一拍供MAC；PRIME先读t=0，RUN同时消费当前q并预读t+1，最后t不再发读。权重读取后选nibble符号扩展至8。默认tile8的最坏奇起点需5字节，备用tile5最多3字节。未使用任意多端口数组。

sx/sw是小规模16-bit寄存器阵列，通过slot选择一行/列。group scratch为ROWS*COLS深、32位，output accumulator同深64位，地址r*COLS+c；均一个同步读与一个写端口。group scratch重复用于下一组，因此并不同时保留全部group；每组独立保存和scale后才覆盖。权重/激活指定distributed、小scratch指定block，实际映射看ram_synth.rpt，不能由属性直接叫BRAM/URAM。

## 双缓冲生命周期

两个operand bank均含A、packed B和scale；DOUBLE_BUFFER=0时仅一个。

FREE → LOADING（req握手）→ READY（包全部接受）→ COMPUTING（consumer拿取匹配坐标）→ FREE。

producer严格顺序遍历mt/nt/kt，consumer按同样顺序交替bank，metadata校验匹配后才读。加载只写LOADING，计算只读COMPUTING。非末组tile在最后MAC后释放bank；组末tile保持COMPUTING到全部slot scale完成，因为scale仍存该bank。最初无READY时等待；最后一包置producer_done；输出背压可使两bank都占满，源自动停止新请求。

## 消费状态与周期

| 状态 | 周期/活动 |
|---|---|
| INIT_Y | 每M/N输出tile，RC拍同步写零到Q24输出累加RAM |
| WAIT_TILE | 等目标bank READY并校验元数据，接管COMPUTING |
| CLEAR_PE | 每group首tile1拍清INT32 PE |
| PRIME | 1拍发同步RAM读t=0 |
| RUN | kl拍，每拍一组广播MAC，尾lane补零 |
| SAVE_G | group完成后RC拍将PE psum写入scratch |
| SCALE_REQ/MUL/ADD | 每槽3拍，分别同步读psum/y并寄存factor、寄存64位乘积、写合并结果；共3RC拍/组 |
| OUT_REQ/LATCH/SEND | 有效槽3拍起，加任意背压等待；无效槽OUT_REQ跳过 |
| FINISH | 最后输出tile处理完，1拍转idle并产生done |

数值合同见 w4a8_numerics.md。所有组缩放并相加后只舍入一次。空尾lane的psum为0、factor为0，不污染有效输出。当前输出采用累加RAM+一个握手寄存器，没有深输出FIFO，背压可阻止下一输出tile消费。

统计定义和CSV见 w4a8_performance.md。外存模型完全在tb/中，首延迟、burst间隔、随机暂停都不是DDR控制器。没有地址指针/DMA/DDR/PCIe、bias/完整FFN、KV/RoPE/Softmax/RMSNorm/SiLU。M=1只用一个有效PE行，后续需要专门的K/N并行Decode映射。只有报告列出的参数组合实际验证。

## 仿真供数可调参数

w4a8_memory_model 的 FIRST_DELAY、BURST_BYTES、BURST_GAP、REQUEST_PERIOD、RANDOM_SEED 可在实例参数中配置，默认分别5/8/4/5/0x20261012。模式0忽略额外延迟，模式1使用固定首延迟和burst间隔，模式2使用首延迟/LFSR暂停及请求周期。延迟/间隔须非负，burst与request period须正，seed须非零。报告中的所有实测数据使用默认数值；其他数值组合未运行。TB另施加输入暂停和输出背压，改变供数参数应生成新的性能结果。

默认TB存储模型的 MAX_DATA=8192（每张量元素/传输字节数组），golden psum数组8192项，用于小型代表性用例；它不是对64×64×4096整层的验证。扩展大任务时需同步调整仿真向量容量和超时，硬件tile容量无需随整层等比例扩张。
