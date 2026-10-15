# requant_group 同步接口 v1

推荐本轮独立顶层 `requant_group`；原计算主线继续为 `w4a8_wave`。所有握手在 clk 上升沿采样；rst 为同步高有效复位，并组合屏蔽 cfg_ready/in_ready/out_valid。GROUP_SIZE 为编译参数，默认 32；默认 MAX_K=4096。只允许一个活动 row/group 和一个在途标量。

| 端口 | 方向/位宽 | 合同 |
|---|---|---|
| clk/rst | 输入 1 | 同步时钟/同步复位 |
| cfg_valid/cfg_ready | 输入/输出 1 | 描述符握手；busy 期间 cfg_ready=0，未接受的描述符不得被上游撤销或更改 |
| cfg_row | 输入 unsigned16 | 行标签，模块不校验张量 M |
| cfg_group | 输入 unsigned16 | 下一层激活 K-group 编号，从 0 开始 |
| cfg_k | 输入 unsigned16 | 下一层总 K，用于严格验证 group 和尾长度 |
| cfg_len | 输入 unsigned16 | 本组有效标量数，严格等于 min(GROUP_SIZE,K-group*GROUP_SIZE) |
| cfg_scale | 输入 unsigned16 | 非零 UQ4.12 sx 编码，在描述符握手时捕获 |
| in_valid/in_ready | 输入/输出 1 | 每次握手消耗一个 signed32 Q16.16 标量；无 keep、无无效填充 |
| in_data | 输入 signed32 | 第 index 个标量，必须保持至握手；in_valid 间断允许 |
| in_pause | 输入 1 | 仅阻止 INPUT_DATA 状态接收，不停止已经在途的除法与输出 |
| out_valid/out_ready | 输出/输入 1 | 每次握手输出一个 INT8 标量；背压时数据、标志、标签全部持稳 |
| out_data | 输出 signed8 | requant 后 qx |
| out_row/out_group | 输出 unsigned16 | 捕获的描述符标签 |
| out_index | 输出 unsigned16 | 组内下标 0..len-1，成功接受输出后才递增 |
| out_scale | 输出 unsigned16 | 本组 sx，逐输出重复；相同标签只需存一份 scale |
| out_last | 输出 1 | 本组最后一个标量，不是整个张量的 last |
| out_saturated | 输出 1 | 当前标量舍入后越 INT8 边界；随 out_valid 使用 |
| busy | 输出 1 | 描述符合法接受后至最后输出握手保持高 |
| done | 输出 1 | 合法组最后输出握手后单拍；非法描述符接受后也单拍，需结合 error_code |
| error_code | 输出 unsigned2 | 0=成功/无错误，1=零 scale，2=非法 group/K/len，3=保留；保持到下一描述符接受或 rst |
| group_saturated | 输出 1 | 本组已计算元素的饱和 OR，包含当前输出；最后输出接受后保留至下一描述符或 rst |

## 生命周期与时序

IDLE 接受描述符 → INPUT_DATA 等输入 → DIVIDE 32 拍 → ROUND 1 拍 → OUTPUT_DATA 保持/发送。非末输出握手后返回 INPUT_DATA；末输出握手后返回 IDLE 并产生 done。没有 RAM 读延迟、异步数组访问或隐藏缓冲：所有状态、除法和一个结果槽均为有限寄存器。

若输入在边沿 e0 握手，e1..e32 执行除法，e33 执行舍入并在边沿后置 out_valid；最早 e34 输出握手。下一输入最早 e35 接受，所以同组 scalar II=35。若描述符 e0 接受且双方连续可用，第一个输入 e1，组最后输出 e(35*len)，done 在此边沿后为高；下一描述符最早 e(35*len+1)。输出背压延长槽所有权，in_valid 缺失或 in_pause 延长输入等待。模块没有整组缓存和组之间重叠。

输出未接受时不能释放组，也不会报 done；group_saturated 在 ROUND 更新并在背压时持稳。done/error_code 是本模块本地结果，不代表外存写回确认。非法描述符被消耗后应由控制端读取错误；上游必须避免继续发送该组的数据。rst 取消全部在途工作，上游应同时清空配套数据队列并重新发送描述符。

## 与队友的集成边界

`w4a8_wave` 按输出 tile 发送 out_m/out_n，不能假定一个 row 的全部下一层 K-group 在流中连续。本轮没有坐标重组适配器，不能宣称把 w4a8_wave.out_data 直接接 in_data 即可构成两层。

上游存储/组装端需按坐标收集第一层 Q16.16 输出，以第一层输出通道作为第二层 K，在每个 row 内按第二层 GROUP_SIZE 排列有效标量；提供本组非零 sx，然后发送 descriptor 和恰好 len 个标量。第二层权重 sw 独立提供，第一层的量化 group 与第二层激活 K-group 编号不能混用。模块只验证单描述符合法性，不检测重复/缺失 group、任务交错或全张量完成。

队友1负责统一任务/格式/任务 ID、错误处理与总体完成；队友2负责有限存储重组、qx/sx 写入和写确认。建议存储映射为 qx[row*K+group*GROUP_SIZE+index] 与 sx[row*ceil(K/GROUP_SIZE)+group]，byte stride 由系统层管理；signed8 使用二进制补码，sx 写入现有 packet 时为低字节在先。上述为新独立模块集成合同，未修改共享 W4A8 接口。

下一轮提示词2增加有限同步 group Buffer 与动态 absmax/scale，再用独立 TB 坐标适配器验证两层。Buffer 的收集、读延迟、端口和释放 fence 应在该轮明确，不借本轮寄存器流接口推定无限容量。
