#!/usr/bin/env bash
# Unverified with VCS: Linux/WSL installation and a valid license are required.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
VCS_BIN="${VCS_BIN:-vcs}"
PYTHON="${PYTHON:-python3}"
if ! command -v "$VCS_BIN" >/dev/null 2>&1; then
  echo "VCS_NOT_FOUND: configure VCS_BIN to an existing Linux VCS executable" >&2
  exit 2
fi
"$PYTHON" "$ROOT/model/w4a8_reference.py" --out "$ROOT/build/w4a8_vectors"
configs=("overlap_pipe:tb_w4a8_post:32" "serial:tb_w4a8_post_serial:32" "pipe_serial:tb_w4a8_post_pipe_serial:32" "scalar_overlap:tb_w4a8_post_scalar_overlap:32" "alt:tb_w4a8_post_alt:12" "single:tb_w4a8_post_single:32" "one:tb_w4a8_post_one:32")
if [[ -n "${TB_TOP:-}" ]]; then configs=("custom:$TB_TOP:${GROUP_SIZE:-32}"); fi
sources=("$ROOT/rtl/sync_sdp_ram.sv" "$ROOT/rtl/mac_pe.sv" "$ROOT/rtl/mac_array.sv"
         "$ROOT/rtl/w4_unpack.sv" "$ROOT/rtl/w4a8_post.sv"
         "$ROOT/tb/w4a8_packed_memory.sv" "$ROOT/tb/tb_w4a8_post.sv")
for entry in "${configs[@]}"; do
  IFS=: read -r name top group <<< "$entry"
  work="$ROOT/build/vcs_w4a8_post_$name"
  mkdir -p -- "$work"
  cp -- "$ROOT/build/w4a8_vectors/group$group.txt" "$work/vectors.txt"
  cd -- "$work"
  rm -f -- PASS.txt
  command=("$VCS_BIN" -full64 -sverilog -timescale=1ns/1ps -top "$top" "${sources[@]}" -o "$work/simv")
  printf '%q ' "${command[@]}" > commands.txt
  printf '\n' >> commands.txt
  "${command[@]}" 2>&1 | tee compile.log
  printf '%q\n' "$work/simv" >> commands.txt
  ./simv 2>&1 | tee run.log
  if ! grep -q W4A8_POST_TESTS_PASS run.log || grep -Eq 'W4A8_POST_CHECK_FAILED|W4A8_POST_GLOBAL_TIMEOUT|Fatal|Error-\[' run.log; then
    echo "VCS_SIMULATION_FAILED: $work" >&2
    exit 1
  fi
  printf 'PASS\n' > PASS.txt
done
echo W4A8_POST_VCS_VALIDATION_PASS
