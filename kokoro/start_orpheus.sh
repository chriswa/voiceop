#!/usr/bin/env bash
export PATH="/usr/local/cuda/bin:$PATH"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"
exec /home/willo/acp-host-projects/tts/venv_orpheus/bin/python \
    /home/willo/acp-host-projects/tts/orpheus_server.py
