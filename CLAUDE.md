# AI Box platform: project memory for Claude Code

## Project context

We are building a Lumeo-style AI video analytics service for businesses. First target: an agricultural
packing station in Morocco/France.

**EDGE (client site): the "AI box"**
- Plugs into the client's EXISTING IP cameras (RTSP/ONVIF).
- First box: NVIDIA Jetson Orin Nano Super Developer Kit (8 GB), JetPack 6.2, up to 8 cameras.
- Runs Frigate (detection, tracking, zones, license plates, faces, classification, semantic search),
  Mosquitto (local MQTT broker + bridge to the VPS), a NetBird client (WireGuard tunnel) and optionally
  Ollama + Qwen3-VL.
- Video and AI stay on site.

**CENTRAL (VPS): receives only small data from every box**
- MQTT events (`frigate/events`, `frigate/reviews`, `frigate/tracked_object_update`) with a unique
  `topic_prefix` per site.
- Box health from Frigate's Prometheus endpoint `/api/metrics`.
- Snapshots.
- Later phases on the VPS: NetBird or Headscale, Node-RED, PostgreSQL + TimescaleDB, Prometheus, Grafana
  (one organization per client), Uptime Kuma, S3-compatible snapshot storage, LLM daily reports.

**Compliance: GDPR / CNIL**
- Keep footage 30 days max.
- No audio recording.
- Never film workstations continuously.
- Treat faces as biometric data: face recognition is disabled by default.

## Environments

| Where | What | Notes |
|---|---|---|
| Operator laptop | This git clone (`~/Desktop/frigate`) | Parrot OS laptop, **not a server**. Never install server components here. |
| Lab/staging VPS (OVHcloud, Ubuntu) | Frigate + Mosquitto lab stack in `~/aibox-platform` | Reach it with `ssh aibox-vps` (alias in `~/.ssh/config`, key `~/.ssh/id_ed25519_aibox_vps`). Host details are in `CLAUDE.local.md` (gitignored). |
| Edge boxes (future) | Jetson Orin Nano Super 8 GB | Reuse the templates from this repo. |

Lab VPS facts (audited 2026-09-16 with commands): Ubuntu 26.04 LTS (KVM/OpenStack), 8 vCPU
"Intel Core Processor (Haswell, no TSX)" with SSE4.2/AVX/AVX2 (no AVX-512), 22 GiB RAM, no swap, 193 GB root disk,
no GPU, SSH on port 22 (socket-activated `ssh.socket`), passwordless sudo for `ubuntu`, host timezone UTC.

Git:
- Remote: `git@github-cybers7:Oussama-CyberS7/frigates7.git`. **The repository is PUBLIC**, so never commit
  secrets, `.env`, passwords, IPs/hostnames, client names, footage, snapshots, or Frigate/Mosquitto runtime data.
- All work happens on a branch (Phase 1: `phase1/vps-lab`), not on `main`.
- Upstream Frigate source is a git submodule in `frigate-upstream/` (read-only reference: docs + config
  schema in `frigate-upstream/frigate/config/`). Keep it checked out at the same stable tag as the pinned image.
  Clone with `git clone --recurse-submodules`.

## Phase 1 goal (lab only, NOT a production NVR)

1. Learn and validate Frigate configuration.
2. Produce real MQTT events so the VPS data pipeline can be built before the Jetson arrives.
3. Create config templates to reuse on the Jetson boxes.

## Working rules

- **Explore first, then write a plan.** Show the plan and WAIT for approval before installing packages,
  changing the firewall, rebooting, or doing anything destructive.
- **Security**
  - Never expose Frigate port 5000 (unauthenticated) or MQTT 1883 to the internet.
  - Bind Frigate's authenticated port 8971 to `127.0.0.1`. Reach it through an SSH tunnel.
  - Never publish 8554/8555 publicly.
  - Before enabling any firewall, confirm the SSH port to avoid a lockout.
  - Docker-published ports bypass UFW. Always bind published ports to `127.0.0.1`, and verify from outside.
- **Test streams only:** looped sample videos with people and vehicles, restreamed by go2rtc/ffmpeg.
  Never use real client cameras. Check the sample video license before use and keep its attribution.
- **Secrets** go in `.env` (chmod 600), never committed. Only the Frigate one-time admin password from the
  logs may be shown to the user. Never print other secrets.
- **Pin the Frigate image** to the current stable version from docs.frigate.video. Never use `:latest` or dev images.
  Pin other images (Mosquitto) to exact versions too.
- **Verify hardware facts with commands** instead of guessing. When unsure, read the official docs or ask.
- Explain each step in one or two sentences.
- Commit only when asked. Push to GitHub only after the user approves.

## Roadmap

- **Phase 1 (current):** Frigate + Mosquitto lab on the VPS, UFW + unattended upgrades, templates, docs.
- **Phase 2:** NetBird tunnel, Prometheus + Grafana, PostgreSQL ingest of MQTT events, Jetson config template.
