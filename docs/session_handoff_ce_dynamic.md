# C/E 接续：动态scale与两层W4A8验证

本轮按 `session_handoff_ce.md` 提示词2执行并完成；`run_dynamic.ps1 -Implement -Regression` 实际退出0，最终DYNAMIC_VALIDATION_PASS及DYNAMIC_ARTIFACT_AUDIT_PASS均通过。保留提示词1外部scale基线、原W4A8 RTL/接口/golden与团队C/E边界。下一轮对应提示词3；不自动同时做输出FIFO或FFN。

## 本轮入口与身份

推荐独立动态顶层 `rtl/vector/requant_dynamic.sv`，内部复用 `requant_group` 与 `sync_sdp_ram`。两层TB为 `tb/vector/tb_w4a8_two_layer.sv`，动态单元TB为 `tb/vector/tb_requant_dynamic.sv`；模型为 `model/vector/dynamic_reference.py`。入口脚本 `scripts/run_dynamic.ps1`，器件脚本 `scripts/synth_dynamic.tcl`，审计 `scripts/summarize_dynamic.py`。

数值合同见 [dynamic_numerics.md](dynamic_numerics.md)，握手、同步Buffer与队友接口见 [dynamic_interface.md](dynamic_interface.md)，实际证据见 [dynamic_validation.md](dynamic_validation.md) 和 [dynamic_delivery.json](../build/dynamic_delivery.json)。源文件SHA256、参数、实际命令、退出码、日志、CSV、RAM/primitive报告和DCP都在build，原始验证结果不替代本轮执行。

起始再次审计了提示词1，退出0、源码身份一致。起始git改动与上一轮一致，未发现新增适用AGENTS.md或队友修改。没有引入openTPU/llama-fpga代码、安装依赖、修改全局环境或接管队友DMA/统一顶层。

## 数值与接口接续

- A=max(abs(T))，INT32_MIN扩展为signed33后取幅值，unsigned32 A可为2^31。
- candidate=ceil(A/2032)，S=clamp(candidate,1,65535)，2032=127×16。全零组S=1；scale采用ceil，标量requant仍最近/tie远离零。
- A>133167120时scale_clipped=1、S=65535，继续量化并独立报告out_saturated/group_saturated。不能将该范围不足标志忽略或默认为无误差成功；没有扩大UQ4.12格式。
- 非法K/group/len拒绝error_code=2、done单拍，无数据接收/输出；row是标签。GROUP_SIZE编译配置32/12，MAX_K4096。
- 每实例一个GROUP_SIZE×32同步1R1W Buffer，只COLLECT写、READ_REQ读；最后输出接受前不释放组。不清RAM，但新组有效槽全部重写后才读，不读无效尾槽。
- 32拍scale恢复除法；最后收集输入至首输出接受70拍，后续输出间隔36拍。无阻塞描述符至末输出为37×len+34拍：len32为1218拍、len12为478拍。
- out_scale每元素重复，sx按row/第二层group仅保存一次。out_last只表示本组末元素，done不等于外存写确认。

## 两层连接的实际范围

两个4×4原`w4a8_wave`实例，第二层group32/12对应第一层group12/32，测试组命名空间、sx与独立sw。第一层按tile坐标写入512×32有限同步RAM，再按第二层row/group读取送入动态模块；qx/sx按输出标签写入第二层有限packet模型。第一层全部坐标收齐、qx/sx全部确认初始化后才启动下一阶段，无阶段重叠。

测试矩阵：1×19→37→5、3×35→29→7、5×23→61→6、2×13→25→3零矩阵、1×9→33→4超范围矩阵。第一层M/N≤64、K≤4096，适配M×H≤512；这只是本轮小矩阵范围，未测满容量。

比较第一层Q16.16、两层INT32 group psum/scaled快照、动态qx/sx/absmax/clip/sat及最终Q16.16。覆盖连续任务、尾组/尾tile、输入/array/post暂停和背压，以及第一层RUN、动态COLLECT/SCALE_DIV/输出保持、第二层RUN/输出保持六种复位中止并完整恢复。

适配RAM每元素4B写+4B读，dynamic Buffer另4B写+4B读，qx1B/元素、sx2B/row-group；两层packet字节/beat和实际周期在CSV。适配器与packet源仅为TB，不代表完整两层DMA/统一任务系统已综合。队友1/2仍负责任务ID/地址/stride/写确认；现有共享W4A8接口未改。

## 已实际执行的核心证据

| 配置 | 独立动态组/输出 | 完整两层任务/最终输出 | 复位中止恢复 | 综合LUT/FF | DSP/RAMB18 | OOC WNS/WHS ns |
|---|---|---|---:|---|---|---|
| group32 | 262/3768 | 16/258 | 6 | 547/411 | 0/1 | +6.079/+0.007 |
| group12 | 222/1418 | 16/258 | 6 | 594/410 | 0/1 | +5.999/+0.018 |

动态单元合计484组、5186输出、474215自检项；两层合计32完整任务、516最终输出、554105自检项。完整任务中每配置1546个中间qx；日志另外包含已验证后被复位任务的前缀，不能把前缀计数混作完整任务吞吐。

模型196605次scale边界检查，覆盖所有非零UQ4.12编码跃迁及上界。模块错误golden、两层错误golden、强制watchdog探针实际退出1。六个正常随机用例最终对已编码scale浮点链相对L2约0.36%–0.64%，零组误差0；故意超范围用例约99.9%的最终相对误差，clip/sat均正确报告，单独列出。整数RTL对golden误差0。

RAM实际映射均为1个RAMB18E2，无LUTRAM/DSP/URAM/latch/blackbox。内部路由808/808与861/861，无路由错误，均有1个OOC边界gap。10ns内部OOC，无板级管脚/IO delay，板卡未确认；setup/hold失败端点0，不能据此声明板上频率。完整警告、时序/DRC和RAM映射以报告为准。TB elaboration的未连接valid_macs计数端口是未使用统计输出，实际数据/请求握手均连接。

## 命令与修复记录

```powershell
Set-Location E:\speed-up

# 复现全部新验证、VU9P综合/OOC、旧requant和W4A8回归
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_dynamic.ps1 -Implement -Regression

# 当前源码的四配置自检与失败探针
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_dynamic.ps1

# 只审计已有产物，不视为重新仿真
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_dynamic.ps1 -AuditOnly

# 指定单配置调试；已有全套仿真后可仅执行EDA
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_dynamic.ps1 -Simulation chain12
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_dynamic.ps1 -SynthOnly -Implement
```

实际先运行module32定向，修复SV字面量旁ternary缺空格导致的词法解析错误，以及TB在posedge读取tick产生的一拍竞争。初次全流程在两层case2遇到H=67超过原MAX_N64，核心按合同拒绝；将测试维度修正为H=61并增加容量检查，未修改核心或golden公式来掩盖失败。之后重新执行四配置、探针和完整器件流程。最终交付状态由脚本 `DYNAMIC_VALIDATION_PASS`、`DYNAMIC_ARTIFACT_AUDIT_PASS` 与delivery.pass确认；单工具退出码在各log.exit_code.txt，预期失败的脚本退出码在observed_exit_code.txt。

旧外部scale与原W4A8回归由-Regression实际重新执行通过，分别为798组/10062输出、409任务/11715输出/37773组检查；最终执行和源码审计结果保存在各自delivery/日志中。VCS、综合网表、板上、真实模型与外存验证未运行。

## 下一轮：提示词3，有效槽优化

先运行动态与原W4A8产物审计，核验当前源码SHA及PASS。然后在w4a8_wave上创建独立优化顶层，仅保存/后处理有效ml×nl槽；原顶层、golden、测试、性能报告必须保留。不要同时修改W4 decode映射、动态scale规则或加入输出tile流水。

重点验证slot坐标、同步psum/Y读延迟、sx/sw索引、双snapshot所有权、组间RAW hazard、post_pause、背压、连续波前和复位。覆盖4×4、8×8、2×3/group12、1×1以及提示词3列出的Decode/Prefill/尾块任务，独立更新周期分类与流量审计，执行仿真、非零失败探针、VU9P综合/OOC。动态/two-layer基线作为后续回归，不接管队友控制或存储系统。

FFN和输出FIFO仍未实现；提示词4/5留给后续独立轮次。
