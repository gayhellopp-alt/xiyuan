# C/E 接续：结构优先的小型FFN

2026-10-14，用户将推进重点改为“先进行结构上的补全跑通”。本轮新增有限容量的可综合FFN中间通路，并验证完整gate/up→SiLU×up→dynamic requant→down。最终`run_ffn.ps1 -SimOnly`及`-SynthOnly -Implement -Regression`实际退出0，`FFN_SIMULATION_AUDIT_PASS`、`FFN_ARTIFACT_AUDIT_PASS`和`FFN_VALIDATION_PASS`通过，delivery.pass=true。输出FIFO/tile重叠暂后置；原w4a8_wave与requant/dynamic数值和接口保持。

## 代码与入口

- `rtl/vector/silu_sigmoid_lut.sv`：数学生成的128×34相邻sigmoid样本同步ROM。
- `rtl/vector/swiglu_element.sv`：Q16.16 SiLU及乘法，两个shift16最近/tie远离零、INT32饱和；单活动标量，背压持稳。
- `rtl/vector/ffn_bridge.sv`：两个512×32同步RAM、坐标seen/重复检查、row/group读取、scalar和dynamic连接，单活动任务。
- `model/vector/ffn_reference.py`：独立整数模型、浮点比较、LUT一致性和误差阈值，固定种子20261014。
- `tb/vector/tb_swiglu_element.sv`、`tb_ffn_protocol.sv`、`tb_w4a8_ffn.sv`：单元、容量/协议及完整FFN自检。
- `scripts/run_ffn.ps1`、`synth_ffn.tcl`、`summarize_ffn.py`：实际工具调用、身份/数值/资源/时序审计。

接口及阶段存储边界见 [ffn_interface.md](ffn_interface.md)，算术见 [ffn_numerics.md](ffn_numerics.md)，结构全貌见 [ce_structural_status.md](ce_structural_status.md)。实际结果见 [ffn_validation.md](ffn_validation.md)、[ffn_delivery.json](../build/ffn_delivery.json)。

## 本轮功能范围

三次投影使用三个原4×4 W4A8实例、有限TB packet源与阶段调度；中间gate/up坐标组装、非线性、乘法及dynamic均为真实RTL，并独立综合ffn_bridge。down的qx/sx回填packet适配与统一任务图仍是TB，不宣称完整FFN系统RTL/外存DMA已综合。

gate/up按tile输出的任意坐标写入bridge。全部gate/up收齐后按down K-group转换，输出标签qx/sx存入down有限packet源，完整初始化后才启动down。配置32/12分别使用第一投影group12/32；down sw独立。m/h≤64且m×h≤512，第一/最后投影仍受原核心容量约束。

本轮矩阵覆盖M=1/M>1、多个group、尾组/尾tile、不同sw、零及故意饱和。每group配置18完整任务、8阶段中止恢复，完整任务中间gate/up/product/qx各1720、最终输出300；日志另含中止前缀。单元1890输入对、两模式及7次阶段复位恢复；协议6次拒绝、16输出、每任务100拍持续背压。

最终合计36完整FFN任务、600个down输出、3440个完整中间qx；四类自检合计1279163检查项。scalar实际3787输出（含7次复位后的恢复事务）、13279拍背压保持；单元/FFN错误golden及FFN强制watchdog探针各实际退出1。协议顶层真实CAPACITY=8，scalar容量标签为0（不适用），FFN及EDA顶层为512，最终manifest逐项审计这些参数。

| GROUP_SIZE | 综合LUT/FF | DSP | RAMB18 | OOC WNS/WHS ns | 完整路由 |
|---|---|---:|---:|---|---|
| 32 | 2576/1765 | 10 | 4 | +3.433/+0.004 | 3509/3509 |
| 12 | 2631/1764 | 10 | 4 | +3.571/+0.007 | 3600/3600 |

两配置均RAMB36/URAM/LUTRAM/latch/blackbox=0、routing error=0、setup/hold失败端点0，1个OOC边界gap。OOC LUT分别2530/2589，其余列资源同综合。各105条警告，代码DRC23-814与Route35-198，原文保存在warnings.txt；RAM层次映射确认gate/up各1个RAMB18、sigmoid ROM1个、dynamic group Buffer1个，DSP中nonlinear7个、bridge地址/数量运算3个。

SiLU采用±8截断、非负区间步长1/16 sigmoid LUT插值；系数unsigned17，INT32_MIN扩展后取幅值，乘积signed64先扩signed65再舍入取幅值。SiLU65537网格点误差限0.00270；正常矩阵product相对L2<0.0002、最终相对L2<0.02；零矩阵绝对误差0。饱和用例单列，不以其大浮点误差掩盖整数错误或忽略状态。

实际SiLU网格最大绝对误差0.002682801；正常小矩阵最终对已编码scale的浮点链相对L2约0.55%–1.75%，零矩阵0；故意超范围矩阵约100%，整数RTL/状态仍与参考完全一致。真实模型精度未验证。

## 复现与实际阶段命令

```powershell
Set-Location E:\speed-up

# 一键完整重现（仿真/探针/两配置综合OOC/旧基线回归）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_ffn.ps1 -Implement -Regression

# 本轮最终源码的四配置仿真和三个非零探针实际用此命令执行
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_ffn.ps1 -SimOnly

# 已有完整仿真后，顺序执行器件和基线回归
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_ffn.ps1 -SynthOnly -Implement -Regression

# 仅审计已有实际产物；不视作重新仿真/综合
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_ffn.ps1 -AuditOnly
python .\scripts\summarize_ffn.py --SimOnly
```

Vivado2025.2，临时VU9P part xcvu9p-flga2104-2L-e，10ns内部OOC。板卡、pin/IO delay未指定，未运行VCS、综合网表、板上或真实模型。各compile/elaborate/run及Vivado console的exit_code.txt、commands.txt、源码SHA、日志、CSV、RAM/primitive/timing/DRC/DCP在build。错误golden及watchdog的脚本退出码在observed_exit_code.txt。

## 修复与工具调度

单元首轮数学值全部通过，但背压覆盖为0；将紧凑repeat等待改为显式块且每拍断言valid/ready，随后产生完整背压覆盖，未修改数学golden或放宽结果断言。协议首轮100拍watchdog不足以覆盖新row/group收集scalar再计算scale的合法延迟，按group12最大收集和首输出预算改为250拍。

初次FFN综合参数记录沿用了动态脚本MAX_K=4096标签；实际bridge的MAX_H及内部quantizer MAX_K是64。修正为MAX_M=64、MAX_H=64、Quantizer_MAX_K=64、Projection_MAX_K=4096，旧器件进程已停止并重新执行。16GB主机并行Vivado内存余量较小，改为有效槽器件流程结束后顺序执行FFN两配置；不能把旧中断结果当最终成功。

有效槽提示词3的RTL/八配置自检先前已完成，本轮收尾其VU9P与回归；FFN功能基线继续使用原w4a8_wave，不依赖优化版。生成器补齐强制超时变换并用`create_valid_variant.py --check`只读确认输出与已验证源码完全一致，没有重新生成或改动原wave/valid RTL。

本轮实际再次执行旧基线回归：requant 798组/10062输出、dynamic 484组/5186输出及两层32完整任务/516最终输出、原W4A8八配置409任务/11715输出/37773组检查，全部通过。有效槽完整交付见 [独立收尾记录](session_handoff_ce_valid.md)。

## 下一轮结构接续

按用户结构优先指示，先核验最新ffn/dynamic/valid delivery和源码身份，读取队友已实际提供的统一任务/存储接口。C/E提供branch坐标Q16.16输入及down qx/sx组输出；任务ID/地址/stride/中间存储/外存写确认由A/D、B/F持有，三阶段done不能混同。

继续结构补全可从RMSNorm/残差开始：先定数值合同与容量/归约/近似误差，再独立参考/RTL/自检/器件验证；随后RoPE和Attention QK/PV、mask、归约/Softmax，与队友KV有效长度/布局接口对齐。当前工程还没有完整Transformer或LLM token推理。输出FIFO、有效槽替换到FFN、并行gate/up、阶段重叠留后续性能轮，当前顺序FFN保留为对照。
