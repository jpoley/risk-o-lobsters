#!/bin/bash
source /home/zlatan/.profile
echo "=== onboard help ==="
zeroclaw onboard --help 2>&1
echo "=== config help ==="
zeroclaw config --help 2>&1
echo "=== current config ==="
cat /home/zlatan/.zeroclaw/config.toml 2>&1
echo "=== channel list ==="
zeroclaw channel list 2>&1
echo "=== status ==="
zeroclaw status 2>&1
