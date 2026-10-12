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
configs=("4x4_k8_g32_db:tb_w4a8:32" "2x3_k5_g12_db:tb_w4a8_alt:12" "4x4_k8_g32_single:tb_w4a8_single:32")
if [[ -n "${TB_TOP:-}" ]]; then configs=("custom:$TB_TOP:${GROUP_SIZE:-32}"); fi
sources=("$ROOT/rtl/sync_sdp_ram.sv" "$ROOT/rtl/mac_pe.sv" "$ROOT/rtl/mac_array.sv"
         "$ROOT/rtl/w4_unpack.sv" "$ROOT/rtl/w4a8_linear.sv"
         "$ROOT/tb/w4a8_memory_model.sv" "$ROOT/tb/tb_w4a8.sv")
for entry in "${configs[@]}"; do
  IFS=: read -r name top group <<< "$entry"
  work="$ROOT/build/vcs_w4a8_$name"
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
  if ! grep -q W4A8_TESTS_PASS run.log || grep -Eq 'W4A8_CHECK_FAILED|W4A8_GLOBAL_TIMEOUT|Fatal|Error-\[' run.log; then
    echo "VCS_SIMULATION_FAILED: $work" >&2
    exit 1
  fi
  printf 'PASS\n' > PASS.txt
done
echo W4A8_VCS_VALIDATION_PASS
