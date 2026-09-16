#!/bin/sh
# Runs ONCE, when the TimescaleDB volume is first initialised, as the postgres superuser.
# Creates the two application roles. Passwords are read from the container environment with
# psql's \getenv, so they never appear in a process command line.
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
\getenv writer_pw INSIGHTS_DB_PASSWORD
\getenv reader_pw GRAFANA_DB_PASSWORD
CREATE ROLE insights_writer LOGIN PASSWORD :'writer_pw';
CREATE ROLE grafana_reader LOGIN PASSWORD :'reader_pw';
SQL
