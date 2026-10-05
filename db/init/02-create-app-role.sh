#!/bin/sh
# Crée (ou met à jour) le rôle applicatif mizan_app utilisé par n8n.
# Exécuté automatiquement au premier démarrage (volume vide). Idempotent :
# peut être relancé à la main, par exemple après un changement de mot de passe :
#   docker compose exec postgres sh /docker-entrypoint-initdb.d/02-create-app-role.sh
# Les droits sur les tables sont accordés par les migrations (db/migrations).
set -e

: "${MIZAN_APP_PASSWORD:?MIZAN_APP_PASSWORD doit être défini dans .env}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -v app_password="$MIZAN_APP_PASSWORD" <<'EOSQL'
SELECT 'CREATE ROLE mizan_app'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'mizan_app')\gexec
ALTER ROLE mizan_app WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'app_password';
EOSQL
