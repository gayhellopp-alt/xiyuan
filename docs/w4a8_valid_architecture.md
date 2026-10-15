# W4A8 有效槽遍历：独立版本与接口

新增独立顶层 `w4a8_valid`，由保留的 `w4a8_wave` 派生；正常构建直接读取新RTL/TB，不运行派生脚本。原wave顶层、参考模型、TB、脚本、报告和动态requant保持不变。`VALID_ONLY=1`是本轮优化，`VALID_ONLY=0`恢复full-slot行为作消融；其他参数和端口沿用原顶层。

本轮只优化slot访问。不改变W4 nibble/packet布局、PE阵列映射、A复用、同group波前、排空、scale格式/舍入/饱和、输出坐标/次序或任务握手。没有输出FIFO、下一tile结果双缓冲或FFN。

## 有效槽与物理地址

每个output tile的有效尺寸为ml=min(ROWS,M-mt)、nl=min(COLS,N-nt)。物理地址始终为r×COLS+c，PE与RAM坐标仍相同；不把存储内容改成紧密打包，也不引入动态除数。

仅遍历0≤r<ml、0≤c<nl：末槽为(ml−1)×COLS+nl−1；每行末跨过无效列到下一行起点。保留最大RC深度RAM，但有效版本只初始化/保存/读取/后处理有效槽。尾部未写槽不会被读取，不依赖清零无效槽。

| 阶段 | VALID_ONLY=1 | 保留的fence |
|---|---|---|
| INIT_Y | 仅清零ml×nl个INT64槽 | 上一tile的输出全部接受后才能进入 |
| SAVE_G | 仅保存ml×nl个INT32 psum到当前snapshot | 组末阵列排空完成、snapshot bank为FREE后才能写 |
| P_STREAM | 根据snapshot自己的ml/nl遍历有效槽 | 捕获的m/n/group/sx/sw不受producer推进影响 |
| post retire | 最后有效tag退休后释放bank并计groups_scaled | 不以最后issue代替最后retire |
| OUT_REQ/LATCH/SEND | 只发有效槽请求，同步读取及背压持稳 | 最后group已完成全部宽累加后才读取/舍入 |

双snapshot状态FREE→WRITING→READY→SCALING→FREE沿用。next group可以在另一bank计算/保存，bank满时仍保留PE sum。只有最后有效slot退休后才让下一snapshot进入scale；因此group间相同Y地址的读取发生在前组写入已完成之后。

## 同步端口、暂停与复位

psum bank各1R1W、共享Y各1R1W，均复用`sync_sdp_ram`的一拍同步读。p_issue时同拍读psum和Y；下一流水级捕获旧Y和scale乘积，再后一流水级写宽累加结果。pipeline全局post_pause保持数据/tag/valid，暂停时无post RAM读写。

同组流式issue与retire可并行，但不能同地址RAW；不同group通过最后retire释放bank和P_IDLE交接，不能让短group（尤其有效槽数1/2）越过该fence。输出读口与post读口、INIT_Y写口与post写口分别互斥。TB独立记录初始化/保存过的槽，逐拍核对同步返回的psum/Y、INT64合并及实际Y写入，而不是读取DUT乘积当golden。

array_pause及WAIT_TILE/PRIME冻结方式、物理D=ROWS+COLS−2排空不变；未压缩无效PE或缩短波前。rst撤销任务/bank/valid，RAM内容不清；新tile的所有有效Y槽重新初始化，snapshot只读当前已写地址。运行中/post/输出/接缝复位测试沿用并加RAM初始化检查。

## 数值与接口

signed8 qx、signed4 qw、INT32 group psum、unsigned16 UQ4.12 sx/sw、signed64 Q24组间累加和最终signed32 Q16.16舍入饱和完全沿用 [原数值合同](w4a8_numerics.md)。golden由原`w4a8_reference.py`和`w4a8_systolic_vectors.py`生成，不改参考值迎合新RTL。

start/start_ready、tile请求、in_valid/ready/data/keep、req_scale/activation以及out_m/n/data/last/valid/ready与原波前顶层同名同宽。输出仍为原tile内有效row-major次序，上游不能假设整个张量row-major。out_last接受不是writeback_committed，外存写确认仍由队友存储桥提供。

统计端口中，psum_groups仍表示物理output tile/group快照数；post_issue_cycles/post_retire_cycles现在是实际有效槽操作数，完整任务为MN×ceil(K/GROUP_SIZE)，不再等于RC×psum_groups。其他计数定义保持，节省控制周期会改变等待/overlap数值。队友或性能脚本切换顶层时需同时更新该统计合同。

## 独立周期闭式与验证入口

令OT=ceil(M/ROWS)×ceil(N/COLS)，G=ceil(K/GROUP_SIZE)，PG=OT×G，T为packet K tile请求数。有效版本walk_output_slots=MN、saved_slots=MN×G；消融版本分别为OT×RC、PG×RC。

`fixed=2×walk_output_slots+saved_slots+2×PG+2×T+2×MN+1`。

`total=fixed+array_cycles+array_pause+input_wait+output_wait+psum_wait+post_drain`。

独立Python坐标枚举给出地址/操作预算；TB的slots.csv从实际状态/交易另行计数；最后与总周期CSV闭合。wave_hold、wave_input_wait、compute/post overlap为上述分类的子集，不能重复加到total。

节省SAVE_G会缩短下一输入预取窗口，缩短post也会改变队列压力和暂停相位，不能只减掉无效槽数推断性能；[实际性能](w4a8_valid_performance.md)同时报告连续/受限供数、等待变化及任何退化。full-slot消融的全部CSV字段与原g4/g8逐项比较。

八配置包含4×4、8×8、2×3/tile5/group12、1×1、单bank、tile19与full-slot两尺寸。数值/逐PE冻结、接缝饥饿恢复、snapshot满、post暂停和复位均保留；新增同步psum/Y、宽累加和有效地址访问检查。实际工具证据见 [验证报告](w4a8_valid_validation.md)。最大逻辑容量和未列参数未全覆盖，VCS/综合网表/板上执行未验证。
