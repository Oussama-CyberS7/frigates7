"""AI Box insights ingest: Frigate MQTT messages -> TimescaleDB.

Reads every site on the broker. The site id is the first topic level (Frigate topic_prefix).
QoS 1 messages are acknowledged only after the database commit (manual ack), and the MQTT session
is persistent, so messages published while the ingest restarts are delivered afterwards.
"""

import json
import logging
import os
import queue
import signal
import threading
from datetime import datetime, timezone
from pathlib import Path

import paho.mqtt.client as mqtt
import psycopg
from paho.mqtt.packettypes import PacketTypes
from paho.mqtt.properties import Properties
from psycopg.types.json import Jsonb

logger = logging.getLogger("insights-ingest")

HEARTBEAT = Path("/tmp/heartbeat")
SUBSCRIPTIONS = [
    ("+/events", 1),
    ("+/reviews", 1),
    ("+/tracked_object_update", 1),
    ("+/available", 1),
    ("+/stats", 0),
    ("+/+/status/+", 1),
]

stopping = threading.Event()
mqtt_connected = threading.Event()


def ts(value):
    """Convert Frigate epoch seconds to an aware datetime (None stays None)."""
    if value is None:
        return None
    return datetime.fromtimestamp(float(value), tz=timezone.utc)


def label_name(value):
    """Frigate sends sub_label as null, a string, or [name, score]."""
    if isinstance(value, list):
        return value[0] if value else None
    return value


# --- message handlers ---------------------------------------------------------------------------


def handle_event(cur, site, msg):
    after = msg.get("after") or {}
    event_id = after.get("id")
    start = ts(after.get("start_time"))
    if not event_id or start is None:
        return
    kind = msg.get("type", "update")
    end = ts(after.get("end_time"))
    camera = after.get("camera", "")
    label = after.get("label", "")

    cur.execute(
        """
        INSERT INTO tracked_objects (site, event_id, camera, label, sub_label, top_score, start_time,
                                     end_time, entered_zones, has_snapshot, has_clip, stationary,
                                     last_update, updated_at)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, now())
        ON CONFLICT (site, event_id, start_time) DO UPDATE SET
            label = EXCLUDED.label, sub_label = EXCLUDED.sub_label, top_score = EXCLUDED.top_score,
            end_time = EXCLUDED.end_time, entered_zones = EXCLUDED.entered_zones,
            has_snapshot = EXCLUDED.has_snapshot, has_clip = EXCLUDED.has_clip,
            stationary = EXCLUDED.stationary, last_update = EXCLUDED.last_update, updated_at = now()
        """,
        (
            site, event_id, camera, label, label_name(after.get("sub_label")),
            after.get("top_score"), start, end, after.get("entered_zones") or [],
            bool(after.get("has_snapshot")), bool(after.get("has_clip")),
            after.get("stationary"), kind,
        ),
    )

    # Zone visits: open a visit when a zone appears in current_zones, close it when it disappears
    # or when the tracked object ends.
    frame_time = ts(after.get("frame_time")) or datetime.now(timezone.utc)
    current = set() if kind == "end" else set(after.get("current_zones") or [])
    close_at = (end or frame_time) if kind == "end" else frame_time
    cur.execute(
        "SELECT zone, enter_time FROM zone_visits WHERE site = %s AND event_id = %s AND exit_time IS NULL",
        (site, event_id),
    )
    open_visits = dict(cur.fetchall())
    for zone in current - open_visits.keys():
        cur.execute(
            """
            INSERT INTO zone_visits (site, event_id, camera, zone, label, enter_time)
            VALUES (%s, %s, %s, %s, %s, %s) ON CONFLICT DO NOTHING
            """,
            (site, event_id, camera, zone, label, frame_time),
        )
    for zone, enter_time in open_visits.items():
        if zone not in current:
            cur.execute(
                """
                UPDATE zone_visits SET exit_time = %s
                WHERE site = %s AND event_id = %s AND zone = %s AND enter_time = %s
                """,
                (max(close_at, enter_time), site, event_id, zone, enter_time),
            )


def handle_review(cur, site, msg):
    after = msg.get("after") or {}
    review_id = after.get("id")
    start = ts(after.get("start_time"))
    if not review_id or start is None:
        return
    data = after.get("data") or {}
    cur.execute(
        """
        INSERT INTO review_items (site, review_id, camera, severity, start_time, end_time, objects,
                                  sub_labels, zones, detections, last_update, updated_at)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, now())
        ON CONFLICT (site, review_id, start_time) DO UPDATE SET
            severity = EXCLUDED.severity, end_time = EXCLUDED.end_time, objects = EXCLUDED.objects,
            sub_labels = EXCLUDED.sub_labels, zones = EXCLUDED.zones,
            detections = EXCLUDED.detections, last_update = EXCLUDED.last_update, updated_at = now()
        """,
        (
            site, review_id, after.get("camera", ""), after.get("severity", ""), start,
            ts(after.get("end_time")), data.get("objects") or [],
            [label_name(s) for s in data.get("sub_labels") or []], data.get("zones") or [],
            data.get("detections") or [], msg.get("type", "update"),
        ),
    )


def handle_object_update(cur, site, msg):
    cur.execute(
        "INSERT INTO object_updates (site, event_id, update_type, payload) VALUES (%s, %s, %s, %s)",
        (site, msg.get("id"), msg.get("type", "unknown"), Jsonb(msg)),
    )


def handle_status(cur, site, component, state):
    cur.execute(
        """
        INSERT INTO site_status (site, component, state, updated_at) VALUES (%s, %s, %s, now())
        ON CONFLICT (site, component) DO UPDATE SET state = EXCLUDED.state, updated_at = now()
        WHERE site_status.state IS DISTINCT FROM EXCLUDED.state
        RETURNING 1
        """,
        (site, component, state),
    )
    inserted_or_changed = cur.fetchone() is not None
    if inserted_or_changed:
        cur.execute(
            "INSERT INTO status_events (site, component, state) VALUES (%s, %s, %s)",
            (site, component, state),
        )


def handle_stats(cur, site, stats):
    speeds = [
        d.get("inference_speed")
        for d in (stats.get("detectors") or {}).values()
        if isinstance(d, dict) and d.get("inference_speed") is not None
    ]
    cur.execute(
        "INSERT INTO frigate_stats (time, site, detection_fps, inference_ms, payload) VALUES (now(), %s, %s, %s, %s)",
        (site, stats.get("detection_fps"), max(speeds) if speeds else None, Jsonb(stats)),
    )


def dispatch(cur, topic, payload):
    """Route one MQTT message to its handler. Returns False if the topic is not handled."""
    parts = topic.split("/")
    site = parts[0]
    if len(parts) == 4 and parts[2] == "status":
        handle_status(cur, site, f"camera/{parts[1]}/{parts[3]}", payload.decode(errors="replace"))
        return True
    if len(parts) != 2:
        return False
    kind = parts[1]
    if kind == "available":
        handle_status(cur, site, "frigate", payload.decode(errors="replace"))
        return True
    handlers = {
        "events": handle_event,
        "reviews": handle_review,
        "tracked_object_update": handle_object_update,
        "stats": handle_stats,
    }
    if kind not in handlers:
        return False
    handlers[kind](cur, site, json.loads(payload))
    return True


# --- infrastructure ----------------------------------------------------------------------------


def db_connect():
    while not stopping.is_set():
        try:
            conn = psycopg.connect(
                host=os.environ["DB_HOST"],
                dbname=os.environ["DB_NAME"],
                user=os.environ["DB_USER"],
                password=os.environ["DB_PASSWORD"],
                application_name="insights-ingest",
                connect_timeout=10,
                autocommit=True,  # each message is committed by its own transaction() block
            )
        except psycopg.OperationalError as err:
            logger.warning("Database not reachable, retrying in 5 s: %s", err)
            stopping.wait(5)
            continue
        logger.info("Connected to database")
        return conn
    return None


def build_mqtt_client(inbox):
    client = mqtt.Client(
        mqtt.CallbackAPIVersion.VERSION2,
        client_id="insights-ingest",
        protocol=mqtt.MQTTv5,
        manual_ack=True,
    )
    client.username_pw_set(os.environ["MQTT_USER"], os.environ["MQTT_PASSWORD"])
    client.reconnect_delay_set(min_delay=1, max_delay=30)

    def on_connect(client, userdata, flags, reason_code, properties):
        if reason_code.is_failure:
            logger.error("MQTT connection refused: %s", reason_code)
            return
        logger.info("Connected to MQTT broker, session_present=%s", flags.session_present)
        client.subscribe(SUBSCRIPTIONS)
        mqtt_connected.set()

    def on_disconnect(client, userdata, flags, reason_code, properties):
        mqtt_connected.clear()
        logger.warning("Disconnected from MQTT broker: %s", reason_code)

    def on_message(client, userdata, message):
        inbox.put(message)

    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_message = on_message

    connect_props = Properties(PacketTypes.CONNECT)
    connect_props.SessionExpiryInterval = 3600  # broker keeps QoS 1 messages for 1 h while we are away
    client.connect_async(
        os.environ.get("MQTT_HOST", "mosquitto"),
        int(os.environ.get("MQTT_PORT", "1883")),
        keepalive=60,
        clean_start=False,
        properties=connect_props,
    )
    return client


def main():
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    signal.signal(signal.SIGTERM, lambda *_: stopping.set())
    signal.signal(signal.SIGINT, lambda *_: stopping.set())

    conn = db_connect()
    if conn is None:
        return
    inbox = queue.Queue(maxsize=10000)
    client = build_mqtt_client(inbox)
    client.loop_start()

    handled = 0
    while not stopping.is_set():
        if mqtt_connected.is_set() and not conn.closed:
            HEARTBEAT.touch()
        try:
            message = inbox.get(timeout=5)
        except queue.Empty:
            continue

        while not stopping.is_set():
            try:
                with conn.transaction(), conn.cursor() as cur:
                    ok = dispatch(cur, message.topic, message.payload)
            except (psycopg.OperationalError, psycopg.InterfaceError) as err:
                # Connection problem: reconnect and retry the same message (not acked yet).
                logger.warning("Database connection error, reconnecting: %s", err)
                conn.close()
                conn = db_connect()
                if conn is None:
                    break
                continue
            except (psycopg.Error, ValueError, TypeError, AttributeError) as err:
                # Malformed payload or rejected row: log and acknowledge so it is not redelivered forever.
                logger.error("Skipping message on %s: %s", message.topic, err)
                break
            if ok:
                handled += 1
                if handled % 500 == 0:
                    logger.info("Stored %d messages", handled)
            break

        if message.qos > 0 and not stopping.is_set():
            client.ack(message.mid, message.qos)

    logger.info("Shutting down")
    client.loop_stop()
    client.disconnect()
    if conn is not None:
        conn.close()


if __name__ == "__main__":
    main()
