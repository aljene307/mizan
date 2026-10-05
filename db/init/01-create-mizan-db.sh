#!/bin/sh
# Crée la base métier de Mizan à côté de la base interne de n8n.
# Exécuté automatiquement par l'image postgres, une seule fois, quand le volume est vide.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
	CREATE DATABASE "$MIZAN_DB";
EOSQL
