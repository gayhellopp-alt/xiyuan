# KV Cache：独立存储合同 v1

实现：`kv_cache_pkg.sv`、`kv_cache_address.sv`、`storage_axi_byte_write.sv`、`kv_cache.sv`，复用 B 的 `w4a8_axi_read.sv`，原 B 文件不修改。单时钟、单序列上下文、单活动命令、有限一字节读返回/写槽。没有 Attention计算模块或统一顶层。

公共 KV 数值/任务合同缺失，因此以下是本模块**明确支持的存储能力 v1**，尚不是团队最终 Attention数值约定。接入前由计算/软件 owner 确认其匹配；未匹配时不能把存储仿真 PASS 当作 Attention集成。

## 1. 类型、scale、布局

- format_id=`KV_INT8_UQ412_V1=1`：K/V 均为 signed INT8 二进制补码，范围-128..127；模块原样搬运 byte，不执行量化、RoPE、乘法、舍入或饱和。
- sK/sV 为 unsigned16 UQ4.12，little endian，编码0..65535，0合法。每个 layer/kv_head/token/dimension-group 独立一个 scale。数据表示的候选语义为 `q * scale/4096`；实际 QKᵀ/AV 的 scale 应用、归约轴和重定标由数值 owner定义。
- GROUP_SIZE 是编译参数（默认32）；配置必须匹配。令 D=dimension，G=ceil(D/GROUP_SIZE)，末组允许不完整。K/V共享同一个D，本版不支持Dk≠Dv。
- 四个独立平面：0=K，1=V，2=sK，3=sV。数据逻辑形状 `[layer][kv_head][token][dimension]`；scale形状 `[layer][kv_head][token][dimension_group]`。配置中的 heads 指 **KV heads**，不是 query heads。

```text
addr(p,l,h,t,b) = base[p] + l*layer_stride[p]
                 + h*head_stride[p] + t*token_stride[p] + b
K/V有效 token bytes = D
sK/sV有效 token bytes = 2*G
scale[g]低/高字节位置 b=2*g / 2*g+1
```

所有 stride/bytes 单位是字节。K/V允许字节对齐；scale基址及三种stride均2字节对齐。plane分配为半开范围 `[base[p],base[p]+bytes[p])`，四区不得重叠。用64位计算：

```text
width = D 或 2G
head_extent = (capacity-1)*token_stride + width
layer_extent = (heads-1)*head_stride + head_extent
plane_extent = (layers-1)*layer_stride + layer_extent
```

要求 token_stride≥width、head_stride≥head_extent、layer_stride≥layer_extent、plane_extent≤bytes，bytes非0、base+bytes≤2^32。所有实际读写仍再次检查 byte offset 与分配范围。没有读写padding或按64位对齐向外越界的分配假设。

## 2. 配置与容量

`cfg_valid/ready` 接受整个 `kv_config_t`（config_id、layers/heads/capacity/dimension/group_size/format_id，四平面各自base/bytes/三种stride），锁存并先校验。结果经共同 completion返回config_id和状态。配置失败不访问AXI，可直接重试配置。

默认编译上限 MAX_LAYERS=4、MAX_HEADS=8、MAX_TOKENS=4096、MAX_DIM=128；实际配置各维必须非0且≤上限。有效长度表为有限 `MAX_LAYERS*MAX_HEADS` 个16位寄存器。token物理范围0..capacity-1，容量是每个layer/head可容纳的token数。成功配置在本轮共同复位前不可替换；没有自动bank切换、多序列context或分页/滑窗/环形回绕。

`query_layer/head` 输出对应 `query_valid/query_length`，只公开已提交前缀长度。配置前、复位期间或query越界时valid=0且length=0。不同layer/head独立提交；如调用方要求同一token对所有heads都可见，应等待所有对应追加成功并检查各前缀长度，本模块不提供跨heads原子提交。

## 3. 命令、追加与读取

`cmd_valid/ready` 锁存 `kv_command_t`：task_id、operation、plane、layer/head、token/count、offset/length。一个完成记录未接受前不接下一命令。所有valid载荷由源保持到握手。

| operation | 行为 |
|---|---|
| KV_APPEND=0 | token必须等于该layer/head当前committed_length；count>0，token+count≤capacity；plane/offset/length必须0 |
| KV_READ=1 | count/length>0，token+count≤committed_length；offset+length≤所选plane有效token宽度 |
| KV_CLEAR=2 | 清所选layer/head的有效长度为0；token/count/plane/offset/length必须0，内存数据不清除 |

APPEND byte stream顺序：每token的K[D] → V[D] → sK[2G] → sV[2G]，再下一个token。`append_valid/ready/data[7:0]/last`；last仅在整个count批次最后一个byte为1。总长度为 `count*(2D+4G)`，不能省略scale或靠占位scale提交。过早last/遗漏最后last产生 KV_STREAM_ERROR，此byte不发写事务。

每个byte独立窄AXI写。前一个B已检查成功后才接受下一个byte，最后一byte接受/最后W握手均不能更新长度。**所有K、V、sK、sV、所有count tokens的B均成功、写槽为空后，原长度一次更新为token+count。** 追加过程中查询仍返回旧长度。末尾写失败也不会提交批次中已经写好的前一个token。

失败可能已修改未提交区的物理内存，不回滚。旧提交前缀不允许覆盖，保持可读。重试必须重新提交同一旧长度起点、完整批次和全部四平面，覆盖未提交残留；不能续写半个token或用失败批次的部分输出。追加失败后通知源停止余下输入，允许撤销尚未接受的append_valid。

READ输出按token外层、所选offset..offset+length-1内层排列，只读有效byte。`read_valid/ready/data[7:0]/last`，last标记整个命令的最后byte。返回寄存器在背压时持稳，无下一byte预取；未提交token的命令在发AR前拒绝。读出是存储byte，不是matmul packet，不做INT4列对packing。

读错误不改变有效长度；错误byte不暴露给consumer。若错误发生前已经输出部分前缀，consumer必须按错误completion废弃整次读帧，不能把部分读当作完整结果。长度/末字节仅在成功completion时可信。

## 4. AXI、错误、复位

64-bit数据、32-bit地址，固定4-bit ID=0，单beat INCR，读写SIZE=0（1byte）、LEN=0。WSTRB仅一个lane位，W data移到addr%8位置，保护padding及相邻字节；单byte天然不跨4KiB。AW/W独立握手，二者均接受后才BREADY。普通非独占内存属性需由平台补齐。检查RRESP/RID/RLAST和BRESP/BID，OKAY=0才成功；错误首R缺RLAST时排空至RLAST后报告错误。

KV和B是独立master，不能把固定ID=0的端口直接并接。队友1提供AXI仲裁/互连：添加master身份，或在前一master全部排空后串行切换并正确路由所有五通道。此集成属于统一顶层，本轮不修改它。

| status | 数值 | 含义 |
|---|---:|---|
| KV_OK | 0 | 配置/clear完成，或读全部交付，或追加全部写确认并提交 |
| KV_BAD_CONFIG | 1 | 形状、格式、group、stride、对齐、容量、重叠、地址溢出非法 |
| KV_BAD_COMMAND | 2 | 未提交token、容量满、越界、读片段越界、追加覆盖旧前缀或操作非法 |
| KV_WRITE_ERROR | 3 | B响应/ID异常，长度不变 |
| KV_READ_ERROR | 4 | R响应/ID/last异常，长度不变 |
| KV_STREAM_ERROR | 5 | append frame的last错误，长度不变 |

completion包含task_id/status，背压保持。单outstanding设计在发现B错误时事务已经响应，在发现stream错误时无在途写；读错误按上述规则排空后completion。若总线永久不响应/无RLAST，硬件保留事务而不接新命令，外部watchdog需共同复位恢复；不通过超时伪造写成功。

只支持 KV、AXI memory/fabric、producer/consumer和控制共同同步复位。配置、有效长度、任务/返回/写槽全失效；内存内容保留但不可读，重新配置后长度全部0，必须完整追加才能再次可见。`KV_CLEAR`只在空闲接受且无需fabric复位，安全作单head逻辑清空。单独KV复位但fabric保留旧响应未支持，必须外部冲刷/隔离后才重新配置；固定ID不区分epoch。

统计32位，每命令接受时清零、完成后保持：cycles为校验到completion的周期；accepted_bytes为协议正确且已发写命令的byte数；acknowledged_bytes为成功B字节数；returned_bytes为consumer接受的read byte数；read_wait/write_wait为引擎占用周期，可重叠不能直接相加。物理64位总线lane容量是每读/写byte事务8字节，真实DDR效率尚未测量。

## 5. 接入前需对齐的公共字段

1. **数值 owner**：K/V真实dtype；scale格式、粒度/轴与zero-point；Dk/Dv；Q dtype和scale；RoPE前/后K的保存时机；QK输出、mask、Softmax概率、AV结果格式、累加/舍入/饱和；当前per-token/dimension-group V scale如何参与AV归约，是否需要额外requant。
2. **控制/软件 owner**：sequence/context ID、layer数量、Qheads/KVheads及GQA映射、token绝对position和物理index、最大长度、KV及workspace分配/stride/允许范围、batch/追加依赖、cache清空/重置/失效、任务ID/完成通知、AXI arbiter和reset/watchdog。
3. **动态算子 owner**：QKᵀ输入布局/transpose、请求及valid/ready/坐标/keep/last、scale通道、tile/归约边界；mask语义和causal位置；Softmax分块/数值合同及行完成；AV读取V/概率的配对与结果接收。
4. **参考 owner**：小序列Prefill和逐步Decode位精确参考，mask/scale/GQA/位置编码、异常状态及容差规则。

当前仓库以上依赖均未提供；Attention数据搬运接线不实施。现有KV read接口可独立验证，后续由适配器按真实动态算子请求读取committed K/V/scale。静态W4A8 INT4权重接口不充当动态QKᵀ/AV接口，也没有占位计算模块。没有整个Transformer或LLM的集成结果。
