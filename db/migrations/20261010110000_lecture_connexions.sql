-- migrate:up

-- Incident du 2026-10-10 : le pool de Grafana gardait les 5 connexions
-- permises à mizan_lecture (D-068) ; le workflow « Questions » et les scripts
-- ne pouvaient plus se connecter. Grafana est désormais limité à 2 connexions
-- (provisionnement) ; la limite du rôle passe à 10 pour laisser la place aux
-- autres lecteurs.
ALTER ROLE mizan_lecture CONNECTION LIMIT 10;

-- migrate:down

ALTER ROLE mizan_lecture CONNECTION LIMIT 5;
