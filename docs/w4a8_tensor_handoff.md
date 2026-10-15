# 两层线性 / 小型 FFN：存储侧依赖与工作区

本轮检查本地及 GitHub main，均为 `2e56af8bbee1fe6e806217e6f729a4984d8cb262`。原 B 工作包未提交代码及实际验证完整保留。当前仓库未提供负责人 requant/SiLU/SwiGLU 模块，也未提供队友1公共任务合同。因此本轮实现 `rtl/w4a8_tensor_dependency.sv`，独立验证工作区校验、任务依赖和占用期；**没有用自行编写的 quantizer 或占位计算替代负责人的模块，没有完成两层数值闭环或 FFN 数值集成。**

## 1. 数据流及地址

```text
第一层 B 写回 Q16.16 Y → producer_fence(success)
  → 向真实 requant 发出带地址/stride/shape 的请求
  → requant 写回下一层 signed INT8 A 和 UQ4.12 sx
  → requant_fence(success，全部写确认)
  → 下一层原 B memory_task_t 提交握手
  → consumer_fence(全部访问排空)
  → 释放此工作区计划 / 完成记录
```

控制端提供 `plan_next_task`（原存储侧 `memory_task_t`），`plan_producer_id`、`plan_requant_id`，以及 `plan_source_base/stride/bytes`。假设下一层逻辑 `M×N×K`，前一级中间结果为 `M×K`：

```text
raw_Y[m,k] = source_base + m*source_stride + 4*k
next_A[m,k] = next_task.a_base + m*next_task.a_stride + k
next_sx[m,g] = next_task.sx_base + m*next_task.sx_stride + 2*g
G = ceil(next_task.k / GROUP_SIZE)
```

RAW Y 是 little-endian signed32 Q16.16，源基址/stride 必须4字节对齐，stride≥4K，extent `(M-1)*stride+4K` 必须落在 source_bytes 内，base+bytes≤2^32。下一层全部区域/格式/group/capacity 使用原 B 校验器；A/sx 两个写入区互不重叠，不能覆盖 raw Y、下一层 W 或 sw。原 Y 可与下一层 Y 输出区复用，但必须等 requant 全部读取和写确认完成后才启动下一层。其他活跃任务的跨计划别名由统一调度/分配器检查，本模块没有全局内存分配器。

最低有效容量：raw=4MK 字节；A=MK 字节；sx=2MG 字节。非紧密布局按 extent 分配，不把 padding 算作有效数据。RQ fence 的 `requant_activation_written` 必须为 MK，`requant_scale_written` 为2MG，两者均是**实际有效字节的成功写确认数量**，不是分配长度或输入接收数。

## 2. 接线与生命周期

- `plan_valid/ready` 接受一次完整计划，锁存全部字段；单活动计划，硬件 GROUP_SIZE 固定且与下一层 B 引擎一致。三个 task ID 必须不同。
- `producer_fence_*` 是从原 B completion 复制/路由来的已写确认通知。匹配 ID 且 status=0 才发 `requant_request_valid`。禁止拿 core done、out_last 或最后 W 当 fence。
- RQ 请求输出源地址/stride/bytes、A/sx目标地址/stride/bytes、rows=M、dimensions=K、group_size。请求接受前保持 payload；由负责人真实 requant 的接入层映射，当前没有共同 requant 数据通道 ABI。
- `requant_fence_*` 必须来自真实 requant 及其存储写回路径，且它已停止/排空该任务的所有读写。匹配 ID、status=0、字节数正确后置 `next_task_valid`，其描述符持稳到 next_task_ready。
- 下一层接受后进入 WAIT_CONSUMER；即使 next_task_valid 已撤销，也不接受新 plan、不释放此中间 A/sx 工作区。匹配下一层 task_id 的 consumer_fence 表示原 B 已停止并排空所有访问，才产生此计划的 completion。status 镜像该 fence；它不是内部计算预测的完成信号。
- completion背压时保持 ID/status。生产者、RQ或消费者错误阻止后续未启动阶段；错误通知必须已经排空对应路径，控制端按整条链失败处理。错误前的部分写入不能作为合法中间张量使用。
- 三类 fence 输入是**独立路由的通知副本**，ready 时可消耗不匹配 ID 的副本并忽略；不直接接共享 completion FIFO 的唯一消费端。队友1应先记录主任务完成，再正确路由/复制通知。当前活动任务期间不重用 ID；复位须清通知队列。
- 共同复位覆盖门禁、B、负责人 requant、调度/通知和外存 fabric；撤销计划。门禁单独复位不能撤销外部还在写的 requant，不能据此安全复用区域。

## 3. 两层和 FFN 对齐项

队友1需提供公共 task/tensor 格式、生产者输出尺寸与下一层输入绑定、buffer ID/允许范围、任务 ID与依赖、内存 owner及 AXI 仲裁。此模块当前使用存储侧 task struct，不定义主机序列化 ABI。必须保证第一层 M=下一层 M、第一层 N=下一层 K；通知只有 ID/status，不能自行验证生产者实际输出形状。

负责人需提供 Q16.16→INT8/sx 的真实模块、group/scale 规则、源/目标 stream 和 last/keep/坐标约定、舍入/饱和/错误合同、全部写确认后的 fence。当前模块不做数值变换，不把 Q16.16 bytes直接当 INT8喂下一层。

小型 FFN还需真实 SiLU/SwiGLU/逐元素乘、gate/up/down分支结果格式和依赖、源张量选择、scratch复用时机、位精确软件参考。可为每条已存在的实际数值边重复使用同一个门禁；门禁自检中三次 next-task握手仅验证生命周期，不代表已经运行两层或 FFN计算。

真实接线准备好后，应增加“两层每个输出与负责人参考一致”和“FFN分支完成顺序/别名/错误传播”的系统自检。本轮交付的地址与 fence 门禁无需改动计算核心、数值模块或统一调度顶层。
