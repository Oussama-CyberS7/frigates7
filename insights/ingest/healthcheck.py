"""Container healthcheck: healthy while the ingest loop is alive with MQTT and DB connected."""

import sys
import time
from pathlib import Path

HEARTBEAT = Path("/tmp/heartbeat")

try:
    age = time.time() - HEARTBEAT.stat().st_mtime
except FileNotFoundError:
    sys.exit(1)
sys.exit(0 if age < 90 else 1)
