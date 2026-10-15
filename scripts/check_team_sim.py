"""XSim may return zero after $fatal; require a clean, completed test log."""
from pathlib import Path
import re
import sys

raw = Path(sys.argv[1]).read_bytes()
log = raw.decode('utf-16' if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else 'utf-8-sig', errors='replace')
if re.search(r'Fatal:|TEAM_CHECK_FAILED|TEAM_.*TIMEOUT|^ERROR:', log, re.M):
    sys.exit('TEAM_SIMULATION_FAILED: simulator reported an assertion/error')
if 'W4A8_TEAM_TESTS_PASS' not in log:
    sys.exit('TEAM_SIMULATION_FAILED: completed test marker missing')
print('TEAM_SIMULATION_LOG_PASS')
