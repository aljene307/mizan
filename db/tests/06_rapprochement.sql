-- Tests du rapprochement bancaire (D-065) : import du relevé et contrôle des
-- soldes, enregistrement des propositions et signalements, décisions
-- humaines, situation de paiement. Préparation par l'administrateur ;
-- actions sous le rôle applicatif. Transaction annulée à la fin.
\set ON_ERROR_STOP on
\set VERBOSITY terse
BEGIN;
SET ROLE mizan_app;
\ir 00_outils.sql
RESET ROLE;
\o /dev/null

-- Données de départ (administrateur) -----------------------------------------------
INSERT INTO utilisateurs (nom, role, fictif) VALUES ('Rappr – Responsable', 'responsable', TRUE), ('Rappr – Validateur', 'validateur', TRUE);
WITH f AS (INSERT INTO fournisseurs (raison_sociale, matricule_fiscal) VALUES ('Fournisseur Rappr', '9912355B') RETURNING id)
INSERT INTO fournisseur_ribs (fournisseur_id, rib, valide_du) SELECT id, '99001000000000000165', '2026-01-01' FROM f;
CREATE FUNCTION pg_temp.u(p TEXT) RETURNS BIGINT LANGUAGE sql AS $f$ SELECT id FROM utilisateurs WHERE nom = p $f$;
CREATE FUNCTION pg_temp.f(p TEXT) RETURNS BIGINT LANGUAGE sql AS $f$ SELECT id FROM factures WHERE fichier_nom = p $f$;
CREATE FUNCTION pg_temp.facture(p_nom TEXT, p_statut TEXT, p_type TEXT, p_ttc NUMERIC) RETURNS VOID LANGUAGE sql AS $f$
    INSERT INTO factures (fichier_nom, statut, type_document, numero, fournisseur_id, canal_reception, format_source,
                          fichier_sha256, montant_ttc, date_facture, date_echeance)
    VALUES (p_nom, p_statut, p_type, p_nom, (SELECT id FROM fournisseurs WHERE matricule_fiscal = '9912355B'),
            'dossier', 'pdf', encode(sha256(convert_to(p_nom, 'UTF8')), 'hex'), p_ttc, '2026-03-01', '2026-03-31')
$f$;
SELECT pg_temp.facture('R-A', 'conforme', 'facture', 100);
SELECT pg_temp.facture('R-B', 'validee', 'facture', 200);
SELECT pg_temp.facture('R-AV', 'conforme', 'avoir', 30);
SELECT pg_temp.facture('R-BLOQ', 'bloquee', 'facture', 77);
CREATE FUNCTION pg_temp.releve(p_sha TEXT, p_lignes JSONB, p_final NUMERIC) RETURNS JSONB LANGUAGE sql AS $f$
    SELECT to_jsonb(r) FROM enregistrer_releve(jsonb_build_object(
        'banque', 'Banque Test', 'rib_compte', '99330228027133819365', 'date_debut', '2026-03-01', 'date_fin', '2026-03-31',
        'solde_initial', 1000, 'solde_final', p_final, 'fichier_nom', 'releve-test.csv', 'fichier_sha256', p_sha,
        'lignes', p_lignes)) r
$f$;
CREATE FUNCTION pg_temp.ligne(n INTEGER) RETURNS BIGINT LANGUAGE sql AS $f$
    SELECT l.id FROM lignes_releve l JOIN releves_bancaires r ON r.id = l.releve_id
    WHERE r.fichier_sha256 = repeat('a', 64) AND l.numero_ligne = n
$f$;

SET ROLE mizan_app;

-- Import et contrôle des soldes -----------------------------------------------------------
SELECT pg_temp.doit_echouer($$
    SELECT pg_temp.releve(repeat('b', 64), '[{"numero_ligne": 1, "date_operation": "2026-03-10", "libelle": "X", "debit": 100, "solde": 950}]', 900)
$$, 'MZ040', 'solde d''une ligne incohérent : import refusé');
SELECT pg_temp.doit_echouer($$
    SELECT pg_temp.releve(repeat('b', 64), '[{"numero_ligne": 1, "date_operation": "2026-03-10", "libelle": "X", "debit": 100, "solde": 900}]', 899)
$$, 'MZ040', 'solde final incohérent : import refusé');
SELECT pg_temp.doit_valoir($$
    SELECT pg_temp.releve(repeat('a', 64), '[
        {"numero_ligne": 1, "date_operation": "2026-03-10", "libelle": "VIR EMIS FOURNISSEUR RAPPR FACT R-A", "debit": 100, "solde": 900},
        {"numero_ligne": 2, "date_operation": "2026-03-11", "libelle": "CHEQUE N 1234567", "debit": 168, "solde": 732},
        {"numero_ligne": 3, "date_operation": "2026-03-12", "libelle": "PRLV LOYER LOCAUX", "debit": 50, "solde": 682},
        {"numero_ligne": 4, "date_operation": "2026-03-13", "libelle": "VIR EMIS FOURNISSEUR RAPPR FACT R-BLOQ", "debit": 77, "solde": 605},
        {"numero_ligne": 5, "date_operation": "2026-03-14", "libelle": "VIR EMIS INCONNU", "debit": 5, "solde": 600}]', 600) ->> 'nouveau'
$$, 'true', 'relevé cohérent importé');
SELECT pg_temp.doit_valoir($$
    SELECT pg_temp.releve(repeat('a', 64), '[]', 1000) ->> 'nouveau'
$$, 'false', 'un fichier déjà importé ne l''est pas deux fois');
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM journal_audit WHERE action = 'releve.importe'
      AND entite_id = (SELECT id::text FROM releves_bancaires WHERE fichier_sha256 = repeat('a', 64))
$$, '1', 'import tracé au journal');

-- Enregistrement d'un passage ---------------------------------------------------------------
SELECT pg_temp.doit_echouer($$
    SELECT enregistrer_rapprochements(jsonb_build_object('releve_id', 0, 'propositions', jsonb_build_array(jsonb_build_object(
        'ligne_releve_id', pg_temp.ligne(4), 'cas', 'exact', 'score', 1, 'ecart', 0, 'auto', true,
        'affectations', jsonb_build_array(jsonb_build_object('facture_id', pg_temp.f('R-BLOQ'), 'montant', 77))))))
$$, 'MZ041', 'aucune affectation à une facture non approuvée');
SELECT pg_temp.doit_echouer($$
    SELECT enregistrer_rapprochements(jsonb_build_object('releve_id', 0, 'propositions', jsonb_build_array(jsonb_build_object(
        'ligne_releve_id', pg_temp.ligne(2), 'cas', 'net_avoir', 'score', 0.9, 'ecart', 0, 'auto', true,
        'affectations', jsonb_build_array(jsonb_build_object('facture_id', pg_temp.f('R-B'), 'montant', 200),
                                          jsonb_build_object('facture_id', pg_temp.f('R-AV'), 'montant', 30, 'role', 'imputation_avoir'))))))
$$, 'MZ044', 'confirmation automatique réservée au cas exact');
SELECT pg_temp.doit_valoir($$
    SELECT enregistrer_rapprochements(jsonb_build_object(
        'releve_id', (SELECT id FROM releves_bancaires WHERE fichier_sha256 = repeat('a', 64)),
        'categories', jsonb_build_array(jsonb_build_object('ligne_releve_id', pg_temp.ligne(3), 'categorie', 'loyer')),
        'propositions', jsonb_build_array(
            jsonb_build_object('ligne_releve_id', pg_temp.ligne(1), 'cas', 'exact', 'score', 1, 'ecart', 0, 'auto', true,
                'raisons', '["montant exact", "numéro dans le libellé"]'::jsonb,
                'affectations', jsonb_build_array(jsonb_build_object('facture_id', pg_temp.f('R-A'), 'montant', 100))),
            jsonb_build_object('ligne_releve_id', pg_temp.ligne(2), 'cas', 'net_avoir', 'score', 0.8, 'ecart', -2, 'auto', false,
                'affectations', jsonb_build_array(jsonb_build_object('facture_id', pg_temp.f('R-B'), 'montant', 200),
                                                  jsonb_build_object('facture_id', pg_temp.f('R-AV'), 'montant', 30, 'role', 'imputation_avoir')))),
        'signalements', jsonb_build_array(
            jsonb_build_object('type', 'payee_non_approuvee', 'ligne_releve_id', pg_temp.ligne(4), 'facture_id', pg_temp.f('R-BLOQ'),
                               'message', 'paiement d''une facture bloquée'),
            jsonb_build_object('type', 'sortie_sans_facture', 'ligne_releve_id', pg_temp.ligne(5), 'message', 'sortie sans facture'))))::text
$$, '{"a_confirmer": 1, "categorisees": 1, "signalements": 2, "confirmees_auto": 1}', 'passage enregistré, bilan renvoyé');
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(l.numero_ligne::text, ',' ORDER BY l.numero_ligne)
    FROM jsonb_array_elements(contexte_rapprochement((SELECT id FROM releves_bancaires WHERE fichier_sha256 = repeat('a', 64))) -> 'lignes') x
    JOIN lignes_releve l ON l.id = (x ->> 'id')::BIGINT
$$, NULL, 'toutes les lignes traitées : plus rien à apparier');
SELECT pg_temp.doit_valoir($$
    SELECT (contexte_rapprochement((SELECT id FROM releves_bancaires WHERE fichier_sha256 = repeat('a', 64))) -> 'factures')::text LIKE '%"deja_paye": 100%'
$$, 'true', 'le contexte connaît les montants déjà payés');
SELECT pg_temp.doit_valoir($$
    SELECT etat || '|' || paiement_propose || '|' || en_retard FROM situation_paiement WHERE numero = 'R-B'
$$, 'paiement_propose|200.000|false',
    'paiement au relevé en attente de confirmation : « paiement proposé », pas « en retard » (échéance passée)');
SELECT pg_temp.doit_echouer($$UPDATE propositions_rapprochement SET statut = 'confirme'$$, '42501', 'une proposition ne se confirme pas directement');
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_rapprochement (proposition_id, decision, utilisateur_id, justification)
    SELECT id, 'confirmer', pg_temp.u('Rappr – Validateur'), 'Confirmation sans passer par un canal' FROM propositions_rapprochement LIMIT 1
$$, '42501', 'une décision ne passe que par un canal (D-062)');

-- Décisions humaines (testées sous l'administrateur, comme dans 04) -------------------------------
RESET ROLE;
CREATE FUNCTION pg_temp.prop(n INTEGER) RETURNS BIGINT LANGUAGE sql AS $f$
    SELECT id FROM propositions_rapprochement WHERE ligne_releve_id = pg_temp.ligne(n)
$f$;
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_rapprochement (proposition_id, decision, utilisateur_id, justification)
    VALUES (pg_temp.prop(2), 'confirmer', pg_temp.u('Rappr – Validateur'), 'Paiement net de l''avoir AV-30')
$$, 'MZ043', 'écart non nul : motif obligatoire pour confirmer');
SELECT pg_temp.doit_reussir($$
    INSERT INTO decisions_rapprochement (proposition_id, decision, motif_ecart, utilisateur_id, justification, canal)
    VALUES (pg_temp.prop(2), 'confirmer', 'frais_bancaires', pg_temp.u('Rappr – Validateur'), 'Paiement net de l''avoir, frais de 2 TND', 'test')
$$, 'un validateur confirme, avec un motif d''écart');
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(r.role || ':' || r.statut, ',' ORDER BY r.role) || '|' || p.statut || '|' || p.motif_ecart
    FROM propositions_rapprochement p JOIN rapprochements r ON r.proposition_id = p.id WHERE p.id = pg_temp.prop(2) GROUP BY p.statut, p.motif_ecart
$$, 'imputation_avoir:confirme,reglement:confirme|confirme|frais_bancaires', 'proposition et affectations confirmées');
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_rapprochement (proposition_id, decision, utilisateur_id, justification)
    VALUES (pg_temp.prop(2), 'rejeter', pg_temp.u('Rappr – Responsable'), 'Changement d''avis après coup')
$$, 'MZ042', 'une proposition déjà décidée ne se redécide pas');
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM journal_audit WHERE action = 'rapprochement.confirmer' AND entite_id = pg_temp.prop(2)::text
$$, '1', 'décision tracée au journal');

-- Signalements : responsable seulement.
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_signalement (signalement_id, utilisateur_id, justification)
    SELECT id, pg_temp.u('Rappr – Validateur'), 'Paiement vérifié avec le fournisseur' FROM signalements_paiement WHERE facture_id = pg_temp.f('R-BLOQ')
$$, 'MZ014', 'un validateur ne classe pas un signalement');
SELECT pg_temp.doit_reussir($$
    INSERT INTO decisions_signalement (signalement_id, utilisateur_id, justification, canal)
    SELECT id, pg_temp.u('Rappr – Responsable'), 'Paiement autorisé par la direction, facture régularisée', 'test'
    FROM signalements_paiement WHERE facture_id = pg_temp.f('R-BLOQ')
$$, 'un responsable classe le signalement, avec justification');
SELECT pg_temp.doit_valoir($$
    SELECT statut FROM signalements_paiement WHERE facture_id = pg_temp.f('R-BLOQ')
$$, 'classe', 'signalement classé');

-- Situation de paiement (calculée) ---------------------------------------------------------------
SET ROLE mizan_app;
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(numero || ':' || etat || ':' || reste_a_payer, ',' ORDER BY numero) FROM situation_paiement WHERE numero LIKE 'R-%'
$$, 'R-A:payee:0.000,R-B:payee:0.000', 'R-A payée ; R-B réglée par une sortie nette de l''avoir (200 réglés, dont 30 d''avoir)');

-- Par le canal (D-062, D-065) ------------------------------------------------------------------
RESET ROLE;
-- Isolement : seules les adresses de ce test sont actives (transaction annulée à la fin).
UPDATE adresses_canal SET active = FALSE;
INSERT INTO adresses_canal (utilisateur_id, canal, adresse) VALUES
    (pg_temp.u('Rappr – Responsable'), 'telegram', '901'), (pg_temp.u('Rappr – Validateur'), 'telegram', '902');
SELECT pg_temp.facture('R-C', 'conforme', 'facture', 60);
SET ROLE mizan_app;
CREATE TEMP TABLE jetons (nom TEXT PRIMARY KEY, jeton TEXT);
SELECT pg_temp.doit_reussir($$
    SELECT pg_temp.releve(repeat('c', 64), '[{"numero_ligne": 1, "date_operation": "2026-03-20", "libelle": "CHEQUE N 7654321", "debit": 60, "solde": 940}]', 940);
    SELECT enregistrer_rapprochements(jsonb_build_object(
        'releve_id', (SELECT id FROM releves_bancaires WHERE fichier_sha256 = repeat('c', 64)),
        'propositions', jsonb_build_array(jsonb_build_object(
            'ligne_releve_id', (SELECT l.id FROM lignes_releve l JOIN releves_bancaires r ON r.id = l.releve_id WHERE r.fichier_sha256 = repeat('c', 64)),
            'cas', 'exact', 'score', 0.7, 'ecart', 0, 'auto', false, 'raisons', '["montant exact", "chèque : pas de numéro"]'::jsonb,
            'affectations', jsonb_build_array(jsonb_build_object('facture_id', pg_temp.f('R-C'), 'montant', 60))))));
$$, 'second relevé : une proposition à confirmer (chèque)');
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(n.objet || ':' || u.nom, ', ' ORDER BY n.objet, u.nom)
    FROM notifications_a_preparer('telegram') n JOIN utilisateurs u ON u.id = n.utilisateur_id
    WHERE n.objet IN ('rapprochement', 'signalement', 'synthese')
      AND n.releve_id IN (SELECT id FROM releves_bancaires WHERE fichier_sha256 IN (repeat('a', 64), repeat('c', 64)))
$$, 'rapprochement:Rappr – Responsable, rapprochement:Rappr – Validateur, signalement:Rappr – Responsable, synthese:Rappr – Responsable, synthese:Rappr – Responsable, synthese:Rappr – Validateur, synthese:Rappr – Validateur',
    'proposition : validateurs et responsables ; signalement ouvert : responsables seulement ; une synthèse par relevé rapproché');
SELECT pg_temp.doit_valoir($$
    SELECT d -> 'proposition' ->> 'cas' || '|' || (d -> 'proposition' -> 'affectations' -> 0 ->> 'numero') || '|' || (d -> 'proposition' -> 'ligne' ->> 'libelle')
    FROM donnees_notifications('telegram') d WHERE d -> 'candidat' ->> 'objet' = 'rapprochement' AND d -> 'candidat' ->> 'role' = 'validateur'
      AND (d -> 'candidat' ->> 'releve_id')::bigint = (SELECT id FROM releves_bancaires WHERE fichier_sha256 = repeat('c', 64))
$$, 'exact|R-C|CHEQUE N 7654321', 'données d''une proposition : cas, factures affectées, ligne du relevé');
SELECT pg_temp.doit_reussir($$
    INSERT INTO jetons SELECT 'prop-V', n.jeton FROM creer_notification(jsonb_build_object(
        'canal', 'telegram', 'utilisateur_id', pg_temp.u('Rappr – Validateur'), 'objet', 'rapprochement',
        'proposition_id', (SELECT max(id) FROM propositions_rapprochement), 'contenu', '{}'::jsonb,
        'actions', '[{"code": "confirmer_rapprochement"}, {"code": "rejeter_rapprochement"}]'::jsonb)) n;
    INSERT INTO jetons SELECT 'sig-R', n.jeton FROM creer_notification(jsonb_build_object(
        'canal', 'telegram', 'utilisateur_id', pg_temp.u('Rappr – Responsable'), 'objet', 'signalement',
        'signalement_id', (SELECT id FROM signalements_paiement WHERE statut = 'ouvert' AND message = 'sortie sans facture'),
        'contenu', '{}'::jsonb, 'actions', '[{"code": "classer_signalement"}]'::jsonb)) n;
$$, 'notifications de rapprochement et de signalement créées');
CREATE FUNCTION pg_temp.ev(p_ref TEXT, p_adresse TEXT, p_extra JSONB) RETURNS TEXT LANGUAGE sql AS $f$
    SELECT recevoir_evenement(jsonb_build_object('canal', 'telegram', 'reference', p_ref, 'adresse', p_adresse) || p_extra) ->> 'code'
$f$;
SELECT pg_temp.doit_valoir($$
    SELECT pg_temp.ev('r1', '902', jsonb_build_object('type', 'action', 'jeton', (SELECT jeton FROM jetons WHERE nom = 'prop-V'), 'indice', '0'))
           || '|' || pg_temp.ev('r2', '902', '{"type": "texte", "texte": "Chèque 7654321 bien émis pour R-C"}')
$$, 'justification_demandee|decision_enregistree', 'le validateur confirme par le canal, avec justification');
SELECT pg_temp.doit_valoir($$
    SELECT p.statut || '|' || d.canal || '|' || (d.utilisateur_id = pg_temp.u('Rappr – Validateur'))::text
    FROM propositions_rapprochement p JOIN decisions_rapprochement d ON d.proposition_id = p.id WHERE p.id = (SELECT max(id) FROM propositions_rapprochement)
$$, 'confirme|telegram|true', 'proposition confirmée, canal et auteur tracés');
SELECT pg_temp.doit_valoir($$
    SELECT pg_temp.ev('r3', '902', jsonb_build_object('type', 'action', 'jeton', (SELECT jeton FROM jetons WHERE nom = 'prop-V'), 'indice', '1'))
$$, 'notification_perimee', 'un bouton de proposition déjà décidée ne vaut plus');
SELECT pg_temp.doit_valoir($$
    SELECT pg_temp.ev('r4', '901', jsonb_build_object('type', 'action', 'jeton', (SELECT jeton FROM jetons WHERE nom = 'sig-R'), 'indice', '0'))
           || '|' || pg_temp.ev('r5', '901', '{"type": "texte", "texte": "Virement du lot de test, hors périmètre"}')
$$, 'justification_demandee|decision_enregistree', 'le responsable classe le signalement par le canal');
-- Instruction séparée : une instruction ne voit pas les effets des fonctions qu'elle appelle elle-même.
SELECT pg_temp.doit_valoir($$SELECT statut FROM signalements_paiement WHERE message = 'sortie sans facture'$$, 'classe',
    'signalement classé');
SELECT pg_temp.doit_echouer($$
    SELECT creer_notification(jsonb_build_object('canal', 'telegram', 'utilisateur_id', pg_temp.u('Rappr – Responsable'),
        'objet', 'signalement', 'signalement_id', (SELECT id FROM signalements_paiement WHERE message = 'sortie sans facture'),
        'contenu', '{}'::jsonb, 'actions', '[]'::jsonb))
$$, 'MZ031', 'pas de notification pour un signalement déjà classé');

RESET ROLE;
ROLLBACK;
