#!/bin/sh
set -eu
fpt_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -n "${FPT_PYTHON:-}" ]; then
    fpt_python=$FPT_PYTHON
else
    if [ ! -x "$fpt_root/.venv/bin/python" ]; then
        if ! python3 -m venv "$fpt_root/.venv"; then
            echo '无法创建虚拟环境。请安装 python3-venv 后重试，或用 FPT_PYTHON 指定已有环境。' >&2
            exit 1
        fi
    fi
    fpt_python="$fpt_root/.venv/bin/python"
    if ! "$fpt_python" -c 'import numpy, torch, transformers, accelerate' >/dev/null 2>&1; then
        "$fpt_python" -m pip install -r "$fpt_root/requirements.txt"
    fi
fi
exec "$fpt_python" -u "$fpt_root/host/gui.py" "$@"
