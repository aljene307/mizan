#!/bin/sh
# Lance les tests du schéma depuis le conteneur postgres :
#   docker compose exec postgres sh /db/tests/lancer.sh
# Les tests s'exécutent dans des transactions annulées : la base reste intacte.
set -e

echo "== Schéma et contraintes (en tant que $POSTGRES_USER)"
psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$MIZAN_DB" -f /db/tests/01_schema_admin.sql

echo "== Droits du rôle applicatif (en tant que mizan_app)"
PGPASSWORD="$MIZAN_APP_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 \
    -h localhost -U mizan_app -d "$MIZAN_DB" -f /db/tests/02_droits_app.sql

echo "== Réception, réservation et extraction (en tant que mizan_app)"
PGPASSWORD="$MIZAN_APP_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 \
    -h localhost -U mizan_app -d "$MIZAN_DB" -f /db/tests/03_extraction.sql

echo "== Contrôles, décisions humaines et référentiel (préparation par $POSTGRES_USER, actions en tant que mizan_app)"
psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$MIZAN_DB" -f /db/tests/04_controles.sql

echo "== Canaux : inscription, notifications, boutons, justification (préparation par $POSTGRES_USER, actions en tant que mizan_app)"
psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$MIZAN_DB" -f /db/tests/05_canaux.sql

echo "== Rapprochement bancaire (préparation par $POSTGRES_USER, actions en tant que mizan_app)"
psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$MIZAN_DB" -f /db/tests/06_rapprochement.sql

echo "== Tous les tests sont passés"
# (Si un test échoue, psql s'arrête sur la ligne « ECHEC » et ce message n'apparaît pas.)
