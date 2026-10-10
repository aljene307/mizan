#!/bin/sh
# Crée (ou met à jour) le rôle mizan_lecture, en lecture seule sur les vues de
# restitution (D-068), utilisé par le tableau de bord et les questions.
# Exécuté automatiquement au premier démarrage (volume vide). Idempotent :
# peut être relancé à la main, par exemple sur une base déjà créée :
#   docker compose exec postgres sh /docker-entrypoint-initdb.d/03-create-lecture-role.sh
# Ses droits et ses réglages de session sont donnés par les migrations.
set -e

: "${MIZAN_LECTURE_PASSWORD:?MIZAN_LECTURE_PASSWORD doit être défini dans .env}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -v lecture_password="$MIZAN_LECTURE_PASSWORD" <<'EOSQL'
SELECT 'CREATE ROLE mizan_lecture'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'mizan_lecture')\gexec
ALTER ROLE mizan_lecture WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'lecture_password';
EOSQL
