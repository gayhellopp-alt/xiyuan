# W4A8 分组定点数值合同（第二阶段）

本实现为自主对称量化基线，无 zero-point；不宣称兼容 AWQ 或具体模型格式。

- qx：signed INT8，-128..127；qw：signed INT4 二进制补码，-8..7。
- 外部权重按输出通道 n 连续存 K，每字节的低 nibble 保存 k=2p，高 nibble 保存 k=2p+1；地址 n*ceil(K/2)+p。K 奇数时末高 nibble 是无效填充。
- 每行/每 K group 的 sx，以及每输出通道/每 K group 的 sw，编码为 unsigned 16-bit UQ4.12，实值 q/4096；合法编码 0..65535，实值范围 0..15.999755859375。
- 默认 GROUP_SIZE=32；另验证 GROUP_SIZE=12。group 最后一段可以不完整，tile 在 group 边界截断。group 跨多个 tile 时 PE 保持整数部分和，仅在 group 完成后保存、缩放。
- INT4 解包符号扩展为 INT8后复用既有 mac_array/mac_pe；8×8 乘积 signed INT16，再显式扩展为 INT32，每 MAC 按模 2^32 回绕。合法 group≤4096 的本合同输入不会自然溢出 INT32。
- group psum：signed INT32，存入同步 scratch RAM。sx*sw：unsigned 32-bit；与 psum 的乘积以 signed 65-bit 表达，再存 signed 64-bit（Q24）并累加组间结果。
- 支持的逻辑容量 MAX_M=MAX_N=64，MAX_K=4096；GROUP_SIZE≤4096；ROWS、COLS、TILE_K 必须为正且 ROWS*COLS≤64。整个 K 累加的绝对值上界为 4096*128*8*65535^2<2^55，所以丢弃 65-bit 符号冗余位不损失合法结果，signed64 加法不会溢出。超出此合同的参数组合未支持。
- 输出 signed INT32 Q16.16。将最终 Q24 结果除以 2^8，采用最近舍入、恰好半值时远离零；然后饱和至 [-2^31,2^31-1]。bias、激活函数和后续 INT8 requantization 未实现。

位精确参考：P=wrap32(sum(qx*qw))；T=P*Sx*Sw；Yraw=sum(T)，用 Python 任意精度整数检查64-bit界限；Y=clamp32(sign(Yraw)*((abs(Yraw)+128)>>8))。

三层验证：A 比较 RTL 与上述定点参考，必须逐元素一致；B 比较 Y/65536 与使用未编码理想 scale 的浮点量化参考（包括 scale 编码、输出舍入及饱和误差）；C 比较浮点量化参考与原始浮点 X@W。定向编码用例的浮点输入由反量化构造，C 误差为零不代表模型精度；独立随机浮点用例用于衡量真实量化误差。饱和用例与非饱和指标分开报告。
