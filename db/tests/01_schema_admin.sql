-- Tests du schéma, exécutés par l'administrateur.
-- Tout se passe dans une transaction annulée à la fin : la base reste intacte.
\set ON_ERROR_STOP on
\set VERBOSITY terse
BEGIN;
\ir 00_outils.sql
-- Masque les résultats (vides) des assertions ; les messages OK/ECHEC restent affichés.
\o /dev/null

-- Structure ------------------------------------------------------------------
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM unnest(ARRAY[
        'fournisseurs', 'fournisseur_ribs', 'factures', 'lignes_facture',
        'resultats_controles', 'releves_bancaires', 'lignes_releve',
        'rapprochements', 'journal_audit', 'config_fiscale'
    ]) AS t WHERE to_regclass('public.' || t) IS NOT NULL
$$, '10', 'les 10 tables métier existent');

-- Configuration fiscale ------------------------------------------------------
SELECT pg_temp.doit_valoir(
    $$SELECT count(*)::text FROM config_fiscale$$, '6',
    'config_fiscale contient 6 valeurs de départ');
SELECT pg_temp.doit_valoir(
    $$SELECT count(*)::text FROM config_fiscale WHERE btrim(source_libelle) = ''$$, '0',
    'chaque valeur fiscale cite une source');
SELECT pg_temp.doit_echouer($$
    INSERT INTO config_fiscale (cle, valeur, unite, libelle, valide_du, source_libelle)
    VALUES ('tva.taux_normal', 20, 'pourcent', 'test', '2026-06-01', 'test')
$$, '23P01', 'deux taux pour la même clé sur des périodes qui se chevauchent');
SELECT pg_temp.doit_reussir($$
    UPDATE config_fiscale SET valide_au = '2027-01-01' WHERE cle = 'tva.taux_normal';
    INSERT INTO config_fiscale (cle, valeur, unite, libelle, valide_du, source_libelle)
    VALUES ('tva.taux_normal', 20, 'pourcent', 'test', '2027-01-01', 'test')
$$, 'un nouveau taux peut succéder à l''ancien sans chevauchement');

-- Fournisseurs et RIB --------------------------------------------------------
SELECT pg_temp.doit_reussir($$
    INSERT INTO fournisseurs (raison_sociale, matricule_fiscal) VALUES ('Fournisseur Test', 'TEST0001');
    INSERT INTO fournisseur_ribs (fournisseur_id, rib, valide_du)
    SELECT id, '00000000000000000001', '2026-01-01' FROM fournisseurs WHERE matricule_fiscal = 'TEST0001'
$$, 'création d''un fournisseur et de son RIB');
SELECT pg_temp.doit_echouer($$
    INSERT INTO fournisseur_ribs (fournisseur_id, rib)
    SELECT id, '00000000000000000002' FROM fournisseurs WHERE matricule_fiscal = 'TEST0001'
$$, '23505', 'deux RIB actifs pour le même fournisseur');
SELECT pg_temp.doit_reussir($$
    UPDATE fournisseur_ribs SET valide_au = '2026-06-01' WHERE rib = '00000000000000000001';
    INSERT INTO fournisseur_ribs (fournisseur_id, rib, valide_du)
    SELECT id, '00000000000000000002', '2026-06-01' FROM fournisseurs WHERE matricule_fiscal = 'TEST0001'
$$, 'changement de RIB : l''ancien est clos, le nouveau devient actif');
SELECT pg_temp.doit_valoir(
    $$SELECT count(*)::text FROM fournisseur_ribs r JOIN fournisseurs f ON f.id = r.fournisseur_id
      WHERE f.matricule_fiscal = 'TEST0001'$$, '2',
    'l''historique conserve les deux RIB');

-- Factures -------------------------------------------------------------------
SELECT pg_temp.doit_reussir($$
    INSERT INTO factures (fournisseur_id, numero, date_facture, montant_ht, montant_tva, droit_timbre,
                          montant_ttc, canal_reception, format_source, fichier_nom, fichier_sha256)
    SELECT id, 'F-001', '2026-03-01', 100.000, 19.000, 1.000, 120.000,
           'dossier', 'pdf', 'test-1.pdf', repeat('a', 64)
    FROM fournisseurs WHERE matricule_fiscal = 'TEST0001'
$$, 'enregistrement d''une facture');
SELECT pg_temp.doit_valoir(
    $$SELECT devise || '/' || type_document || '/' || statut FROM factures WHERE fichier_nom = 'test-1.pdf'$$,
    'TND/facture/recue', 'valeurs par défaut : TND, facture, recue');
SELECT pg_temp.doit_reussir($$
    INSERT INTO factures (fournisseur_id, numero, canal_reception, format_source, fichier_nom, fichier_sha256)
    SELECT id, 'F-001', 'email', 'pdf', 'test-1-copie.pdf', repeat('a', 64)
    FROM fournisseurs WHERE matricule_fiscal = 'TEST0001'
$$, 'un doublon est enregistré (il sera signalé par un contrôle, D-013)');
SELECT pg_temp.doit_reussir($$
    INSERT INTO factures (fournisseur_id, type_document, facture_origine_id, numero,
                          canal_reception, format_source, fichier_nom, fichier_sha256)
    SELECT fournisseur_id, 'avoir', id, 'AV-001', 'dossier', 'pdf', 'test-avoir.pdf', repeat('b', 64)
    FROM factures WHERE fichier_nom = 'test-1.pdf'
$$, 'un avoir peut référencer la facture qu''il corrige');
SELECT pg_temp.doit_echouer($$
    INSERT INTO factures (type_document, facture_origine_id, canal_reception, format_source, fichier_nom, fichier_sha256)
    SELECT 'facture', id, 'dossier', 'pdf', 'x.pdf', repeat('c', 64) FROM factures WHERE fichier_nom = 'test-1.pdf'
$$, '23514', 'une facture (pas un avoir) ne peut pas avoir de facture d''origine');
SELECT pg_temp.doit_echouer($$
    INSERT INTO factures (montant_ht, canal_reception, format_source, fichier_nom, fichier_sha256)
    VALUES (-5, 'dossier', 'pdf', 'x.pdf', repeat('c', 64))
$$, '23514', 'montant négatif refusé');
SELECT pg_temp.doit_echouer($$
    INSERT INTO factures (devise, canal_reception, format_source, fichier_nom, fichier_sha256)
    VALUES ('tnd', 'dossier', 'pdf', 'x.pdf', repeat('c', 64))
$$, '23514', 'devise hors format ISO 4217 refusée');
SELECT pg_temp.doit_echouer($$
    INSERT INTO factures (type_document, canal_reception, format_source, fichier_nom, fichier_sha256)
    VALUES ('bon_de_commande', 'dossier', 'pdf', 'x.pdf', repeat('c', 64))
$$, '23514', 'type de document inconnu refusé');
SELECT pg_temp.doit_echouer($$
    INSERT INTO factures (statut, canal_reception, format_source, fichier_nom, fichier_sha256)
    VALUES ('payee', 'dossier', 'pdf', 'x.pdf', repeat('c', 64))
$$, '23514', 'statut inconnu refusé');
SELECT pg_temp.doit_echouer($$
    INSERT INTO factures (canal_reception, format_source, fichier_nom, fichier_sha256)
    VALUES ('dossier', 'pdf', 'x.pdf', 'pas-une-empreinte')
$$, '23514', 'empreinte SHA-256 mal formée refusée');

-- Filet de sécurité : pas deux factures approuvées identiques (D-021) ----------
SELECT pg_temp.doit_reussir($$UPDATE factures SET statut = 'validee' WHERE fichier_nom = 'test-1.pdf'$$,
    'une facture est validée');
SELECT pg_temp.doit_echouer($$UPDATE factures SET statut = 'validee' WHERE fichier_nom = 'test-1-copie.pdf'$$,
    '23505', 'son doublon ne peut pas être validé');
SELECT pg_temp.doit_echouer($$UPDATE factures SET statut = 'conforme' WHERE fichier_nom = 'test-1-copie.pdf'$$,
    '23505', 'son doublon ne peut pas non plus être déclaré conforme');
SELECT pg_temp.doit_reussir($$UPDATE factures SET statut = 'bloquee' WHERE fichier_nom = 'test-1-copie.pdf'$$,
    'son doublon peut être bloqué');
SELECT pg_temp.doit_echouer($$
    INSERT INTO factures (fournisseur_id, numero, statut, canal_reception, format_source, fichier_nom, fichier_sha256)
    SELECT id, ' f-0 01 ', 'conforme', 'telegram', 'image', 'variante.jpg', repeat('9', 64)
    FROM fournisseurs WHERE matricule_fiscal = 'TEST0001'
$$, '23505', 'un numéro écrit autrement (casse, espaces) est reconnu comme doublon');
SELECT pg_temp.doit_reussir($$
    UPDATE factures SET statut = 'rejetee' WHERE fichier_nom = 'test-1.pdf';
    UPDATE factures SET statut = 'validee' WHERE fichier_nom = 'test-1-copie.pdf'
$$, 'une facture rejetée ne bloque pas la validation d''une autre');
SELECT pg_temp.doit_echouer($$
    INSERT INTO factures (numero, statut, canal_reception, format_source, fichier_nom, fichier_sha256)
    VALUES ('F-999', 'validee', 'dossier', 'pdf', 'orpheline.pdf', repeat('8', 64))
$$, '23514', 'une facture sans fournisseur ne peut pas être validée');

-- Résultats de contrôles -----------------------------------------------------
SELECT pg_temp.doit_echouer($$
    INSERT INTO resultats_controles (facture_id, passage, regle, version_regle, resultat, gravite)
    SELECT id, nextval('passages_controle_seq'), 'devise', '1', 'anomalie', 'critique' FROM factures WHERE fichier_nom = 'test-1.pdf'
$$, '23514', 'gravité inconnue refusée');

-- Relevés --------------------------------------------------------------------
SELECT pg_temp.doit_reussir($$
    INSERT INTO releves_bancaires (banque, rib_compte, date_debut, date_fin, fichier_nom, fichier_sha256)
    VALUES ('Banque Test', '99999999999999999999', '2026-03-01', '2026-03-31', 'releve.csv', repeat('d', 64))
$$, 'import d''un relevé');
SELECT pg_temp.doit_echouer($$
    INSERT INTO releves_bancaires (banque, rib_compte, date_debut, date_fin, fichier_nom, fichier_sha256)
    VALUES ('Banque Test', '99999999999999999999', '2026-03-01', '2026-03-31', 'releve-bis.csv', repeat('d', 64))
$$, '23505', 'le même fichier de relevé ne peut pas être importé deux fois');
SELECT pg_temp.doit_echouer($$
    INSERT INTO lignes_releve (releve_id, numero_ligne, date_operation, libelle, debit, credit)
    SELECT id, 1, '2026-03-05', 'test', 10, 10 FROM releves_bancaires WHERE fichier_nom = 'releve.csv'
$$, '23514', 'une ligne de relevé ne peut pas être à la fois au débit et au crédit');

-- Journal d'audit ------------------------------------------------------------
SELECT pg_temp.doit_reussir($$
    INSERT INTO journal_audit (horodatage, acteur, action, entite, entite_id)
    VALUES ('2000-01-01', 'test', 'facture.validee', 'factures', '1')
$$, 'ajout d''une entrée au journal d''audit');
SELECT pg_temp.doit_valoir(
    $$SELECT (horodatage = now())::text FROM journal_audit WHERE acteur = 'test'$$, 'true',
    'l''horodatage est forcé à l''heure du serveur (pas d''antidatage)');
SELECT pg_temp.doit_echouer($$UPDATE journal_audit SET acteur = 'pirate' WHERE acteur = 'test'$$,
    'MZ001', 'UPDATE refusé sur journal_audit');
SELECT pg_temp.doit_echouer($$DELETE FROM journal_audit WHERE acteur = 'test'$$,
    'MZ001', 'DELETE refusé sur journal_audit');
SELECT pg_temp.doit_echouer($$TRUNCATE journal_audit$$,
    'MZ001', 'TRUNCATE refusé sur journal_audit');

-- Historique des extractions : ajout seul, même pour l'administrateur ----------
SELECT pg_temp.doit_reussir($$
    INSERT INTO extractions (facture_id, fichier_sha256, resultat, code_resultat)
    SELECT id, fichier_sha256, 'erreur', 'erreur_fournisseur' FROM factures WHERE fichier_nom = 'test-1.pdf'
$$, 'ajout d''une extraction');
SELECT pg_temp.doit_echouer($$UPDATE extractions SET code_resultat = 'ok'$$,
    'MZ001', 'UPDATE refusé sur extractions');
SELECT pg_temp.doit_echouer($$DELETE FROM extractions$$,
    'MZ001', 'DELETE refusé sur extractions');
SELECT pg_temp.doit_echouer($$TRUNCATE extractions$$,
    'MZ001', 'TRUNCATE refusé sur extractions');

ROLLBACK;
