#!/bin/bash
# logs.sh — follow the panel log (logs/current.log follows rotation and restarts). Ctrl+C to stop following.
. "$(dirname "$0")/_common.sh"
exec tail -F "$LOG_DIR/current.log"
