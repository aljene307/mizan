-- Tests de la file des questions en langage naturel (D-068, B2) : réception
-- par le canal (inscrit seulement, longueur, quota par heure), prise et
-- conclusion par le workflow, droits. Transaction annulée à la fin.
\set ON_ERROR_STOP on
\set VERBOSITY terse
BEGIN;
SET ROLE mizan_app;
\ir 00_outils.sql
RESET ROLE;
\o /dev/null

INSERT INTO utilisateurs (nom, role, fictif) VALUES ('Questions – Validateur', 'validateur', TRUE);
CREATE FUNCTION pg_temp.u(p TEXT) RETURNS BIGINT LANGUAGE sql AS $f$ SELECT id FROM utilisateurs WHERE nom = p $f$;
UPDATE adresses_canal SET active = FALSE;
INSERT INTO adresses_canal (utilisateur_id, canal, adresse) VALUES (pg_temp.u('Questions – Validateur'), 'telegram', '931');
-- Isolement : les questions réelles en attente sont mises de côté.
UPDATE questions SET statut = 'echec' WHERE statut IN ('a_traiter', 'en_cours');

SET ROLE mizan_app;
CREATE FUNCTION pg_temp.q(p_ref TEXT, p_adresse TEXT, p_texte TEXT) RETURNS JSONB LANGUAGE sql AS $f$
    SELECT recevoir_evenement(jsonb_build_object('canal', 'telegram', 'reference', p_ref, 'adresse', p_adresse, 'type', 'question', 'texte', p_texte))
$f$;

-- Réception ------------------------------------------------------------------------------------
SELECT pg_temp.doit_valoir($$SELECT pg_temp.q('q1', '931', 'Combien je dois à Trans-Cap ?') ->> 'code'$$,
    'question_recue', 'question d''un utilisateur inscrit : mise en file');
SELECT pg_temp.doit_valoir($$SELECT pg_temp.q('q2', '999999', 'Quelles factures sont en retard ?') ->> 'code'$$,
    'expediteur_inconnu', 'expéditeur inconnu : rien n''est mis en file');
SELECT pg_temp.doit_valoir($$SELECT pg_temp.q('q3', '931', repeat('x', 501)) ->> 'motif'$$, 'longueur', 'question trop longue refusée');
SELECT pg_temp.doit_valoir($$SELECT pg_temp.q('q1', '931', 'Combien je dois à Trans-Cap ?') ->> 'code'$$,
    'deja_traite', 'même événement reçu deux fois : une seule question');
SELECT pg_temp.doit_echouer($$INSERT INTO questions (utilisateur_id, canal, adresse, texte) VALUES (1, 'telegram', '1', 'x')$$,
    '42501', 'aucune question écrite directement');
SELECT pg_temp.doit_echouer($$SELECT count(*) FROM questions$$, '42501', 'le rôle applicatif ne lit pas les questions');

-- Prise et conclusion ------------------------------------------------------------------------------
CREATE TEMP TABLE prises AS SELECT * FROM prendre_questions(5);
SELECT pg_temp.doit_valoir($$SELECT string_agg(texte || '|' || adresse || '|' || role, ',') FROM prises$$,
    'Combien je dois à Trans-Cap ?|931|validateur', 'question prise une fois, avec l''adresse de réponse et le rôle');
SELECT pg_temp.doit_valoir($$SELECT count(*)::text FROM prendre_questions(5)$$, '0', 'une question prise ne l''est pas deux fois');
SELECT pg_temp.doit_valoir($$
    SELECT conclure_question(jsonb_build_object('question_id', (SELECT question_id FROM prises), 'question_catalogue', 'du_a_un_fournisseur',
        'parametres', jsonb_build_object('fournisseur', 'Trans-Cap'), 'code_reponse', 'ok', 'envoyee', true, 'execution_n8n_id', 'exec-test'))
$$, 'repondue', 'question conclue');
SELECT pg_temp.doit_echouer($$
    SELECT conclure_question(jsonb_build_object('question_id', (SELECT question_id FROM prises), 'envoyee', true))
$$, 'MZ042', 'une question conclue ne l''est pas deux fois');
RESET ROLE;
SELECT pg_temp.doit_valoir($$
    SELECT statut || '|' || question_catalogue || '|' || (parametres ->> 'fournisseur') || '|' || code_reponse
    FROM questions WHERE id = (SELECT question_id FROM prises)
$$, 'repondue|du_a_un_fournisseur|Trans-Cap|ok', 'trace gardée : question du catalogue, paramètres, code de réponse');
SELECT pg_temp.doit_echouer($$DELETE FROM questions$$, 'MZ001', 'une question ne se supprime pas');
-- Exécution interrompue : une question « en cours » depuis plus de 10 minutes est reprise.
UPDATE questions SET statut = 'en_cours', prise_le = now() - interval '11 minutes' WHERE id = (SELECT question_id FROM prises);
SET ROLE mizan_app;
SELECT pg_temp.doit_valoir($$SELECT count(*)::text FROM prendre_questions(5)$$, '1', 'question restée en cours plus de 10 minutes : reprise');

-- Quota par heure --------------------------------------------------------------------------------------
RESET ROLE;
INSERT INTO questions (utilisateur_id, canal, adresse, texte, statut)
SELECT pg_temp.u('Questions – Validateur'), 'telegram', '931', 'question ' || g, 'repondue' FROM generate_series(1, 19) g;
SET ROLE mizan_app;
SELECT pg_temp.doit_valoir($$SELECT (pg_temp.q('q4', '931', 'Encore une ?') ->> 'code') || '|' || (pg_temp.q('q5', '931', 'Et une autre ?') ->> 'motif')$$,
    'question_refusee|quota', 'au-delà de 20 questions par heure : refus');

RESET ROLE;
ROLLBACK;
