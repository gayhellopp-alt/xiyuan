# 小型 SwiGLU FFN 数值合同

本轮按“先补全结构跑通”的新指示，先实现提示词5的顺序功能基线；提示词4输出重叠留后续。原 `w4a8_wave`、外部scale及dynamic规则均保留。gate/up/down仍采用原W4A8数值合同，原始输入、权重布局和scale编码见 [w4a8_numerics.md](w4a8_numerics.md)。

## 阶段格式

| 阶段 | 输入 | 计算及输出 |
|---|---|---|
| gate/up投影 | signed8 qx、signed4 qw、UQ4.12 sx/sw | 原group INT32 wrap累加、signed64 Q24合并；末尾shift8最近/tie远离零，饱和signed32 Q16.16 |
| SiLU近似 | signed32 Q16.16 gate T | sigmoid系数unsigned17，编码1为2^-16；signed32×signed18乘积精确保存在signed64；shift16最近/tie远离零，饱和signed32 Q16.16 |
| SiLU×up | 两个signed32 Q16.16 | 精确signed64 Q32乘积；shift16最近/tie远离零，饱和signed32 Q16.16 |
| 动态requant | product signed32 Q16.16、down GROUP_SIZE | 原absmax、ceil(absmax/2032)、clamp(1,65535)，qx=sat8(round(T/(16S))) |
| down投影 | 上阶段qx与row/down-K-group sx；独立down sw | 原W4A8，输出signed32 Q16.16 |

没有bias、残差、归一化或zero-point。gate/up的sx相同，权重及sw分别独立；down的sx来自product动态量化，down sw独立提供。测试中gate/up group12对应down group32，或gate/up group32对应down group12，避免混用group编号。

## SiLU近似

定义 SiLU(x)=x/(1+exp(-x))。对abs(x)<8，在非负区间0..8每1/16取样：

```
L[i] = floor(65536/(1+exp(-i/16)) + 0.5), i=0..128
a = abs(sign_extend_33(T))
i = a >> 12; f = a & 4095
Spos = L[i] + ((L[i+1]-L[i])*f + 2048) >> 12
S = Spos (T>=0), 65536-Spos (T<0)
```

上述插值式实际执行为 `L[i] + (((L[i+1]-L[i])*f+2048)>>12)`，加法不参与右移。RTL ROM为128×34，每行打包两个相邻unsigned17样本，同步读取一拍，不用异步多端口RAM。`ffn_reference.py --emit-lut`生成常量，正常测试只检查常量一致，不改写RTL。

T>=8×65536采用S=65536，即SiLU=T；T<=-8×65536采用S=0，即SiLU=0。边界是明确的近似截断；不是指数运算硬件。INT32_MIN先扩展signed33后取绝对值。系数包含65536，因此必须用17个unsigned位、乘法前再扩为signed18，不能用signed16承载1。

Python实际扫描[-8,8]共65537个Q16.16网格点，含两端截断。绝对误差验收阈值0.00270，实际最大值及RTL测试见 [ffn_validation.md](ffn_validation.md)。这只是单元网格与合成矩阵证据，不等于真实模型精度保证；对很小的SiLU结果，相对误差可能很大。

## 舍入、饱和与状态

每个signed64产品P先扩为signed65再取幅值，R=(abs(P)+32768)>>16，恢复符号后clamp signed32。两次shift分别执行，不能先对gate或up截位，也不能将两次舍入合并成一个公式。标量out_saturated为两次clamp标志之OR；bridge.nonlinear_saturated是本任务的累计OR。

dynamic的scale_clipped、out_saturated与group_saturated保留原义：scale超范围继续S=65535量化并标记，量化元素饱和单独报告。nonlinear_saturated与scale_clipped是不同阶段状态。故意超范围矩阵必须报告所有这些状态，并与正常/零矩阵误差分列；不得用扩大格式或修改golden掩盖。

RTL逐阶段与独立Python整数参考比较，整数误差必须为0；另将product和最终down与采用已编码sx/sw的浮点SiLU链比较，误差指标在delivery和验证文档。gate/up投影、product饱和、SiLU截断和动态量化均可能贡献浮点误差。

本轮正常小矩阵的验收限为product相对L2<0.0002、最终FFN相对L2<0.02，零矩阵最大绝对误差必须为0；模型实际执行这些断言。故意饱和用例检查整数合同和状态，单独报告浮点误差，不套用正常矩阵阈值。上述限仅适用于本轮合成用例，后续真实模型需要独立精度验收。
