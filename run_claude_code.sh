#!/bin/bash
# This script will run all 230 tasks in the tasks folder
# To run a subset of tasks, please create another folder contain the tasks you want to run,
# then point the dataset variable to it

dataset="tasks"
model="openrouter/openai/gpt-6-luna"

# Run Claude-Code
harbor run \
    --path "$dataset" \
    -a claude-code \
    -m "$model" \
    --n-concurrent 6 \
    --ak "config=config/setting.local.json" \
    --agent-timeout-multiplier 1 \
    --verifier-timeout-multiplier 10 \
    --agent-setup-timeout-multiplier 10 \
    --environment-build-timeout-multiplier 10 \
    --verifier-timeout-multiplier 5
