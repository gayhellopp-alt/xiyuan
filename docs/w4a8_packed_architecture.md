# W4A8 列对权重打包架构

本轮新增w4a8_packed，保留旧w4a8_stream与w4a8_linear。复用原MAC阵列、INT4解包、同步单读单写RAM及量化数值合同；没有改变广播式output-stationary阵列，也没有实现脉动波前或DSP内多乘法打包。计算、group保存/scale、输出背压及bank生命周期沿用上一轮。

## 参数与接口

PACK_COLS默认1；仅BUS_BYTES=8时启用两列打包，其他宽度等效单列（本轮只验证BUS_BYTES8）。PACK_COLS=0为旧布局对照。ROWS4、COLS4、TILE_K8、GROUP_SIZE32、SCALE_ONCE1、DOUBLE_BUFFER1为综合默认；另仿真2×3/tile5/group12、tile19、单buffer和每tile传scale。

req字段、req_scale及64bit input valid/ready、8bit keep接口不变，但host必须知道编译时PACK_COLS，不可向新布局发送旧格式。in_data/in_keep在未接受时保持稳定；keep须符合下述槽位定义，DUT依赖合法packet合同，不新增malformed packet硬件检测。reset同步中止请求、bank状态和输出，外部源也须reset。

## 外部存储与数据包

外部packed INT4仍按列沿K连续，地址n*ceil(K/2)+floor(k/2)。偶k低nibble、奇k高nibble；全局K末无效nibble规则不变。列对重排在TB供数模型中完成，没有更改原模型向量或通过越界读生成padding。

每请求权重有效字节数/列：wbytes=ceil((k0%2+kl)/2)。

权重段遍历：先列对，再32bit word。local列对(0,1)、(2,3)…；对某列对，word起点p=0,4,8…：
- data[31:0]：local列c的p..p+3四字节。
- data[63:32]：local列c+1的相同p..p+3字节。
- keep[j]=1 iff p+(j%4)<wbytes 且 c+floor(j/4)<nl。
- 每列的byte来自该列全局floor(k0/2)+p；只有keep合法时读取源数组。
- odd nl末列对只用低32bit，高槽填0xA5且keep=0。

这不是将短尾压紧到低字节。每列独占固定32bit槽，权重尾beat的keep可以非连续：

| 情形 | keep |
|---|---|
| 两列各4字节 | 0xFF |
| 两列各3字节 | 0x77 |
| 两列各1字节 | 0x11 |
| 仅一列4字节 | 0x0F |
| 仅一列1字节 | 0x01 |

激活段仍逐行64bit word对齐，scale的SX/SW各为独立64bit对齐段，低字节在前。SCALE_ONCE1仅group末K tile带scale；其他tile在最后激活beat后READY。A/scale的尾keep仍为低位连续1。

## 权重RAM与有限端口

W bank改为WIDTH32、DEPTH=ceil(floor((TILE_K+2)/2)/4)。每beat最多写两个不同列bank，各bank的一个word；不存在同一bank多地址同拍写入。load_lane是local列对起点，load_pos是每列packed byte偏移，先每word加4，末word后列起点加2。实际write mask仅包含valid列，奇末列的高槽不写任何bank。

A bank仍WIDTH64、DEPTH=ceil(TILE_K/8)，每beat写一个行bank。sx/sw为少量FF，不称为多端口RAM。

每W bank有一个同步读端口，word地址floor(packed_byte_index/4)，寄存byte选择packed_byte_index%4与nibble选择；下一拍取q word中的INT4。A仍按8byte字选择。PRIME/RUN顺序不变，保证同步读首拍及预读时序；read_tile末有效K之后不再发读。

默认W深2，A深1；实际是否LUTRAM/FF看ram_synth.rpt，不能仅根据属性判断。tile19使W深3、A深3，仿真覆盖跨word、word尾和奇K起点。多word配置本轮仅仿真。

## 双buffer、数值与输出

FREE → LOADING（请求接受）→ READY（包全部接受）→ COMPUTING → FREE。
两组operand bank独立；LOADING写入不能覆盖COMPUTING。组内跨tile保持INT32 psum，组末保存并按sx/sw缩放、合并INT64 Q24，所有group完成后舍入/饱和Q16.16输出。组末operand bank仍保留至scale完成；psum/scale尚未解耦。

M/N/K尾lane不参与有效MAC计数，不向无效列bank写入；输入word未用字节虽可在有效bank内保存poison，但不会被合法K计算读取。所有有效输出按坐标比较，输出受阻保持data/坐标/last。

## 实测与供数口径

独立TB w4a8_packed_memory仅模拟请求与packet供数。mode0连续；mode1按固定物理字节预算限流（padding也消耗预算）；mode2固定种子暂停并加输入/输出背压。请求首延迟、burst和LFSR参数沿用上一轮。真实外存DMA要另外实现这个gather/repack合同，当前没有DDR/DMA。

有效字节计数popcount(keep)，physical_bytes=beats×8，padding=physical−valid。compute/input_wait/output_wait互斥，overlap仅RUN同拍接受beat，是compute子集。计数32bit、合法start清零、done后保持。

Prefill4×12×96/4×4/tile8/group32：36请求，W72beat、A144beat、scale18beat，合计234beat/1872byte/padding0；数据有效字节和MAC不变。Decode1×13×96仍有奇列与小scale段padding。周期和资源见w4a8_packed_validation.md；不是DDR或板上性能。

未实现A跨N复用、跨输出tile scale cache、独立scale流水、NPU队列适配、AXI/DDR/PCIe、bias/INT8 requant/完整Transformer。最大逻辑尺寸及其他组合未验证，TB仅支持小型代表性向量。
