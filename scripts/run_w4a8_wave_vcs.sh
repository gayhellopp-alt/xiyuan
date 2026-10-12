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
"$PYTHON" "$ROOT/model/w4a8_systolic_vectors.py"
configs=("g4:tb_w4a8_wave:32" "g8:tb_w4a8_wave8:32" "t4:tb_w4a8_wave_tile4:32" "t8:tb_w4a8_wave_tile8:32" "alt:tb_w4a8_wave_alt:12" "words8:tb_w4a8_wave_words8:32" "single:tb_w4a8_wave_single:32" "one:tb_w4a8_wave_one:32")
if [[ -n "${TB_TOP:-}" ]]; then configs=("custom:$TB_TOP:${GROUP_SIZE:-32}"); fi
sources=("$ROOT/rtl/sync_sdp_ram.sv" "$ROOT/rtl/mac_pe.sv" "$ROOT/rtl/mac_array.sv"
         "$ROOT/rtl/systolic_pe.sv" "$ROOT/rtl/systolic_array.sv" "$ROOT/rtl/w4_unpack.sv" "$ROOT/rtl/w4a8_wave.sv"
         "$ROOT/tb/w4a8_reuse_memory.sv" "$ROOT/tb/tb_w4a8_wave.sv")
for entry in "${configs[@]}"; do
  IFS=: read -r name top group <<< "$entry"
  work="$ROOT/build/vcs_w4a8_wave_$name"
  mkdir -p -- "$work"
  cp -- "$ROOT/build/w4a8_systolic_vectors/group$group.txt" "$work/vectors.txt"
  cd -- "$work"
  rm -f -- PASS.txt
  command=("$VCS_BIN" -full64 -sverilog -timescale=1ns/1ps -top "$top" "${sources[@]}" -o "$work/simv")
  printf '%q ' "${command[@]}" > commands.txt
  printf '\n' >> commands.txt
  "${command[@]}" 2>&1 | tee compile.log
  printf '%q\n' "$work/simv" >> commands.txt
  ./simv 2>&1 | tee run.log
  if ! grep -q W4A8_WAVE_TESTS_PASS run.log || grep -Eq 'W4A8_WAVE_CHECK_FAILED|W4A8_WAVE_GLOBAL_TIMEOUT|Fatal|Error-\[' run.log; then
    echo "VCS_SIMULATION_FAILED: $work" >&2
    exit 1
  fi
  printf 'PASS\n' > PASS.txt
done
echo W4A8_WAVE_VCS_VALIDATION_PASS
