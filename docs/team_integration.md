# 三人工作整合记录（2026-10-15）

本地整合目录：`E:\speed-up`。本轮把 A/D、B/F、C/E 的源码汇入同一项目，并增加可运行的单层 W4A8 AXI 系统入口。完整 FFN/Attention 的统一任务图尚未实现，不能把模块汇入等同于整条 Transformer 链路完成。

## 来源与保护措施

| 部分 | 来源 | 处理 |
|---|---|---|
| A/D 控制与软件 | GitHub main `0a0438028cca44443ee2137458dc537ef9de2c0c` | 合并真实 Git 历史，保留原 `task_controller`、`w4a8_system_top`、软件导出与运行时 |
| B/F 存储与 KV | `xiyuan_BF\xiyuan_BF` | 汇入存储桥、AXI 引擎、描述符校验、KV、依赖门禁、参考模型与自测；原包保留 |
| C/E 计算与数值 | 开始整合时主目录中未提交的工作 | 先保存本地检查点，保留 wave/valid、requant、dynamic、FFN RTL、参考模型与验证文件 |

整合分支：`integration/team-20261015-195253`。原 `main` 保留在 `2e56af8`。本地 C/E 检查点为 `163d8ee`，合入 A/D 的 merge 为 `78d8686`。所有操作仅在本地，未推送 GitHub。

修改前全部工作文件（包括 build、B/F 原包，排除 Git 元数据）备份：`build/team_integration_20261015-195253/before_integration.zip`。对应 `sources.json` 保存 B/F 导入文件清单及 SHA256。旧 build 中的报告是历史证据；本轮测试证据以当前源码重新运行的日志为准。

忽略换行差异后，B/F 没有更改原计算 RTL；唯一原文件逻辑修改是 `run_w4a8_wave.ps1` 使用当前 PowerShell 进程启动子任务。此兼容性改动已保留。新存储脚本与 A/D 脚本默认 Vivado 路径统一为本机 `E:\AMDDesignTools\2025.2\Vivado\bin`，仍可通过参数覆盖。

## 当前统一入口

```text
A/D task_desc_t + 调用者提供的五个分配容量
    → w4a8_task_adapter：格式/地址宽度/stride/容量/输出别名校验
    → w4a8_memory_bridge：单活动任务、packet、AXI、错误排空和写确认
    → 原 C/E w4a8_wave：INT8 × signed INT4，group scale，Q16.16
    → AXI 写回 + 全部 B response
    → 与 A/D task ID/status 格式兼容的完成记录
```

新顶层为 `rtl/w4a8_team_top.sv`。主机端口沿用 A/D 的 `task_desc_pkg::task_desc_t`，增加 `a_bytes/w_bytes/sx_bytes/sw_bytes/y_bytes` 五个 uint32 容量端口；它们表示真实分配的范围，不从矩阵形状猜测容量。描述符和容量在 task valid/ready 握手时一起锁存，调用方随后可以修改输入。错误任务不产生外部访问。

统一顶层复用 A/D 的描述符与软件协议，由 B/F bridge 负责实际执行状态。原 A/D `task_controller` + `w4a8_system_top` 保留为独立 packet 系统并单独回归，**没有把两个任务控制器串起来竞争同一核心**。

保留原数值合同与内存布局：A `[M][K]`、W `[N][ceil(K/2)]` 低 nibble 在前、sx `[M][groups]`、sw `[groups][N]`、Y `[M][N]`。scale 为 little-endian UQ4.12，Y 为 signed32 Q16.16。GROUP_SIZE 是编译参数，运行时描述符必须匹配；K 不按独立舍入任务切分。

当前实际存储通路只支持 32 位地址。A/D 的 64 位地址字段保留，但高 32 位非零或 allocation 越过 4 GiB 会拒绝，不做静默截断。scale 地址和 stride 必须 2 字节对齐，Y 地址和 stride 必须 4 字节对齐。Y 分配区不能与任何输入分配区重叠，容量校验沿用 B/F 的完整区域语义。

原状态 0–9 保持编号；统一 AXI 顶层新增 10=读错误、11=写错误、12=分配容量/区域非法、13=存储协议错误。完成记录受反压时保持稳定，成功记录只在全部输出写确认后出现。读写错误会先停止核心并排空已发出的 AXI 事务，再发布失败；错误前的部分写回不能当作合法结果。

统一 AXI 通路沿用 B/F 的排空合同。外部 fabric 必须最终响应已接受事务；本顶层没有在未收齐响应时强制释放任务的超时机制。原 A/D packet 顶层的 TIMEOUT_CYCLES 继续保留，但不代表统一 AXI 通路具有安全的总线取消能力。系统复位必须同时覆盖外部 fabric，不能只复位本顶层后复用仍可能被写入的区域。

软件新增 `software/w4a8_memory_task.py`。`W4A8MemoryTask` 包含原 `W4A8Task` 和五个容量，`validate()` 复核同样的边界，`to_dict()` 输出 descriptor 与容量。可交给原 `W4A8Runtime.submit()`；具体 transport 必须支持把这些字段写到对应端口。项目没有新增真实 PCIe/MMIO 板级驱动。

## 验证入口

在项目根目录执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_team_integration.ps1
```

此入口依次运行 software、team、ad、memory、kv、ce、valid。可用 `-Suite team` 单独检查新系统，或选择对应 suite。`-Suite team -Synthesize` 还会调用 VU9P 综合；不自动进行布局布线或板级验证。脚本失败即返回非零。

新系统自测使用独立 Python 数值参考生成的 byte image，连接真实存储 bridge 和真实 wave RTL。包含 group32 的 4×4/8×8 及 group12 的 2×3、奇数 TILE_K，尾组/尾 tile、padding、随机存储反压、计算暂停、握手后修改输入、13 类非法任务、延迟写确认、读写错误、错误后连续任务、复位与恢复。每个输出逐项比较，同时检查输入和保护区域未被改写。故意破坏 golden 和强制超时探针必须被日志校验器判定为非零失败；XSim 原进程可能在 `$fatal` 后返回 0，不能单独用它的退出码判成功。

日志保存在 `build/team_validation/`，新系统编译来源 SHA256 为 `sources.json`。各 suite 的 `.PASS.txt` 与 `latest_run.json` 记录本次执行；原模块各自的 build 目录保留原有详细审计产物。

## 本轮边界

| 功能 | 本轮整合范围 |
|---|---|
| 单层任务 → 外存 → W4A8 → 写确认 → 完成 | 新统一 AXI 顶层与端到端验证 |
| A/D 原控制、任务导出、运行时 | 保留并回归；bounded task 增加软件适配 |
| C/E requant、dynamic、SwiGLU、FFN bridge、valid 优化核心 | 全部保留；FFN 与 valid 使用原自测回归，统一 AXI 路径仍选 wave 基线 |
| B/F KV cache、tensor dependency/workspace lease | 汇入并独立回归 |
| FFN gate/up/down 跨外存的统一任务调度 | 尚需连接 ffn_bridge 输出 qx/sx 的存储写回、AXI 仲裁和统一 fence 路由 |
| Attention QK/Softmax/AV、RMSNorm/RoPE、完整 Transformer | 原交付尚未具备完整数值/任务图，本轮未新增 |
| FPGA 板级 DDR/PCIe、真实模型、性能/OOC | 不能由 RTL 仿真推定；本轮实际执行情况见验证结果 |

因此当前三人的源代码可以共同维护，单层系统已有贯通入口；完整 FFN/Attention 系统仍需上述后续模块对接。

## 本轮实际执行结果

七类回归全部实际执行并通过：software、team、ad、memory、kv、ce、valid。新入口三种配置合计 60 条完成记录、1,170 个逐项输出比较；golden 破坏与强制超时探针的校验程序均返回 1。软件共 13 项测试通过。B/F 存储四组配置及其失败/超时探针通过；KV 两组配置各 59 条命令，tensor 门禁检查通过。C/E 完整 FFN 自测与 valid 各配置回归通过。既有 C/E 数值 RTL、模型和 TB 与整合前检查点一致。

具体计数和来源信息见 `build/team_validation/integration_summary.json`；日志与退出码均保存在 `build/team_validation/` 及原模块的 build 目录。备份 ZIP 的全部成员已完成 CRC 校验。

新统一顶层已实际通过 VU9P 综合，生成 DCP 与资源报告，见 `build/team_validation/synthesis/`。未执行布局布线、OOC 时序收敛或板级测试。

综合后估计：WNS=+2.287 ns，WHS=-0.066 ns，hold 失败端点 3647。当前未完成时序收敛；综合后的 hold 估计必须由后续布局布线及 hold 修复重新验证，不能宣称已满足板级频率。
