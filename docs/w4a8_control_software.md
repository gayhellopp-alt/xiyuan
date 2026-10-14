# W4A8 control and software interface

This first system wrapper accepts one task at a time and connects the validated `w4a8_stream` core to an external memory adapter. The adapter owns actual memory reads and writes; this block supplies stable task metadata, forwards tile requests and packets, and waits for each output write acknowledgement before allowing the next output.

## Descriptor

`rtl/task_desc_pkg.sv` defines packed `task_desc_t`:

| Field | Meaning |
|---|---|
| `task_id` | Host supplied 32-bit completion tag |
| `m`, `n`, `k` | Logical GEMM dimensions |
| `a_addr`, `w_addr`, `sx_addr`, `sw_addr`, `y_addr` | 64-bit byte base addresses |
| `a_stride`, `w_stride`, `sx_stride`, `sw_stride`, `y_stride` | Byte row/group strides |
| `activation_format` | `1`: signed INT8 |
| `weight_format` | `1`: row-major output-channel signed INT4, low nibble first |
| `scale_format` | `1`: unsigned UQ4.12 |
| `output_format` | `1`: signed INT32 Q16.16 |
| `group_size` | Must equal elaborated `GROUP_SIZE` (default 32) |
| `flags` | Must be zero in this version |

Layouts: A is `[M][K]`, weight is `[N][ceil(K/2)]`, activation scale is `[M][groups]` of little-endian uint16, weight scale is `[groups][N]` of little-endian uint16, and output is `[M][N]` of signed 32-bit values. A/W/Y strides must cover one logical row; sx stride must cover `groups*2`; sw stride must cover `N*2`; y stride must be at least `N*4`. Scale addresses are 2-byte aligned and output address 4-byte aligned. Group tail handling stays inside the core; software must not split K into independently rounded tasks.

## Handshakes and completion

Submit a descriptor with `task_valid`; it is accepted when `task_ready` is high. On acceptance the controller validates all fields and snapshots the descriptor. Invalid tasks return a held completion with a nonzero status and do not start the core. While a task is active, `task_ready` remains low.

`mem_req_valid/ready` forwards the core's tile request. Request metadata includes M/N/K tile origins, valid extents, group index, and whether scale packets follow. The adapter uses the latched base addresses and strides to fetch the tile and returns 64-bit packets plus byte `keep` through `mem_in_valid/ready`. `load_pause` is passed through to the core's packet pause.

Each result is exposed on `mem_wr_valid`, with task ID, row/column, byte address `y_addr + row*y_stride + column*4`, Q16.16 data and `last`. The write request remains stable while `mem_wr_ready` is low. After the adapter accepts it, no next output is accepted until `mem_wr_ack` arrives. Completion status is held while `completion_valid` is high and clears when `completion_ready` is asserted. `result_available` is high only for a successful completion, after every output write acknowledgement.

`elapsed_cycles` counts controller active/wait cycles. `TIMEOUT_CYCLES` covers launch, core progress, and write acknowledgement wait. On timeout, the controller resets the core, suppresses the result and returns status 9. Reset clears controller state and the core, so prior result availability is removed.

## Status values

| Code | Meaning |
|---:|---|
| 0 | Success |
| 1 | Invalid dimensions |
| 2 | Unsupported format |
| 3 | Invalid/unaligned address |
| 4 | Invalid byte stride |
| 5 | Group size mismatch |
| 6 | Unsupported flags |
| 7 | Core error |
| 8 | Write acknowledgement/protocol error |
| 9 | Timeout |

## Software backend

`software/w4a8_task.py` builds and validates descriptors, and tiles oversized M/N dimensions while keeping K whole. `w4a8_runtime.py` provides a transport-neutral submit/poll/wait/read API. Supply a transport implementing `write_descriptor`, `ring_doorbell`, `read_completion`, and `read_tensor`. `export_w4a8_model.py` emits a JSON manifest for already quantized buffers; floating-point quantization/export is intentionally not claimed by this initial backend. `w4a8_reference.py` follows the repository's modulo-2^32 group accumulation, UQ4.12 scales, modulo-2^64 group accumulation, Q16.16 rounding and saturation.

## Verification

Run `powershell -ExecutionPolicy Bypass -File scripts/run_w4a8_system.ps1` for the RTL system test. Run `python -m unittest software.test_w4a8_software` from the repository root for descriptor, tail tiling, runtime and reference checks. The RTL integration keeps one outstanding output write and expects the memory adapter to acknowledge every accepted write exactly once.
