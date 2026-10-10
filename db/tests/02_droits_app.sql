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
-- Relevé et rapprochement : seulement par les fonctions prévues (D-065).
SELECT pg_temp.doit_reussir($$
    SELECT enregistrer_releve(jsonb_build_object('banque', 'Banque App', 'rib_compte', '11111111111111111111',
        'date_debut', '2026-03-01', 'date_fin', '2026-03-31', 'solde_initial', 100, 'solde_final', 50,
        'fichier_nom', 'app.csv', 'fichier_sha256', repeat('f', 64),
        'lignes', jsonb_build_array(jsonb_build_object('numero_ligne', 1, 'date_operation', '2026-03-10',
                                                       'libelle', 'VIR FOURNISSEUR APP', 'debit', 50, 'solde', 50))));
$$, 'importer un relevé par la fonction prévue');
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
SELECT pg_temp.doit_echouer($$
    INSERT INTO rapprochements (facture_id, ligne_releve_id, montant_affecte, methode, cree_par)
    SELECT f.id, l.id, 50, 'auto', 'test-app' FROM factures f, lignes_releve l
    WHERE f.fichier_nom = 'app.jpg' AND l.libelle = 'VIR FOURNISSEUR APP'
$$, '42501', 'créer un rapprochement directement (D-065)');
SELECT pg_temp.doit_echouer($$UPDATE lignes_releve SET debit = 0$$, '42501', 'modifier une ligne de relevé');
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

-- Fonctions SECURITY DEFINER (D-063) : vérifie aussi les fonctions futures.
SELECT pg_temp.doit_valoir($$
    SELECT coalesce(string_agg(p.oid::regprocedure::text, ', '), 'aucune') FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace AND p.prosecdef
      AND NOT coalesce(p.proconfig, '{}') @> ARRAY['search_path=public, pg_temp']
$$, 'aucune', 'chaque fonction SECURITY DEFINER fixe son search_path (public, puis pg_temp en dernier)');
SELECT pg_temp.doit_valoir($$
    SELECT coalesce(string_agg(p.oid::regprocedure::text, ', '), 'aucune') FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace AND p.prosecdef
      AND has_function_privilege('public', p.oid, 'EXECUTE')
$$, 'aucune', 'aucune fonction SECURITY DEFINER n''est exécutable par PUBLIC');
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(p.proname, ', ' ORDER BY p.proname) FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace AND p.prosecdef
      AND has_function_privilege('mizan_app', p.oid, 'EXECUTE')
$$, 'conclure_question, creer_notification, enregistrer_rapprochements, enregistrer_releve, marquer_notification, prendre_bail_canal, prendre_questions, proposer_lot_paiement, recevoir_evenement, rendre_bail_canal',
    'mizan_app n''exécute que les fonctions privilégiées prévues (canal, relevé, rapprochement, ordres, questions)');
SELECT pg_temp.doit_valoir($$SELECT has_schema_privilege('mizan_app', 'public', 'CREATE')::text$$,
    'false', 'mizan_app ne peut rien créer dans le schéma public (search_path sûr)');

ROLLBACK;
