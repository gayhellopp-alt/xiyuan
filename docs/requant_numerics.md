# 外部 scale requant 数值合同 v1

本轮新增独立 `rtl/vector/requant_group.sv`，保留原 W4A8 所有数据格式、RTL、golden 和接口。该模块把上一层 signed32 Q16.16 编码 T 转为下一层 signed8 激活 qx，并携带外部给定的 row/K-group scale S。S 为 unsigned16 UQ4.12，实值 S/4096。没有 zero-point，没有动态 scale。

实数关系为 x=T/65536、sx=S/4096，因此 qx=saturate_int8(round(T/(16*S)))。round 为最近舍入，恰好半值时远离零；饱和范围 [-128,127]。不能截取低 8 位代替饱和。

## 明确的异常行为

| 输入或配置 | 行为 |
|---|---|
| S=0 | 拒绝整个描述符，error_code=1、done 单拍，busy 保持 0；不接收数据、不产生输出。全零 group 也必须指定非零 S |
| 非法 K/group/长度 | 拒绝描述符，error_code=2；优先于零 scale 错误 |
| INT32_MIN | 33-bit 符号扩展后求绝对值，得到 2147483648；按普通数值路径除法/舍入/饱和 |
| 舍入后值 >127 或 <-128 | 输出相应饱和端点，out_saturated=1；group_saturated 累积本组该标志 |
| 舍入后值恰为 -128 或 127 | 合法输出，out_saturated=0 |
| rst | 同步撤销未完成描述符、除法与待接受输出，清空状态；不发送取消完成记录 |

GROUP_SIZE 是综合参数，本轮实际验证 32 和 12。支持参数范围 GROUP_SIZE=1..4096、MAX_K=1..65535；只有已列组合有仿真/综合证据，不能推广到任意参数。默认 MAX_K=4096。描述符必须满足 1≤K≤MAX_K、group*GROUP_SIZE<K、len=min(GROUP_SIZE,K-group*GROUP_SIZE)。因此非末 group 必须完整，尾组允许短长度，不能把中间 group 任意缩短。row 是 16-bit 不透明标签，模块不知道张量 M/任务 ID，也不校验行范围。上游负责跨描述符的行/组顺序与一致性。

## 位宽与逐位算法

1. T 符号扩展为 signed33，再求无符号 magnitude；其范围 [0,2^31]，随后存入 32-bit dividend。负号独立保存。
2. divisor=S<<4 为 unsigned20，合法范围 [16,1048560]。
3. 每拍将下一个 dividend 高位移入 remainder。trial 为 unsigned21；比较 trial≥divisor，成立则减去 divisor，并向 quotient 移入 1，否则移入 0。执行 32 拍。
4. remainder 始终满足 0≤remainder<divisor。最终 magnitude=quotient*divisor+remainder。quotient 为 unsigned32；最大有效 quotient=134217728。
5. 将 2*remainder 与 divisor 比较，等于时也进位；rounded 为 unsigned33。按正数 127、负数 128 检查幅值上限。
6. 饱和检查通过后才恢复符号并转为 INT8；因此截取发生在已经证明合法的分支中。

RTL 没有运行时 `/`、`%`、倒数近似或厂商除法 IP。描述符 group 起点是编译常数 GROUP_SIZE 乘法；其资源与标量迭代除法均计入实际综合。没有 group RAM，也没有整组 absmax 缓冲；一次只保存一个标量。结果寄存器保持至 out_valid&&out_ready，此前不能接受下一个标量。

Python 参考见 `model/vector/requant_reference.py`：逐位执行上述步骤，每步检查 remainder；同时通过独立 divmod 身份及 `(2*abs(T)+D)//(2*D)` 舍入 oracle 核对。所有非零 scale 编码的边界检查、固定种子随机/定向向量和 INT32_MIN 的 32 步 trace 保存在 `build/requant_vectors/`。参考模型的零 scale 函数调用会抛异常，描述符函数返回对应错误码；零 scale 不存在可供输出比较的 golden。

非饱和输出的反量化误差满足 |qx*S/4096 - T/65536|≤S/8192；恰好 tie 可达到上界。饱和元素没有这一误差界，必须结合 out_saturated/group_saturated 判断。本轮证明整数合同一致，不提供真实模型量化精度结论。

动态 scale 与两层 W4A8 串联尚未实现。下一轮 absmax 策略需另行规定 UQ4.12 范围不足时的饱和/拒绝规则，不能改变本合同格式掩盖越界。
