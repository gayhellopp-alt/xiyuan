# 队友2后续存储交付：实际验证

日期2026-10-14，Asia/Shanghai。继续使用本地main `2e56af8bbee1fe6e806217e6f729a4984d8cb262`，只读GitHub API查询main最新SHA相同。适用祖先及项目目录未发现AGENTS.md。已核对团队/状态文档、原B接口与验证报告、最新RTL/model文件及未提交修改；保留此前B工作，没有拉取覆盖、重置工作文件、提交、推送或合并。

实际状态：B模块存在于本地未提交工作，四配置源码哈希审计有效；历史project_status描述的“尚无可综合传输”不用于判断当前本地B状态。负责人requant/SiLU/SwiGLU、队友1公共W4A8任务格式、动态QKᵀ/AV、mask/Softmax及Attention软件参考均未出现在当前checkout/main。因此交付下表范围，不声称两层数值、FFN或Attention集成完成。

## 1. 新增文件

| 文件 | 内容 |
|---|---|
| rtl/w4a8_tensor_dependency.sv | 源/目标容量和地址校验，producer→requant→next task依赖，consumer完成前持有工作区 |
| rtl/kv_cache_pkg.sv | 存储侧KV v1 config/command/type/status合同 |
| rtl/kv_cache_address.sv | 四平面的layer/head/token/byte地址、stride、范围和溢出校验 |
| rtl/storage_axi_byte_write.sv | 有限1byte写槽，64-bit narrow AXI，独立AW/W/B |
| rtl/kv_cache.sv | 有效长度、批次追加、提交、读取、clear、错误和共同复位 |
| tb/storage_axi_memory.sv | TB-only独立AXI memory，逐byte权限、WSTRB和暂停/故障注入 |
| tb/tb_kv_cache.sv | 独立Python地址/data oracle、scoreboard、容量/失败/背压/复位自检 |
| tb/tb_w4a8_tensor_dependency.sv | 工作区和三类fence门禁的独立自检；不包含数值占位模块 |
| model/kv_cache_reference.py | 仅存储oracle，生成288个合法byte的地址/数据向量 |
| scripts/run_kv_cache.ps1 | 编译/执行、两个故意非零探针、原B回归及可选综合入口 |
| scripts/summarize_kv_cache.py | 当前source hash与日志/CSV/退出码审计，区分未集成数值/Attention |
| scripts/synth_kv_cache.tcl | 独立KV OOC synthesis清单，排除全部TB memory |
| docs/w4a8_tensor_handoff.md | 两层/FFN中间工作区、RQ接入及剩余数值依赖 |
| docs/kv_cache_interface.md | KV布局、类型、容量、追加/读取/错误/复位及公共字段对齐 |
| 本文 | 实际执行证据和交付限制 |

原计算核心、数值参考、统一调度顶层及B RTL均未修改。只复用B的可综合byte读引擎和task校验。没有新增“Attention顶层”或用静态INT4权重接口代替动态矩阵乘。

## 2. 实际工具和命令

PowerShell7.6.5、Python3.12.14、Vivado/XSim2025.2 build6299465。脚本可覆盖VivadoBin/Python；默认PATH无Python时需使用实际完整路径。以下从 `C:\Users\20376\Desktop\xiyuan` 执行：

```powershell
$taskPython='C:\Users\20376\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
$taskVivado='C:\AMDDesignTools\2025.2\Vivado\bin'

# 新模块第一轮实际运行，包括B真实核心4×4回归；退出0
& .\scripts\run_kv_cache.ps1 -Python $taskPython -VivadoBin $taskVivado
# 最终增加consumer工作区占用及整批提交检查后，重新跑当前全部新源码；退出0
& .\scripts\run_kv_cache.ps1 -Python $taskPython -VivadoBin $taskVivado -SkipBRegression

# 两个自动子进程实际执行，均退出1
& .\scripts\run_kv_cache.ps1 -Python $taskPython -CorruptExpected
& .\scripts\run_kv_cache.ps1 -Python $taskPython -TimeoutProbe

# 真实调用的独立综合尝试；退出1，缺Synthesis/xcvu9p授权
Push-Location .\build\synth_kv_cache
& "$taskVivado\vivado.bat" -mode batch `
  -source C:/Users/20376/Desktop/xiyuan/scripts/synth_kv_cache.tcl `
  -tclargs C:/Users/20376/Desktop/xiyuan
Pop-Location
```

现场日志：`build/kv_dev.log`（包含本轮B回归）、`build/kv_delivery.log`（最终自检），各TB目录的compile/elaborate/run.log、commands.txt、source_inputs.json及kv_results.csv。最终输出 `KV_STORAGE_EVIDENCE_PASS configs=2 tensor_handoffs=3` 和 `STORAGE_FOLLOWUP_VALIDATION_PASS`。

不是AuditOnly；实际重新调用xvlog/xelab/xsim。脚本对Fatal/FAILED/TIMEOUT和缺少PASS sentinel均非零退出，不能依赖XSim对$fatal的退出码。`-ReferenceOnly`明确表示只执行Python、RTL未执行，缺EDA工具时普通入口非零。每命令20000拍watchdog，KV全局20ms、handoff全局100us；脚本run all，超时监控不会因有限run窗口被跳过。

## 3. 当前自检结果

| 配置 | 已完成记录 | require检查 | 追加输入背压拍 | 读取输出背压拍 |
|---|---:|---:|---:|---:|
| KV GROUP_SIZE=4 | 59 | 79592 | 3204 | 63 |
| KV GROUP_SIZE=3 | 59 | 79592 | 3204 | 63 |
| tensor dependency GROUP_SIZE=4 | 3次next-task交接（含consumer错误） | 143 | 请求/描述符强制持稳 | consumer fence前禁止复用 |

两个KV配置都为2 layers、2 KV heads、capacity4、dimension5；末dimension group不完整。group3/4均有2个scale group，物理向量共用；这是两种**存储参数**验证，不是两种Attention数值正确性验证。默认硬件4layers/8heads/capacity4096/dimension128及其他最大组合未全部仿真。

每配置59条记录分布：22成功（含配置和clear）、12非法配置、16非法命令、4写错误、3读错误、2stream last错误。成功追加累计198字节、成功读取59字节。失败写也可已经改动物理内存，统计/scoreboard包含这一行为。中途共同复位中止的任务不产生完成记录。

覆盖内容：

- 非紧密的token/head/layer stride，四plane分别分配，signed INT8负数byte、UQ4.12零/65535编码、little endian和不完整group；基址4093跨4KiB。Python独立输出288个byte的合法地址/data，TB不使用DUT地址生成器作为golden。
- AW地址、WSTRB、write data、AR精确顺序及read data/last逐beat检查，防丢失、重复、错址。所有AR还检查独立shadow committed长度。最终逐byte比较整片64KiB内存与shadow image，guard和所有padding不得变化。
- 接受config/command后提交端字段被改成0，验证锁存；追加源valid在ready=0期间持有data/last，AXI AR/AW/W、read输出和completion持稳；随机独立AR/AW/W暂停、R/B延迟、read consumer背压；AW先W和W先AW两种顺序均命中。
- 多head/layer互不污染；连续追加1 token再2 tokens；直到capacity4填满；拒绝超过容量、token起点不是旧长度、覆盖旧prefix、越界head/layer、读offset/length越界、count0、非法op及65535+65535溢出边界。配置检查格式/group不匹配、短stride、短区域、重叠、scale未对齐、32位地址溢出和编译容量超限。
- 最后一B强制延迟100拍，所有物理W已接受、仅最后B未确认时，query_length保持旧值且无completion；B释放后才提交。
- 1 token末B失败时18个byte物理已写，只有17个B成功，旧length不变；2 token批次末B失败时36个byte物理已写、35个B成功，**连第一个已完全写好的token也不提交**，读两个新token均拒绝。中途B失败、错误BID、提前last和缺失最后last也不提交。恢复必须从旧length重写完整批次；旧已提交token仍可读。
- RRESP、RID、缺首个RLAST后追加终止beat均错误完成，失败byte不交consumer，有效长度不变，后续正常读恢复。测试故障均在首个read byte；中途read错误的“丢弃已输出前缀”合同已规定，但尚未单独注入该位置。
- KV_CLEAR只清指定head有效长度，旧物理data仍在但读命令拒绝；重新追加后重新可见。共同复位覆盖B等待及read result背压，配置/所有length失效，重新配置后不能读旧prefix，完整新追加后恢复。
- 错误golden探针返回1；永久保持最后B不返回触发command watchdog，返回1。证据：`build/kv_CorruptExpected.exit.txt`、`build/kv_TimeoutProbe.exit.txt`及对应stdout/stderr日志。

handoff单元验证：生产者fence未到不发RQ；不匹配ID不能释放依赖；RQ请求及下一层描述符背压持稳；生产者/RQ错误和字节计数不符阻断下一层；RAW容量过小、A覆盖sx拒绝；下一层接受后workspace仍占用，consumer fence缺失/ID错误不能释放；consumer错误传播；等待RQ时共同复位后新计划恢复。三个交接使用**测试通知**，仅验证门禁/占用逻辑，没有真实requant、两层或FFN算术。

## 4. 部分实际周期/流量

来自GROUP_SIZE=4 `kv_results.csv`；GROUP_SIZE=3此向量结果相同。cycles从校验至completion；等待列可重叠。窄传输每个有效byte占一个64-bit物理lane beat；不代表DDR带宽。

| task_id / 操作 | cycles | 已发写字节 | 成功B字节 | 已交付读字节 | 读占用拍 | 写占用拍 |
|---|---:|---:|---:|---:|---:|---:|
| 102：首次1 token，末B延迟100拍 | 333 | 18 | 18 | 0 | 0 | 295 |
| 103：读K，5 bytes | 70 | 0 | 0 | 5 | 64 | 0 |
| 104：读V，5 bytes | 72 | 0 | 0 | 5 | 66 | 0 |
| 107：连续追加2 tokens | 568 | 36 | 36 | 0 | 0 | 494 |
| 108：跨3 tokens读取K片段 | 114 | 0 | 0 | 9 | 104 | 0 |
| 112：1 token末B失败 | 232 | 18 | 17 | 0 | 0 | 195 |
| 125：2 tokens末B失败 | 499 | 36 | 35 | 0 | 0 | 426 |

寄存器buffer限定一个在途byte，没有整token大数组或不受限返回队列。提交元数据独立于物理写数据；错误场景的byte计数不自动变成committed length。

## 5. 原B与综合

本轮真实重新运行原B4×4：29个完成记录、11个成功任务、1054个逐元素外存Y比较、994532个require检查，退出0。未改B/core源；其他既有B配置源码哈希仍通过原summary审计。前轮wave409任务/11715输出是已有证据，本轮不重复声称重新跑了全部wave。

KV独立综合已实际调用、读取5个综合RTL文件（包括复用读引擎），到VU9P synth_design时缺Synthesis/xcvu9p授权，Common17-345，退出1。日志 `build/synth_kv_cache/synth.console.log`。因此无本轮KV资源、综合网表、OOC布局布线/时序；XSim编译/elaborate通过不代替综合。脚本提供 `-Synthesize`，有合法授权可继续；没有换器件、安装license或修改用户工具配置。

未执行：板上DDR/PCIe、CDC、多outstanding/长burst、完整最大容量矩阵、bridge-only warm reset、多个序列context/分页/eviction/GQA系统测试；handoff独立器件综合；真实requant/两层/FFN、动态QKᵀ/Softmax/AV及Attention参考。v1单byte AXI优先保证范围和确认正确性，效率及组合stride地址乘法资源待后续综合/优化评估。

## 6. 接入依赖与下一步

两层/FFN具体字段和状态见 `w4a8_tensor_handoff.md`，KV合同/公共字段列表见 `kv_cache_interface.md`。本轮交付可独立验证KV和存储门禁；依赖未就绪时保留这些模块，后续按实际负责人接口增加adaptation，禁止把测试通知或byte oracle称为实际数值集成。

待队友1映射公共任务/tensor/context及内存仲裁、工作区依赖；待负责人提供requant/非线性、动态QKᵀ和AV、mask/Softmax数值接口；待软件参考覆盖小序列Prefill/Decode、scale/GQA/position/mask。准备好后新增真实模块闭环testbench及逐元素/逐阶段参考比较，再确认Attention集成。

建议本地提交说明：

```text
feat(storage): add transactional KV cache and tensor workspace fences

Add guarded layer/head/token KV layouts, narrow AXI transfers, append commit
after all K/V/scale write responses, committed-only reads and reset recovery.
Add producer/requant/consumer dependency and workspace lease gates without
modifying compute or unified scheduling. Validate with independent byte
oracle, AXI memory, fault/backpressure/reset tests and nonzero watchdog probes.

KV: 2 configurations x 59 completion records; tensor gate: 143 checks.
No actual requant/FFN/Attention integration; upstream interfaces absent.
VU9P synthesis attempted, blocked by missing Synthesis/xcvu9p license.
```

全部新文件及build证据留在本机xiyuan；不提交/推送/合并。`build/kv_cache_summary.json`明确标记 two_layer_numerics_integrated=false、attention_integrated=false、synthesis.completed=false。
