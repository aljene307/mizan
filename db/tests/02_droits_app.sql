-- Tests des droits du rôle applicatif mizan_app (celui qu'utilisera n8n).
-- Tout se passe dans une transaction annulée à la fin : la base reste intacte.
\set ON_ERROR_STOP on
\set VERBOSITY terse
BEGIN;
\ir 00_outils.sql
-- Masque les résultats (vides) des assertions ; les messages OK/ECHEC restent affichés.
\o /dev/null

SELECT pg_temp.doit_valoir($$SELECT current_user::text$$, 'mizan_app',
    'connecté en tant que mizan_app');

-- Ce que l'application doit pouvoir faire ------------------------------------
SELECT pg_temp.doit_reussir($$
    INSERT INTO factures (numero, canal_reception, format_source, fichier_nom, fichier_sha256)
    VALUES ('F-APP', 'telegram', 'image', 'app.jpg', repeat('e', 64));
    INSERT INTO lignes_facture (facture_id, numero_ligne, designation)
    SELECT id, 1, 'Article' FROM factures WHERE fichier_nom = 'app.jpg';
$$, 'ajouter une facture et une ligne');
SELECT pg_temp.doit_valoir($$SELECT count(*)::text FROM fournisseurs WHERE false$$, '0', 'lire le référentiel');
SELECT pg_temp.doit_reussir($$
    UPDATE factures SET statut = 'en_extraction', montant_ttc = 50 WHERE fichier_nom = 'app.jpg'
$$, 'modifier une facture (statut prévu, montants)');
SELECT pg_temp.doit_reussir($$
    INSERT INTO resultats_controles (facture_id, passage, regle, version_regle, resultat, gravite, detail)
    SELECT id, nextval('passages_controle_seq'), 'devise', '1', 'ok', 'info', '{"attendu": 1}'
    FROM factures WHERE fichier_nom = 'app.jpg'
$$, 'enregistrer un résultat de contrôle');
SELECT pg_temp.doit_reussir($$
    INSERT INTO journal_audit (acteur, action, entite, entite_id)
    VALUES ('test-app', 'facture.extraite', 'factures', '0')
$$, 'écrire dans le journal d''audit');
SELECT pg_temp.doit_reussir($$
    INSERT INTO releves_bancaires (banque, rib_compte, date_debut, date_fin, fichier_nom, fichier_sha256)
    VALUES ('Banque App', '11111111111111111111', '2026-03-01', '2026-03-31', 'app.csv', repeat('f', 64));
    INSERT INTO lignes_releve (releve_id, numero_ligne, date_operation, libelle, debit)
    SELECT id, 1, '2026-03-10', 'VIR FOURNISSEUR APP', 50 FROM releves_bancaires WHERE fichier_nom = 'app.csv';
    INSERT INTO rapprochements (facture_id, ligne_releve_id, montant_affecte, methode, cree_par)
    SELECT f.id, l.id, 50, 'auto', 'test-app'
    FROM factures f, lignes_releve l
    WHERE f.fichier_nom = 'app.jpg' AND l.libelle = 'VIR FOURNISSEUR APP';
$$, 'importer un relevé et créer un rapprochement');
SELECT pg_temp.doit_valoir($$SELECT count(*)::text FROM config_fiscale$$, '6',
    'lire la configuration fiscale');

-- Ce que l'application ne doit pas pouvoir faire -----------------------------
SELECT pg_temp.doit_echouer($$DELETE FROM factures WHERE fichier_nom = 'app.jpg'$$,
    '42501', 'supprimer une facture');
SELECT pg_temp.doit_echouer($$DELETE FROM fournisseurs WHERE matricule_fiscal = 'TESTAPP1'$$,
    '42501', 'supprimer un fournisseur');
SELECT pg_temp.doit_echouer($$INSERT INTO fournisseurs (raison_sociale, matricule_fiscal) VALUES ('App', 'TESTAPP1')$$,
    '42501', 'créer un fournisseur sans demande approuvée (D-056)');
SELECT pg_temp.doit_echouer($$UPDATE fournisseur_ribs SET valide_au = current_date$$,
    '42501', 'modifier un RIB sans demande approuvée (D-056)');
SELECT pg_temp.doit_echouer($$INSERT INTO utilisateurs (nom, role) VALUES ('Intrus', 'responsable')$$,
    '42501', 'créer un utilisateur');
SELECT pg_temp.doit_echouer($$UPDATE factures SET statut = 'validee' WHERE fichier_nom = 'app.jpg'$$,
    'MZ010', 'changer un statut hors des transitions prévues');
SELECT pg_temp.doit_echouer($$UPDATE journal_audit SET acteur = 'pirate'$$,
    '42501', 'modifier le journal d''audit');
SELECT pg_temp.doit_echouer($$DELETE FROM journal_audit$$,
    '42501', 'supprimer des entrées du journal d''audit');
SELECT pg_temp.doit_echouer($$UPDATE resultats_controles SET resultat = 'ok'$$,
    '42501', 'réécrire un résultat de contrôle');
SELECT pg_temp.doit_echouer($$UPDATE config_fiscale SET valeur = 0$$,
    '42501', 'modifier la configuration fiscale');
SELECT pg_temp.doit_echouer($$
    INSERT INTO config_fiscale (cle, valeur, unite, libelle, valide_du, source_libelle)
    VALUES ('test', 1, 'TND', 'test', '2026-01-01', 'test')
$$, '42501', 'ajouter une valeur fiscale');
SELECT pg_temp.doit_echouer($$SELECT * FROM schema_migrations$$,
    '42501', 'lire la table des migrations');
SELECT pg_temp.doit_echouer($$CREATE TABLE intrus (id int)$$,
    '42501', 'créer une table');

ROLLBACK;
