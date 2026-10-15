# C/E 接续：有效槽变体收尾

提示词3独立实现及实际器件/回归已完成。`run_w4a8_valid.ps1 -SynthOnly -Implement -Regression`在2026-10-14实际退出0，最终`W4A8_VALID_ARTIFACT_AUDIT_PASS`和`W4A8_VALID_VALIDATION_PASS`均通过。本轮用户随后要求优先补齐结构，FFN顺序基线见 [FFN接续](session_handoff_ce_ffn.md)，不自动把有效槽版本替换进FFN。

入口 `rtl/w4a8_valid.sv`，默认VALID_ONLY=1，VALID_ONLY=0是全槽消融；原w4a8_wave/数值golden/测试保持。canonical slot地址仍row×COLS+col，RAM容量仍RC，仅跳过无效槽init、save、post及output读；物理PE、W4 decode和packet协议不变。详见 [架构](w4a8_valid_architecture.md)、[实际验证](w4a8_valid_validation.md)、[性能对照](w4a8_valid_performance.md)、[delivery](../build/w4a8_valid_delivery.json)。

八配置含4×4、8×8、2×3/group12、1×1、单bank、tile19、full-slot 4/8消融。合计413任务、11823输出、38097组检查、27109358自检项。两次预期失败（错误golden、强制watchdog）实际脚本退出1。独立monitor审计同步psum/Y读、宽累加、RAW、snapshot所有权、有效槽访问、暂停/背压/复位；每任务slots.csv与独立Python地址预算及总周期闭式逐项闭合。full-slot两个配置所有CSV字段与原g4/g8完全一致。

| 阵列 | 综合LUT/FF | DSP | RAMB36/RAMB18 | OOC WNS/WHS ns | 完整路由 |
|---|---|---:|---|---|---|
| 4×4 | 2921/2436 | 21 | 5/2 | +4.482/+0.015 | 5853/5853 |
| 8×8 | 4592/3906 | 69 | 9/2 | +3.872/+0.011 | 10345/10345 |

均latch/blackbox/URAM=0，route error=0，内部setup/hold失败端点0，1个OOC边界gap；LUTRAM实际160/364。4×4/8×8分别178/116条警告，含未使用寄存器删除、常量接口位、OOC DRC/route边界；原文、RAM/DSP映射、timing/DRC/DCP在各synth_w4a8_valid_v*/。10ns内部OOC、VU9P临时评估part，板卡未确认；不能作为板上频率或完整系统时序证据。

性能对照仍保留。连续供数的1×13×96：4×4 1003→697，8×8 1139→449；4×12×96：4×4 829→829，8×8 1215→735；8×16×96：2209/1403不变；9×11×67：4×4 2080→1810，8×8 2305→1363。模式2中8×8的8×16×96退化12拍，单bank两用例退化30/3拍，均真实记录；暂停/预取窗口相位改变，不能只减无效slot推断总周期收益。

统计接口差异：psum_groups仍为物理快照数，post_issue/retire现在计真实有效操作，完整任务为MN×ceil(K/G)。其余数值/输出m/n/data/last协议保持。需要队友或性能脚本同步更新该统计合同。

```powershell
# 完整复现
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_valid.ps1 -Implement -Regression
# 当前源码已有仿真后仅跑器件与回归（本轮实际命令）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_valid.ps1 -SynthOnly -Implement -Regression
# 审计/只读生成器一致性
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_w4a8_valid.ps1 -AuditOnly
python .\scripts\create_valid_variant.py --check
```

首次器件流程先前被会话中断，检查无存活工具后重跑本轮完整VU9P流程，不用旧中断日志作新增成功证据。生成器补齐FORCE_TIMEOUT变换并只读确认当前valid RTL/TB逐字一致；正常验证从不调用生成器，不覆盖原wave或golden。原W4A8八配置和dynamic四配置/探针实际回归通过。

按照新的结构优先指示，接下来FFN沿用原wave稳定功能基线，输出FIFO/有效槽FFN替换留后续性能轮。完整Transformer结构还需RMSNorm/残差/RoPE/Attention数值通路和队友统一系统/KV接入。
