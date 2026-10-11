#!/bin/zsh
# Régénère les audios du banc franglais avec la voix française de macOS (Thomas, 16 kHz mono).
set -euo pipefail
cd "$(dirname "$0")/.."
dir=Tests/Fixtures/franglais
python3 - "$dir" <<'PY'
import json, subprocess, sys
d = sys.argv[1]
for case in json.load(open(f"{d}/cases.json"))["cases"]:
    subprocess.run(["say", "-v", "Thomas", "-o", f"{d}/audio/{case['id']}.wav", "--data-format=LEI16@16000", case["text"]], check=True)
    print(case["id"])
PY
