# 工作包 B：实际验证与交付记录

日期：2026-10-14（Asia/Shanghai）。基线 main `2e56af8bbee1fe6e806217e6f729a4984d8cb262`。最初 xiyuan 文件夹为空，没有未提交工作；GitHub HTTPS 克隆曾失败，先下载 API 归档，再 fetch 原始 Git 提交并恢复 main 索引，源码与原始提交一致。未发现适用 AGENTS.md 或公共任务描述符；已阅读 README、团队/状态/上游说明、wave/reuse/packed 架构、核心与 TB、数值合同及 Python 参考。没有引入第三方 RTL。

## 1. 文件与维护边界

| 文件 | 作用 |
|---|---|
| rtl/w4a8_memory_pkg.sv | 存储侧 task struct、格式及状态码 |
| rtl/w4a8_memory_validate.sv | 启动前尺寸/格式/group/stride/分配区/溢出/重叠检查 |
| rtl/w4a8_memory_packet.sv | 请求锁存、有限 byte gather、列对 packet/keep |
| rtl/w4a8_axi_read.sv | 单事务窄读、响应保留、RRESP/RID/RLAST 检查及排空 |
| rtl/w4a8_axi_write.sv | 单写槽、独立 AW/W/B、32位 narrow write/WSTRB |
| rtl/w4a8_memory_bridge.sv | 任务生命周期、输出坐标写回、错误 drain、completion fence、统计 |
| tb/w4a8_axi_memory.sv | 独立 AXI slave，仅用于仿真，guard/有效源地址/重复写检查 |
| tb/tb_w4a8_memory.sv | 真实核心集成及独立单元 driver、参考 scoreboard、异常/复位/暂停测试 |
| model/w4a8_memory_vectors.py | 非紧密内存图像，调用项目位精确 reference 生成 Y |
| scripts/run_w4a8_memory.ps1 | 从零生成向量、编译/运行、失败/超时探针、wave 门禁、可选综合 |
| scripts/run_w4a8_memory_xsim.tcl | run all，TB 全局 watchdog 生效 |
| scripts/synth_w4a8_memory.tcl | 存储侧综合清单、VU9P OOC synthesis/报告入口 |
| scripts/summarize_w4a8_memory.py | 对当前源哈希、日志、CSV 和探针退出码审计 |
| docs/w4a8_memory_interface.md | 队友1接入、布局、时序、支持范围及复位/错误合同 |
| scripts/run_w4a8_wave.ps1 | 仅两处子进程改为使用当前 PowerShell executable，避免切换宿主后 Get-FileHash 模块加载失败 |

没有修改 w4a8_wave、systolic_array、systolic_pe、npu_top、数值参考或其他 RTL。回归脚本自动生成的历史 wave/systolic 文档已经恢复到基线，新的现场副本在 `build/memory_regression_docs/`；本报告记录本轮证据，不覆盖历史综合/OOC资源。没有自动提交、推送或合并。

## 2. 工具及实际命令

实际使用 PowerShell 7.6.5、Python 3.12.14、Vivado/XSim 2025.2 build6299465。PATH 未提供 Python/EDA；通过本机和 workspace runtime 探测找到路径。新脚本接受 `-VivadoBin` 和 `-Python`。

以下命令在 `C:\Users\20376\Desktop\xiyuan` 执行，`$taskPython` 为此次实际路径：

```powershell
$taskPython='C:\Users\20376\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
$taskVivado='C:\AMDDesignTools\2025.2\Vivado\bin'

# 初次完整入口（执行真实编译/仿真，从空 build 开始；不是 AuditOnly）
& .\scripts\run_w4a8_memory.ps1 -Python $taskPython -VivadoBin $taskVivado -Synthesize
# 此次初次运行在 wave 自动 negative 子进程的 PowerShell 模块加载处退出1。
# 修复宿主选择后，以下两个最终命令分别重新完成 wave 门禁和最新存储 TB。
& .\scripts\run_w4a8_wave.ps1 -Python $taskPython -VivadoBin $taskVivado
& .\scripts\run_w4a8_memory.ps1 -Python $taskPython -VivadoBin $taskVivado -SkipWaveRegression

# 独立综合尝试：实际已调用，退出1（无 Synthesis/xcvu9p 授权）
Push-Location .\build\synth_w4a8_memory
& "$taskVivado\vivado.bat" -mode batch `
  -source C:/Users/20376/Desktop/xiyuan/scripts/synth_w4a8_memory.tcl `
  -tclargs C:/Users/20376/Desktop/xiyuan
Pop-Location

# 可单独重现的故意失败/超时：均应退出非零
& .\scripts\run_w4a8_memory.ps1 -Python $taskPython -CorruptExpected
& .\scripts\run_w4a8_memory.ps1 -Python $taskPython -TimeoutProbe
```

最终存储命令退出0，`build/memory_delivery.log` 包含 `W4A8_MEMORY_EVIDENCE_PASS configs=4` 和 `W4A8_MEMORY_VALIDATION_PASS`。自动子进程确实调用了上述两个失败探针，退出码都为1，分别存于 `build/memory_negative_exit.txt`、`build/memory_timeout_exit.txt`。XSim 对 `$fatal` 可能仍返回0，因此脚本额外检查 PASS sentinel 与 Fatal/FAILED/TIMEOUT 文本；缺少 PASS 不能被当作成功。

全新 checkout 可直接运行首个入口去掉 `-Synthesize`，自动复现缺失的已有基线。`-ReferenceOnly` 只生成向量，打印 RTL 未执行，不宣称 PASS；缺工具时普通入口非零退出。`-SingleConfig` 只跑4×4；`-SkipWaveRegression` 只跳过原波前门禁，仍跑四个存储配置和两个非零探针。脚本不安装软件或许可证，不修改全局环境。

## 3. 最终仿真结果

| 配置 | 真实 core | tile/group | 完成记录 | 成功且逐元素检查任务 | 检查输出 | require 检查 | 非连续 keep | 奇数 req_k |
|---|---|---|---:|---:|---:|---:|---:|---:|
| 4×4 | 是 | 8/32 | 29 | 11 | 1054 | 994532 | 158 | 0 |
| 8×8 | 是 | 8/32 | 29 | 11 | 1054 | 957284 | 104 | 0 |
| 2×3 | 是 | 5/12 | 29 | 11 | 1054 | 1229485 | 2120 | 636 |
| 独立存储 unit driver 2×3 | 否 | 5/12 | 31 | 12 | 1153 | 1426637 | 2320 | 696 |

合计118个完成记录，45个成功任务、4315个逐元素外存 Y 比较，4607938个 require 检查。完成记录包括11类非法描述符、5类 AXI 错误、核心 error/过早 done；unit 额外拒绝非法 tile request。运行中共同复位中止的两个任务不计入完成记录。每次错误或复位后立即执行新图像任务，验证旧数据/响应/坐标不会污染恢复任务。

成功数据为 `8×8×37` 和 `9×11×41`，第二任务地址偏移128、全部维度/数据改变，K 为奇数，group32/12 均有不完整末组；默认4×4有多 M/N tile，8×8测试满阵列及尾块，2×3覆盖奇数 K tile 起点和 group 截断。Python 调用原 `w4a8_reference.reference`（经 make_case）计算固定点 Y，外存逐元素与该结果一致。独立 unit 按列顺序输出坐标，故可证明写回不依赖完整矩阵逐行输出顺序。

覆盖证据：

- 接受 task/request 后锁存；提交端被改成全0，unit 将全部 request 字段改为无效值，已接受的 packet 仍正确。valid&& !ready 时检查 request全部字段、packet data/keep、输出坐标/data/last、AR/AW地址、W数据/strb和 completion 持稳。
- 每个请求独立枚举预期 packet 和读字节地址队列，对 AR 精确次序、完整 packet data/keep 检查，成功时两个 scoreboard 必须全部排空，禁止多读/少读/丢包/重复。
- 五种非紧密 stride；A 基址4093越过4KiB边界；源区仅有效字节可读，最末有效字节之后没有合法分配 padding。仿真 slave 对实际读越界/访问行 padding直接 fatal。
- 写地址和 WSTRB 精确检查，重复写 word 直接 fatal；对整片64KiB内存逐字节检查源区、相邻数据、输出行 padding和 guard不变。
- LFSR独立 AR/AW/W 暂停及 R/B 延迟；核心 input/array/post 暂停。强制第一 packet 完整后持有40拍，之后恢复；单写槽满时核心输出背压，检查 AW先于W、W先于AW两种顺序均发生。
- 最后 B 强制延迟100拍，检查最后W已提交、核心done/out_last已观察、写槽仍非空且不能成功；释放B后才成功。
- RRESP错误、BRESP错误、缺首个RLAST后追加终止beat、错误RID、错误BID均产生错误完成；新任务不用共同复位即可恢复。
- 共同复位覆盖 read response 在途和 write response 等待；复位后重新加载另一图像任务。每任务250000拍 watchdog、全局100ms watchdog；故意最后B永久不返回使 per-task watchdog触发，脚本退出1。

## 4. 实际周期和流量

下表为每配置最初连续两个任务，包含固定LFSR暂停和第一任务人为最后B延迟；单位为字节/周期，不是DDR测量。恢复任务的全部记录在各配置 `memory_results.csv` 和 `build/w4a8_memory_summary.json`。

| 配置/ID | cycles | 有效读 | 有效写 | 读总线 | 写总线 | packet有效/物理 | 读占用 | 写占用 | 输入等 | 输出等 | packet峰值/写槽峰值 |
|---|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|---|
| 4×4/101 | 11235 | 728 | 256 | 5824 | 512 | 728/768 | 8774 | 845 | 95 | 586 | 8/1 |
| 4×4/102 | 19445 | 1302 | 396 | 10416 | 792 | 1302/1584 | 15517 | 1241 | 125 | 930 | 8/1 |
| 8×8/101 | 8521 | 512 | 256 | 4096 | 512 | 512/544 | 6186 | 825 | 69 | 586 | 8/1 |
| 8×8/102 | 15696 | 991 | 396 | 7928 | 792 | 991/1200 | 11605 | 1203 | 75 | 940 | 8/1 |
| 2×3/101 | 23358 | 1448 | 256 | 11584 | 512 | 1448/3008 | 17346 | 912 | 242 | 533 | 6/1 |
| 2×3/102 | 38493 | 2417 | 396 | 19336 | 792 | 2417/4800 | 29250 | 1130 | 285 | 694 | 6/1 |

总线字节按64位lane容量计，窄读有效字节仅1；不能据此估算DDR burst效率。等待列互相重叠，不能相加为总周期。unit数据同2×3，计算被替换为测试driver，不能与真实核心性能比较。完整buffer/计数定义见接口文档。

## 5. 相关原回归

最终原 `run_w4a8_wave.ps1` 退出0；八配置409任务、11715输出、37773组psum/scaled检查通过，失败探针退出1，当前核心源哈希通过原审计。冷启动同时重建了所需 reuse/systolic/array 基线。具体现场日志是 `build/wave_final.log`、`build/sim_w4a8_wave_*/`、`build/w4a8_wave_summary.json`。

历史文档中的 VU9P资源数字不是本轮资源。本轮不重新声称旧核心综合/OOC；回归只复现 RTL仿真。两处 PowerShell启动修改只影响回归进程选择，无数值、协议或 RTL行为变化。

## 6. 综合尝试和未验证项

实际调用 Vivado batch 并读取全部6个新 RTL 文件。安装中的用户 TclStore catalog 损坏，最初 appinit/xsim/modelsim不能加载；综合脚本只在当前进程追加安装区 package 搜索路径，没有修改安装或用户配置。源根通过显式 `-tclargs` 传入，避免现场工具 `file normalize` 的路径问题。修复后进入 `synth_design -top w4a8_memory_bridge -part xcvu9p-flga2104-2L-e -mode out_of_context`，因没有 Synthesis/xcvu9p 许可证而退出1：`Common 17-345`。日志 `build/synth_w4a8_memory/synth.console.log`；前期环境错误日志另存同目录。

因此 **综合未完成，无本轮 LUT/FF/DSP/BRAM资源、综合网表、OOC布局布线或时序结果**。RTL被 XSim编译和elaborate，但这不能替代器件综合。脚本在有合法工具授权的环境可用 `-Synthesize` 继续，综合源明确排除仿真内存。不切换其他器件冒充VU9P结果。

未执行：VCS/Verilator、综合网表仿真、全部最大容量/所有参数、桥单独带在途事务复位、真实DDR/PCIe、板级时序/执行、真实模型及工作包F。首版只支持共同复位；单独桥复位后需外部冲刷/隔离fabric，不能直接接受新任务。没有多beat burst、深队列、跨时钟或ID epoch。每字节读事务的效率与组合地址乘法资源待获得授权后的综合和后续burst优化评估。

## 7. 本地交付和提交说明

接口与队友1步骤见 `w4a8_memory_interface.md` 第7节。软件/统一顶层 owner 只需映射 descriptor、原样连接核心握手与 reset、接AXI并消费 completion；status=0 后才使用Y。B模块不等待公共软件格式；未来新增公共定义可在控制边界做映射。

建议提交说明：

```text
feat(memory): bridge W4A8 tasks to AXI packets and fenced writeback

Add a synthesizable storage-side task contract, guarded address generation,
finite packet gather, independent narrow AXI read/write channels, error drain
and completion after all write responses. Preserve the existing wave core.
Add independent AXI memory/unit driver and real-core 4x4/8x8/2x3 regressions,
bit-exact external-memory scoreboards and nonzero failure/timeout probes.
Keep wave regression subprocesses on the invoking PowerShell host.

Validation: 118 completion records, 4315 bit-exact stored outputs;
preserved wave regression: 409 tasks / 11715 outputs; probes exit 1.
Vivado synthesis attempted; blocked by missing Synthesis/xcvu9p license.
```

代码、文档和现场 build产物均留在 xiyuan 供审阅；build为gitignored，不自动进入提交。未提交或推送。新的验证摘要同时保留 simulation pass 与 synthesis completed=false，不能把二者混作一个硬件完成结论。
