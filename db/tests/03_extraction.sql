-- Tests de la réception, de la réservation et de l'enregistrement des
-- extractions, exécutés par le rôle applicatif mizan_app (comme n8n).
-- Tout se passe dans une transaction annulée à la fin : la base reste intacte.
-- La concurrence entre deux exécutions est testée à part, avec deux
-- connexions (tests/integration/reservation.test.js).
\set ON_ERROR_STOP on
\set VERBOSITY terse
BEGIN;
\ir 00_outils.sql
\o /dev/null

-- Isole le test des factures déjà présentes (annulé par le ROLLBACK final).
UPDATE factures SET statut = 'erreur_extraction', reservee_le = NULL
WHERE statut IN ('recue', 'en_extraction');

-- Réception --------------------------------------------------------------------
SELECT pg_temp.doit_valoir($$
    SELECT nouvelle::text FROM enregistrer_reception('dossier', 'T1.pdf', 'pdf', 'T1.pdf', repeat('1', 64), 'exec-1')
$$, 'true', 'un nouveau fichier est enregistré');
SELECT pg_temp.doit_valoir($$
    SELECT nouvelle::text FROM enregistrer_reception('dossier', 'T1.pdf', 'pdf', 'T1.pdf', repeat('1', 64), 'exec-2')
$$, 'false', 'le même fichier relu par une autre exécution n''est pas réenregistré');
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM factures WHERE fichier_sha256 = repeat('1', 64)
$$, '1', 'une seule facture pour ce fichier');
SELECT pg_temp.doit_valoir($$
    SELECT (r.facture_id = f.id)::text
    FROM enregistrer_reception('dossier', 'T1.pdf', 'pdf', 'T1.pdf', repeat('1', 64)) r,
         factures f WHERE f.fichier_nom = 'T1.pdf'
$$, 'true', 'la réception répétée renvoie l''identifiant existant');
SELECT pg_temp.doit_valoir($$
    SELECT nouvelle::text FROM enregistrer_reception('dossier', 'T1-copie.pdf', 'pdf', 'T1-copie.pdf', repeat('1', 64))
$$, 'true', 'le même contenu sous un autre nom est une nouvelle facture (doublon tracé)');
SELECT pg_temp.doit_valoir($$
    SELECT statut || '/' || canal_reception FROM factures WHERE fichier_nom = 'T1.pdf'
$$, 'recue/dossier', 'statut « recue » et canal « dossier »');
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM journal_audit j JOIN factures f ON j.entite_id = f.id::text
    WHERE j.action = 'facture.recue' AND f.fichier_sha256 = repeat('1', 64)
$$, '2', 'une entrée « facture.recue » par facture enregistrée, aucune pour la relecture');

-- Réservation ------------------------------------------------------------------
SELECT pg_temp.doit_valoir($$
    SELECT fichier_nom FROM reserver_facture_a_extraire()
$$, 'T1.pdf', 'la plus ancienne facture reçue est réservée');
SELECT pg_temp.doit_valoir($$
    SELECT statut || '/' || (reservee_le IS NOT NULL)::text FROM factures WHERE fichier_nom = 'T1.pdf'
$$, 'en_extraction/true', 'statut « en_extraction » avec horodatage de réservation');
SELECT pg_temp.doit_valoir($$
    SELECT fichier_nom FROM reserver_facture_a_extraire()
$$, 'T1-copie.pdf', 'la réservation suivante prend une autre facture');
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM reserver_facture_a_extraire()
$$, '0', 'plus rien à réserver : une facture réservée n''est pas reprise');
SELECT pg_temp.doit_reussir($$
    UPDATE factures SET reservee_le = now() - interval '1 hour' WHERE fichier_nom = 'T1-copie.pdf'
$$, 'simulation d''une exécution interrompue il y a une heure');
SELECT pg_temp.doit_valoir($$
    SELECT fichier_nom FROM reserver_facture_a_extraire()
$$, 'T1-copie.pdf', 'une réservation abandonnée depuis plus de 15 minutes est reprise');

-- Extraction valide ------------------------------------------------------------
SELECT pg_temp.doit_reussir($$
    SELECT enregistrer_extraction(jsonb_build_object(
        'facture_id', (SELECT id FROM factures WHERE fichier_nom = 'T1.pdf'),
        'resultat', 'valide', 'code_resultat', 'ok', 'methode_lecture', 'texte_pdf',
        'fournisseur_llm', 'google', 'modele', 'gemini-3.5-flash-lite',
        'version_prompt', 'v1', 'empreinte_prompt', repeat('a', 64),
        'duree_lecture_ms', 120, 'duree_llm_ms', 2300, 'jetons_entree', 1800, 'jetons_sortie', 400,
        'tentatives', 1, 'execution_n8n_id', 'exec-1',
        'donnees', '{
          "type_document": "facture", "numero": "FA-2026-0001", "date_facture": "2026-03-01",
          "date_echeance": "2026-03-31", "devise": "TND",
          "fournisseur": {"raison_sociale": "Fournisseur Test", "matricule_fiscal": "9912345K/A/M/000",
                          "adresse": null, "rib": "99001000000000000099"},
          "client": {"raison_sociale": "Société Démo Mizan SARL", "matricule_fiscal": null},
          "lignes": [
            {"designation": "Article A", "quantite": 2, "prix_unitaire_ht": 10.5, "taux_tva": 19, "montant_ht": 21},
            {"designation": "Article B", "quantite": 1.5, "prix_unitaire_ht": 4, "taux_tva": 7, "montant_ht": 6}
          ],
          "montant_ht": 27, "montant_tva": 4.41, "droit_timbre": 1, "montant_ttc": 32.41,
          "facture_origine_numero": null}'::jsonb))
$$, 'enregistrement d''une extraction valide');
SELECT pg_temp.doit_valoir($$
    SELECT concat_ws('|', statut, numero, date_facture, montant_ttc, matricule_fiscal_lu,
                     methode_extraction, (reservee_le IS NULL)::text)
    FROM factures WHERE fichier_nom = 'T1.pdf'
$$, 'extraite|FA-2026-0001|2026-03-01|32.410|9912345K/A/M/000|texte_llm|true',
    'la facture reçoit les champs extraits, statut « extraite », réservation levée');
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(l.numero_ligne || ':' || l.designation || ':' || l.montant_ht, ',' ORDER BY l.numero_ligne)
    FROM lignes_facture l JOIN factures f ON f.id = l.facture_id WHERE f.fichier_nom = 'T1.pdf'
$$, '1:Article A:21.000,2:Article B:6.000', 'les lignes sont enregistrées dans l''ordre');
SELECT pg_temp.doit_valoir($$
    SELECT concat_ws('|', resultat, modele, version_prompt, duree_llm_ms, jetons_entree)
    FROM extractions e JOIN factures f ON f.id = e.facture_id WHERE f.fichier_nom = 'T1.pdf'
$$, 'valide|gemini-3.5-flash-lite|v1|2300|1800', 'modèle, version du prompt, durée et jetons sont tracés (D-035)');
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM journal_audit j JOIN factures f ON j.entite_id = f.id::text
    WHERE j.action = 'facture.extraite' AND f.fichier_nom = 'T1.pdf'
$$, '1', 'entrée « facture.extraite » au journal d''audit');
SELECT pg_temp.doit_echouer($$
    SELECT enregistrer_extraction(jsonb_build_object(
        'facture_id', (SELECT id FROM factures WHERE fichier_nom = 'T1.pdf'),
        'resultat', 'erreur', 'code_resultat', 'erreur_fournisseur'))
$$, 'MZ003', 'une facture non réservée ne peut pas recevoir d''extraction');

-- Réutilisation pour un même fichier (D-035, point 2) --------------------------
SELECT pg_temp.doit_valoir($$
    SELECT (extraction_id IS NOT NULL)::text || '/' || (donnees ->> 'numero')
    FROM extraction_valide_existante(repeat('1', 64))
$$, 'true/FA-2026-0001', 'l''extraction valide du même fichier est retrouvée');
SELECT pg_temp.doit_reussir($$
    SELECT enregistrer_extraction(jsonb_build_object(
        'facture_id', (SELECT id FROM factures WHERE fichier_nom = 'T1-copie.pdf'),
        'resultat', 'reutilisee', 'code_resultat', 'reutilisation',
        'reutilise_de', e.extraction_id, 'methode_lecture', e.methode_lecture, 'donnees', e.donnees))
    FROM extraction_valide_existante(repeat('1', 64)) e
$$, 'le doublon réutilise l''extraction existante, sans appel au LLM');
SELECT pg_temp.doit_valoir($$
    SELECT concat_ws('|', f.statut, f.numero, (SELECT count(*) FROM lignes_facture l WHERE l.facture_id = f.id))
    FROM factures f WHERE f.fichier_nom = 'T1-copie.pdf'
$$, 'extraite|FA-2026-0001|2', 'le doublon a les mêmes champs et les mêmes lignes');
SELECT pg_temp.doit_valoir($$
    SELECT (count(*) FILTER (WHERE resultat = 'valide'))::text || '/' || count(*)::text
    FROM extractions WHERE fichier_sha256 = repeat('1', 64)
$$, '1/2', 'une seule extraction « valide » (un seul appel au LLM) pour deux factures');
SELECT pg_temp.doit_echouer($$
    INSERT INTO extractions (facture_id, fichier_sha256, resultat, code_resultat, donnees)
    SELECT id, fichier_sha256, 'reutilisee', 'reutilisation', '{}' FROM factures WHERE fichier_nom = 'T1-copie.pdf'
$$, '23514', 'une réutilisation doit indiquer l''extraction d''origine');

-- Paramètres de génération et alertes « identifiant absent du texte » (D-047, D-048)
SELECT pg_temp.doit_reussir($$
    SELECT enregistrer_reception('dossier', 'T4.pdf', 'pdf', 'T4.pdf', repeat('4', 64));
    UPDATE factures SET statut = 'erreur_extraction'
    WHERE statut = 'recue' AND fichier_nom <> 'T4.pdf';
$$, 'réception de T4 (seule facture en attente)');
SELECT pg_temp.doit_valoir($$SELECT fichier_nom FROM reserver_facture_a_extraire()$$, 'T4.pdf',
    'réservation de T4');
SELECT pg_temp.doit_reussir($$
    SELECT enregistrer_extraction(jsonb_build_object(
        'facture_id', (SELECT id FROM factures WHERE fichier_nom = 'T4.pdf'),
        'resultat', 'valide', 'code_resultat', 'ok', 'methode_lecture', 'texte_pdf',
        'modele', 'gemini-3.5-flash-lite', 'version_prompt', 'v1', 'jetons_reflexion', 120,
        'parametres_generation', '{"temperature": 1.0, "thinkingLevel": "low", "maxOutputTokens": 8192}'::jsonb,
        'verifications_source', '[{"champ": "fournisseur.rib", "valeur": "99999000000000000651", "present": false}]'::jsonb,
        'alertes_source', '["fournisseur.rib « 99999000000000000651 » absent du texte source"]'::jsonb,
        'donnees', (SELECT donnees FROM extraction_valide_existante(repeat('1', 64)))))
$$, 'extraction valide avec une alerte');
SELECT pg_temp.doit_valoir($$
    SELECT concat_ws('|', e.parametres_generation ->> 'thinkingLevel', e.parametres_generation ->> 'temperature',
                     e.jetons_reflexion, jsonb_array_length(e.alertes_source))
    FROM extractions e JOIN factures f ON f.id = e.facture_id WHERE f.fichier_nom = 'T4.pdf'
$$, 'low|1.0|120|1', 'paramètres de génération, jetons de réflexion et alertes enregistrés');
SELECT pg_temp.doit_valoir($$
    SELECT j.action || '/' || f.statut FROM journal_audit j JOIN factures f ON j.entite_id = f.id::text
    WHERE f.fichier_nom = 'T4.pdf' AND j.acteur = 'n8n:extraction'
$$, 'facture.extraite_avec_alertes/extraite',
    'facture extraite mais signalée au journal (« extraite_avec_alertes »)');
SELECT pg_temp.doit_valoir($$
    SELECT concat_ws('|', jsonb_array_length(e.alertes_source), jsonb_array_length(e.verifications_source))
    FROM extractions e JOIN factures f ON f.id = e.facture_id WHERE f.fichier_nom = 'T1.pdf'
$$, '0|0', 'sans alerte transmise, les listes sont vides (valeur par défaut)');

-- Texte transmis au LLM (D-051) -------------------------------------------------
SELECT pg_temp.doit_reussir($$
    SELECT enregistrer_reception('dossier', 'T5.pdf', 'pdf', 'T5.pdf', repeat('5', 64));
    UPDATE factures SET statut = 'erreur_extraction' WHERE statut = 'recue' AND fichier_nom <> 'T5.pdf';
$$, 'réception de T5 (seule facture en attente)');
SELECT pg_temp.doit_valoir($$SELECT fichier_nom FROM reserver_facture_a_extraire()$$, 'T5.pdf',
    'réservation de T5');
SELECT pg_temp.doit_reussir($$
    SELECT enregistrer_extraction(jsonb_build_object(
        'facture_id', (SELECT id FROM factures WHERE fichier_nom = 'T5.pdf'),
        'resultat', 'erreur', 'code_resultat', 'erreur_fournisseur', 'methode_lecture', 'texte_pdf',
        'texte_source', E'FACTURE N° T5\nTotal TTC 10,000', 'erreurs', '["HTTP 503"]'::jsonb))
$$, 'extraction en erreur avec son texte source');
SELECT pg_temp.doit_valoir($$
    SELECT e.texte_source FROM extractions e JOIN factures f ON f.id = e.facture_id WHERE f.fichier_nom = 'T5.pdf'
$$, E'FACTURE N° T5\nTotal TTC 10,000', 'le texte transmis au LLM est conservé, retours à la ligne compris');
SELECT pg_temp.doit_valoir($$
    SELECT (e.texte_source IS NULL)::text FROM extractions e JOIN factures f ON f.id = e.facture_id
    WHERE f.fichier_nom = 'T1-copie.pdf'
$$, 'true', 'une réutilisation (aucun appel au LLM) n''a pas de texte source');

-- Corrections par le code et propositions (D-053) ---------------------------------
SELECT pg_temp.doit_reussir($$
    WITH f AS (INSERT INTO fournisseurs (raison_sociale, matricule_fiscal)
               VALUES ('Fournisseur Référentiel', '9912399Z') RETURNING id)
    INSERT INTO fournisseur_ribs (fournisseur_id, rib) SELECT id, '99001000000000000099' FROM f;
    WITH f AS (INSERT INTO fournisseurs (raison_sociale, matricule_fiscal)
               VALUES ('Fournisseur Ancien RIB', '9912398Y') RETURNING id)
    INSERT INTO fournisseur_ribs (fournisseur_id, rib, valide_du, valide_au)
    SELECT id, '99001000000000000198', '2026-01-01', '2026-02-01' FROM f;
$$, 'deux fournisseurs : un RIB actif, un RIB clos');
SELECT pg_temp.doit_valoir($$SELECT ribs_referentiel() ->> '9912399Z'$$, '99001000000000000099',
    'le référentiel donne le RIB actif par matricule fiscal');
SELECT pg_temp.doit_valoir($$SELECT (ribs_referentiel() ? '9912398Y')::text$$, 'false',
    'un RIB clos n''est pas dans le référentiel');
SELECT pg_temp.doit_reussir($$
    SELECT enregistrer_reception('dossier', 'T6.pdf', 'pdf', 'T6.pdf', repeat('6', 64));
    SELECT enregistrer_reception('dossier', 'T6-copie.pdf', 'pdf', 'T6-copie.pdf', repeat('6', 64));
    UPDATE factures SET statut = 'erreur_extraction'
    WHERE statut = 'recue' AND fichier_nom NOT IN ('T6.pdf', 'T6-copie.pdf');
$$, 'réception de T6 et de sa copie');
SELECT pg_temp.doit_valoir($$SELECT fichier_nom FROM reserver_facture_a_extraire()$$, 'T6.pdf',
    'réservation de T6');
SELECT pg_temp.doit_reussir($$
    SELECT enregistrer_extraction(jsonb_build_object(
        'facture_id', (SELECT id FROM factures WHERE fichier_nom = 'T6.pdf'),
        'resultat', 'valide', 'code_resultat', 'ok', 'methode_lecture', 'texte_pdf',
        'donnees', (SELECT donnees FROM extraction_valide_existante(repeat('1', 64))),
        'donnees_brutes', (SELECT donnees || '{"devise": "DT"}' FROM extraction_valide_existante(repeat('1', 64))),
        'corrections_code', '["devise : « DT » converti en TND"]'::jsonb,
        'propositions', '[{"champ": "fournisseur.rib", "valeur": "99001000000000000198", "rib_referentiel": null}]'::jsonb))
$$, 'extraction corrigée par le code, avec une proposition de RIB');
SELECT pg_temp.doit_valoir($$
    SELECT concat_ws('|', e.donnees_brutes ->> 'devise', e.donnees ->> 'devise', jsonb_array_length(e.corrections_code),
                     jsonb_array_length(e.signalements_code), e.propositions -> 0 ->> 'valeur', f.devise,
                     f.extraction_brute ->> 'devise')
    FROM extractions e JOIN factures f ON f.id = e.facture_id WHERE f.fichier_nom = 'T6.pdf'
$$, 'DT|TND|1|0|99001000000000000198|TND|DT',
    'sortie brute et données corrigées conservées ; la facture reçoit les données corrigées');
SELECT pg_temp.doit_valoir($$
    SELECT j.action FROM journal_audit j JOIN factures f ON j.entite_id = f.id::text
    WHERE f.fichier_nom = 'T6.pdf' AND j.acteur = 'n8n:extraction'
$$, 'facture.extraite_avec_alertes', 'une proposition suffit à signaler la facture au journal');
SELECT pg_temp.doit_valoir($$SELECT fichier_nom FROM reserver_facture_a_extraire()$$, 'T6-copie.pdf',
    'réservation de la copie de T6');
SELECT pg_temp.doit_reussir($$
    SELECT enregistrer_extraction(jsonb_build_object(
        'facture_id', (SELECT id FROM factures WHERE fichier_nom = 'T6-copie.pdf'),
        'resultat', 'reutilisee', 'code_resultat', 'reutilisation',
        'reutilise_de', (SELECT e.id FROM extractions e JOIN factures f ON f.id = e.facture_id WHERE f.fichier_nom = 'T6.pdf'),
        'methode_lecture', 'texte_pdf',
        'donnees', (SELECT e.donnees FROM extractions e JOIN factures f ON f.id = e.facture_id WHERE f.fichier_nom = 'T6.pdf')))
$$, 'la copie réutilise l''extraction de T6');
SELECT pg_temp.doit_valoir($$
    SELECT concat_ws('|', e.propositions -> 0 ->> 'valeur', e.donnees_brutes ->> 'devise', jsonb_array_length(e.corrections_code))
    FROM extractions e JOIN factures f ON f.id = e.facture_id WHERE f.fichier_nom = 'T6-copie.pdf'
$$, '99001000000000000198|DT|1', 'une réutilisation garde la proposition de RIB et la sortie brute d''origine');

-- Erreur et libération -----------------------------------------------------------
SELECT pg_temp.doit_reussir($$
    SELECT enregistrer_reception('dossier', 'T2.jpg', 'image', 'T2.jpg', repeat('2', 64));
    SELECT enregistrer_reception('dossier', 'T3.jpg', 'image', 'T3.jpg', repeat('3', 64));
$$, 'réception de deux autres fichiers');
SELECT pg_temp.doit_valoir($$SELECT fichier_nom FROM reserver_facture_a_extraire()$$, 'T2.jpg',
    'réservation de T2');
SELECT pg_temp.doit_reussir($$
    SELECT enregistrer_extraction(jsonb_build_object(
        'facture_id', (SELECT id FROM factures WHERE fichier_nom = 'T2.jpg'),
        'resultat', 'erreur', 'code_resultat', 'erreur_fournisseur', 'methode_lecture', 'ocr',
        'erreurs', '["délai dépassé"]'::jsonb))
$$, 'enregistrement d''une extraction en erreur');
SELECT pg_temp.doit_valoir($$
    SELECT statut || '/' || (extraction_brute IS NULL)::text FROM factures WHERE fichier_nom = 'T2.jpg'
$$, 'erreur_extraction/true', 'la facture passe en « erreur_extraction »');
SELECT pg_temp.doit_valoir($$SELECT fichier_nom FROM reserver_facture_a_extraire()$$, 'T3.jpg',
    'le traitement continue avec la facture suivante');
SELECT pg_temp.doit_valoir($$
    SELECT liberer_facture(id)::text FROM factures WHERE fichier_nom = 'T3.jpg'
$$, 'true', 'quota journalier épuisé : la facture réservée est libérée');
SELECT pg_temp.doit_valoir($$SELECT statut FROM factures WHERE fichier_nom = 'T3.jpg'$$, 'recue',
    'elle revient au statut « recue » pour le prochain passage');
SELECT pg_temp.doit_valoir($$
    SELECT liberer_facture(id)::text FROM factures WHERE fichier_nom = 'T1.pdf'
$$, 'false', 'une facture déjà extraite ne peut pas être « libérée »');

-- Droits ---------------------------------------------------------------------------
SELECT pg_temp.doit_echouer($$UPDATE extractions SET resultat = 'valide'$$,
    '42501', 'mizan_app ne peut pas réécrire une extraction');
SELECT pg_temp.doit_echouer($$DELETE FROM extractions$$,
    '42501', 'mizan_app ne peut pas supprimer une extraction');

ROLLBACK;
