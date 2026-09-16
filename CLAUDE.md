# AI Box platform: project memory for Claude Code

## Project context

We are building a Lumeo-style AI video analytics service for businesses. First target: an agricultural
packing station in Morocco/France.

### EDGE (client site): the "AI box"

- Plugs into the client's EXISTING IP cameras (RTSP/ONVIF).
- First box: NVIDIA Jetson Orin Nano Super Developer Kit (8 GB), JetPack 6.2, up to 8 cameras.
- Runs Frigate (detection, tracking, zones, license plates, faces, classification, semantic search),
  Mosquitto (local MQTT broker + bridge to the VPS), a NetBird client (WireGuard tunnel) and optionally
  Ollama + Qwen3-VL.
- Video and AI stay on site.

### CENTRAL (VPS): receives only small data from every box

- MQTT events (`frigate/events`, `frigate/reviews`, `frigate/tracked_object_update`) with a unique
  `topic_prefix` per site.
- Box health from Frigate's Prometheus endpoint `/api/metrics`.
- Snapshots.
- Later phases on the VPS: NetBird or Headscale, Node-RED, PostgreSQL + TimescaleDB, Prometheus, Grafana
  (one organization per client), Uptime Kuma, S3-compatible snapshot storage, LLM daily reports.
- 2026-09-16: the user also asked for the VPS Frigate to receive live streams from a box and turn them into
  insights. The lab does this with a box simulator. The tradeoffs of central inference (the VPS is in Canada,
  so it's a GDPR transfer; upload bandwidth) are documented in README.md. Edge inference is recommended for
  production.

### Compliance: GDPR / CNIL

- Keep footage 30 days max.
- No audio recording.
- Never film workstations continuously.
- Treat faces as biometric data: face recognition is disabled by default.

## Environments

| Where | What | Notes |
|---|---|---|
| Operator laptop | This git clone (`~/Desktop/frigate`) | Parrot OS laptop, **not a server**. Never install server components here. |
| Lab/staging VPS (OVHcloud BHS, Canada) | Phase 1 stack in `~/aibox-platform` (clone of branch `phase1/vps-lab`) | `ssh aibox-vps` (alias in `~/.ssh/config`, key `~/.ssh/id_ed25519_aibox_vps`, ControlMaster on). Host details in `CLAUDE.local.md` (gitignored). |
| Edge boxes (future) | Jetson Orin Nano Super 8 GB | Reuse the templates from this repo. |

Lab VPS facts (audited 2026-09-16 with commands):

- Ubuntu 26.04 LTS (KVM/OpenStack) with uutils coreutils and sudo-rs.
- 8 vCPU "Intel Core Processor (Haswell, no TSX)" with SSE4.2/AVX/AVX2 (no AVX-512).
- 22 GiB RAM, no swap, 193 GB root disk, blank 50 GB `sdb` (untouched), no GPU.
- SSH on port 22 via `ssh.socket`; passwordless sudo for `ubuntu`; host timezone UTC.

Git:

- Remote: `git@github-cybers7:Oussama-CyberS7/frigates7.git`. **The repository is PUBLIC**, so never commit
  secrets, `.env`, passwords, IPs/hostnames, client names, footage, snapshots, or Frigate/Mosquitto runtime data.
- All work happens on a branch (Phase 1: `phase1/vps-lab`); there is no `main` yet.
- Upstream Frigate source is a git submodule in `frigate-upstream/`, pinned at tag `v0.18.0`, the same as the
  image. It is the authoritative reference for config keys (`frigate/config/*.py`) and docs. Its own CLAUDE.md
  is for Frigate contributors, not for this project.
- Deploy flow: edit on the laptop, commit, push the branch, then `git pull` on the VPS and `sudo docker compose up -d`.

## Phase 1 goal (lab only, NOT a production NVR)

1. Learn and validate Frigate configuration.
2. Produce real MQTT events so the VPS data pipeline can be built before the Jetson arrives.
3. Create config templates to reuse on the Jetson boxes.

State on 2026-09-16:

- Running: box-sim, Frigate 0.18.0, Mosquitto 2.1.2, TimescaleDB, insights-ingest, Grafana.
- Verified: detection, MQTT on `lab-vps/*`, `/api/metrics`, insights rows, tunnel access, and external exposure
  (only SSH is reachable).
- Remaining: the reboot test is still pending user approval.

## Working rules

- **Explore first, then write a plan.** Show the plan and WAIT for approval before installing packages,
  changing the firewall, rebooting, or doing anything destructive.
- **Security**
  - Never expose Frigate port 5000 (unauthenticated) or MQTT 1883 to the internet.
  - Bind Frigate's authenticated port 8971 to `127.0.0.1`. Reach it through an SSH tunnel.
  - Never publish 8554/8555 publicly.
  - Before enabling any firewall, confirm the SSH port to avoid a lockout.
  - Docker-published ports bypass UFW. Always bind published ports to `127.0.0.1`, and verify from outside.
  - SSH password login stays enabled by user decision (2026-09-16). Do not disable it without asking.
- **Test streams only:** looped sample videos with people and vehicles, restreamed by go2rtc/ffmpeg.
  Never use real client cameras. Check the sample video license before use and keep its attribution.
- **Secrets** go in `.env` (chmod 600), never committed. Only the Frigate one-time admin password from the
  logs may be shown to the user. Never print other secrets, and never put them in argv (use stdin or files).
- **Pin images** to exact version + digest (Frigate from docs.frigate.video stable). Never `:latest` or dev images.
- **Verify hardware facts with commands** instead of guessing. When unsure, read the official docs or ask.
- Explain each step in one or two sentences.
- Commit only when asked. Push to GitHub only after the user approves.

## Lessons learned (Phase 1)

- **Admin password:** Frigate prints it only on first start. Recreating the container loses it. Reset with
  `auth.reset_admin_password: true` + `docker compose restart` (not `up`), then remove the flag.
- **shm:** the 0.18.0 runtime shm check (`frigate/util/services.py`) is stricter than the docs formula.
  See the README; the lab uses 512mb.
- **Frigate 0.18 config pitfalls:**
  - `detect.enabled` defaults to false.
  - The default record preset keeps audio (use `preset-record-generic`).
  - The bundled labelmap maps truck to car (override `model.labelmap: {8: truck}`).
  - Unknown keys put Frigate into safe mode.
- **Frigate's internal go2rtc:** API/RTSP are unauthenticated. They are bound to container loopback via
  `go2rtc.api.listen` / `go2rtc.rtsp.listen`.
- **Ubuntu 26.04:** uutils `install -o 1883` fails; use `chown`.
- **Remote scripts:** `docker compose exec` inside an ssh here-doc consumes stdin; add `</dev/null`.
- **Mosquitto 2.1.2:**
  - Plugin auth syntax; passwd/acl files owned 1883:1883 mode 0600.
  - `mosquitto_passwd -c` refuses existing files.
  - Pass passwords via stdin / `-o` options files only.
- **UFW `limit 22/tcp`:** it blocks bursts of new SSH connections. Keep ControlMaster on for automation.
- **OpenVINO CPU cost:** OpenVINO (LATENCY hint) spreads every inference over all visible cores.
  - Unpinned, Frigate used 7.8 vCPU; with `cpuset: "0-3"`, 2.8 vCPU at +1.2 ms per inference.
  - Measure CPU with `docker stats`, not Frigate's `cpu_usages`.
  - 2 test cameras use about 3 vCPU, so central inference for 8-camera sites does not fit this VPS.
- **Commands:** never put a password literally in a command (auto mode blocks it, and it leaks to history/ps).
