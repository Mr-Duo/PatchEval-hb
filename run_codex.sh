#!/bin/bash

dataset="tasks"
model="openrouter/openai/gpt-6-luna"

# Run Codex
harbor run \
    --path "$dataset" \
    -a codex \
    -m "$model" \
    --n-concurrent 6 \
    --ak "config=config/config.toml" \
    --ae "OPENROUTER_API_KEY=$OPENROUTER_API_KEY" \
    --agent-timeout-multiplier 1 \
    --verifier-timeout-multiplier 10 \
    --agent-setup-timeout-multiplier 10 \
    --environment-build-timeout-multiplier 10 \
    --verifier-timeout-multiplier 5
