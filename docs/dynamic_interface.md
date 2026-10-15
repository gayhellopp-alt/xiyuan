# 动态 requant 接口与Buffer所有权 v1

独立可综合顶层为 `requant_dynamic`，默认GROUP_SIZE=32、MAX_K=4096。原`requant_group`仍可用于外部scale对照。新增接口与该基线保持相同row/group/K/len、输入/输出握手概念，但移除cfg_scale，增加group_absmax与scale_clipped。它没有与统一DMA/描述符系统直接接线。

| 端口 | 合同 |
|---|---|
| clk/rst | 上升沿同步；rst同步高有效并组合屏蔽三个握手使能 |
| cfg_valid/cfg_ready | 单活动row/group描述符握手，busy时不接受替换 |
| cfg_row/cfg_group/cfg_k/cfg_len | unsigned16；第二层激活row/K-group标签、总K及严格有效尾长度 |
| in_valid/in_ready/in_data | 逐标量signed32 Q16.16；未握手时上游保持valid/data |
| in_pause | 只冻结COLLECT接收；不暂停已完成收集后的scale/quant/发送 |
| out_valid/out_ready/out_data | signed8结果；数据与所有元数据背压持稳 |
| out_row/out_group/out_index/out_scale | unsigned16；原标签、组内0..len-1下标、编码后的sx；scale每beat重复 |
| out_last | 本组最后有效元素，不能当作全张量last或写回完成 |
| out_saturated/group_saturated | 当前元素饱和/本组已产生输出饱和OR；整组标志包含当前可见输出，最终接受后保留 |
| scale_clipped | candidate超unsigned16范围时置1，至下一描述符或rst；发送阶段持稳 |
| group_absmax | unsigned32编码A，收集期间递增，输出期间固定；可包含INT32_MIN幅值2^31 |
| busy/done/error_code | 单活动组所有权；最终输出接受后done单拍；非法描述符也done且error_code=2；错误保持至下一描述符或rst |

## 有限同步Buffer

每实例只含一个GROUP_SIZE×32 Buffer，使用现有`sync_sdp_ram`，请求block映射；有一个同步写端口和一个同步读端口，无异步多端口数组。实际BRAM/LUT/DSP映射见工具报告。

生命周期为IDLE → COLLECT → SCALE_DIV(32拍) → SCALE_SET → QCFG → READ_REQ/READ_SEND/WAIT_OUT循环 → IDLE。COLLECT每次握手写一个有效标量，更新absmax；最后写完成后禁止新数据和新描述符。求scale阶段不读RAM。QCFG将已确定的scale交给原scalar。

READ_REQ边沿触发同步读，RAM输出在该边沿后更新；READ_SEND保持该数据直到scalar接受；随后只等待量化结果/输出背压。下一RAM读仅在上一元素输出已接受后发出。任何时刻不会同时读写group Buffer，最多一个标量在scalar/结果槽中，未接受的末输出不会释放组或覆盖Buffer。

rst清控制、标签、scale与状态，不清RAM内容。新组必须重新写满本组len个槽再读，因此旧RAM数据不会因复位或短尾组泄露；无效尾槽不读、不量化、不输出。既不收集下一组，也不进行双组重叠。

无暂停/背压时，最后一个收集输入接受到第一输出接受70拍；后续输出接受间隔36拍，包括同步RAM读控制。描述符接受到最后输出接受为37×len+34拍。该公式由单元TB逐组核对；组之间还有描述符握手开销。实际周期CSV包含输入间断和长背压，不将内部目标时钟推导为真实板上吞吐。

## 两层TB与队友边界

`tb/vector/tb_w4a8_two_layer.sv`使用两个未经修改的4×4 `w4a8_wave`。第二层GROUP_SIZE=32时第一层为12，反之为32，验证group命名空间及scale独立。第一层输出tile次序不是row-major：TB按out_m×第二层K+out_n写入512×32有限同步适配存储；全部坐标收齐后，按第二层row/group顺序逐字同步读取，再送入动态模块。

适配器每元素4字节写/4字节读；模块group Buffer另有4字节写/4字节读；量化结果每元素1字节、sx每row/group2字节。qx和sx按接受输出的标签写入第二层packet供数模型的有限数组；同组sx仅保存一次。第二层sw从独立参考向量加载，不使用第一层sw或group编号。全部qx/sx确认初始化后才启动第二层。

这个坐标适配器和packet源属于TB验证环境，未声明为可综合外存/DMA或统一两层系统；本轮综合的是动态模块及其scalar/group RAM。当前系统采用分阶段fence，不重叠第一层收集与requant或第二层计算。实际RTL跨层集成的地址/stride、任务ID、返回缓冲和写确认由队友1/2维护。done/out_last不表示writeback_committed。

TB比较第一层Q16.16、动态qx/sx/absmax/clip/sat、第二层Q16.16及两层每组psum/scaled快照；用有限端口适配器读取并检查坐标初始化。覆盖零/超范围、不同scale、多组/尾组/尾tile、输入/array/post暂停、输出背压、连续任务，以及第一层RUN、动态收集/scale/输出持稳、第二层RUN/输出持稳六种阶段复位并恢复。
