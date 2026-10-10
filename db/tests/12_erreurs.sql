-- Tests du journal des erreurs de workflow (D-086) : enregistrement par le
-- rôle applicatif, masquage et troncature en base, un message par workflow et
-- par intervalle, destinataires (responsables réels actifs et inscrits),
-- ajout seul, droits, vue de restitution sans message technique.
-- Transaction annulée à la fin.
\set ON_ERROR_STOP on
\set VERBOSITY terse
BEGIN;
SET ROLE mizan_app;
\ir 00_outils.sql
RESET ROLE;
\o /dev/null

INSERT INTO utilisateurs (nom, role, fictif) VALUES
    ('Erreurs – Responsable', 'responsable', FALSE),
    ('Erreurs – Responsable fictif', 'responsable', TRUE),
    ('Erreurs – Validateur', 'validateur', FALSE),
    ('Erreurs – Responsable inactif', 'responsable', FALSE);
CREATE FUNCTION pg_temp.u(p TEXT) RETURNS BIGINT LANGUAGE sql AS $f$ SELECT id FROM utilisateurs WHERE nom = p $f$;
UPDATE utilisateurs SET actif = FALSE WHERE nom = 'Erreurs – Responsable inactif';
UPDATE adresses_canal SET active = FALSE;
INSERT INTO adresses_canal (utilisateur_id, canal, adresse) VALUES
    (pg_temp.u('Erreurs – Responsable'), 'telegram', '941'),
    (pg_temp.u('Erreurs – Responsable fictif'), 'telegram', '942'),
    (pg_temp.u('Erreurs – Validateur'), 'telegram', '943'),
    (pg_temp.u('Erreurs – Responsable inactif'), 'telegram', '944');

SET ROLE mizan_app;
CREATE FUNCTION pg_temp.e(p_workflow TEXT, p_message TEXT) RETURNS JSONB LANGUAGE sql AS $f$
    SELECT signaler_erreur_workflow(jsonb_build_object('workflow_id', 'wf-test', 'workflow_nom', p_workflow,
        'noeud', 'Nœud test', 'execution_n8n_id', '123', 'mode', 'trigger', 'message', p_message))
$f$;

-- Un message par workflow et par intervalle ------------------------------------------------------
SELECT pg_temp.doit_valoir($$SELECT (pg_temp.e('Erreurs – WF A', 'panne 1') ->> 'notifier')$$,
    'true', 'première erreur d''un workflow : message envoyé');
SELECT pg_temp.doit_valoir($$SELECT (pg_temp.e('Erreurs – WF A', 'panne 2') ->> 'notifier') || '|' || (pg_temp.e('Erreurs – WF A', 'panne 3') -> 'destinataires')::text$$,
    'false|[]', 'erreurs suivantes du même workflow dans l''intervalle : enregistrées, sans message ni destinataire');
SELECT pg_temp.doit_valoir($$SELECT (pg_temp.e('Erreurs – WF B', 'panne') ->> 'notifier')$$,
    'true', 'un autre workflow a son propre intervalle');
SELECT pg_temp.doit_valoir($$SELECT (pg_temp.e('Erreurs – WF C', 'panne') -> 'destinataires')::text$$,
    '["941"]', 'destinataires : responsables réels, actifs, inscrits (ni fictif, ni validateur, ni inactif)');
SELECT pg_temp.doit_valoir($$SELECT (pg_temp.e('Erreurs – WF D', 'panne') ->> 'intervalle_minutes')$$,
    '60', 'intervalle renvoyé pour le message (paramètre)');
RESET ROLE;
-- Intervalle écoulé : un nouveau message part.
ALTER TABLE erreurs_workflow DISABLE TRIGGER erreurs_workflow_pas_de_modification;
UPDATE erreurs_workflow SET survenue_le = now() - interval '61 minutes' WHERE workflow_nom = 'Erreurs – WF A';
ALTER TABLE erreurs_workflow ENABLE TRIGGER erreurs_workflow_pas_de_modification;
SET ROLE mizan_app;
SELECT pg_temp.doit_valoir($$SELECT (pg_temp.e('Erreurs – WF A', 'panne 4') ->> 'notifier')$$,
    'true', 'intervalle écoulé : nouveau message');

-- Masquage et troncature en base -------------------------------------------------------------
SELECT pg_temp.doit_valoir($$SELECT (pg_temp.e('Erreurs – WF M', 'url https://api.telegram.org/bot123456789:AAFabcdefghijklmnopqrstuvwxyz0123456/getUpdates') ->> 'notifier')$$,
    'true', 'erreur citant un jeton de bot : enregistrée');
SELECT pg_temp.e('Erreurs – WF M', 'clé AIzaSyA1234567890abcdefghijklmnopqrstu et postgres://mizan_app:motdepasse123@postgres/mizan et ?key=abc&x=1');
SELECT pg_temp.e('Erreurs – WF L', repeat('x', 800));
SELECT pg_temp.e('', NULL);
RESET ROLE;
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(message, ' || ' ORDER BY id) FROM erreurs_workflow WHERE workflow_nom = 'Erreurs – WF M'
$$, 'url https://api.telegram.org/bot***/getUpdates || clé *** et postgres://mizan_app:***@postgres/mizan et ?key=***&x=1',
    'jeton, clé Google, mot de passe d''URL et secret en paramètre masqués en base');
SELECT pg_temp.doit_valoir($$SELECT max(char_length(message))::text FROM erreurs_workflow WHERE workflow_nom = 'Erreurs – WF L'$$,
    '500', 'message tronqué à 500 caractères');
SELECT pg_temp.doit_valoir($$SELECT workflow_nom || '|' || message FROM erreurs_workflow ORDER BY id DESC LIMIT 1$$,
    'workflow inconnu|erreur sans message', 'donnée incomplète : erreur enregistrée quand même');
SELECT pg_temp.doit_valoir($$SELECT masquer_secrets('erreur à 12:30, facture 2026-10-10')$$,
    'erreur à 12:30, facture 2026-10-10', 'texte ordinaire : rien masqué');

-- Ajout seul et droits ------------------------------------------------------------------------------
SELECT pg_temp.doit_echouer($$UPDATE erreurs_workflow SET message = 'x'$$, 'MZ001', 'une erreur enregistrée ne se modifie pas');
SELECT pg_temp.doit_echouer($$DELETE FROM erreurs_workflow$$, 'MZ001', 'une erreur enregistrée ne se supprime pas');
SET ROLE mizan_app;
SELECT pg_temp.doit_echouer($$SELECT count(*) FROM erreurs_workflow$$, '42501', 'le rôle applicatif ne lit pas le journal des erreurs');
SELECT pg_temp.doit_echouer($$INSERT INTO erreurs_workflow (workflow_nom, message, notifiee) VALUES ('x', 'x', true)$$,
    '42501', 'aucune erreur écrite directement : seulement par la fonction');
RESET ROLE;
SET ROLE mizan_lecture;
SELECT pg_temp.doit_valoir($$SELECT count(*)::text FROM restitution.erreurs_workflow WHERE workflow_nom LIKE 'Erreurs – %'$$,
    '10', 'restitution : erreurs lisibles par le rôle de lecture');
RESET ROLE;
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(column_name, ',' ORDER BY ordinal_position) FROM information_schema.columns
    WHERE table_schema = 'restitution' AND table_name = 'erreurs_workflow'
$$, 'erreur_id,survenue_le,workflow_nom,noeud,notifiee', 'restitution : jamais le message technique');

ROLLBACK;
