-- Tests du rapprochement manuel d'une ligne rejetée (D-068, D1) : lignes à
-- rapprocher, notification et candidates, rapprochement par le canal (facture
-- proposée ou désignée par son numéro), écart, refus (MZ041, MZ045, MZ046),
-- « aucune facture », contrôle « sortie sans ordre ». Préparation par
-- l'administrateur ; actions sous le rôle applicatif. Transaction annulée.
\set ON_ERROR_STOP on
\set VERBOSITY terse
BEGIN;
SET ROLE mizan_app;
\ir 00_outils.sql
RESET ROLE;
\o /dev/null

-- Données de départ (administrateur) -----------------------------------------------------
INSERT INTO utilisateurs (nom, role, fictif) VALUES ('Manuel – Responsable', 'responsable', TRUE), ('Manuel – Validateur', 'validateur', TRUE);
CREATE FUNCTION pg_temp.u(p TEXT) RETURNS BIGINT LANGUAGE sql AS $f$ SELECT id FROM utilisateurs WHERE nom = p $f$;
UPDATE adresses_canal SET active = FALSE;
INSERT INTO adresses_canal (utilisateur_id, canal, adresse) VALUES
    (pg_temp.u('Manuel – Responsable'), 'telegram', '921'), (pg_temp.u('Manuel – Validateur'), 'telegram', '922');
WITH f AS (INSERT INTO fournisseurs (raison_sociale, matricule_fiscal) VALUES ('Fournisseur Manuel', '9912355B') RETURNING id)
INSERT INTO fournisseur_ribs (fournisseur_id, rib, valide_du) SELECT id, '99001000000000000165', '2026-01-01' FROM f;
CREATE FUNCTION pg_temp.f(p TEXT) RETURNS BIGINT LANGUAGE sql AS $f$ SELECT id FROM factures WHERE fichier_nom = p $f$;
CREATE FUNCTION pg_temp.facture(p_fichier TEXT, p_numero TEXT, p_statut TEXT, p_ttc NUMERIC) RETURNS VOID LANGUAGE sql AS $f$
    INSERT INTO factures (fichier_nom, statut, numero, fournisseur_id, canal_reception, format_source, fichier_sha256,
                          montant_ttc, devise, date_facture, date_echeance)
    VALUES (p_fichier, p_statut, p_numero, (SELECT id FROM fournisseurs WHERE matricule_fiscal = '9912355B'), 'dossier', 'pdf',
            encode(sha256(convert_to(p_fichier, 'UTF8')), 'hex'), p_ttc, 'TND', '2026-08-01', '2026-09-30')
$f$;
SELECT pg_temp.facture('M-A', 'M-A', 'validee', 300);
SELECT pg_temp.facture('M-B', 'M-B', 'conforme', 500);
SELECT pg_temp.facture('M-C', 'M-C', 'validee', 900);
SELECT pg_temp.facture('M-D', 'M-D', 'validee', 100);
SELECT pg_temp.facture('M-BLOQ', 'M-BLOQ', 'bloquee', 50);
-- Même numéro chez deux fournisseurs (la base interdit le doublon chez un même fournisseur).
SELECT pg_temp.facture('M-DOUBLE-1', 'M-DOUBLE', 'validee', 10);
INSERT INTO fournisseurs (raison_sociale, matricule_fiscal) VALUES ('Second Fournisseur Manuel', '9900001Z');
SELECT pg_temp.facture('M-DOUBLE-2', 'M-DOUBLE', 'a_valider', 20);
UPDATE factures SET fournisseur_id = (SELECT id FROM fournisseurs WHERE matricule_fiscal = '9900001Z'), statut = 'validee'
WHERE fichier_nom = 'M-DOUBLE-2';
-- Relevé : lignes 1, 2 et 4 avant la mise en service du contrôle des ordres ;
-- ligne 3 du jour (contrôlée).
SELECT enregistrer_releve(jsonb_build_object(
    'banque', 'Banque Test', 'rib_compte', '99330228027133819365', 'date_debut', '2026-09-20', 'date_fin', current_date,
    'solde_initial', 5000, 'solde_final', 3248, 'fichier_nom', 'releve-manuel.csv', 'fichier_sha256', repeat('7', 64),
    'lignes', jsonb_build_array(
        jsonb_build_object('numero_ligne', 1, 'date_operation', '2026-09-20', 'libelle', 'CHEQUE N 111', 'debit', 300, 'solde', 4700),
        jsonb_build_object('numero_ligne', 2, 'date_operation', '2026-09-21', 'libelle', 'CHEQUE N 222', 'debit', 502, 'solde', 4198),
        jsonb_build_object('numero_ligne', 3, 'date_operation', current_date, 'libelle', 'CHEQUE N 333', 'debit', 900, 'solde', 3298),
        jsonb_build_object('numero_ligne', 4, 'date_operation', '2026-09-22', 'libelle', 'VIR EMIS INCONNU MANUEL', 'debit', 50, 'solde', 3248))));
CREATE FUNCTION pg_temp.ligne(n INTEGER) RETURNS BIGINT LANGUAGE sql AS $f$
    SELECT l.id FROM lignes_releve l JOIN releves_bancaires r ON r.id = l.releve_id
    WHERE r.fichier_sha256 = repeat('7', 64) AND l.numero_ligne = n
$f$;
CREATE FUNCTION pg_temp.proposee(n INTEGER, p_facture TEXT, p_montant NUMERIC) RETURNS JSONB LANGUAGE sql AS $f$
    SELECT jsonb_build_object('ligne_releve_id', pg_temp.ligne(n), 'cas', 'exact', 'score', 0.6, 'ecart', 0, 'auto', false,
        'affectations', jsonb_build_array(jsonb_build_object('facture_id', pg_temp.f(p_facture), 'montant', p_montant)))
$f$;
SELECT enregistrer_rapprochements(jsonb_build_object(
    'releve_id', (SELECT id FROM releves_bancaires WHERE fichier_sha256 = repeat('7', 64)),
    'propositions', jsonb_build_array(pg_temp.proposee(1, 'M-D', 100), pg_temp.proposee(2, 'M-D', 100),
                                      pg_temp.proposee(3, 'M-D', 100), pg_temp.proposee(4, 'M-D', 50))));
-- Les quatre propositions sont rejetées par le validateur.
INSERT INTO decisions_rapprochement (proposition_id, decision, utilisateur_id, justification, canal)
SELECT p.id, 'rejeter', pg_temp.u('Manuel – Validateur'), 'Ce paiement ne règle pas M-D', 'test'
FROM propositions_rapprochement p WHERE p.ligne_releve_id IN (pg_temp.ligne(1), pg_temp.ligne(2), pg_temp.ligne(3), pg_temp.ligne(4));

-- Lignes à rapprocher, notification, candidates ------------------------------------------------
SET ROLE mizan_app;
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(numero_ligne::text || ':' || array_length(factures_rejetees, 1), ',' ORDER BY numero_ligne)
    FROM lignes_a_rapprocher WHERE releve_id = (SELECT id FROM releves_bancaires WHERE fichier_sha256 = repeat('7', 64))
$$, '1:1,2:1,3:1,4:1', 'proposition rejetée : la ligne est à rapprocher à la main (factures rejetées connues)');
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(DISTINCT u.role, ',' ORDER BY u.role) FROM notifications_a_preparer('telegram') n JOIN utilisateurs u ON u.id = n.utilisateur_id
    WHERE n.objet = 'ligne_a_rapprocher' AND n.ligne_releve_id = pg_temp.ligne(1)
$$, 'responsable,validateur', 'notifiée aux validateurs et aux responsables');
SELECT pg_temp.doit_valoir($$
    SELECT (d -> 'ligne_a_rapprocher' -> 'ligne' ->> 'libelle') || '|'
        || (SELECT string_agg(x ->> 'numero', ',' ORDER BY (x ->> 'distance')::numeric, x ->> 'numero')
            FROM jsonb_array_elements(d -> 'ligne_a_rapprocher' -> 'candidats') x WHERE x ->> 'numero' LIKE 'M-%')
    FROM donnees_notifications('telegram') d
    WHERE d -> 'candidat' ->> 'objet' = 'ligne_a_rapprocher' AND (d -> 'candidat' ->> 'ligne_releve_id')::bigint = pg_temp.ligne(1)
      AND d -> 'candidat' ->> 'role' = 'validateur'
$$, 'CHEQUE N 111|M-A,M-B,M-DOUBLE,M-DOUBLE,M-C',
    'candidates : factures approuvées à payer, par montant le plus proche ; la facture rejetée (M-D) et la facture bloquée exclues');
SET ROLE mizan_lecture;
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM restitution.a_traiter WHERE type = 'ligne_a_rapprocher' AND objet IN ('CHEQUE N 111', 'CHEQUE N 222')
$$, '2', 'restitution : les lignes à rapprocher sont « à traiter »');
SET ROLE mizan_app;
SELECT pg_temp.doit_echouer($$
    SELECT rapprocher_manuellement(pg_temp.ligne(1), pg_temp.f('M-A'), pg_temp.u('Manuel – Validateur'), 'Rapprochement sans canal', 'test')
$$, '42501', 'le rapprochement manuel ne passe que par le canal (D-062)');

-- Par le canal : facture proposée -------------------------------------------------------------
CREATE TEMP TABLE jetons (nom TEXT PRIMARY KEY, jeton TEXT);
CREATE FUNCTION pg_temp.notifier(p_nom TEXT, n INTEGER, p_actions JSONB) RETURNS VOID LANGUAGE sql AS $f$
    INSERT INTO jetons SELECT p_nom, x.jeton FROM creer_notification(jsonb_build_object(
        'canal', 'telegram', 'utilisateur_id', pg_temp.u('Manuel – Validateur'), 'objet', 'ligne_a_rapprocher',
        'ligne_releve_id', pg_temp.ligne(n), 'contenu', '{}'::jsonb, 'actions', p_actions)) x
$f$;
SELECT pg_temp.doit_reussir($$
    SELECT pg_temp.notifier('L1', 1, jsonb_build_array(jsonb_build_object('code', 'rapprocher_facture', 'params', jsonb_build_object('facture_id', pg_temp.f('M-A')))));
    SELECT pg_temp.notifier('L3', 3, '[{"code": "rapprocher_autre"}]');
    SELECT pg_temp.notifier('L4', 4, '[{"code": "signaler_sans_facture"}]');
$$, 'notifications des lignes créées');
CREATE FUNCTION pg_temp.ev(p_ref TEXT, p_extra JSONB) RETURNS JSONB LANGUAGE sql AS $f$
    SELECT recevoir_evenement(jsonb_build_object('canal', 'telegram', 'reference', p_ref, 'adresse', '922') || p_extra)
$f$;
CREATE FUNCTION pg_temp.bouton(p_ref TEXT, p_nom TEXT) RETURNS TEXT LANGUAGE sql AS $f$
    SELECT pg_temp.ev(p_ref, jsonb_build_object('type', 'action', 'jeton', (SELECT jeton FROM jetons WHERE nom = p_nom), 'indice', '0')) ->> 'code'
$f$;
CREATE FUNCTION pg_temp.texte(p_ref TEXT, p_texte TEXT) RETURNS JSONB LANGUAGE sql AS $f$
    SELECT pg_temp.ev(p_ref, jsonb_build_object('type', 'texte', 'texte', p_texte))
$f$;
SELECT pg_temp.doit_valoir($$
    SELECT pg_temp.bouton('m1', 'L1') || '|' || (pg_temp.texte('m2', 'Chèque 111 remis pour M-A') ->> 'code')
$$, 'justification_demandee|decision_enregistree', 'le validateur rapproche la ligne de la facture proposée');
SELECT pg_temp.doit_valoir($$
    SELECT p.cas || '|' || p.methode || '|' || p.statut || '|' || r.montant_affecte || '|' || d.canal
    FROM propositions_rapprochement p JOIN rapprochements r ON r.proposition_id = p.id JOIN decisions_rapprochement d ON d.proposition_id = p.id
    WHERE p.ligne_releve_id = pg_temp.ligne(1) AND p.statut <> 'rejete'
$$, 'exact|manuel|confirme|300.000|telegram', 'proposition manuelle confirmée par une décision ordinaire (canal tracé)');
SELECT pg_temp.doit_valoir($$SELECT etat FROM situation_paiement WHERE facture_id = pg_temp.f('M-A')$$, 'payee', 'M-A payée');
SELECT pg_temp.doit_valoir($$SELECT pg_temp.bouton('m3', 'L1')$$, 'notification_perimee', 'un bouton d''une ligne déjà rapprochée ne vaut plus');

-- Facture désignée par son numéro ---------------------------------------------------------------
SELECT pg_temp.doit_valoir($$
    SELECT pg_temp.bouton('m4', 'L3') || '|' || (pg_temp.texte('m5', 'INCONNU-9 chèque remis au fournisseur') ->> 'erreur')
$$, 'justification_demandee|MZ045', 'numéro introuvable : refus explicite, rien n''est appliqué');
SELECT pg_temp.doit_valoir($$
    SELECT pg_temp.bouton('m6', 'L3') || '|' || (pg_temp.texte('m7', 'M-DOUBLE chèque remis au fournisseur') ->> 'erreur')
$$, 'justification_demandee|MZ045', 'numéro ambigu (deux factures approuvées) : refus');
SELECT pg_temp.doit_valoir($$
    SELECT pg_temp.bouton('m8', 'L3') || '|' || (pg_temp.texte('m9', 'M-D : chèque 333 remis au fournisseur') ->> 'erreur')
$$, 'justification_demandee|MZ046', 'paiement bien supérieur au reste dû : refus');
SELECT pg_temp.doit_valoir($$
    SELECT pg_temp.bouton('m10', 'L3') || '|' || (pg_temp.texte('m11', 'm-c : chèque 333 remis au fournisseur') ->> 'code')
$$, 'justification_demandee|decision_enregistree', 'facture désignée par son numéro (casse et ponctuation tolérées)');
SELECT pg_temp.doit_valoir($$
    SELECT s.type || '|' || f.numero FROM signalements_paiement s JOIN factures f ON f.id = s.facture_id WHERE s.ligne_releve_id = pg_temp.ligne(3)
$$, 'sortie_sans_ordre|M-C', 'rapprochement manuel d''une opération du jour sans ordre : signalé aussi');

-- « Aucune facture » --------------------------------------------------------------------------------
SELECT pg_temp.doit_valoir($$
    SELECT pg_temp.bouton('m12', 'L4') || '|' || (pg_temp.texte('m13', 'Aucune facture : virement inconnu, à vérifier') ->> 'code')
$$, 'justification_demandee|decision_enregistree', 'le validateur signale la ligne sans facture');
SELECT pg_temp.doit_valoir($$
    SELECT s.type || '|' || s.statut || '|' || (s.detail ->> 'justification') FROM signalements_paiement s WHERE s.ligne_releve_id = pg_temp.ligne(4)
$$, 'sortie_sans_facture|ouvert|Aucune facture : virement inconnu, à vérifier', 'signalement ouvert pour le responsable, justification gardée');

-- Règles (administrateur) ----------------------------------------------------------------------------
RESET ROLE;
SELECT pg_temp.doit_echouer($$
    SELECT rapprocher_manuellement(pg_temp.ligne(2), pg_temp.f('M-B'), pg_temp.u('Manuel – Validateur'), 'ok', 'test')
$$, 'MZ013', 'justification obligatoire');
SELECT pg_temp.doit_echouer($$
    SELECT rapprocher_manuellement(pg_temp.ligne(2), pg_temp.f('M-BLOQ'), pg_temp.u('Manuel – Validateur'), 'Chèque 222 pour la facture bloquée', 'test')
$$, 'MZ041', 'facture non approuvée : refus');
SELECT pg_temp.doit_reussir($$
    SELECT rapprocher_manuellement(pg_temp.ligne(2), pg_temp.f('M-B'), pg_temp.u('Manuel – Responsable'), 'Chèque 222 pour M-B, 2 TND de frais', 'test')
$$, 'écart dans la tolérance (502 pour 500) : rapproché, écart qualifié');
SELECT pg_temp.doit_valoir($$
    SELECT p.cas || '|' || p.ecart || '|' || p.motif_ecart || '|' || r.montant_affecte
    FROM propositions_rapprochement p JOIN rapprochements r ON r.proposition_id = p.id
    WHERE p.ligne_releve_id = pg_temp.ligne(2) AND p.statut = 'confirme'
$$, 'ecart|2.000|autre|500.000', 'écart enregistré avec le motif « autre » (la justification l''explique)');
SELECT pg_temp.doit_echouer($$
    SELECT rapprocher_manuellement(pg_temp.ligne(2), pg_temp.f('M-C'), pg_temp.u('Manuel – Responsable'), 'Second rapprochement de la ligne', 'test')
$$, 'MZ042', 'une ligne déjà rapprochée ne l''est pas deux fois');
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM lignes_a_rapprocher WHERE releve_id = (SELECT id FROM releves_bancaires WHERE fichier_sha256 = repeat('7', 64))
$$, '0', 'plus aucune ligne à rapprocher');

RESET ROLE;
ROLLBACK;
