-- AI Box insights schema v0 (TimescaleDB 2.30 / PostgreSQL 17).
-- Runs ONCE on first initialisation, as postgres, in database "insights".
-- site = the Frigate MQTT topic_prefix of the box (lab: "lab-vps").
-- GDPR: raw rows (per tracked object / visit / review) are dropped after 30 days.
-- Hourly aggregates contain only counts and durations (no personal data) and are kept 400 days.

CREATE EXTENSION IF NOT EXISTS timescaledb;

-- One row per Frigate tracked object (event id), upserted on every new/update/end message.
CREATE TABLE tracked_objects (
    site          text        NOT NULL,
    event_id      text        NOT NULL,
    camera        text        NOT NULL,
    label         text        NOT NULL,
    sub_label     text,
    top_score     real,
    start_time    timestamptz NOT NULL,
    end_time      timestamptz,
    entered_zones text[]      NOT NULL DEFAULT '{}',
    has_snapshot  boolean     NOT NULL DEFAULT false,
    has_clip      boolean     NOT NULL DEFAULT false,
    stationary    boolean,
    last_update   text        NOT NULL,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (site, event_id, start_time)
);
SELECT create_hypertable('tracked_objects', by_range('start_time', INTERVAL '1 day'));
CREATE INDEX tracked_objects_camera_time ON tracked_objects (site, camera, start_time DESC);

-- Zone presence derived from current_zones changes: one row per object entering a zone.
CREATE TABLE zone_visits (
    site       text        NOT NULL,
    event_id   text        NOT NULL,
    camera     text        NOT NULL,
    zone       text        NOT NULL,
    label      text        NOT NULL,
    enter_time timestamptz NOT NULL,
    exit_time  timestamptz,
    PRIMARY KEY (site, event_id, zone, enter_time)
);
SELECT create_hypertable('zone_visits', by_range('enter_time', INTERVAL '1 day'));
CREATE INDEX zone_visits_open ON zone_visits (site, event_id) WHERE exit_time IS NULL;

-- Frigate review items (alerts and detections).
CREATE TABLE review_items (
    site        text        NOT NULL,
    review_id   text        NOT NULL,
    camera      text        NOT NULL,
    severity    text        NOT NULL,
    start_time  timestamptz NOT NULL,
    end_time    timestamptz,
    objects     text[]      NOT NULL DEFAULT '{}',
    sub_labels  text[]      NOT NULL DEFAULT '{}',
    zones       text[]      NOT NULL DEFAULT '{}',
    detections  text[]      NOT NULL DEFAULT '{}',
    last_update text        NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (site, review_id, start_time)
);
SELECT create_hypertable('review_items', by_range('start_time', INTERVAL '1 day'));

-- Enrichment updates (tracked_object_update: genai description, face, lpr, classification).
CREATE TABLE object_updates (
    received_at timestamptz NOT NULL DEFAULT now(),
    site        text        NOT NULL,
    event_id    text,
    update_type text        NOT NULL,
    payload     jsonb       NOT NULL
);
SELECT create_hypertable('object_updates', by_range('received_at', INTERVAL '1 day'));

-- Box health: current state per component, plus the history of state changes.
CREATE TABLE site_status (
    site       text        NOT NULL,
    component  text        NOT NULL,  -- 'frigate' or 'camera/<name>/<role>'
    state      text        NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (site, component)
);

CREATE TABLE status_events (
    time      timestamptz NOT NULL DEFAULT now(),
    site      text        NOT NULL,
    component text        NOT NULL,
    state     text        NOT NULL
);
SELECT create_hypertable('status_events', by_range('time', INTERVAL '7 days'));

-- Frigate stats (published every mqtt.stats_interval seconds).
CREATE TABLE frigate_stats (
    time          timestamptz NOT NULL,
    site          text        NOT NULL,
    detection_fps real,
    inference_ms  real,
    payload       jsonb       NOT NULL
);
SELECT create_hypertable('frigate_stats', by_range('time', INTERVAL '1 day'));

-- Hourly aggregates (real-time: the most recent, not yet materialised data is included).
CREATE MATERIALIZED VIEW objects_hourly
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT time_bucket(INTERVAL '1 hour', start_time) AS bucket,
       site, camera, label,
       count(*) AS objects,
       avg(EXTRACT(EPOCH FROM (end_time - start_time))) AS avg_duration_s
FROM tracked_objects
GROUP BY bucket, site, camera, label
WITH NO DATA;

CREATE MATERIALIZED VIEW zone_dwell_hourly
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT time_bucket(INTERVAL '1 hour', enter_time) AS bucket,
       site, camera, zone, label,
       count(*) AS visits,
       avg(EXTRACT(EPOCH FROM (exit_time - enter_time))) AS avg_dwell_s,
       max(EXTRACT(EPOCH FROM (exit_time - enter_time))) AS max_dwell_s
FROM zone_visits
GROUP BY bucket, site, camera, zone, label
WITH NO DATA;

SELECT add_continuous_aggregate_policy('objects_hourly',
    start_offset => INTERVAL '3 days', end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '5 minutes');
SELECT add_continuous_aggregate_policy('zone_dwell_hourly',
    start_offset => INTERVAL '3 days', end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '5 minutes');

-- Convenience view for dashboards: visit duration (still-open visits count up to now).
CREATE VIEW zone_visits_v AS
SELECT site, camera, zone, label, event_id, enter_time, exit_time,
       EXTRACT(EPOCH FROM (coalesce(exit_time, now()) - enter_time)) AS dwell_s,
       exit_time IS NULL AS in_zone_now
FROM zone_visits;

-- Retention (GDPR): raw rows 30 days, anonymous aggregates 400 days.
SELECT add_retention_policy('tracked_objects', INTERVAL '30 days');
SELECT add_retention_policy('zone_visits',     INTERVAL '30 days');
SELECT add_retention_policy('review_items',    INTERVAL '30 days');
SELECT add_retention_policy('object_updates',  INTERVAL '30 days');
SELECT add_retention_policy('status_events',   INTERVAL '30 days');
SELECT add_retention_policy('frigate_stats',   INTERVAL '30 days');
SELECT add_retention_policy('objects_hourly',    INTERVAL '400 days');
SELECT add_retention_policy('zone_dwell_hourly', INTERVAL '400 days');

-- Least privilege: the ingest writes, Grafana only reads.
GRANT USAGE ON SCHEMA public TO insights_writer, grafana_reader;
GRANT SELECT, INSERT, UPDATE ON tracked_objects, zone_visits, review_items, object_updates,
    site_status, status_events, frigate_stats TO insights_writer;
GRANT SELECT ON tracked_objects, zone_visits, review_items, object_updates, site_status,
    status_events, frigate_stats, objects_hourly, zone_dwell_hourly, zone_visits_v TO grafana_reader;
