# Roadmap

## Open items

- [x] Re-login to Claude Code on the server (`claude`, then `/login`).
- [x] `gh auth login` on the server (HTTPS), so `agent new owner/repo ...` can clone and push.
- [x] Run one real agent end to end and confirm the hooks move it working, needs-you, done (verified 2026-10-13).
- [ ] Pick the first real project and point `agent` at it.

## Server housekeeping still open

- [ ] BIOS: Restore on AC/Power Loss set to Power On (set; not yet tested with a real power cut).
- [ ] Bind Redis and MariaDB to loopback and require authentication, or remove them if unused.
- [ ] Backups for anything on the server that can't be recreated.
- [ ] Prefer wired Ethernet over Wi-Fi for the server.

## v1: sandbox for true fire-and-forget

Run each agent in a rootless Podman container: worktree mounted in, no host secrets, scoped credentials only.
Only then pre-approve everything inside the container, because the container is the boundary.
Builds on what already works: rootless Podman, SELinux enforcing, GPU passthrough.

## Later

- **Task queue:** a GitHub issue labelled `agent` triggers a runner on the server, which makes a worktree, works the task, and opens a PR. A self-hosted Actions runner could be the trigger.
- **Scheduled agents** via `systemd` timers: dependency bumps, flaky-test triage, health checks, daily digests.
- **Builder plus reviewer:** a second agent with a fresh context and a stricter prompt reviews the first one's diff before it reaches a human.
- **Phone push** when an agent finishes or is blocked (e.g. ntfy over Tailscale).
- **A real "stuck" signal:** a hook for API and auth errors, so those stop showing as `working`.
- **Sidecar models:** a small local model (Ollama in a GPU container) for triage, summaries and embeddings; see [local-models.md](local-models.md).
- **Status page** of running agents and their last progress line.

## Risks to design around

- **Prompt injection** from web pages and dependency READMEs: keep unattended agents away from secrets and from the Samba-mounted data; mount it read-only where needed.
- **Blast radius:** nothing an agent pushes reaches `main` without review (branch protection).
- **Cost:** unattended means nobody is watching the meter; use turn and runtime limits.

## Open questions

- Which project goes first, and how many agents does it really need in parallel?
- Keep the shared subscription login, or move the server to a separate API key later?
