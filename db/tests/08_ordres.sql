-- Tests des ordres de paiement (D-068, C-a1) : proposition d'un lot sur le
-- RIB du référentiel (D-058), approbation par le canal (responsable seul,
-- revérification MZ051), et contrôle « sortie sans ordre » à partir de la
-- date de mise en service. Préparation par l'administrateur ; actions sous le
-- rôle applicatif. Transaction annulée à la fin.
\set ON_ERROR_STOP on
\set VERBOSITY terse
BEGIN;
SET ROLE mizan_app;
\ir 00_outils.sql
RESET ROLE;
\o /dev/null

-- Données de départ (administrateur) -----------------------------------------------------
INSERT INTO utilisateurs (nom, role, fictif) VALUES ('Ordres – Responsable', 'responsable', TRUE), ('Ordres – Validateur', 'validateur', TRUE);
CREATE FUNCTION pg_temp.u(p TEXT) RETURNS BIGINT LANGUAGE sql AS $f$ SELECT id FROM utilisateurs WHERE nom = p $f$;
-- Isolement : un lot réel en attente est mis de côté, seules les adresses du
-- test sont actives (transaction annulée à la fin).
INSERT INTO decisions_lot_paiement (lot_id, decision, utilisateur_id, justification)
SELECT id, 'refuser', pg_temp.u('Ordres – Responsable'), 'Isolement du test : lot réel mis de côté' FROM lots_paiement WHERE statut = 'propose';
UPDATE adresses_canal SET active = FALSE;
INSERT INTO adresses_canal (utilisateur_id, canal, adresse) VALUES
    (pg_temp.u('Ordres – Responsable'), 'telegram', '911'), (pg_temp.u('Ordres – Validateur'), 'telegram', '912');
WITH f AS (INSERT INTO fournisseurs (raison_sociale, matricule_fiscal) VALUES ('Fournisseur Ordres', '9912355B') RETURNING id)
INSERT INTO fournisseur_ribs (fournisseur_id, rib, valide_du) SELECT id, '99001000000000000165', '2026-01-01' FROM f;
CREATE FUNCTION pg_temp.f(p TEXT) RETURNS BIGINT LANGUAGE sql AS $f$ SELECT id FROM factures WHERE fichier_nom = p $f$;
CREATE FUNCTION pg_temp.facture(p_nom TEXT, p_statut TEXT, p_ttc NUMERIC, p_echeance DATE, p_devise TEXT DEFAULT 'TND') RETURNS VOID LANGUAGE sql AS $f$
    INSERT INTO factures (fichier_nom, statut, numero, fournisseur_id, canal_reception, format_source, fichier_sha256,
                          montant_ttc, devise, date_facture, date_echeance, rib_facture)
    VALUES (p_nom, p_statut, p_nom, (SELECT id FROM fournisseurs WHERE matricule_fiscal = '9912355B'), 'dossier', 'pdf',
            encode(sha256(convert_to(p_nom, 'UTF8')), 'hex'), p_ttc, p_devise, '2026-08-01', p_echeance, '99003000000000000269')
$f$;
SELECT pg_temp.facture('O-RETARD', 'validee', 100, '2026-09-30');
SELECT pg_temp.facture('O-PROCHE', 'conforme', 40, current_date + 3);
SELECT pg_temp.facture('O-LOIN', 'validee', 50, current_date + 60);
SELECT pg_temp.facture('O-AVANT', 'validee', 70, '2026-09-30');
SELECT pg_temp.facture('O-EUR', 'validee', 80, '2026-09-30', 'EUR');
SELECT pg_temp.facture('O-BLOQ', 'bloquee', 90, '2026-09-30');
CREATE FUNCTION pg_temp.ordres_test() RETURNS TEXT LANGUAGE sql AS $f$
    SELECT string_agg(f.numero || ':' || o.montant || ':' || o.rib || ':' || o.reference, ',' ORDER BY f.numero)
    FROM ordres_paiement o JOIN factures f ON f.id = o.facture_id WHERE f.numero LIKE 'O-%'
$f$;

-- Proposition d'un lot (rôle applicatif) ----------------------------------------------------
SET ROLE mizan_app;
CREATE TEMP TABLE bilans (nom TEXT PRIMARY KEY, bilan JSONB);
SELECT pg_temp.doit_reussir($$
    INSERT INTO bilans SELECT 'premier', proposer_lot_paiement('{"execution_n8n_id": "exec-test"}')
$$, 'proposer un lot par la fonction prévue');
SELECT pg_temp.doit_valoir($$SELECT (bilan ->> 'nouveau') FROM bilans WHERE nom = 'premier'$$, 'true', 'un lot est créé');
SELECT pg_temp.doit_valoir($$SELECT pg_temp.ordres_test()$$,
    'O-AVANT:70.000:99001000000000000165:FACT O-AVANT,O-PROCHE:40.000:99001000000000000165:FACT O-PROCHE,O-RETARD:100.000:99001000000000000165:FACT O-RETARD',
    'ordres : retards et échéances de la semaine, sur le RIB du référentiel (jamais celui de la facture) ; ni échéance lointaine, ni devise, ni facture non approuvée');
SELECT pg_temp.doit_valoir($$
    SELECT (proposer_lot_paiement('{}') ->> 'lot_id') = (SELECT bilan ->> 'lot_id' FROM bilans WHERE nom = 'premier')
$$, 'true', 'un lot déjà en attente est renvoyé tel quel');
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM journal_audit WHERE action = 'lot_paiement.propose'
      AND entite_id = (SELECT bilan ->> 'lot_id' FROM bilans WHERE nom = 'premier')
$$, '1', 'proposition tracée au journal');
SELECT pg_temp.doit_echouer($$INSERT INTO ordres_paiement (lot_id, facture_id, fournisseur_id, fournisseur_rib_id, rib, beneficiaire, montant, reference)
    SELECT lot_id, facture_id, fournisseur_id, fournisseur_rib_id, '99003000000000000269', beneficiaire, montant, reference FROM ordres_paiement LIMIT 1$$,
    '42501', 'aucun ordre écrit directement (RIB de son choix)');
SELECT pg_temp.doit_echouer($$UPDATE lots_paiement SET statut = 'approuve'$$, '42501', 'un lot ne s''approuve pas directement');
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_lot_paiement (lot_id, decision, utilisateur_id, justification)
    SELECT (bilan ->> 'lot_id')::bigint, 'approuver', pg_temp.u('Ordres – Responsable'), 'Approbation sans passer par un canal' FROM bilans
$$, '42501', 'une décision ne passe que par un canal (D-062)');

-- Décision : règles (administrateur, comme dans 04 et 06) -------------------------------------
RESET ROLE;
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_lot_paiement (lot_id, decision, utilisateur_id, justification)
    SELECT (bilan ->> 'lot_id')::bigint, 'approuver', pg_temp.u('Ordres – Validateur'), 'Lot vérifié, à payer cette semaine' FROM bilans
$$, 'MZ014', 'un validateur n''approuve pas un lot (responsable seulement)');
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_lot_paiement (lot_id, decision, utilisateur_id, justification)
    SELECT (bilan ->> 'lot_id')::bigint, 'approuver', pg_temp.u('Ordres – Responsable'), 'ok' FROM bilans
$$, 'MZ013', 'justification obligatoire');
-- RIB changé au référentiel après la proposition : l'ordre est périmé.
SAVEPOINT avant_rib;
UPDATE fournisseur_ribs SET valide_au = current_date WHERE rib = '99001000000000000165';
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_lot_paiement (lot_id, decision, utilisateur_id, justification)
    SELECT (bilan ->> 'lot_id')::bigint, 'approuver', pg_temp.u('Ordres – Responsable'), 'Lot vérifié, à payer cette semaine' FROM bilans
$$, 'MZ051', 'RIB plus actif au référentiel : approbation refusée');
ROLLBACK TO SAVEPOINT avant_rib;
-- Facture rejetée entre-temps : l'ordre est périmé.
SAVEPOINT avant_rejet;
UPDATE factures SET statut = 'rejetee' WHERE numero = 'O-PROCHE';
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_lot_paiement (lot_id, decision, utilisateur_id, justification)
    SELECT (bilan ->> 'lot_id')::bigint, 'approuver', pg_temp.u('Ordres – Responsable'), 'Lot vérifié, à payer cette semaine' FROM bilans
$$, 'MZ051', 'facture plus approuvée : approbation refusée');
ROLLBACK TO SAVEPOINT avant_rejet;

-- Par le canal (D-062) : notification au responsable seul, approbation ---------------------------
SET ROLE mizan_app;
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(u.nom, ', ') FROM notifications_a_preparer('telegram') n JOIN utilisateurs u ON u.id = n.utilisateur_id
    WHERE n.objet = 'lot_paiement' AND n.lot_id = (SELECT (bilan ->> 'lot_id')::bigint FROM bilans WHERE nom = 'premier')
$$, 'Ordres – Responsable', 'lot en attente : notifié aux responsables seulement');
SELECT pg_temp.doit_valoir($$
    SELECT (SELECT string_agg(o ->> 'reference' || '@' || (o ->> 'rib'), ',' ORDER BY o ->> 'reference')
            FROM jsonb_array_elements(d -> 'lot' -> 'ordres') o WHERE o ->> 'reference' LIKE 'FACT O-%')
    FROM donnees_notifications('telegram') d WHERE d -> 'candidat' ->> 'objet' = 'lot_paiement'
$$, 'FACT O-AVANT@99001000000000000165,FACT O-PROCHE@99001000000000000165,FACT O-RETARD@99001000000000000165',
    'données du lot : ordres avec le RIB du référentiel');
CREATE TEMP TABLE jetons (nom TEXT PRIMARY KEY, jeton TEXT);
SELECT pg_temp.doit_reussir($$
    INSERT INTO jetons SELECT 'lot', n.jeton FROM creer_notification(jsonb_build_object(
        'canal', 'telegram', 'utilisateur_id', pg_temp.u('Ordres – Responsable'), 'objet', 'lot_paiement',
        'lot_id', (SELECT (bilan ->> 'lot_id')::bigint FROM bilans WHERE nom = 'premier'), 'contenu', '{}'::jsonb,
        'actions', '[{"code": "approuver_lot"}, {"code": "refuser_lot"}]'::jsonb)) n;
$$, 'notification du lot créée');
CREATE FUNCTION pg_temp.ev(p_ref TEXT, p_adresse TEXT, p_extra JSONB) RETURNS TEXT LANGUAGE sql AS $f$
    SELECT recevoir_evenement(jsonb_build_object('canal', 'telegram', 'reference', p_ref, 'adresse', p_adresse) || p_extra) ->> 'code'
$f$;
SELECT pg_temp.doit_valoir($$
    SELECT pg_temp.ev('o1', '911', jsonb_build_object('type', 'action', 'jeton', (SELECT jeton FROM jetons WHERE nom = 'lot'), 'indice', '0'))
           || '|' || pg_temp.ev('o2', '911', '{"type": "texte", "texte": "Lot vérifié, échéances de la semaine"}')
$$, 'justification_demandee|decision_enregistree', 'le responsable approuve le lot par le canal, avec justification');
SELECT pg_temp.doit_valoir($$
    SELECT l.statut || '|' || d.canal || '|' || (d.utilisateur_id = pg_temp.u('Ordres – Responsable'))::text
    FROM lots_paiement l JOIN decisions_lot_paiement d ON d.lot_id = l.id
    WHERE l.id = (SELECT (bilan ->> 'lot_id')::bigint FROM bilans WHERE nom = 'premier')
$$, 'approuve|telegram|true', 'lot approuvé, canal et auteur tracés');
SELECT pg_temp.doit_valoir($$
    SELECT pg_temp.ev('o3', '911', jsonb_build_object('type', 'action', 'jeton', (SELECT jeton FROM jetons WHERE nom = 'lot'), 'indice', '1'))
$$, 'notification_perimee', 'un bouton de lot déjà décidé ne vaut plus');
SELECT pg_temp.doit_echouer($$
    SELECT creer_notification(jsonb_build_object('canal', 'telegram', 'utilisateur_id', pg_temp.u('Ordres – Responsable'),
        'objet', 'lot_paiement', 'lot_id', (SELECT (bilan ->> 'lot_id')::bigint FROM bilans WHERE nom = 'premier'),
        'contenu', '{}'::jsonb, 'actions', '[]'::jsonb))
$$, 'MZ031', 'pas de notification pour un lot déjà décidé');
SELECT pg_temp.doit_echouer($$UPDATE ordres_paiement SET rib = '99003000000000000269'$$, '42501', 'un ordre ne se modifie pas (rôle applicatif)');
RESET ROLE;
SELECT pg_temp.doit_echouer($$UPDATE ordres_paiement SET rib = '99003000000000000269'$$, 'MZ001', 'un ordre ne se modifie pas, même par l''administrateur');

-- Un ordre approuvé n'est pas reproposé ------------------------------------------------------
SET ROLE mizan_app;
SELECT pg_temp.doit_reussir($$INSERT INTO bilans SELECT 'second', proposer_lot_paiement('{}')$$, 'nouvelle proposition');
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM ordres_paiement o JOIN factures f ON f.id = o.facture_id WHERE f.numero LIKE 'O-%'
$$, '3', 'factures déjà ordonnées : pas de second ordre');

-- Contrôle « sortie sans ordre » ----------------------------------------------------------------
-- Relevé : une opération avant la mise en service (2026-10-01), puis des
-- opérations du jour : paiement ordonné, paiement sans ordre, second paiement
-- d'une facture déjà payée selon son ordre.
SELECT pg_temp.doit_reussir($$
    SELECT enregistrer_releve(jsonb_build_object(
        'banque', 'Banque Test', 'rib_compte', '99330228027133819365', 'date_debut', '2026-09-15', 'date_fin', current_date,
        'solde_initial', 1000, 'solde_final', 640, 'fichier_nom', 'releve-ordres.csv', 'fichier_sha256', repeat('e', 64),
        'lignes', jsonb_build_array(
            jsonb_build_object('numero_ligne', 1, 'date_operation', '2026-09-15', 'libelle', 'VIR EMIS FOURNISSEUR ORDRES FACT O-AVANT', 'debit', 70, 'solde', 930),
            jsonb_build_object('numero_ligne', 2, 'date_operation', current_date, 'libelle', 'VIR EMIS FOURNISSEUR ORDRES FACT O-RETARD', 'debit', 100, 'solde', 830),
            jsonb_build_object('numero_ligne', 3, 'date_operation', current_date, 'libelle', 'VIR EMIS FOURNISSEUR ORDRES FACT O-LOIN', 'debit', 50, 'solde', 780),
            jsonb_build_object('numero_ligne', 4, 'date_operation', current_date, 'libelle', 'CHEQUE N 1112223', 'debit', 100, 'solde', 680),
            jsonb_build_object('numero_ligne', 5, 'date_operation', current_date, 'libelle', 'VIR EMIS FOURNISSEUR ORDRES FACT O-PROCHE', 'debit', 40, 'solde', 640))));
$$, 'relevé importé');
CREATE FUNCTION pg_temp.ligne(n INTEGER) RETURNS BIGINT LANGUAGE sql AS $f$
    SELECT l.id FROM lignes_releve l JOIN releves_bancaires r ON r.id = l.releve_id
    WHERE r.fichier_sha256 = repeat('e', 64) AND l.numero_ligne = n
$f$;
CREATE FUNCTION pg_temp.auto(n INTEGER, p_facture TEXT, p_montant NUMERIC) RETURNS JSONB LANGUAGE sql AS $f$
    SELECT jsonb_build_object('ligne_releve_id', pg_temp.ligne(n), 'cas', 'exact', 'score', 1, 'ecart', 0, 'auto', true,
        'affectations', jsonb_build_array(jsonb_build_object('facture_id', pg_temp.f(p_facture), 'montant', p_montant)))
$f$;
SELECT pg_temp.doit_reussir($$
    SELECT enregistrer_rapprochements(jsonb_build_object(
        'releve_id', (SELECT id FROM releves_bancaires WHERE fichier_sha256 = repeat('e', 64)),
        'propositions', jsonb_build_array(
            pg_temp.auto(1, 'O-AVANT', 70), pg_temp.auto(2, 'O-RETARD', 100), pg_temp.auto(3, 'O-LOIN', 50),
            pg_temp.auto(5, 'O-PROCHE', 40),
            -- Second paiement de O-RETARD, proposé puis confirmé par une décision.
            jsonb_build_object('ligne_releve_id', pg_temp.ligne(4), 'cas', 'exact', 'score', 0.6, 'ecart', 0, 'auto', false,
                'affectations', jsonb_build_array(jsonb_build_object('facture_id', pg_temp.f('O-RETARD'), 'montant', 100))))));
$$, 'rapprochements enregistrés');
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(f.numero, ',' ORDER BY f.numero) FROM signalements_paiement s JOIN factures f ON f.id = s.facture_id
    WHERE s.type = 'sortie_sans_ordre' AND f.numero LIKE 'O-%'
$$, 'O-LOIN', 'paiement sans ordre signalé ; paiements ordonnés et opération antérieure à la mise en service non signalés');
RESET ROLE;
SELECT pg_temp.doit_reussir($$
    INSERT INTO decisions_rapprochement (proposition_id, decision, utilisateur_id, justification, canal)
    SELECT id, 'confirmer', pg_temp.u('Ordres – Validateur'), 'Chèque 1112223 pour O-RETARD', 'test'
    FROM propositions_rapprochement WHERE ligne_releve_id = pg_temp.ligne(4)
$$, 'second paiement confirmé par une décision');
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(f.numero || '@' || l.numero_ligne, ',' ORDER BY f.numero, l.numero_ligne)
    FROM signalements_paiement s JOIN factures f ON f.id = s.facture_id JOIN lignes_releve l ON l.id = s.ligne_releve_id
    WHERE s.type = 'sortie_sans_ordre' AND f.numero LIKE 'O-%'
$$, 'O-LOIN@3,O-RETARD@4', 'paiement au-delà de l''ordre (confirmé à la main) signalé aussi');
SELECT pg_temp.doit_valoir($$
    SELECT s.detail -> 'ordres_de_la_facture' -> 0 ->> 'lot_statut' FROM signalements_paiement s
    WHERE s.type = 'sortie_sans_ordre' AND s.facture_id = pg_temp.f('O-RETARD')
$$, 'approuve', 'le signalement cite les ordres existants de la facture');
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(n.objet || ':' || u.nom, ', ') FROM notifications_a_preparer('telegram') n JOIN utilisateurs u ON u.id = n.utilisateur_id
    WHERE n.objet = 'signalement' AND n.signalement_id IN (SELECT id FROM signalements_paiement WHERE type = 'sortie_sans_ordre' AND facture_id = pg_temp.f('O-LOIN'))
$$, 'signalement:Ordres – Responsable', 'sortie sans ordre : notifiée au responsable, comme tout signalement');

-- Restitution (lecture seule) ------------------------------------------------------------------
SET ROLE mizan_lecture;
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(numero || ':' || statut_lot || ':' || paye_depuis || ':' || reste_a_executer || ':' || rib_paiement, ',' ORDER BY numero)
    FROM restitution.ordres_paiement WHERE numero LIKE 'O-%'
$$, 'O-AVANT:approuve:0.000:70.000:99001000000000000165,O-PROCHE:approuve:40.000:0.000:99001000000000000165,O-RETARD:approuve:200.000:0.000:99001000000000000165',
    'ordres en restitution : payé depuis l''approbation, reste à exécuter, RIB du référentiel');
RESET ROLE;
ROLLBACK;
