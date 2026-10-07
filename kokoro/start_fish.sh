#!/usr/bin/env bash
export PATH="/usr/local/cuda/bin:$PATH"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"
exec /home/willo/acp-host-projects/tts/venv_fish/bin/python \
    /home/willo/acp-host-projects/tts/fish_server.py
