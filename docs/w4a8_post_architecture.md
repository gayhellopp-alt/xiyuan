# W4A8 独立 group 后处理

本轮独立顶层w4a8_post保留列对输入布局、INT4解包、原MAC阵列与数值合同；增加两组INT32 psum snapshot及独立scale流水。旧w4a8_packed/stream/linear保留，控制模块暂时增量复制，未接旧NPU任务队列。

~~~mermaid
flowchart LR
  L["64bit列对packet"] --> O["A/W operand ping-pong"]
  O --> C["广播MAC阵列<br/>组内INT32累加"]
  C --> P0["psum bank0<br/>32bit同步RAM"]
  C --> P1["psum bank1<br/>32bit同步RAM"]
  P0 --> S["独立scale流水"]
  P1 --> S
  T["每bank的sx/sw<br/>坐标/组tag FF"] --> S
  S --> Y["64bit Q24输出累加RAM"]
  Y --> R["Q16.16舍入/饱和<br/>valid/ready"]
~~~

## 配置与接口

参数POST_OVERLAP=1允许下一group计算与上一group后处理重叠；为0时每组保存后等待后处理完成。POST_PIPELINE=1每enabled clock issue一个slot，为0时每3个enabled clock issue一个slot。两组psum bank固定，均保留在所有消融配置中。

新增post_pause：高时冻结全部后处理状态、valid/tag/data、issue gap，禁止psum/Y读和Y写。计算与输入加载继续，直到可用psum bank耗尽再停顿。生产者若不能交付，保留PE内完成group的sum，不会清PE、写被占用bank或丢group。低后恢复同一个流水事务。reset仍优先同步中止整个任务，并要求外部源同步reset。

输出总任务状态、输入req/scale/data/keep、输出valid/ready合同不变。输入layout见w4a8_packed_architecture.md，数值见w4a8_numerics.md。没有AXI、CDC或真实DMA。

## 两种bank生命周期

Operand bank：FREE→LOADING→READY→COMPUTING→FREE。
group末tile完成MAC后进入WAIT_PSUM，只有目标psum bank FREE才捕获descriptor与scale；SAVE_G逐拍写RC个PE sum，最后一拍将psum bank READY并释放operand bank。因此后续加载可以在scale工作时复用原operand bank。

Psum bank：P_FREE→P_WRITING→P_READY→P_SCALING→P_FREE。
- producer/consumer各1bit交替指针，按group顺序消费，容量2。
- P_WRITING时32bit单写端口逐slot保存，地址r*COLS+c。
- descriptor FF含tile m/n、group、有效ml/nl及每行sx/每列sw。合法lane完整复制；尾lane scale写0。
- snapshot完毕才READY，descriptor稳定到最后一次后处理写回。
- 下一group首tile才清原PE；保存阶段仍需RC拍，没有双PE阵列。
- 最后slot退休后FREE，指针交替。若同拍释放与等待，producer下一拍看到FREE，保留显式同步握手周期。

每psum RAM单同步读/单写，没有多端口数组。两bank可一组写、一组读；不会同拍对同bank多地址写入。scale/tag FF可以并行复制，但不是大容量多端口RAM。

## Scale流水与RAM时序

对一个slot s，在三个上升沿：

| 拍 | 操作 |
|---|---|
| E0 issue | 同步读psum和旧Y[s]，寄存factor=sx×sw与tag0=s |
| E1 multiply | 读上拍RAM q/factor，寄存signed64 scaled、Ybase及tag1 |
| E2 retire | 将Ybase+scaled写回Y[tag1] |

无暂停时PIPELINE1连续E0 issue下个slot，形成II=1；每group RC个slot共RC+2拍活动。默认RC16对应18拍。PIPELINE0在issue后加2个enabled空拍，II=3，对应3RC拍活动。暂停冻结整个pipe，不重复写回；RAM q在rd_en=0保持，恢复后操作原事务。

psum32×unsigned32factor以signed65表达，截取符号冗余位存signed64，规则与旧版相同。合并所有group之后才一次舍入、饱和Q16.16。缩放顺序按group FIFO，不提前统一应用不同scale。

只有一个group在scale流水内，等最后slot写回后才取下一group，因此同一Y地址下次读取发生在前组写回之后。即使RC=1，也不会读取尚未更新的Y。一个group内每slot仅一次读写。

## 输出RAM所有权与任务顺序

输出RAM仍为单读/单写：
- INIT_Y：compute每输出tile写RC个0，此时post没有可处理group。
- post：issue同步读、retire同步写，可同拍读/写不同slot。
- OUT_REQ：最后group写回后才读取最终Y，和post issue互斥。
- 末group保存后compute进入WAIT_POST，检查本tilegroups_scaled>wait_group才输出。
- 所有有效输出接受后才初始化下一M/N tile，输出tile间没有重叠，Y不需额外buffer。

groups_scaled在每输出tile INIT_Y slot0清零，在最后slot retire加1。psum指针不必每tile清零；上一tile所有group已消费，指针保持同相空队列。新任务/reset清指针、ownership与流水valid；不清物理RAM，靠完整写入和输出初始化消除旧值。

## 性能统计

旧指标保持。新增：
- psum_groups：完整snapshot交付数量。
- post_issue_cycles/post_retire_cycles：发读/写回slot数，包括物理尾槽0。
- post_active_cycles：P_STREAM状态拍数，包括post_pause。
- compute_post_overlap_cycles：RUN且P_STREAM，是RUN子集，也包含post暂停。
- psum_wait_cycles：WAIT_PSUM且producer目标bank非FREE。
- post_drain_cycles：compute WAIT_POST拍数，包含组末依赖和后处理暂停。

RUN、input_wait、output_wait、psum_wait、post_drain互斥；active/overlap不能加入这些分类重复相加。32bit计数每合法start清零，done后保持，极长暂停可回绕。流水并未减少有效MAC或改变输入有效字节。

## 验证与当前边界

七组合含串行、只流水、只重叠、流水重叠、2×3/group12、单operand bank、1×1阵列。强制冻结post直到两bank满，恢复后比较所有结果；另在pipe非空时复位，再执行非零任务。模式2也周期暂停post；与旧模式2条件不同。

默认器件综合/OOC证据见w4a8_post_validation.md；RAM_STYLE不等于实际映射。其他参数/最大逻辑尺寸未验证。输入外存模型仍独立TB，不代表DDR。A复用、输出tile重叠、深输出FIFO、NPU描述符适配、脉动阵列、bias/INT8 requant/完整Transformer尚未实现。
