# W4A8 宽供数增量架构

w4a8_stream 从已验证 w4a8_linear 的控制/计算路径增量演化，原顶层和回归仍可执行。独立新顶层便于消融对照；不改变数值、组内INT32跨tile累加、64位缩放合并、Q16.16舍入饱和及输出握手。共享原 mac_array/mac_pe/w4_unpack/sync_sdp_ram，当前两个顶层的控制代码有重复，稳定后可再合并公共控制模块。

## 新参数和握手

BUS_BYTES 默认8，对应64-bit input；已验证1和8。SCALE_ONCE默认1，每group仅在最后K tile请求scale；为0时每tile重复传scale。其他positive参数合同沿用 w4a8_numerics.md，其他bus宽度组合未验证。

保留 req_m/n/k/ml/nl/kl/group，新增 req_scale：
!SCALE_ONCE || k0+kl==K || (k0+kl)%GROUP_SIZE==0。
req_scale随请求字段在valid且未ready时保持；接受后producer寄存load_scale。没有新增cache容量：scale在组末bank完整装载后才使用，组内前面的bank无需scale。跨不同M/N输出tile仍分别传scale，尚未实现跨输出tile复用。

in_data宽8×BUS_BYTES，in_keep宽BUS_BYTES。第j个keep对应data[8j+:8]，低字节在前。完整beat全1；每个对齐段尾部keep为低位连续1，高位0。源必须保持valid/data/keep直到接受；不能通过keep任意删除有效元素。DUT依赖合法packet/keep合同，不增加硬件malformed packet检测。in_ready仍由busy、loading、rst、load_pause控制，暂停不丢数据。

## 每请求的传输布局

1. 权重：每个有效输出列单独word对齐。wbytes=ceil((k0%2+kl)/2)，传ceil(wbytes/BUS_BYTES)个beat。每beat装该列连续packed bytes，从全局floor(k0/2)开始；列末补齐高字节。
2. 激活：每个有效行单独word对齐。传ceil(kl/BUS_BYTES)个beat，每beat装该行连续INT8。
3. req_scale=1时，传sx和sw两个独立对齐段：sx按有效行顺序连续16bit值，sw按有效列顺序连续16bit值。各值低字节先，多个scale可以合并到一个beat。
4. req_scale=0时，激活最后beat完成后直接READY，无sx/sw段。

无效padding在TB中填0xA5，不应影响输出。packed权重的K边界nibble规则保持不变。真实有效字节地址均合法，不额外读取外部矩阵边界之外；padding是模型生成的，不是越界读。

默认完整tile4×4×8：每列4权重字节占1个64bit beat，W4拍；每行8激活字节占1beat，A4拍；组末sx/sw各1beat，总10拍payload，非组末8拍。仍有每权重列4字节padding。因此有效/物理带宽必须分别统计。

## 有限端口的word RAM

每A bank：WIDTH=8×BUS_BYTES，DEPTH=ceil(TILE_K/BUS_BYTES)。
每W bank：同WIDTH，DEPTH=ceil(floor((TILE_K+2)/2)/BUS_BYTES)。
每个RAM仍1同步read+1write端口；接受一个W/A beat，只向当前一列/一行的一个RAM字写一次，不用多地址同拍写入。sx/sw是小容量FF，可以按keep并行写相应byte，没有将它们称为多端口RAM。

PRIME/RUN同步读word地址floor(t/BUS_BYTES)及floor(packed_byte_index/BUS_BYTES)，同时寄存字内byte选择。下一拍从word q选择A byte与packed W byte，再选高/低nibble符号扩展到原INT8 PE。read_high仍使用全局k parity。test tile19使A深度3、W深度2，覆盖不同word地址与尾word。

默认tile8时A/W深度都是1；综合可能将指定distributed的浅数组映射为FF，实际报告为准。较宽接口不等于更多RAM端口，也不代表已取得8倍吞吐。

## bank与任务生命周期

FREE → LOADING（请求接受）→ READY（最后合法beat接受）→ COMPUTING → FREE。
两bank均含A/W/scale。非组末tile在末MAC后释放；组末bank在保存psum及scale合并完成后释放。计算不读LOADING、加载不覆盖COMPUTING；旧数据不靠清RAM消除，而靠完整加载、有效lane屏蔽、组首清PE和输出tile累加器初始化。

复位、busy启动拒绝、输出背压、done和连续任务合同沿用阶段二。req_scale减少传输不改变scale应用顺序，64位输出所有group合并后只舍入一次。

## 供数模型与统计

独立仿真模块 w4a8_stream_memory：
- mode0：每拍一个beat，无额外首延迟；扩大bus改变名义最大供数带宽。
- mode1：每包FIRST_DELAY=5；每beat之后等待BUS_BYTES-1拍，累计每BURST_BYTES=8物理字节再等待BURST_GAP=4拍。各宽度名义物理带宽预算相同，padding占预算。每包首延迟/最后beat不等待下一beat，短包会影响实际平均带宽。
- mode2：固定0x20261012 LFSR暂停、请求周期、首延迟，另由TB施加DUT输入暂停和输出背压。

新增input_beats和padding_bytes，接受beat分别加1与BUS_BYTES−popcount(keep)；W/A/scale byte计数加keep数量。必须满足physical_bytes=beats×BUS_BYTES=valid_bytes+padding_bytes。overlap仅RUN同拍接受beat，不涵盖scale/输出期间预取。其余统计口径沿用阶段二，32-bit无符号回绕，每合法start清零，done后保持。

现阶段没有A跨N tile复用、跨列packing、真实AXI/DDR/DMA、NPU队列连接、深输出FIFO或完整模型。当前默认64bit口是自定义packet协议，尚不是AXI接口。
