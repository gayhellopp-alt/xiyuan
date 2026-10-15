# 动态 row/K-group 数值合同 v1

新增独立 `requant_dynamic`，内部复用已经实际验证的 `requant_group`，原W4A8与外部scale模块保持不变。输入为signed32 Q16.16；每组统计A=max(abs(T))。INT32_MIN先扩展到signed33再取幅值，A可为2147483648，使用unsigned32保存。

scale编码规则为 `candidate=ceil(A/2032)`，其中2032=127×16；`S=max(1,min(65535,candidate))`。S实值为S/4096，仍是unsigned16 UQ4.12；无zero-point。选择向上取整可保证未发生scale范围钳位时全部元素量化结果位于[-127,127]且无饱和；这里scale编码采用ceil，而标量requant仍采用最近/tie远离零，不能混淆两个舍入步骤。

全零组S=1、qx全0。最小非零scale也是1；不会生成外部scale基线所拒绝的S=0。对A/2032执行32拍整数恢复除法，结束后quotient+(remainder!=0)得到ceil；Python逐位算法同时核对独立整数 `(A+2031)//2032`。

UQ4.12上限不足时采取**钳位并报告状态**：candidate>65535时S=65535、scale_clipped=1，继续对所有有效元素执行已验证的 `sat_int8(round(T/(16*S)))`。不扩大scale格式、不丢弃整组，也不把范围不足隐藏在普通成功状态中。阈值A>133167120即scale_clipped=1。该标志表示127幅值目标无法覆盖本组，不必然等于标量已经越INT8边界；INT8正负范围不对称，out_saturated与group_saturated另行精确报告。调用方必须根据scale_clipped和饱和标志决定接受、记录误差或重试。

非法K/group/len的行为沿用外部基线：描述符接受后error_code=2、done单拍，busy保持0，不接收数据或产生输出；0表示正常，1/3保留。默认MAX_K=4096；len严格等于min(GROUP_SIZE,K-group*GROUP_SIZE)。row是16-bit不透明标签，任务ID/行范围/跨描述符一致性由系统层保证。已实际测试/综合参数以验证报告为准，本轮目标为GROUP_SIZE32/12。

非饱和反量化误差界为 `|qx*S/4096-T/65536|≤S/8192`。编码scale向上取整会增加量化步长，但不增加格式位宽。scale_clipped组的饱和误差可能很大，报告必须与正常组分开。第一层自身Q16.16饱和损失无法通过动态scale恢复。

参考模型 `model/vector/dynamic_reference.py` 保留原scalar整数golden，生成动态模块逐元素/absmax/scale/clip/sat向量，以及两层INT32 group psum、Q16.16中间/最终输出。float比较分为第一层固定误差、动态反量化误差、第二层固定误差、最终对已编码scale浮点链误差。合成边界/饱和矩阵不代表真实模型准确率。
