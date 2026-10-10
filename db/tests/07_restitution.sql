-- Tests de la restitution (D-068) : droits du rôle mizan_lecture (lire les
-- vues de restitution, rien d'autre) et contenu des vues. Préparation par
-- l'administrateur ; lectures sous mizan_lecture. Transaction annulée à la fin.
-- Les réglages de connexion du rôle (lecture seule…) sont vérifiés par une
-- vraie connexion, dans lancer.sh.
\set ON_ERROR_STOP on
\set VERBOSITY terse
BEGIN;
SET ROLE mizan_lecture;
\ir 00_outils.sql
RESET ROLE;
\o /dev/null

-- Réglages et droits du rôle (vus par l'administrateur) ---------------------------------
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(c, ',' ORDER BY c) FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole,
           unnest(s.setconfig) c WHERE r.rolname = 'mizan_lecture' AND s.setdatabase = 0
$$, 'default_transaction_read_only=on,idle_in_transaction_session_timeout=30s,search_path=restitution,statement_timeout=5s',
    'session du rôle : lecture seule, délais, vues de restitution seules dans le chemin');
SELECT pg_temp.doit_valoir($$
    SELECT (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)::text
    FROM pg_roles WHERE rolname = 'mizan_lecture'
$$, 'false', 'aucun attribut privilégié');
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'v', 'm', 'p', 'S')
      AND (has_table_privilege('mizan_lecture', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
           OR (c.relkind = 'S' AND has_sequence_privilege('mizan_lecture', c.oid, 'USAGE,SELECT,UPDATE')))
$$, '0', 'aucun droit sur une table, une vue ou une séquence de public');
SELECT pg_temp.doit_valoir($$
    SELECT has_schema_privilege('mizan_lecture', 'public', 'USAGE')::text || '|'
        || has_schema_privilege('mizan_app', 'public', 'USAGE')::text
$$, 'false|true', 'schéma public fermé au rôle de lecture, ouvert au rôle applicatif');
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'restitution' AND c.relkind <> 'v'
$$, '0', 'le schéma de restitution ne contient que des vues');
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'restitution'
      AND (NOT has_table_privilege('mizan_lecture', c.oid, 'SELECT')
           OR has_table_privilege('mizan_lecture', c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'))
$$, '0', 'chaque vue de restitution : lecture seulement');
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM information_schema.columns
    WHERE table_schema = 'restitution' AND column_name ~ 'rib' AND column_name <> 'rib_paiement'
$$, '0', 'aucune vue ne montre le RIB lu sur une facture (D-058)');

-- Une fonction appelée dans une vue s'exécute avec les droits et le chemin de
-- recherche du LECTEUR : pour mizan_lecture, elle échouerait (défaut du
-- 2026-10-09, generer-releve-demo). Aucune vue atteinte depuis la restitution,
-- directement ou par une autre vue, n'appelle de fonction hors du catalogue.
SELECT pg_temp.doit_valoir($$
    WITH RECURSIVE vues(oid) AS (
        SELECT c.oid FROM pg_class c WHERE c.relnamespace = 'restitution'::regnamespace AND c.relkind = 'v'
        UNION
        SELECT d.refobjid FROM vues v JOIN pg_rewrite w ON w.ev_class = v.oid
        JOIN pg_depend d ON d.classid = 'pg_rewrite'::regclass AND d.objid = w.oid AND d.refclassid = 'pg_class'::regclass
        JOIN pg_class c ON c.oid = d.refobjid AND c.relkind = 'v'
    )
    SELECT coalesce(string_agg(DISTINCT p.proname, ', '), 'aucune') FROM vues v JOIN pg_rewrite w ON w.ev_class = v.oid
    JOIN pg_depend d ON d.classid = 'pg_rewrite'::regclass AND d.objid = w.oid AND d.refclassid = 'pg_proc'::regclass
    JOIN pg_proc p ON p.oid = d.refobjid
    WHERE p.pronamespace <> 'pg_catalog'::regnamespace
$$, 'aucune', 'aucune vue lue par mizan_lecture n''appelle une fonction de la base');

-- Données de départ (administrateur) -----------------------------------------------------
-- Instantané de la trésorerie prévue avant les données du test, pour mesurer
-- leur seule contribution (la base réelle a ses propres factures).
CREATE TEMP TABLE avant AS SELECT semaine, factures, sorties_prevues FROM restitution.tresorerie_prevue;
CREATE TEMP TABLE tva_avant AS SELECT * FROM restitution.tva_factures;
GRANT SELECT ON avant, tva_avant TO mizan_lecture;
WITH f AS (INSERT INTO fournisseurs (raison_sociale, matricule_fiscal) VALUES ('Fournisseur Restit', '9912355B') RETURNING id)
INSERT INTO fournisseur_ribs (fournisseur_id, rib, valide_du) SELECT id, '99001000000000000165', '2026-01-01' FROM f;
CREATE FUNCTION pg_temp.f(p TEXT) RETURNS BIGINT LANGUAGE sql AS $f$ SELECT id FROM factures WHERE fichier_nom = p $f$;
CREATE FUNCTION pg_temp.facture(p_nom TEXT, p_statut TEXT, p_ttc NUMERIC, p_echeance DATE, p_devise TEXT DEFAULT 'TND') RETURNS VOID LANGUAGE sql AS $f$
    INSERT INTO factures (fichier_nom, statut, numero, fournisseur_id, canal_reception, format_source, fichier_sha256,
                          montant_ht, montant_tva, montant_ttc, devise, date_facture, date_echeance, rib_facture)
    VALUES (p_nom, p_statut, p_nom, (SELECT id FROM fournisseurs WHERE matricule_fiscal = '9912355B'), 'dossier', 'pdf',
            encode(sha256(convert_to(p_nom, 'UTF8')), 'hex'), round(p_ttc / 1.19, 3), p_ttc - round(p_ttc / 1.19, 3), p_ttc,
            p_devise, '2026-03-01', p_echeance, '11111111111111111111')
$f$;
SELECT pg_temp.facture('S-RETARD', 'validee', 100, '2026-03-31');
SELECT pg_temp.facture('S-PROPOSE', 'conforme', 200, '2026-03-31');
SELECT pg_temp.facture('S-FUTUR', 'validee', 50, current_date + 14);
SELECT pg_temp.facture('S-PAYEE', 'conforme', 30, '2026-03-31');
SELECT pg_temp.facture('S-EUR', 'validee', 70, current_date + 14, 'EUR');
SELECT pg_temp.facture('S-BLOQ', 'bloquee', 80, '2026-03-31');
-- Relevé daté d'aujourd'hui : c'est le dernier, son solde sert à la trésorerie.
SELECT enregistrer_releve(jsonb_build_object(
    'banque', 'Banque Test', 'rib_compte', '99330228027133819365', 'date_debut', current_date, 'date_fin', current_date,
    'solde_initial', 1000, 'solde_final', 765, 'fichier_nom', 'releve-restit.csv', 'fichier_sha256', repeat('d', 64),
    'lignes', jsonb_build_array(
        jsonb_build_object('numero_ligne', 1, 'date_operation', current_date, 'libelle', 'VIR EMIS FOURNISSEUR RESTIT FACT S-PAYEE', 'debit', 30, 'solde', 970),
        jsonb_build_object('numero_ligne', 2, 'date_operation', current_date, 'libelle', 'CHEQUE N 7654321', 'debit', 200, 'solde', 770),
        jsonb_build_object('numero_ligne', 3, 'date_operation', current_date, 'libelle', 'VIR EMIS INCONNU RESTIT', 'debit', 5, 'solde', 765))));
CREATE FUNCTION pg_temp.ligne(n INTEGER) RETURNS BIGINT LANGUAGE sql AS $f$
    SELECT l.id FROM lignes_releve l JOIN releves_bancaires r ON r.id = l.releve_id
    WHERE r.fichier_sha256 = repeat('d', 64) AND l.numero_ligne = n
$f$;
SELECT enregistrer_rapprochements(jsonb_build_object(
    'releve_id', (SELECT id FROM releves_bancaires WHERE fichier_sha256 = repeat('d', 64)),
    'propositions', jsonb_build_array(
        jsonb_build_object('ligne_releve_id', pg_temp.ligne(1), 'cas', 'exact', 'score', 1, 'ecart', 0, 'auto', true,
            'affectations', jsonb_build_array(jsonb_build_object('facture_id', pg_temp.f('S-PAYEE'), 'montant', 30))),
        jsonb_build_object('ligne_releve_id', pg_temp.ligne(2), 'cas', 'exact', 'score', 0.7, 'ecart', 0, 'auto', false,
            'affectations', jsonb_build_array(jsonb_build_object('facture_id', pg_temp.f('S-PROPOSE'), 'montant', 200)))),
    'signalements', jsonb_build_array(
        jsonb_build_object('type', 'sortie_sans_facture', 'ligne_releve_id', pg_temp.ligne(3), 'message', 'sortie sans facture'))));

SET ROLE mizan_lecture;

-- Ce que le rôle de lecture ne peut pas faire ----------------------------------------------
SELECT pg_temp.doit_echouer($$SELECT count(*) FROM public.factures$$, '42501', 'lire une table');
SELECT pg_temp.doit_echouer($$SELECT count(*) FROM public.situation_paiement$$, '42501', 'lire une vue hors restitution');
SELECT pg_temp.doit_echouer($$SELECT public.contexte_rapprochement(0)$$, '42501', 'appeler une fonction de la base');
-- Vue non modifiable (55000), refusée avant même le contrôle des droits ;
-- l'absence de droit d'écriture est vérifiée plus haut.
SELECT pg_temp.doit_echouer($$DELETE FROM restitution.echeancier$$, '55000', 'modifier par une vue');
SELECT pg_temp.doit_echouer($$CREATE VIEW restitution.x AS SELECT 1$$, '42501', 'créer un objet dans la restitution');
SELECT pg_temp.doit_echouer($$CREATE TABLE public.x (a int)$$, '42501', 'créer un objet dans public');

-- Contenu des vues (lu sous mizan_lecture) --------------------------------------------------------
SELECT pg_temp.doit_valoir($$
    SELECT etat || '|' || reste_a_payer || '|' || en_retard || '|' || (jours_de_retard = current_date - date '2026-03-31') || '|' || rib_paiement
    FROM restitution.echeancier WHERE numero = 'S-RETARD'
$$, 'non_payee|100.000|true|true|99001000000000000165',
    'échéancier : facture en retard, RIB de paiement du référentiel (pas celui lu sur la facture)');
SELECT pg_temp.doit_valoir($$
    SELECT etat || '|' || paiement_propose || '|' || en_retard FROM restitution.echeancier WHERE numero = 'S-PROPOSE'
$$, 'paiement_propose|200.000|false', 'échéancier : paiement au relevé en attente, pas en retard');
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM restitution.echeancier WHERE numero IN ('S-PAYEE', 'S-BLOQ')
$$, '0', 'échéancier : ni facture payée, ni facture non approuvée');
SELECT pg_temp.doit_valoir($$
    SELECT numero || '|' || montant || '|' || date_operation || '|' || methode FROM restitution.paiements WHERE numero LIKE 'S-%'
$$, 'S-PAYEE|30.000|' || current_date || '|auto', 'paiements : seulement les règlements confirmés');
SELECT pg_temp.doit_valoir($$
    SELECT (solde_releve = 765 AND date_releve = current_date)::text FROM restitution.tresorerie_prevue LIMIT 1
$$, 'true', 'trésorerie : part du solde du dernier relevé');
-- Contribution du test : semaine en cours 100 (S-RETARD ; S-PROPOSE déjà au
-- relevé : 0) ; dans deux semaines 50 (S-FUTUR ; S-EUR exclue : autre devise).
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(t.semaine - date_trunc('week', current_date)::date || ':' || (t.sorties_prevues - coalesce(a.sorties_prevues, 0)), ',' ORDER BY t.semaine)
    FROM restitution.tresorerie_prevue t LEFT JOIN avant a USING (semaine)
    WHERE t.sorties_prevues IS DISTINCT FROM a.sorties_prevues
$$, '0:100.000,' || (date_trunc('week', current_date + 14)::date - date_trunc('week', current_date)::date) || ':50.000',
    'trésorerie : échéances passées dans la semaine en cours, paiement proposé et devise étrangère exclus');
SELECT pg_temp.doit_valoir($$
    SELECT bool_and(solde_prevu_fin_semaine = solde_releve - cumul)::text FROM (
        SELECT solde_prevu_fin_semaine, solde_releve, sum(sorties_prevues) OVER (ORDER BY semaine) AS cumul
        FROM restitution.tresorerie_prevue) x
$$, 'true', 'trésorerie : solde prévu = solde du relevé − sorties cumulées');
SELECT pg_temp.doit_valoir($$
    SELECT (t.factures - coalesce(a.factures, 0))::text FROM restitution.tresorerie_prevue t LEFT JOIN avant a USING (semaine)
    WHERE t.semaine = date_trunc('week', current_date)::date
$$, '1', 'trésorerie : une facture dont le paiement est au relevé n''est pas comptée');
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(t.devise || ':' || (t.documents - coalesce(a.documents, 0)) || ':' || (t.montant_ttc - coalesce(a.montant_ttc, 0)), ',' ORDER BY t.devise)
    FROM restitution.tva_factures t LEFT JOIN tva_avant a USING (mois, devise, type_document)
    WHERE t.mois = '2026-03-01' AND t.type_document = 'facture' AND t.documents IS DISTINCT FROM a.documents
$$, 'EUR:1:70.000,TND:4:380.000', 'TVA : par mois et devise, factures approuvées seulement (facture bloquée exclue)');
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(type || ':' || detail, ',' ORDER BY type) FROM restitution.a_traiter
    WHERE objet IN ('S-BLOQ', 'CHEQUE N 7654321', 'VIR EMIS INCONNU RESTIT')
$$, 'facture_a_decider:bloquee,rapprochement_a_confirmer:exact,signalement_ouvert:sortie_sans_facture',
    'à traiter : facture à décider, rapprochement à confirmer, signalement ouvert');

RESET ROLE;
ROLLBACK;
