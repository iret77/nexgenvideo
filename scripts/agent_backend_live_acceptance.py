"""Manual Actions-only real backend smoke. No local credential discovery or media calls."""
import argparse
import os
from pathlib import Path
import signal
import subprocess

from agent_backend_live_evidence import validate


def run(backend, output, source):
    if os.environ.get("CI") != "true" or os.environ.get("NGV_AGENT_BACKEND_SPEND_APPROVED") != "1":
        raise ValueError("Only a separately owner-approved Actions job may run the live backend smoke")
    output.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ)
    api_key = env.pop("NGV_CI_ANTHROPIC_KEY", "")
    oauth = env.pop("NGV_CI_CLAUDE_OAUTH", "")
    for name in list(env):
        if name.startswith(("ANTHROPIC_", "CLAUDE_")):
            env.pop(name)
    env["DISABLE_AUTOUPDATER"] = "1"
    if backend == "anthropicAPI":
        if not api_key or not env.get("NGV_BACKEND_MODEL_ID"):
            raise ValueError("Missing dedicated CI Anthropic API key/model")
        env["NGV_BACKEND_API_KEY"] = api_key
    else:
        if not oauth or not env.get("NGV_EXPECTED_CLAUDE_VERSION"):
            raise ValueError("Missing dedicated CI Claude OAuth authentication/version")
        config = output / "private-claude-config"; config.mkdir(mode=0o700)
        env["CLAUDE_CONFIG_DIR"] = str(config.resolve())
        env["CLAUDE_CODE_OAUTH_TOKEN"] = oauth
        env["NGV_BACKEND_API_KEY"] = ""
    evidence = output / "live-backend.json"
    env.update(NGV_AGENT_BACKEND_LIVE_ACCEPTANCE="1", NGV_AGENT_LIVE_BACKEND=backend,
               NGV_AGENT_LIVE_EVIDENCE=str(evidence.resolve()), GITHUB_SHA=source,
               CLAUDE_CODE_DISABLE_ADVISOR_TOOL="1")
    raw_log = output / "private-test-output.log"
    command = ["swift", "test", "--skip-build", "--filter", "AgentBackendLiveAcceptanceTests"]
    if env.get("NGV_SWIFTPM_CACHE_PATH"):
        command += ["--cache-path", env["NGV_SWIFTPM_CACHE_PATH"]]
    with raw_log.open("w") as log:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                   env=env, start_new_session=True)
        try:
            code = process.wait(timeout=180)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL); process.wait()
            code = 124
    text = raw_log.read_text(errors="replace")
    for credential in (api_key, oauth):
        if credential: text = text.replace(credential, "[REDACTED]")
    (output / "test-output.redacted.log").write_text(text)
    if code != 0:
        raise ValueError("The real backend smoke failed; no retry was started")
    return validate(evidence, backend, source, env.get("NGV_EXPECTED_CLAUDE_VERSION"), env.get("NGV_BACKEND_MODEL_ID"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", required=True, choices=("claudeCode", "anthropicAPI"))
    parser.add_argument("--output", required=True, type=Path); parser.add_argument("--source", required=True)
    args = parser.parse_args()
    run(args.backend, args.output, args.source)
