# openTPU / llama-fpga：许可证、补齐范围与三人分工

核查日期：2026-10-13。已通过 GitHub API 获取完整文件树、许可证查询结果，并读取 56 个选定的许可证/文档/源文件；核查副本只放在 build/upstream_review，不接入 DUT。未整仓复制、安装依赖或运行上游仿真/综合。

## 1. 固定版本与许可证结论

| 项目 | 固定 commit | 核查结果 | 本阶段用途 |
|---|---|---|---|
| openTPU | 810632e2e1d4961575a3c6f8f194abc8fc3f8fd3 | 根 LICENSE 为 Apache-2.0；pyproject 同样声明；GitHub license API 确认 | 按条款选择性复用自有源码，先隔离验证再适配 |
| llama-fpga | bdd90206675594ab6b710a32d5319c68a58d9c36 | GitHub repo license=null、license API 返回404；完整非截断文件树2206个文件未发现 LICENSE/LICENCE/NOTICE/COPYING 路径；README与选定源文件未发现授权声明 | 阅读公开架构/论文作设计参考；代码引入等待明确许可 |

openTPU 文件树718个文件，查到根 LICENSE 和 asic/nangate45/openlayout/skills/LICENSE。后者内容是 GPLv3，不属于本次 FPGA 复用范围，不能把仓库每个目录都概括为 Apache-2.0。厂商 IP、外部依赖和模型权重也应分别按其来源确认条款。

Apache-2.0 允许按条款修改、使用和分发；引入时保留许可证及适用的版权/归属声明，修改文件标记修改，存在上游 NOTICE 时按要求保留。现有文件树未找到根 NOTICE。该结论不替代对未来实际引入文件的第三方来源检查。[openTPU LICENSE](https://github.com/FeSens/openTPU/blob/810632e2e1d4961575a3c6f8f194abc8fc3f8fd3/LICENSE)

llama-fpga 目前应称为“公开源码、复用授权未明确”。GitHub 公开可查看/fork，不等同于获得任意修改分发授权；不能凭 README 的 open-source 字样推定 MIT/Apache。上述检查覆盖文件名和选定文本，不保证所有未读取文件都没有特殊授权。[GitHub 许可说明](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository)、[llama-fpga 固定版本](https://github.com/adamgallas/llama-fpga/tree/bdd90206675594ab6b710a32d5319c68a58d9c36)

本次未联系作者；若需要直接引入 llama-fpga 源码，取得明确许可后再决定。

## 2. 哪些内容能补齐当前工程

表中“复用候选”表示许可允许且技术上值得验证，不表示已编译通过或能直接插入。文件路径均来自上述固定版本。

| 当前空白 | openTPU 的实际内容 | 接入方式与差异 | llama-fpga 可参考内容 |
|---|---|---|---|
| A：统一控制 | rtl/seq/otpu_seq.sv、rtl/top/otpu_pkg.sv、rtl/shell/otpu_ctrl.sv；opentpu/host/regs.py | 复用候选：指令/状态/能力查询/依赖管理；当前引擎只有start及tile请求，须添加wrapper与独立W4A8定点格式标识 | top/AxiLiteCtrl.scala、top/StateGen.scala、schedule/MemCmd.scala 的token控制与地址/长度合同 |
| B：外存搬运 | rtl/dma/otpu_dma.sv、rtl/shell/otpu_mem_ch.sv；板级native memory适配 | 复用候选：请求前预留返回空间、有限队列、加载/写回完成跟踪；DMA使用自定义burst/TMEM接口，不能直接称为AXI通用IP；需转成当前64bit/keep packet | util/AXIDataMoverWrapper.scala、cfgGen内存命令/映射；使用厂商DataMover，不是自包含RTL DMA |
| C：内核吞吐 | MXU/预取与供数资料、编译出的FFN流水 | 保留当前已验证4×4/8×8 W4A8阵列，借鉴供数、结果生命周期、预取；完整替换MXU需要重新验证数值/端口 | Decode流式布局、输出缓存/分配思想；不直接移入计算核心 |
| D：软件与模型 | opentpu/isa.py、isasim.py、compiler.py、runtime.py、llm/llama.py；host工具 | 复用候选：张量描述、任务生成、模拟运行、能力/错误管理；先做当前格式的最小后端，不要求完整编译器马上支持本机 | python/model2bin.py、au250/host_sdk.c 与load_param.sh 的导出/加载过程 |
| E：层间与非线性 | rtl/vpu/otpu_quant.sv、otpu_vpu.sv；opentpu/kernels/lib.py、mlp.py | 复用候选：absmax/group量化及Buffer控制，RMSNorm/SiLU/RoPE/残差的组合；FP32数据/scale与本项目Q16.16/UQ4.12不同，须显式转换或按定点规格重实现 | quant/、norm/、rope/、mlp/、residual/模块结构，存在FP16/FP32及Xilinx浮点IP依赖 |
| F：Attention/KV | opentpu/kernels/attention.py、llm/llama.py 等；INT8 KV、分块/在线Softmax、mask与GQA组合 | 复用候选：软件算法/布局/小序列参考；Attention由矩阵/向量指令组成，并非可直接取出的单一Softmax RTL；需动态激活matmul路径 | attn/QKMul.scala、SerialSafeSoftmax.scala、busdemux/KvCacheCase.scala 的Decode数据流 |

复用判断：**以 openTPU 的控制/软件/Buffer机制为主要候选；llama-fpga 先提供完整 Decode 系统的架构参考。当前计算核心继续作为 bit-exact 基线。**

### 三个不能跳过的适配点

1. **数值不兼容。** 我们是 signed INT4 -8..7、UQ4.12双scale、INT64 Q24合并、signed32 Q16.16输出。openTPU的生产4-bit路径是FP4 E2M1与两级scale；TMEM/向量算子使用FP32，激活scale也为FP32。llama-fpga的AWQ导出包含zero-point，转换源把unsigned量化值减zero后送浮点路径。二者均不能直接喂给当前packed INT4入口。[openTPU quant](https://github.com/FeSens/openTPU/blob/810632e2e1d4961575a3c6f8f194abc8fc3f8fd3/docs/quant.md)、[llama转换源](https://github.com/adamgallas/llama-fpga/blob/bdd90206675594ab6b710a32d5319c68a58d9c36/scala/src/main/scala/convert/Int4Int8FP16Conv.scala)
2. **DMA不是现成packet适配器。** openTPU DMA以32bit word、D-byte chunk和TMEM bank工作，读返回不能拒收，因此发请求前占用credit；当前引擎按tile请求接收W/A/sx/sw的64bit packet，必须做地址/stride/打包与背压桥接。写回完成必须等待全部写确认，不能只看out_last。[DMA源](https://github.com/FeSens/openTPU/blob/810632e2e1d4961575a3c6f8f194abc8fc3f8fd3/rtl/dma/otpu_dma.sv)
3. **板级结果不能移植成我们的证据。** openTPU已有Kintex-7板上报告；新BCU1525/VU9P文档说明尚未完成VU9P构建，部分IP检查在xcku5p完成。其平台part为xcvu9p-fsgd2104-2L-e，与本项目临时xcvu9p-flga2104-2L-e不同；不能直接复用管脚/时钟约束。llama-fpga支持KV260/ZCU104/U250且主打Decode，README称没有专门Prefill加速。[BCU1525状态](https://github.com/FeSens/openTPU/blob/810632e2e1d4961575a3c6f8f194abc8fc3f8fd3/docs/bcu1525.md)、[llama README](https://github.com/adamgallas/llama-fpga/blob/bdd90206675594ab6b710a32d5319c68a58d9c36/README.md)

另外，openTPU ISA文档的顺序完成描述与当前seq源的并发窗口应结合阅读：RTL按内存范围记录RAW/WAR/WAW依赖，可重叠独立单元，HALT等窗口排空，目标是保持顺序执行的结果语义。首版适配仍采用单活动W4A8任务，先不引入完整scoreboard复杂度。[seq源](https://github.com/FeSens/openTPU/blob/810632e2e1d4961575a3c6f8f194abc8fc3f8fd3/rtl/seq/otpu_seq.sv)

rtl/mem/otpu_dram.sv 自注释为 behavioural simulation DRAM，包含大数组模拟并行端口；它只能用作参考模型，不能借此宣称有真实DDR或无限端口片上RAM。

## 3. 三人重新分工：围绕可复用模块

按三人包含你安排。A–F范围保留，工作重心由“所有外围从零做”调整为“隔离上游候选，建立适配层”；下表是建议分工，尚未发送给外部队友。

| 人员 | 首轮职责 | 重点阅读/复用候选 | 首个交付 |
|---|---|---|---|
| 你：C/E | 当前内核与数值合同owner；group输出、后处理/输出FIFO、层间requant适配 | openTPU quant/VPU与kernels/lib.py、mlp.py；llama非线性结构仅参考 | 当前输出→INT8/sx的最小位精确参考与自检模块；明确后续FP32桥接成本 |
| 队友1：A/D | 控制wrapper、tensor/task格式、最小软件后端、系统集成 | openTPU pkg/seq/ctrl、isa/isasim/runtime/compiler；llama token调度与导出流程仅参考 | 一条带地址/stride/format的W4A8任务，由软件提交、完成后读取结果；非法格式拒绝 |
| 队友2：B/F | 先外存请求/packet桥；再KV布局与Attention集成 | openTPU dma/mem_ch、attention.py与llama模型；llama DataMover/KV结构仅参考 | 有限缓冲仿真内存→当前packet入口→结果写回，带暂停、尾块和写确认 |

各人先验证一个小闭环；共享内核只由你修改，统一顶层由队友1维护，存储桥由队友2维护。实际引入代码保留固定commit、源路径、许可证、修改记录，不把build核查副本当作生产vendor目录。

### 先做与后做

- **第一轮：** 队友1提交任务、队友2供数/写回、你提供稳定计算接口；三人跑单任务和连续两任务闭环。你的requant可独立并行，不阻塞最初的单层写回。
- **第二轮：** 两层串联及小FFN。你负责requant/逐元素/SiLU，队友1编译图与参考，队友2搬运中间张量。
- **第三轮：** Attention/KV。队友2主责KV和接线，你负责动态矩阵/归约/Softmax算子，队友1主责Prefill/Decode参考与任务。F不是全部压给队友2。
- 验证是每人的交付条件；板级仍待实际板卡确认。真实模型权重和厂商IP按各自来源处理。

共同验收：输出与本项目参考一致；输入/输出暂停持稳、连续任务/复位通过、尾部不越界；报告实际周期/流量。代码是否能编译/综合须实际执行后才标记通过，Apache许可或上游文件存在不代表通过了技术验证。

## 4. 已执行与未执行

**已执行：** GitHub元数据/完整树查询、license API查询、56个选定文件下载与SHA256记录、关键接口/数值/依赖阅读。总核查副本约1.22MB，manifest pass=true。

**未执行：** 上游完整代码/所有第三方依赖审计、上游VCS/Verilator/XSim、移植后的综合、实际模型下载、上游代码接入当前RTL、板上验证。本次当前RTL未修改，原验证结果不作为上游适配成功证据。

证据：[下载与源码清单](../build/upstream_review/review_manifest.json)、[openTPU许可证查询](../build/upstream_review/openTPU_license.json)、[llama许可证查询](../build/upstream_review/llama-fpga_license.json)、[固定文件树](../build/upstream_review/llama-fpga_pinned_tree.json)。

复现核查（网络可用时）：
~~~powershell
Set-Location E:\speed-up
python .\scripts\review_upstream.py
~~~

脚本固定版本、只保存选择性核查副本；任何下载失败返回非零。不启动上游工具链、不修改全局环境。
