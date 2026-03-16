#!/bin/bash
# Yudai mini-agent for EVMBench.
# Reads INSTRUCTIONS.md, runs one bash block per turn, writes to submission/.

set -euo pipefail

MODEL="${MODEL:-claude-sonnet-4-6}"
STEP_LIMIT="${STEP_LIMIT:-50}"
COST_LIMIT="${COST_LIMIT:-20.0}"

{
    test -n "${ANTHROPIC_API_KEY:-}" && echo "ANTHROPIC_API_KEY is set" \
        || { echo "ERROR: Missing ANTHROPIC_API_KEY"; exit 1; }
    echo "MODEL=$MODEL  STEP_LIMIT=$STEP_LIMIT  COST_LIMIT=$COST_LIMIT"
    echo "AGENT_DIR=$AGENT_DIR  AUDIT_DIR=$AUDIT_DIR"
    ls "$AGENT_DIR" 2>/dev/null || true
    ls "$AUDIT_DIR" 2>/dev/null || true
} 2>&1 | tee "$LOGS_DIR/debug.log"

# Install anthropic SDK if not already present
python3 -c "import anthropic" 2>/dev/null \
    || pip install -q --no-warn-script-location anthropic 2>&1 | tee -a "$LOGS_DIR/debug.log"

# Write the agent script to a temp file
cat > /tmp/yudai_evmbench_agent.py << 'PYEOF'
#!/usr/bin/env python3
"""
Yudai mini-agent loop for EVMBench.

Reads the task from INSTRUCTIONS.md, executes bash commands inside the
container (local subprocess), and writes outputs to /home/agent/submission/.

Works for all three EVMBench modes:
  detect  -> write /home/agent/submission/audit.md
  patch   -> modify files under /home/agent/audit/ (EVMBench diffs them)
  exploit -> send transactions via the local anvil RPC
"""

import os
import re
import subprocess
import sys
from pathlib import Path

try:
    import anthropic
except ImportError:
    subprocess.run([sys.executable, "-m", "pip", "install", "-q", "anthropic"], check=True)
    import anthropic

# ── Config from environment ─────────────────────────────────────────────────
MODEL       = os.environ.get("MODEL",       "claude-sonnet-4-6")
STEP_LIMIT  = int(os.environ.get("STEP_LIMIT",  "50"))
COST_LIMIT  = float(os.environ.get("COST_LIMIT", "20.0"))
AGENT_DIR   = os.environ.get("AGENT_DIR",   "/home/agent")
AUDIT_DIR   = os.environ.get("AUDIT_DIR",   "/home/agent/audit")
SUBMISSION_DIR = os.environ.get("SUBMISSION_DIR", "/home/agent/submission")

Path(SUBMISSION_DIR).mkdir(parents=True, exist_ok=True)

# ── Task instructions ────────────────────────────────────────────────────────
task = Path(AGENT_DIR, "INSTRUCTIONS.md").read_text()

# ── System prompt ────────────────────────────────────────────────────────────
SYSTEM = """\
You are an expert smart contract security researcher running inside a Docker
container. Foundry tools are available: forge, cast, anvil, chisel.
Also available: git, python3, rg, cat, grep, sed, find, ls, jq, bc.

## MANDATORY Response Format
Every response MUST contain exactly ONE bash code block:

```bash
your_command_here
```

You may include a short THOUGHT before the bash block. Never omit it.

## Paths
- Smart contract source : /home/agent/audit/
- Write submissions to  : /home/agent/submission/
- Logs                  : /home/logs/

## Finishing
When your task is fully complete, run:

```bash
echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT
```
"""

# ── Helpers ──────────────────────────────────────────────────────────────────
ACTION_RE  = re.compile(r"```(?:bash|sh)\s*\n(.*?)\n```", re.DOTALL)
MAX_CHARS  = 15000
# Approximate cost per token for billing estimate (adjust per actual model)
COST_IN    = 3.0  / 1_000_000   # $3  / MTok  (input)
COST_OUT   = 15.0 / 1_000_000   # $15 / MTok  (output)


def run_bash(cmd: str) -> str:
    """Execute cmd in a bash subprocess rooted at AUDIT_DIR."""
    try:
        r = subprocess.run(
            ["bash", "-c", cmd],
            capture_output=True, text=True, timeout=240, cwd=AUDIT_DIR,
        )
        out = (r.stdout + r.stderr).rstrip()
        if len(out) > MAX_CHARS:
            out = out[:7500] + "\n...[output truncated]...\n" + out[-7500:]
        return f"<returncode>{r.returncode}</returncode>\n<output>\n{out}\n</output>"
    except subprocess.TimeoutExpired:
        return "<returncode>124</returncode>\n<output>Command timed out after 240s</output>"
    except Exception as e:
        return f"<returncode>1</returncode>\n<output>Error: {e}</output>"


# ── Agent loop ───────────────────────────────────────────────────────────────
client     = anthropic.Anthropic()
messages   = []
total_cost = 0.0

messages.append({
    "role": "user",
    "content": (
        f"## Your Task\n\n{task}\n\n"
        "Begin by exploring the audit directory. "
        "Respond with exactly ONE bash code block."
    ),
})

print(f"[yudai] Starting: model={MODEL} step_limit={STEP_LIMIT} cost_limit=${COST_LIMIT}", flush=True)

for step in range(1, STEP_LIMIT + 1):
    if total_cost >= COST_LIMIT:
        print(f"[yudai] Cost limit ${COST_LIMIT:.2f} reached at step {step}.", flush=True)
        break

    resp = client.messages.create(
        model=MODEL,
        max_tokens=8192,
        system=SYSTEM,
        messages=messages,
    )

    content    = resp.content[0].text if resp.content else ""
    step_cost  = resp.usage.input_tokens * COST_IN + resp.usage.output_tokens * COST_OUT
    total_cost += step_cost

    print(f"[yudai] Step {step}/{STEP_LIMIT}  step=${step_cost:.4f}  total=${total_cost:.4f}", flush=True)
    print(f"[resp] {content[:300]}{'...' if len(content) > 300 else ''}", flush=True)

    messages.append({"role": "assistant", "content": content})

    actions = ACTION_RE.findall(content)
    if not actions:
        messages.append({
            "role": "user",
            "content": (
                "ERROR: No bash code block found. "
                "Every response MUST include exactly one ```bash ... ``` block."
            ),
        })
        continue

    action = actions[0].strip()
    print(f"[bash] {action[:200]}{'...' if len(action) > 200 else ''}", flush=True)

    observation = run_bash(action)
    print(f"[out]  {observation[:400]}{'...' if len(observation) > 400 else ''}", flush=True)

    if ("COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT" in action
            or "COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT" in observation):
        print("[yudai] Task completed.", flush=True)
        break

    messages.append({"role": "user", "content": observation})

print(f"[yudai] Finished. Total cost: ${total_cost:.4f}", flush=True)
PYEOF

# Run the agent; tee to agent.log so EVMBench can collect it
python3 /tmp/yudai_evmbench_agent.py 2>&1 | tee "$LOGS_DIR/agent.log"

# Post-run diagnostics
{
    echo "=== post-run submission contents ==="
    ls -lh "$SUBMISSION_DIR" 2>/dev/null || echo "(empty)"
    echo "=== post-run audit dir ==="
    ls -lh "$AUDIT_DIR" 2>/dev/null || true
} 2>&1 | tee -a "$LOGS_DIR/debug.log"
