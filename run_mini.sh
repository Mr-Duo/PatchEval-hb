#!/bin/bash

dataset="tasks"
model="openrouter/openai/gpt-6-luna"

# Run Mini-SWE-Agent
harbor run \
    --path "$dataset" \
    -a mini-swe-agent \
    -m "$model" \
    --n-concurrent 6 \
    --agent-timeout-multiplier 1 \
    --verifier-timeout-multiplier 10 \
    --agent-setup-timeout-multiplier 10 \
    --environment-build-timeout-multiplier 10  \
    --verifier-timeout-multiplier 5