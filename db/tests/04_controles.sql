-- Tests du modèle des contrôles et de leurs suites humaines (D-055, D-056) :
-- transitions de statut, passage de contrôle complet, décisions humaines,
-- demandes de modification du référentiel (quatre yeux).
-- Lancé par l'administrateur, qui prépare les données ; les actions testées
-- sont faites sous le rôle applicatif (SET ROLE mizan_app), comme n8n.
-- Tout se passe dans une transaction annulée à la fin.
\set ON_ERROR_STOP on
\set VERBOSITY terse
BEGIN;
-- Les fonctions d'assertion sont créées sous mizan_app pour lui rester utilisables.
SET ROLE mizan_app;
\ir 00_outils.sql
RESET ROLE;
\o /dev/null

-- Données de départ (administrateur) -------------------------------------------
UPDATE factures SET statut = 'erreur_extraction', reservee_le = NULL
WHERE statut IN ('recue', 'en_extraction', 'extraite', 'en_controle');

INSERT INTO utilisateurs (nom, role, fictif) VALUES
    ('Test – Responsable A', 'responsable', TRUE),
    ('Test – Responsable B', 'responsable', TRUE),
    ('Test – Validateur', 'validateur', TRUE);
INSERT INTO utilisateurs (nom, role, actif, fictif) VALUES ('Test – Ancien', 'responsable', FALSE, TRUE);

WITH f AS (INSERT INTO fournisseurs (raison_sociale, matricule_fiscal)
           VALUES ('Fournisseur Contrôlé', '9912399Z') RETURNING id)
INSERT INTO fournisseur_ribs (fournisseur_id, rib, valide_du) SELECT id, '99001000000000000165', '2026-01-01' FROM f;
WITH f AS (INSERT INTO fournisseurs (raison_sociale, matricule_fiscal)
           VALUES ('Fournisseur Ancien RIB', '9912398Y') RETURNING id)
INSERT INTO fournisseur_ribs (fournisseur_id, rib, valide_du, valide_au)
SELECT id, '99002000000000000120', '2026-01-01', '2026-02-01' FROM f;

CREATE FUNCTION pg_temp.u(p_nom TEXT) RETURNS BIGINT LANGUAGE sql AS
    $f$ SELECT id FROM utilisateurs WHERE nom = p_nom $f$;
CREATE FUNCTION pg_temp.f(p_nom TEXT) RETURNS BIGINT LANGUAGE sql AS
    $f$ SELECT id FROM factures WHERE fichier_nom = p_nom $f$;
CREATE FUNCTION pg_temp.fournisseur(p_matricule TEXT) RETURNS BIGINT LANGUAGE sql AS
    $f$ SELECT id FROM fournisseurs WHERE matricule_fiscal = p_matricule $f$;

-- Facture de test, au statut voulu (l'administrateur n'est pas soumis à la garde).
CREATE FUNCTION pg_temp.facture(p_nom TEXT, p_statut TEXT, p_numero TEXT DEFAULT NULL,
                                p_fournisseur BIGINT DEFAULT NULL) RETURNS BIGINT LANGUAGE sql AS $f$
    INSERT INTO factures (fichier_nom, statut, numero, fournisseur_id, canal_reception, format_source,
                          fichier_sha256, montant_ttc, date_facture)
    VALUES (p_nom, p_statut, p_numero, p_fournisseur, 'dossier', 'pdf',
            encode(sha256(convert_to(p_nom, 'UTF8')), 'hex'), 100, '2026-03-01')
    RETURNING id
$f$;

-- Résultats d'un passage complet : toutes les règles actives « ok », sauf
-- celles données dans p_ecarts ({ regle: [resultat, gravite] }).
CREATE FUNCTION pg_temp.resultats(p_ecarts JSONB DEFAULT '{}') RETURNS JSONB LANGUAGE sql AS $f$
    SELECT jsonb_agg(jsonb_build_object(
        'regle', c.regle, 'version_regle', '1',
        'resultat', coalesce(p_ecarts -> c.regle ->> 0, 'ok'),
        'gravite', coalesce(p_ecarts -> c.regle ->> 1, 'info'),
        'message', 'test', 'detail', '{}'::jsonb))
    FROM regles_controle c WHERE c.actif
$f$;

-- Passage déjà enregistré pour une facture bloquée (préparation administrateur).
CREATE FUNCTION pg_temp.passage(p_facture BIGINT, p_ecarts JSONB) RETURNS VOID LANGUAGE sql AS $f$
    INSERT INTO resultats_controles (facture_id, passage, regle, version_regle, resultat, gravite)
    SELECT p_facture, currval('passages_controle_seq'), r ->> 'regle', '1', r ->> 'resultat', r ->> 'gravite'
    FROM (SELECT nextval('passages_controle_seq')) n, jsonb_array_elements(pg_temp.resultats(p_ecarts)) r
$f$;

SELECT pg_temp.facture('C-tva.pdf', 'bloquee', 'C-1', pg_temp.fournisseur('9912399Z'));
SELECT pg_temp.passage(pg_temp.f('C-tva.pdf'), '{"coherence_tva": ["anomalie", "bloquant"]}');
SELECT pg_temp.facture('C-rib.pdf', 'bloquee', 'C-2', pg_temp.fournisseur('9912399Z'));
SELECT pg_temp.passage(pg_temp.f('C-rib.pdf'), '{"changement_rib": ["anomalie", "bloquant"]}');
SELECT pg_temp.facture('C-inconnu.pdf', 'bloquee', 'C-3');
SELECT pg_temp.passage(pg_temp.f('C-inconnu.pdf'), '{"fournisseur_inconnu": ["anomalie", "bloquant"]}');
SELECT pg_temp.facture('C-devise.pdf', 'anomalie', 'C-4', pg_temp.fournisseur('9912399Z'));
SELECT pg_temp.facture('C-a-controler.pdf', 'extraite', 'C-5');
SELECT pg_temp.facture('C-a-controler-copie.pdf', 'erreur_extraction', 'c-5');

SET ROLE mizan_app;

-- Paramètres de contrôle (précision 3 de D-055) ------------------------------------
SELECT pg_temp.doit_valoir($$SELECT parametre_controle('seuil_validation_ttc')::text$$, '20000.000',
    'le seuil de validation vient de la table de configuration');
SELECT pg_temp.doit_valoir($$SELECT parametres_controle_en_vigueur() ->> 'tolerance.tva_millimes_par_ligne'$$, '1.000',
    'les tolérances d''arrondi viennent de la table de configuration');
SELECT pg_temp.doit_echouer($$SELECT parametre_controle('inexistant')$$, 'MZ017', 'paramètre absent : erreur explicite');
SELECT pg_temp.doit_echouer($$UPDATE parametres_controle SET valeur = 0$$, '42501',
    'mizan_app ne peut pas modifier les paramètres');

-- Garde des transitions ------------------------------------------------------------
SELECT pg_temp.doit_echouer($$UPDATE factures SET statut = 'validee' WHERE id = pg_temp.f('C-a-controler.pdf')$$,
    'MZ010', 'transition non prévue refusée (extraite → validee)');
SELECT pg_temp.doit_echouer($$UPDATE factures SET statut = 'validee' WHERE id = pg_temp.f('C-tva.pdf')$$,
    'MZ011', 'sortir de « bloquee » sans décision humaine est refusé');

-- Passage de contrôle ---------------------------------------------------------------
SELECT pg_temp.doit_valoir($$SELECT facture_id = pg_temp.f('C-a-controler.pdf') FROM reserver_facture_a_controler()$$,
    'true', 'la facture extraite est réservée pour les contrôles');
SELECT pg_temp.doit_valoir($$SELECT statut FROM factures WHERE id = pg_temp.f('C-a-controler.pdf')$$, 'en_controle',
    'statut « en_controle »');
SELECT pg_temp.doit_valoir($$SELECT count(*)::text FROM reserver_facture_a_controler()$$, '0',
    'plus rien à contrôler');
SELECT pg_temp.doit_valoir($$
    SELECT concat_ws('|', c -> 'facture' ->> 'numero_normalise', jsonb_array_length(c -> 'regles'),
                     c -> 'parametres' ->> 'seuil_validation_ttc', c -> 'config_fiscale' -> 'timbre.facture' ->> 'valeur',
                     (SELECT count(*) FROM jsonb_array_elements(c -> 'autres_factures') a WHERE a ->> 'numero' = 'c-5'),
                     (SELECT count(*) FROM jsonb_array_elements(c -> 'referentiel') r WHERE r ->> 'matricule_fiscal' = '9912399Z'))
    FROM contexte_controles(pg_temp.f('C-a-controler.pdf')) c
$$, 'C-5|22|20000.000|1.0000|1|1',
    'contexte : facture, règles, paramètres, configuration fiscale à la date, candidat doublon, référentiel');
SELECT pg_temp.doit_echouer($$
    SELECT enregistrer_controles(jsonb_build_object('facture_id', pg_temp.f('C-a-controler.pdf'),
        'resultats', (SELECT jsonb_agg(r) FROM jsonb_array_elements(pg_temp.resultats()) r WHERE r ->> 'regle' <> 'devise')))
$$, 'MZ021', 'un passage sans toutes les règles est refusé (toutes les règles s''exécutent)');
SELECT pg_temp.doit_echouer($$
    SELECT enregistrer_controles(jsonb_build_object('facture_id', pg_temp.f('C-a-controler.pdf'),
        'resultats', pg_temp.resultats() || jsonb_build_array(jsonb_build_object('regle', 'devise'))))
$$, 'MZ021', 'une règle enregistrée deux fois dans un passage est refusée');
SELECT pg_temp.doit_reussir($$
    SELECT enregistrer_controles(jsonb_build_object('facture_id', pg_temp.f('C-a-controler.pdf'),
        'execution_n8n_id', 'exec-c', 'resultats',
        pg_temp.resultats('{"devise": ["anomalie", "avertissement"], "seuil_validation": ["anomalie", "validation"],
                            "matricule_suffixe": ["anomalie", "info"]}')))
$$, 'passage complet enregistré');
SELECT pg_temp.doit_valoir($$
    SELECT concat_ws('|', f.statut, (SELECT count(*) FROM resultats_controles r WHERE r.facture_id = f.id),
                     j.donnees_apres ->> 'avertissement', j.donnees_apres -> 'regles_en_anomalie')
    FROM factures f JOIN journal_audit j ON j.entite_id = f.id::text AND j.action = 'facture.controlee'
    WHERE f.id = pg_temp.f('C-a-controler.pdf')
$$, 'anomalie|22|1|["devise", "seuil_validation"]',
    'gravité la plus forte → « anomalie » ; 22 résultats ; bilan au journal (info exclue)');
SELECT pg_temp.doit_echouer($$UPDATE resultats_controles SET resultat = 'ok'$$, '42501',
    'un résultat de contrôle ne se réécrit pas');

-- Statut calculé selon la gravité (préparation : nouvelles factures à contrôler).
RESET ROLE;
SELECT pg_temp.facture('C-seuil.pdf', 'extraite', 'C-6', pg_temp.fournisseur('9912399Z'));
SELECT pg_temp.facture('C-sain.pdf', 'extraite', 'C-7');
SELECT pg_temp.facture('C-bloque.pdf', 'extraite', 'C-8');
SET ROLE mizan_app;
SELECT pg_temp.doit_reussir($$
    SELECT reserver_facture_a_controler(); SELECT reserver_facture_a_controler(); SELECT reserver_facture_a_controler();
    SELECT enregistrer_controles(jsonb_build_object('facture_id', pg_temp.f('C-seuil.pdf'),
        'fournisseur_id', pg_temp.fournisseur('9912399Z'),
        'resultats', pg_temp.resultats('{"seuil_validation": ["anomalie", "validation"]}')));
    SELECT enregistrer_controles(jsonb_build_object('facture_id', pg_temp.f('C-sain.pdf'),
        'fournisseur_id', pg_temp.fournisseur('9912399Z'), 'resultats', pg_temp.resultats()));
    SELECT enregistrer_controles(jsonb_build_object('facture_id', pg_temp.f('C-bloque.pdf'),
        'resultats', pg_temp.resultats('{"fournisseur_inconnu": ["anomalie", "bloquant"], "devise": ["anomalie", "avertissement"]}')));
$$, 'trois passages enregistrés');
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(statut || ':' || coalesce(fournisseur_source, '-'), ',' ORDER BY id) FROM factures
    WHERE id IN (pg_temp.f('C-seuil.pdf'), pg_temp.f('C-sain.pdf'), pg_temp.f('C-bloque.pdf'))
$$, 'a_valider:controle,conforme:controle,bloquee:-',
    'seuil → « a_valider », rien → « conforme » (fournisseur rattaché), bloquant → « bloquee »');

-- Décisions humaines ----------------------------------------------------------------
-- Depuis D-062, mizan_app ne crée plus de décision directement : seule la
-- fonction recevoir_evenement (canal authentifié) le fait (05_canaux.sql).
-- Les déclencheurs de décision sont donc testés ici sous l'administrateur.
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_humaines (facture_id, utilisateur_id, decision, justification)
    VALUES (pg_temp.f('C-tva.pdf'), pg_temp.u('Test – Responsable A'), 'valider', 'Décision sans passer par un canal')
$$, '42501', 'mizan_app ne peut pas insérer une décision directement (D-062)');
RESET ROLE;
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_humaines (facture_id, utilisateur_id, decision, justification)
    VALUES (pg_temp.f('C-tva.pdf'), pg_temp.u('Test – Validateur'), 'valider', 'TVA vérifiée avec le fournisseur')
$$, 'MZ014', 'un validateur ne peut pas sortir une facture de « bloquee »');
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_humaines (facture_id, utilisateur_id, decision, justification)
    VALUES (pg_temp.f('C-tva.pdf'), pg_temp.u('Test – Responsable A'), 'valider', 'ok')
$$, 'MZ013', 'justification obligatoire (longueur minimale)');
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_humaines (facture_id, utilisateur_id, decision, justification)
    VALUES (pg_temp.f('C-tva.pdf'), pg_temp.u('Test – Ancien'), 'valider', 'TVA vérifiée avec le fournisseur')
$$, 'MZ012', 'un utilisateur inactif ne décide rien');
SELECT pg_temp.doit_reussir($$
    INSERT INTO decisions_humaines (facture_id, utilisateur_id, decision, justification, canal)
    VALUES (pg_temp.f('C-tva.pdf'), pg_temp.u('Test – Responsable A'), 'valider',
            'Écart de TVA confirmé par le fournisseur, avoir à venir', 'test')
$$, 'dérogation par un responsable, avec justification (règle dérogeable)');
SELECT pg_temp.doit_valoir($$
    SELECT concat_ws('|', f.statut, d.statut_avant, d.statut_apres, (d.passage_controle IS NOT NULL)::text, j.commentaire)
    FROM factures f JOIN decisions_humaines d ON d.facture_id = f.id
    JOIN journal_audit j ON j.entite_id = f.id::text AND j.action = 'facture.decision.valider'
    WHERE f.id = pg_temp.f('C-tva.pdf')
$$, 'validee|bloquee|validee|true|Écart de TVA confirmé par le fournisseur, avoir à venir',
    'statut changé, décision et justification tracées au journal');
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_humaines (facture_id, utilisateur_id, decision, justification)
    VALUES (pg_temp.f('C-rib.pdf'), pg_temp.u('Test – Responsable A'), 'valider', 'Le fournisseur a confirmé par téléphone')
$$, 'MZ015', 'changement de RIB : règle non dérogeable, pas de validation');
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_humaines (facture_id, utilisateur_id, decision, justification, corrections)
    VALUES (pg_temp.f('C-rib.pdf'), pg_temp.u('Test – Responsable A'), 'renvoyer_aux_controles',
            'Correction du montant après vérification', '{"montant_ttc": 1}')
$$, 'MZ016', 'seule la correction du fournisseur est admise');
SELECT pg_temp.doit_reussir($$
    INSERT INTO decisions_humaines (facture_id, utilisateur_id, decision, justification)
    VALUES (pg_temp.f('C-devise.pdf'), pg_temp.u('Test – Validateur'), 'valider', 'Facture en dinars, devise mal lue')
$$, 'un validateur valide une facture en « anomalie »');
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_humaines (facture_id, utilisateur_id, decision, justification)
    VALUES (pg_temp.f('C-devise.pdf'), pg_temp.u('Test – Responsable A'), 'rejeter', 'Rejet demandé après validation')
$$, 'MZ010', 'une facture validée ne peut plus changer de statut');
SELECT pg_temp.doit_echouer($$DELETE FROM decisions_humaines$$, 'MZ001', 'une décision ne se supprime pas (ajout seul)');

-- Référentiel : plus d'écriture directe (D-056) ---------------------------------------
SET ROLE mizan_app;
SELECT pg_temp.doit_echouer($$INSERT INTO fournisseurs (raison_sociale, matricule_fiscal) VALUES ('Pirate', '9900001A')$$,
    '42501', 'mizan_app ne crée pas de fournisseur directement');
SELECT pg_temp.doit_echouer($$UPDATE fournisseur_ribs SET rib = '99003000000000000269'$$,
    '42501', 'mizan_app ne modifie pas un RIB directement');
SELECT pg_temp.doit_valoir($$SELECT ribs_referentiel() ->> '9912399Z'$$, '99001000000000000165',
    'le référentiel donne le RIB actif par matricule fiscal');
SELECT pg_temp.doit_valoir($$SELECT (ribs_referentiel() ? '9912398Y')::text$$, 'false',
    'un RIB clos n''est pas dans le référentiel');
SELECT pg_temp.doit_valoir($$
    SELECT concat_ws('|', rib_cle_valide('99001000000000000165'), rib_cle_valide('99001000000000000166'),
                     rib_cle_valide('10006035183598478831'), rib_cle_valide('9900100000000000016'))
$$, 't|f|t|f', 'clé RIB vérifiée comme src/rib.js (exemple du registre IBAN compris)');

RESET ROLE;
-- Changement de RIB : demande, quatre yeux, méthode de vérification ------------------
SELECT pg_temp.doit_echouer($$
    INSERT INTO demandes_referentiel (type_demande, fournisseur_id, facture_id, donnees, demande_par, justification)
    VALUES ('changement_rib', pg_temp.fournisseur('9912399Z'), pg_temp.f('C-rib.pdf'),
            '{"rib": "99003000000000000268"}', pg_temp.u('Test – Validateur'), 'Nouveau RIB indiqué sur la facture')
$$, 'MZ019', 'un RIB à clé fausse ne peut pas être demandé');
SELECT pg_temp.doit_reussir($$
    INSERT INTO demandes_referentiel (type_demande, fournisseur_id, facture_id, donnees, demande_par, justification)
    VALUES ('changement_rib', pg_temp.fournisseur('9912399Z'), pg_temp.f('C-rib.pdf'),
            '{"rib": "99003000000000000269", "banque": "Banque fictive"}', pg_temp.u('Test – Validateur'),
            'Nouveau RIB indiqué sur la facture C-2')
$$, 'demande de changement de RIB par un validateur');
SELECT pg_temp.doit_valoir($$
    SELECT rib_actuel || '|' || (SELECT count(*) FROM journal_audit j WHERE j.entite = 'demandes_referentiel'
                                 AND j.entite_id = d.id::text AND j.action = 'referentiel.demande.changement_rib')
    FROM demandes_referentiel d WHERE d.facture_id = pg_temp.f('C-rib.pdf')
$$, '99001000000000000165|1', 'le RIB actif au moment de la demande est conservé ; demande au journal');
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_referentiel (demande_id, decision, utilisateur_id, methode_verification, justification)
    SELECT id, 'approuvee', pg_temp.u('Test – Validateur'), 'rib_rappel_contact_connu', 'Fournisseur rappelé au numéro connu'
    FROM demandes_referentiel WHERE facture_id = pg_temp.f('C-rib.pdf')
$$, 'MZ014', 'seul un responsable approuve un changement de RIB');
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_referentiel (demande_id, decision, utilisateur_id, justification)
    SELECT id, 'approuvee', pg_temp.u('Test – Responsable A'), 'Fournisseur rappelé au numéro connu'
    FROM demandes_referentiel WHERE facture_id = pg_temp.f('C-rib.pdf')
$$, '23514', 'méthode de vérification obligatoire pour approuver');
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_referentiel (demande_id, decision, utilisateur_id, methode_verification, justification)
    SELECT id, 'approuvee', pg_temp.u('Test – Responsable A'), 'creation_attestation_bancaire', 'Attestation bancaire reçue'
    FROM demandes_referentiel WHERE facture_id = pg_temp.f('C-rib.pdf')
$$, 'MZ019', 'la méthode doit correspondre au type de demande');

-- Quatre yeux : un responsable ne peut pas approuver sa propre demande.
SELECT pg_temp.doit_reussir($$
    INSERT INTO demandes_referentiel (type_demande, fournisseur_id, donnees, demande_par, justification)
    VALUES ('changement_rib', pg_temp.fournisseur('9912399Z'), '{"rib": "99004000000000000321"}',
            pg_temp.u('Test – Responsable A'), 'Demande faite par le responsable lui-même')
$$, 'demande d''un responsable');
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_referentiel (demande_id, decision, utilisateur_id, methode_verification, justification)
    SELECT id, 'approuvee', pg_temp.u('Test – Responsable A'), 'rib_rappel_contact_connu', 'Fournisseur rappelé au numéro connu'
    FROM demandes_referentiel WHERE donnees ->> 'rib' = '99004000000000000321'
$$, 'MZ018', 'quatre yeux : pas d''approbation de sa propre demande');
SELECT pg_temp.doit_reussir($$
    INSERT INTO decisions_referentiel (demande_id, decision, utilisateur_id, justification)
    SELECT id, 'refusee', pg_temp.u('Test – Responsable B'), 'Aucune confirmation du fournisseur obtenue'
    FROM demandes_referentiel WHERE donnees ->> 'rib' = '99004000000000000321'
$$, 'refus par un autre responsable (sans méthode)');
SELECT pg_temp.doit_valoir($$
    SELECT (SELECT rib FROM fournisseur_ribs WHERE fournisseur_id = pg_temp.fournisseur('9912399Z') AND valide_au IS NULL)
           || '|' || (SELECT count(*) FROM journal_audit WHERE action = 'referentiel.demande_refusee')
$$, '99001000000000000165|1', 'un refus ne change pas le référentiel ; il est tracé');

-- Approbation du changement demandé par le validateur.
SELECT pg_temp.doit_reussir($$
    INSERT INTO decisions_referentiel (demande_id, decision, utilisateur_id, methode_verification, justification)
    SELECT id, 'approuvee', pg_temp.u('Test – Responsable A'), 'rib_rappel_contact_connu',
           'Fournisseur rappelé au numéro du référentiel, changement confirmé'
    FROM demandes_referentiel WHERE facture_id = pg_temp.f('C-rib.pdf')
$$, 'changement de RIB approuvé par un responsable, avec méthode de vérification');
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(rib || ':' || coalesce(valide_au::text, 'actif') || ':' || origine, ',' ORDER BY id)
    FROM fournisseur_ribs WHERE fournisseur_id = pg_temp.fournisseur('9912399Z')
$$, '99001000000000000165:' || current_date || ':saisie,99003000000000000269:actif:facture',
    'ancien RIB clos aujourd''hui, nouveau RIB actif (historique conservé)');
SELECT pg_temp.doit_valoir($$
    SELECT concat_ws('|', f.statut, d.decision, d.demande_id IS NOT NULL,
                     (SELECT count(*) FROM journal_audit j WHERE j.action = 'fournisseur.rib_modifie'
                      AND j.donnees_apres ->> 'methode_verification' = 'rib_rappel_contact_connu'))
    FROM factures f JOIN decisions_humaines d ON d.facture_id = f.id WHERE f.id = pg_temp.f('C-rib.pdf')
$$, 'extraite|renvoyer_aux_controles|t|1',
    'la facture bloquée est renvoyée aux contrôles ; changement au journal avec sa méthode');
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_referentiel (demande_id, decision, utilisateur_id, justification)
    SELECT id, 'refusee', pg_temp.u('Test – Responsable B'), 'Seconde décision sur la même demande'
    FROM demandes_referentiel WHERE facture_id = pg_temp.f('C-rib.pdf')
$$, '23505', 'une seule décision par demande');

-- Création d'un fournisseur : même discipline --------------------------------------------
SELECT pg_temp.doit_echouer($$
    INSERT INTO demandes_referentiel (type_demande, facture_id, donnees, demande_par, justification)
    VALUES ('creation_fournisseur', pg_temp.f('C-inconnu.pdf'),
            '{"raison_sociale": "Nouveau", "matricule_fiscal": "991234A"}', pg_temp.u('Test – Validateur'),
            'Fournisseur absent du référentiel')
$$, 'MZ019', 'création : matricule court mal formé refusé');
SELECT pg_temp.doit_echouer($$
    INSERT INTO demandes_referentiel (type_demande, donnees, demande_par, justification)
    VALUES ('creation_fournisseur', '{"raison_sociale": "Doublon", "matricule_fiscal": "9912399Z"}',
            pg_temp.u('Test – Validateur'), 'Fournisseur absent du référentiel')
$$, 'MZ019', 'création : fournisseur déjà présent refusé');
SELECT pg_temp.doit_reussir($$
    INSERT INTO demandes_referentiel (type_demande, facture_id, donnees, demande_par, justification)
    VALUES ('creation_fournisseur', pg_temp.f('C-inconnu.pdf'),
            '{"raison_sociale": "Nouveau Fournisseur Test", "matricule_fiscal": "9912397X", "rib": "99004000000000000321"}',
            pg_temp.u('Test – Validateur'), 'Fournisseur absent du référentiel, facture C-3')
$$, 'demande de création d''un fournisseur');
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_referentiel (demande_id, decision, utilisateur_id, methode_verification, justification)
    SELECT id, 'approuvee', pg_temp.u('Test – Responsable B'), 'rib_rappel_contact_connu', 'Vérification faite par téléphone'
    FROM demandes_referentiel WHERE type_demande = 'creation_fournisseur'
$$, 'MZ019', 'création : une méthode de changement de RIB ne convient pas');
SELECT pg_temp.doit_reussir($$
    INSERT INTO decisions_referentiel (demande_id, decision, utilisateur_id, methode_verification, justification)
    SELECT id, 'approuvee', pg_temp.u('Test – Responsable B'), 'creation_identifiant_fiscal_verifie',
           'Matricule et raison sociale vérifiés auprès d''une source officielle'
    FROM demandes_referentiel WHERE type_demande = 'creation_fournisseur'
$$, 'création approuvée par un responsable, avec méthode de vérification');
SELECT pg_temp.doit_valoir($$
    SELECT concat_ws('|', fo.raison_sociale, r.rib, r.origine, f.statut, f.fournisseur_id = fo.id, f.fournisseur_source,
                     (SELECT count(*) FROM journal_audit j WHERE j.action = 'fournisseur.cree' AND j.entite_id = fo.id::text))
    FROM fournisseurs fo JOIN fournisseur_ribs r ON r.fournisseur_id = fo.id, factures f
    WHERE fo.matricule_fiscal = '9912397X' AND f.id = pg_temp.f('C-inconnu.pdf')
$$, 'Nouveau Fournisseur Test|99004000000000000321|facture|extraite|t|decision|1',
    'fournisseur et RIB créés ; facture rattachée par décision et renvoyée aux contrôles ; création au journal');

-- Un rattachement décidé par une personne n'est pas remplacé par les contrôles.
SET ROLE mizan_app;
SELECT pg_temp.doit_reussir($$
    SELECT reserver_facture_a_controler(); SELECT reserver_facture_a_controler();
    SELECT enregistrer_controles(jsonb_build_object('facture_id', pg_temp.f('C-inconnu.pdf'), 'fournisseur_id', NULL,
        'resultats', pg_temp.resultats('{"devise": ["anomalie", "avertissement"]}')));
$$, 'nouveau contrôle de la facture rattachée par décision');
SELECT pg_temp.doit_valoir($$
    SELECT statut || '|' || fournisseur_source || '|' || (fournisseur_id = pg_temp.fournisseur('9912397X'))::text
    FROM factures WHERE id = pg_temp.f('C-inconnu.pdf')
$$, 'anomalie|decision|true', 'le fournisseur confirmé par décision est conservé au contrôle suivant');

-- Historique du fournisseur dans le contexte (D-060) ---------------------------------
RESET ROLE;
INSERT INTO factures (fichier_nom, statut, numero, matricule_fiscal_lu, canal_reception, format_source, fichier_sha256, montant_ttc, date_facture)
VALUES ('H-1.pdf', 'anomalie', 'H-1', '9912399Z/A/M/008', 'dossier', 'pdf', repeat('7', 64), 10, '2026-01-10'),
       ('H-2.pdf', 'extraite', 'H-2', '9912399 Z/A/M/000', 'dossier', 'pdf', repeat('8', 64), 20, '2026-02-10'),
       ('H-3.pdf', 'anomalie', 'H-3', '9912398Y/A/M/000', 'dossier', 'pdf', repeat('9', 64), 30, '2026-03-10');
UPDATE factures SET fournisseur_id = pg_temp.fournisseur('9912399Z') WHERE fichier_nom IN ('H-1.pdf', 'H-2.pdf', 'H-3.pdf');
SET ROLE mizan_app;
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(a ->> 'numero', ',' ORDER BY (a ->> 'id')::bigint)
    FROM jsonb_array_elements(contexte_controles(pg_temp.f('H-2.pdf')) -> 'autres_factures') a
    WHERE a ->> 'numero' LIKE 'H-%'
$$, 'H-1,H-3',
    'le contexte transmet l''historique du fournisseur : même matricule lu (espaces ignorés) ou même rattachement');

RESET ROLE;
ROLLBACK;
