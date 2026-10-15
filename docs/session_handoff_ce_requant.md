# C/E 接续：提示词1已完成，下一轮提示词2

本轮继续 E:\speed-up 现有工程，交付外部 scale 的独立 `requant_group`。原 `w4a8_wave`/INT8 顶层、参考模型、TB 与共享接口未改。没有接入 openTPU 或 llama-fpga 代码；没有接管 A/D 控制软件或 B/F 存储/KV 集成。

## 起始核查

- 读取 `session_handoff_ce.md` 提示词0与1、README/config、团队工作包、工程状态、上游参考说明、W4A8 数值/架构/验证/性能与对应 RTL/TB/model/scripts/delivery。
- 起始 git status 只有 `docs/session_handoff_ce.md` 未跟踪。E:\ 与工程目录没有适用 AGENTS.md；目录内搜索也未发现该文件。保留用户已有交接文档。
- Windows/PowerShell，工具路径 E:\AMDDesignTools\2025.2\Vivado\bin，Vivado/XSim 2025.2 build6299465。实际综合许可证获得；Tcl `get_parts` 核验 xcvu9p-flga2104-2L-e 存在。评估板卡仍未确认，10ns 仅内部 OOC。
- 先执行原 `run_w4a8_wave.ps1 -AuditOnly`，退出0；历史409任务/11715输出/37773组检查和两尺寸综合/OOC源码身份一致。之后实际重新执行八配置 W4A8 回归及失败探针，不把审计当新增 RTL 仿真。
- VCS/综合网表/板上验证未运行；没有安装工具或修改全局环境。

## 本轮文件与接口

| 类别 | 文件 |
|---|---|
| 独立可综合顶层 | rtl/vector/requant_group.sv |
| 整数参考/逐位除法/全非零scale oracle | model/vector/requant_reference.py |
| group32/12 自检、背压/暂停、8次复位、异常与探针 | tb/vector/tb_requant_group.sv |
| 一键与综合/OOC | scripts/run_requant.ps1、scripts/synth_requant.tcl |
| 源码/工具产物审计 | scripts/summarize_requant.py |
| 数值/接口/实际验证 | docs/requant_numerics.md、requant_interface.md、requant_validation.md |
| 实际产物入口 | build/requant_delivery.json、requant_vectors/、sim_requant_g32/、sim_requant_g12/、synth_requant_g32/、synth_requant_g12/ |

数值为 `sat_int8(round(T/(16*S)))`，最近/tie远离零。T signed32 Q16.16，S 非零 unsigned16 UQ4.12。S=0拒绝 error_code=1；非法 K/group/len 拒绝2且优先；done同时用于成功/拒绝，需看 error_code。INT32_MIN 33-bit扩展取幅值。逐元素 out_saturated 和整组 group_saturated 均已验证。row/group/index/scale/last 与输出握手绑定，背压持稳。

GROUP_SIZE 是编译参数，实际完成32/12验证，MAX_K=4096。描述符带 row/group/K/len/scale；len 严格等于该group的有效尾长度。row为标签，上游校验行范围与任务一致性。一组一个标量在途，无group RAM、无坐标组装。32拍恢复除法+1拍舍入；e0输入接受，e33后valid，e34最早输出接受，同组II=35。按100MHz目标为约2.857M标量/s，组之间另有描述符开销；这是内部周期推算，不是板上测量。

原引擎按tile坐标输出，上游必须按第二层row/K-group重新排序，不能直接接线宣称两层完成。第二层sx由本模块描述符给定，sw仍独立供给；group编号属于第二层激活K布局。out_last只是本组末元素，done不代表外存写确认。

## 实际命令、结果与修复

工程根目录下执行：

```powershell
# 起始核对：退出0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_wave.ps1 -AuditOnly

# 本轮实际执行参考/自检/失败探针、两组综合OOC、原W4A8八配置回归
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_requant.ps1 -Implement -Regression

# 修复脚本编码与模型日志目录后，实际重跑受影响自检/探针并审计全部EDA：退出0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_requant.ps1

# 只核对已有产物与当前源码，不视作新仿真
python .\scripts\summarize_requant.py
```

首次完整命令中的各仿真、Vivado综合/OOC、W4A8回归均完成，最后汇总因PowerShell5 Tee-Object写UTF-16日志而退出1。汇总器已按BOM识别UTF-16/UTF-8，参考模型命令记录已统一移至build；第二次命令实际退出0。RTL/golden未改以处理该问题。完整复现仍使用 `-Implement -Regression`，耗时主要为两次VU9P OOC。

每个仿真/综合目录有commands.txt、source_inputs.json SHA256、实际日志、PASS标记或报告/DCP；失败目录有 observed_exit_code.txt。根目录首次模型命令记录移至 build/requant_first_model_commands.txt。build被.gitignore排除，但本地工具证据实际存在。

| 配置 | 成功group | 输出 | 自检项 | 综合LUT/FF | DSP/RAM/latch/blackbox | OOC WNS/WHS ns |
|---|---:|---:|---:|---|---|---|
| group32 | 409 | 7161 | 952438 | 258/188 | 全0 | +7.047/+0.043 |
| group12 | 389 | 2901 | 418235 | 282/188 | 全0 | +6.970/+0.010 |

共798组、10062输出、1370673项自检；原W4A8另外重跑409任务、11715输出、37773组检查。参考模型458745次检查覆盖全部65535非零scale。每配置9个拒绝描述符、8次复位；最小接受延迟34拍、II35拍，压力用例最大接受延迟90拍、II95拍。错误golden与强制watchdog探针实际退出1。所有RTL输出对整数参考误差0；非饱和反量化误差界≤S/8192，真实模型精度未测量。

新模块每配置105条Vivado警告，代码仅DRC 23-814、Route 35-198，属于OOC检查范围/PARTPIN边界；完整原文在warnings.txt。内部setup/hold失败端点、无时钟/内部无约束端点/时序环均0；OOC DRC Checks found=0。可路由网络342/342与371/371，无路由错误；报告存在一个OOC边界显式gap且设计状态Partially Routed。不能用这些结果推导完整板级路由或频率。

## 下一轮：仅执行提示词2

先运行 `python scripts/summarize_requant.py`，核实当前源码SHA、group32/12 PASS、失败非零、EDA报告；若修改RTL，必须重新仿真/综合。然后增加 row/K-group absmax、非零UQ4.12 scale编码及有限同步group Buffer，明确全零组、INT32_MIN、scale上限不足时的饱和或拒绝状态，以及端口/读延迟/收集→求scale→发送→释放所有权。

通过独立模块自检后，再在TB中实现有限存储/坐标组装适配器：第一层w4a8_wave Q16.16 → 按第二层K分组动态requant/sx → 第二层w4a8_wave。逐阶段比较位精确参考，另报浮点误差，验证尾块、暂停、背压、连续任务和复位。第二层sw独立提供。真实DMA/统一任务系统仍由队友负责。

本轮尚未实现动态scale、两层连接、有效槽优化、输出tile流水、FFN。不要同时推进提示词3/4/5；先完成提示词2并保留本轮外部scale基线。
