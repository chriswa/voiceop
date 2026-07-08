#!/bin/bash
export PATH=/home/willo/.local/bin:/usr/local/cuda-12.8/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.8/lib64:$LD_LIBRARY_PATH
cd /home/willo/acp-host-projects/tts
exec python3 -W ignore chatterbox_server.py
