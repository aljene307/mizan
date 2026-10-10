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

echo "== Restitution : rôle de lecture et vues (préparation par $POSTGRES_USER, lectures en tant que mizan_lecture)"
psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$MIZAN_DB" -f /db/tests/07_restitution.sql

echo "== Ordres de paiement et sortie sans ordre (préparation par $POSTGRES_USER, actions en tant que mizan_app)"
psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$MIZAN_DB" -f /db/tests/08_ordres.sql

echo "== Rapprochement manuel d'une ligne rejetée (préparation par $POSTGRES_USER, actions en tant que mizan_app)"
psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$MIZAN_DB" -f /db/tests/09_rapprochement_manuel.sql

echo "== Questions en langage naturel : file et quota (préparation par $POSTGRES_USER, actions en tant que mizan_app)"
psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$MIZAN_DB" -f /db/tests/10_questions.sql

echo "== Annulation d'un rapprochement (préparation par $POSTGRES_USER, actions en tant que mizan_app)"
psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$MIZAN_DB" -f /db/tests/11_annulation.sql

echo "== Restitution : vraie connexion en tant que mizan_lecture (réglages de session)"
lecture() {
    PGPASSWORD="$MIZAN_LECTURE_PASSWORD" psql -X -q -t -A -h localhost -U mizan_lecture -d "$MIZAN_DB" -c "$1" 2>&1
}
verifier() {  # verifier <libellé> <obtenu> <motif attendu>
    case "$2" in
        *$3*) echo "OK     $1" ;;
        *) echo "ECHEC  $1 : obtenu « $2 »"; exit 1 ;;
    esac
}
verifier "connexion : transaction en lecture seule" "$(lecture 'SHOW transaction_read_only')" "on"
verifier "connexion : vues de restitution lisibles sans préfixe" "$(lecture 'SELECT count(*) >= 0 FROM echeancier')" "t"
# Chaque vue, toutes colonnes : une vraie connexion applique les réglages du
# rôle (chemin de recherche), ce que SET ROLE ne fait pas (défaut du 2026-10-09).
for vue in $(psql -X -q -t -A -U "$POSTGRES_USER" -d "$MIZAN_DB" \
        -c "SELECT table_name FROM information_schema.views WHERE table_schema = 'restitution' ORDER BY 1"); do
    # x::text lit chaque ligne entière : aucune colonne ne peut être ignorée.
    obtenu="$(lecture "SELECT 'lu:' || coalesce(sum(length(x::text)), 0) FROM (SELECT * FROM $vue) x")"
    case "$obtenu" in
        lu:*) echo "OK     connexion : vue $vue lisible en entier" ;;
        *) echo "ECHEC  connexion : vue $vue illisible : « $obtenu »"; exit 1 ;;
    esac
done
verifier "connexion : écriture refusée même dans une table temporaire créée" \
    "$(lecture 'CREATE TEMP TABLE t (a int)')" "read-only transaction"
# La lecture seule de la session peut être levée par le rôle lui-même : ce
# sont les droits qui protègent la base, pas ce réglage (défense en profondeur).
verifier "connexion : même en mode écriture, aucune table de public accessible" \
    "$(lecture 'BEGIN READ WRITE; SELECT 1 FROM public.factures')" "permission denied"

echo "== Tous les tests sont passés"
# (Si un test échoue, psql s'arrête sur la ligne « ECHEC » et ce message n'apparaît pas.)
