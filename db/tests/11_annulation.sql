-- Tests de l'annulation d'un rapprochement (D-075, D-077) : commande
-- « /annuler », choix, demande, approbation par un AUTRE responsable,
-- contre-passation (rien d'effacé), ligne de nouveau « à rapprocher »,
-- facture exclue des ordres jusqu'au nouveau rapprochement, virement groupé.
-- Préparation par l'administrateur ; actions sous le rôle applicatif.
\set ON_ERROR_STOP on
\set VERBOSITY terse
BEGIN;
SET ROLE mizan_app;
\ir 00_outils.sql
RESET ROLE;
\o /dev/null

-- Données de départ (administrateur) -----------------------------------------------------
INSERT INTO utilisateurs (nom, role, fictif) VALUES
    ('Annul – Responsable 1', 'responsable', TRUE), ('Annul – Responsable 2', 'responsable', TRUE), ('Annul – Validateur', 'validateur', TRUE);
CREATE FUNCTION pg_temp.u(p TEXT) RETURNS BIGINT LANGUAGE sql AS $f$ SELECT id FROM utilisateurs WHERE nom = p $f$;
UPDATE adresses_canal SET active = FALSE;
INSERT INTO adresses_canal (utilisateur_id, canal, adresse) VALUES
    (pg_temp.u('Annul – Responsable 1'), 'telegram', '941'), (pg_temp.u('Annul – Responsable 2'), 'telegram', '942'),
    (pg_temp.u('Annul – Validateur'), 'telegram', '943');
INSERT INTO decisions_lot_paiement (lot_id, decision, utilisateur_id, justification)
SELECT id, 'refuser', pg_temp.u('Annul – Responsable 1'), 'Isolement du test : lot réel mis de côté' FROM lots_paiement WHERE statut = 'propose';
WITH f AS (INSERT INTO fournisseurs (raison_sociale, matricule_fiscal) VALUES ('Fournisseur Annul', '9912355B') RETURNING id)
INSERT INTO fournisseur_ribs (fournisseur_id, rib, valide_du) SELECT id, '99001000000000000165', '2026-01-01' FROM f;
CREATE FUNCTION pg_temp.f(p TEXT) RETURNS BIGINT LANGUAGE sql AS $f$ SELECT id FROM factures WHERE fichier_nom = p $f$;
CREATE FUNCTION pg_temp.facture(p TEXT, p_ttc NUMERIC) RETURNS VOID LANGUAGE sql AS $f$
    INSERT INTO factures (fichier_nom, statut, numero, fournisseur_id, canal_reception, format_source, fichier_sha256, montant_ttc, devise, date_facture, date_echeance)
    VALUES (p, 'validee', p, (SELECT id FROM fournisseurs WHERE matricule_fiscal = '9912355B'), 'dossier', 'pdf',
            encode(sha256(convert_to(p, 'UTF8')), 'hex'), p_ttc, 'TND', '2026-08-01', current_date + 3)
$f$;
SELECT pg_temp.facture('A-A', 300); SELECT pg_temp.facture('A-B', 200); SELECT pg_temp.facture('A-C', 100); SELECT pg_temp.facture('A-D', 300);
SELECT pg_temp.facture('A-X', 150); SELECT pg_temp.facture('A-Y', 150);
SELECT enregistrer_releve(jsonb_build_object(
    'banque', 'Banque Test', 'rib_compte', '99330228027133819365', 'date_debut', '2026-09-20', 'date_fin', current_date,
    'solde_initial', 1000, 'solde_final', 250, 'fichier_nom', 'releve-annul.csv', 'fichier_sha256', repeat('6', 64),
    'lignes', jsonb_build_array(
        jsonb_build_object('numero_ligne', 1, 'date_operation', current_date, 'libelle', 'VIR EMIS FOURNISSEUR ANNUL FACT A-A', 'debit', 300, 'solde', 700),
        jsonb_build_object('numero_ligne', 2, 'date_operation', '2026-09-20', 'libelle', 'VIR EMIS FOURNISSEUR ANNUL FACT A-B A-C', 'debit', 300, 'solde', 400),
        jsonb_build_object('numero_ligne', 3, 'date_operation', '2026-09-21', 'libelle', 'CHEQUE N 5550555', 'debit', 150, 'solde', 250))));
CREATE FUNCTION pg_temp.ligne(n INTEGER) RETURNS BIGINT LANGUAGE sql AS $f$
    SELECT l.id FROM lignes_releve l JOIN releves_bancaires r ON r.id = l.releve_id WHERE r.fichier_sha256 = repeat('6', 64) AND l.numero_ligne = n
$f$;
CREATE FUNCTION pg_temp.prop(n INTEGER) RETURNS BIGINT LANGUAGE sql AS $f$
    SELECT id FROM propositions_rapprochement WHERE ligne_releve_id = pg_temp.ligne(n) ORDER BY id DESC LIMIT 1
$f$;
-- L1 : confirmé automatiquement (opération du jour, sans ordre : signalement
-- « sortie sans ordre ») ; L2 : virement groupé A-B + A-C, confirmé par une personne.
SELECT enregistrer_rapprochements(jsonb_build_object('releve_id', (SELECT id FROM releves_bancaires WHERE fichier_sha256 = repeat('6', 64)),
    'propositions', jsonb_build_array(
        jsonb_build_object('ligne_releve_id', pg_temp.ligne(1), 'cas', 'exact', 'score', 1, 'ecart', 0, 'auto', true,
            'affectations', jsonb_build_array(jsonb_build_object('facture_id', pg_temp.f('A-A'), 'montant', 300))),
        jsonb_build_object('ligne_releve_id', pg_temp.ligne(2), 'cas', 'groupe', 'score', 0.9, 'ecart', 0, 'auto', false,
            'affectations', jsonb_build_array(jsonb_build_object('facture_id', pg_temp.f('A-B'), 'montant', 200),
                                              jsonb_build_object('facture_id', pg_temp.f('A-C'), 'montant', 100))))));
INSERT INTO decisions_rapprochement (proposition_id, decision, utilisateur_id, justification, canal)
VALUES (pg_temp.prop(2), 'confirmer', pg_temp.u('Annul – Validateur'), 'Virement groupé A-B et A-C', 'test');
CREATE TEMP TABLE avant AS SELECT count(*) AS n FROM rapprochements;
GRANT SELECT ON avant TO mizan_app;

SET ROLE mizan_app;
CREATE FUNCTION pg_temp.ev(p_ref TEXT, p_adresse TEXT, p_extra JSONB) RETURNS JSONB LANGUAGE sql AS $f$
    SELECT recevoir_evenement(jsonb_build_object('canal', 'telegram', 'reference', p_ref, 'adresse', p_adresse) || p_extra)
$f$;
CREATE FUNCTION pg_temp.annuler(p_ref TEXT, p_adresse TEXT, p_numero TEXT) RETURNS JSONB LANGUAGE sql AS $f$
    SELECT pg_temp.ev(p_ref, p_adresse, jsonb_build_object('type', 'commande', 'commande', 'annuler', 'argument', p_numero))
$f$;

-- Commande « /annuler » -------------------------------------------------------------------
SELECT pg_temp.doit_valoir($$SELECT pg_temp.annuler('a1', '943', 'A-B') ->> 'code'$$, 'commande_refusee', 'commande réservée aux responsables');
SELECT pg_temp.doit_valoir($$SELECT pg_temp.annuler('a2', '941', 'INCONNU-1') ->> 'code'$$, 'annulation_introuvable', 'aucun rapprochement confirmé pour ce numéro');
SELECT pg_temp.doit_valoir($$SELECT (pg_temp.annuler('a3', '941', 'a-b') ->> 'code') || '|' || (pg_temp.annuler('a3b', '941', 'A-B') ->> 'rapprochements')$$,
    'recherche_annulation_enregistree|1', 'recherche enregistrée (casse tolérée), un rapprochement confirmé');
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(DISTINCT u.nom, ',') FROM notifications_a_preparer('telegram') n JOIN utilisateurs u ON u.id = n.utilisateur_id
    WHERE n.objet = 'choix_annulation'
$$, 'Annul – Responsable 1', 'liste des rapprochements : au seul demandeur');
SELECT pg_temp.doit_valoir($$
    SELECT (SELECT string_agg(a ->> 'numero', ',' ORDER BY a ->> 'numero') FROM jsonb_array_elements(d -> 'choix_annulation' -> 'propositions' -> 0 -> 'affectations') a)
    FROM donnees_notifications('telegram') d WHERE d -> 'candidat' ->> 'objet' = 'choix_annulation' LIMIT 1
$$, 'A-B,A-C', 'virement groupé : toutes les factures du rapprochement sont listées');

-- Choix, puis demande ----------------------------------------------------------------------
CREATE TEMP TABLE jetons (nom TEXT PRIMARY KEY, jeton TEXT);
CREATE FUNCTION pg_temp.recherche() RETURNS BIGINT LANGUAGE sql AS $f$ SELECT max(id) FROM recherches_annulation $f$;
SELECT pg_temp.doit_echouer($$
    SELECT creer_notification(jsonb_build_object('canal', 'telegram', 'utilisateur_id', pg_temp.u('Annul – Responsable 1'),
        'objet', 'choix_annulation', 'recherche_annulation_id', pg_temp.recherche(), 'contenu', '{}'::jsonb,
        'actions', jsonb_build_array(jsonb_build_object('code', 'demander_annulation', 'params', jsonb_build_object('proposition_id', pg_temp.prop(1))))))
$$, 'MZ032', 'un bouton ne peut désigner qu''un rapprochement de la facture recherchée');
SELECT pg_temp.doit_reussir($$
    INSERT INTO jetons SELECT 'choix', n.jeton FROM creer_notification(jsonb_build_object('canal', 'telegram',
        'utilisateur_id', pg_temp.u('Annul – Responsable 1'), 'objet', 'choix_annulation', 'recherche_annulation_id', pg_temp.recherche(),
        'contenu', '{}'::jsonb,
        'actions', jsonb_build_array(jsonb_build_object('code', 'demander_annulation', 'params', jsonb_build_object('proposition_id', pg_temp.prop(2)))))) n
$$, 'notification de choix créée');
SELECT pg_temp.doit_valoir($$
    SELECT (pg_temp.ev('a4', '941', jsonb_build_object('type', 'action', 'jeton', (SELECT jeton FROM jetons WHERE nom = 'choix'), 'indice', '0')) ->> 'code')
        || '|' || (pg_temp.ev('a5', '941', '{"type": "texte", "texte": "Virement destiné à une autre facture, vu avec la banque"}') ->> 'code')
$$, 'justification_demandee|decision_enregistree', 'le responsable 1 demande l''annulation, justifiée');
SELECT pg_temp.doit_valoir($$SELECT (SELECT statut FROM propositions_rapprochement WHERE id = pg_temp.prop(2))$$, 'confirme',
    'une demande ne change rien tant qu''elle n''est pas approuvée');
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(u.nom, ',' ORDER BY u.nom) FROM notifications_a_preparer('telegram') n JOIN utilisateurs u ON u.id = n.utilisateur_id
    WHERE n.objet = 'demande_annulation'
$$, 'Annul – Responsable 2', 'demande : aux AUTRES responsables seulement (quatre yeux)');
SELECT pg_temp.doit_valoir($$
    SELECT (d -> 'demande_annulation' ->> 'demande_par_nom') || '|' || jsonb_array_length(d -> 'demande_annulation' -> 'proposition' -> 'affectations')
    FROM donnees_notifications('telegram') d WHERE d -> 'candidat' ->> 'objet' = 'demande_annulation'
$$, 'Annul – Responsable 1|2', 'l''approbateur voit le demandeur et les deux factures du virement groupé');
SELECT pg_temp.doit_echouer($$
    INSERT INTO demandes_annulation (proposition_id, demande_par, justification) VALUES (pg_temp.prop(2), pg_temp.u('Annul – Responsable 1'), 'Directement')
$$, '42501', 'une demande ne passe que par le canal (D-062)');
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_annulation (demande_id, decision, utilisateur_id, justification)
    SELECT max(id), 'approuvee', pg_temp.u('Annul – Responsable 2'), 'Directement' FROM demandes_annulation
$$, '42501', 'une décision ne passe que par le canal (D-062)');

-- Règles (administrateur) ------------------------------------------------------------------------
RESET ROLE;
SELECT pg_temp.doit_echouer($$
    INSERT INTO demandes_annulation (proposition_id, demande_par, justification) VALUES (pg_temp.prop(2), pg_temp.u('Annul – Responsable 2'), 'Seconde demande pour la même proposition')
$$, 'MZ042', 'une seule demande en attente par rapprochement');
SELECT pg_temp.doit_echouer($$
    INSERT INTO demandes_annulation (proposition_id, demande_par, justification) VALUES (pg_temp.prop(1), pg_temp.u('Annul – Validateur'), 'Demande d''un validateur')
$$, 'MZ014', 'un validateur ne demande pas d''annulation');
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_annulation (demande_id, decision, utilisateur_id, justification)
    SELECT max(id), 'approuvee', pg_temp.u('Annul – Responsable 1'), 'J''approuve ma propre demande' FROM demandes_annulation
$$, 'MZ018', 'le demandeur n''approuve pas sa propre demande');
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_annulation (demande_id, decision, utilisateur_id, justification)
    SELECT max(id), 'approuvee', pg_temp.u('Annul – Validateur'), 'Approbation d''un validateur' FROM demandes_annulation
$$, 'MZ014', 'un validateur n''approuve pas');

-- Approbation par le responsable 2, par le canal -------------------------------------------------------
SET ROLE mizan_app;
SELECT pg_temp.doit_reussir($$
    INSERT INTO jetons SELECT 'demande', n.jeton FROM creer_notification(jsonb_build_object('canal', 'telegram',
        'utilisateur_id', pg_temp.u('Annul – Responsable 2'), 'objet', 'demande_annulation', 'demande_annulation_id', (SELECT max(id) FROM demandes_annulation),
        'contenu', '{}'::jsonb, 'actions', '[{"code": "approuver_annulation"}, {"code": "refuser_annulation"}]'::jsonb)) n
$$, 'notification de la demande créée');
SELECT pg_temp.doit_valoir($$
    SELECT (pg_temp.ev('a6', '942', jsonb_build_object('type', 'action', 'jeton', (SELECT jeton FROM jetons WHERE nom = 'demande'), 'indice', '0')) ->> 'code')
        || '|' || (pg_temp.ev('a7', '942', '{"type": "texte", "texte": "Vérifié avec la banque : annulation fondée"}') ->> 'code')
$$, 'justification_demandee|decision_enregistree', 'le responsable 2 approuve, justifié');
SELECT pg_temp.doit_valoir($$
    SELECT p.statut || '|' || string_agg(r.statut, ',' ORDER BY r.id) FROM propositions_rapprochement p JOIN rapprochements r ON r.proposition_id = p.id
    WHERE p.id = pg_temp.prop(2) GROUP BY p.statut
$$, 'annule|annule,annule', 'contre-passation : proposition et affectations annulées');
SELECT pg_temp.doit_valoir($$SELECT (count(*) = (SELECT n FROM avant))::text FROM rapprochements$$, 'true', 'rien n''est effacé');
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(numero || ':' || etat, ',' ORDER BY numero) FROM situation_paiement WHERE numero IN ('A-B', 'A-C')
$$, 'A-B:non_payee,A-C:non_payee', 'les factures redeviennent à payer');
SELECT pg_temp.doit_valoir($$
    SELECT motif || '|' || array_to_string(factures_rejetees, ',') = 'rapprochement annulé|' || pg_temp.f('A-B') || ',' || pg_temp.f('A-C')
    FROM lignes_a_rapprocher WHERE ligne_releve_id = pg_temp.ligne(2)
$$, 'true', 'la ligne redevient « à rapprocher » ; les factures annulées sont exclues des candidates');
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(f.numero, ',' ORDER BY f.numero) || '|' || montant_a_ordonner(pg_temp.f('A-B'))
    FROM factures_bloquees_ordres b JOIN factures f ON f.id = b.facture_id WHERE f.numero LIKE 'A-%'
$$, 'A-B,A-C|0', 'protection : factures exclues des ordres tant que la ligne n''est pas retraitée');
SELECT pg_temp.doit_valoir($$
    SELECT pg_temp.ev('a8', '942', jsonb_build_object('type', 'action', 'jeton', (SELECT jeton FROM jetons WHERE nom = 'demande'), 'indice', '1')) ->> 'code'
$$, 'notification_perimee', 'un bouton d''une demande déjà décidée ne vaut plus');
SELECT pg_temp.doit_valoir($$
    SELECT pg_temp.ev('a9', '941', jsonb_build_object('type', 'action', 'jeton', (SELECT jeton FROM jetons WHERE nom = 'choix'), 'indice', '0')) ->> 'code'
$$, 'notification_perimee', 'le bouton de choix d''un rapprochement annulé ne vaut plus');
SELECT pg_temp.doit_reussir($$SELECT proposer_lot_paiement('{}')$$, 'proposition d''un lot');
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM ordres_paiement o JOIN factures f ON f.id = o.facture_id WHERE f.numero IN ('A-B', 'A-C')
$$, '0', 'aucun ordre pour une facture bloquée');
RESET ROLE;
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM journal_audit WHERE action IN ('rapprochement.annulation_demandee', 'rapprochement.annule')
      AND entite_id = pg_temp.prop(2)::text
$$, '2', 'demande et annulation tracées au journal');
SET ROLE mizan_lecture;
SELECT pg_temp.doit_valoir($$SELECT blocage FROM restitution.echeancier WHERE numero = 'A-B'$$,
    'exclue des ordres : rapprochement annulé, ligne à retraiter', 'échéancier : motif du blocage affiché');
SELECT pg_temp.doit_valoir($$
    SELECT detail FROM restitution.a_traiter WHERE type = 'ligne_a_rapprocher' AND objet = 'VIR EMIS FOURNISSEUR ANNUL FACT A-B A-C'
$$, 'rapprochement annulé ; facture(s) exclue(s) des ordres : A-B, A-C', 'à traiter : ligne et factures bloquées');

-- Nouveau rapprochement : le blocage tombe ---------------------------------------------------------------
RESET ROLE;
SELECT pg_temp.doit_reussir($$
    SELECT rapprocher_manuellement(pg_temp.ligne(2), pg_temp.f('A-D'), pg_temp.u('Annul – Responsable 2'), 'Le virement réglait en fait A-D', 'test')
$$, 'ligne rapprochée de nouveau (d''une autre facture)');
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM factures_bloquees_ordres b JOIN factures f ON f.id = b.facture_id WHERE f.numero LIKE 'A-%'
$$, '0', 'ligne retraitée : plus aucune facture bloquée');

-- Annulation d'une confirmation automatique, malgré un signalement « sortie sans ordre » -----------
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM signalements_paiement WHERE ligne_releve_id = pg_temp.ligne(1) AND type = 'sortie_sans_ordre' AND statut = 'ouvert'
$$, '1', 'L1 : signalement « sortie sans ordre » ouvert');
INSERT INTO demandes_annulation (proposition_id, demande_par, justification)
VALUES (pg_temp.prop(1), pg_temp.u('Annul – Responsable 1'), 'Confirmation automatique erronée');
INSERT INTO decisions_annulation (demande_id, decision, utilisateur_id, justification)
SELECT max(id), 'approuvee', pg_temp.u('Annul – Responsable 2'), 'Vérifié : annulation fondée' FROM demandes_annulation;
SELECT pg_temp.doit_valoir($$
    SELECT (SELECT statut FROM propositions_rapprochement WHERE id = pg_temp.prop(1)) || '|'
        || EXISTS (SELECT 1 FROM lignes_a_rapprocher WHERE ligne_releve_id = pg_temp.ligne(1))::text || '|'
        || (SELECT statut FROM signalements_paiement WHERE ligne_releve_id = pg_temp.ligne(1) AND type = 'sortie_sans_ordre')
$$, 'annule|true|ouvert', 'confirmation automatique annulable ; le signalement reste ouvert sans bloquer la ligne');
SELECT pg_temp.doit_echouer($$
    INSERT INTO demandes_annulation (proposition_id, demande_par, justification) VALUES (pg_temp.prop(1), pg_temp.u('Annul – Responsable 1'), 'Encore une fois')
$$, 'MZ042', 'un rapprochement déjà annulé ne l''est pas deux fois');

-- Défaut du 2026-10-10 : une ligne redevenue « à rapprocher » doit être renotifiée ;
-- une notification antérieure ne compte plus et ses boutons sont périmés.
SET ROLE mizan_app;
SELECT pg_temp.doit_reussir($$
    INSERT INTO jetons SELECT 'ancienne', n.jeton FROM creer_notification(jsonb_build_object('canal', 'telegram',
        'utilisateur_id', pg_temp.u('Annul – Responsable 1'), 'objet', 'ligne_a_rapprocher', 'ligne_releve_id', pg_temp.ligne(1),
        'contenu', '{}'::jsonb, 'actions', '[{"code": "signaler_sans_facture"}]'::jsonb)) n;
    SELECT marquer_notification((SELECT max(id) FROM notifications), '9001', NULL);
$$, 'notification de la ligne L1, envoyée');
RESET ROLE;
-- Elle date d'avant le moment où la ligne est redevenue à rapprocher (même transaction : on la recule).
UPDATE notifications SET cree_le = cree_le - interval '1 minute' WHERE id = (SELECT max(id) FROM notifications);
SET ROLE mizan_app;
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM notifications_a_preparer('telegram') WHERE objet = 'ligne_a_rapprocher' AND ligne_releve_id = pg_temp.ligne(1)
      AND utilisateur_id = pg_temp.u('Annul – Responsable 1')
$$, '1', 'une notification antérieure n''empêche pas de renotifier la ligne');
SELECT pg_temp.doit_valoir($$
    SELECT pg_temp.ev('a10', '941', jsonb_build_object('type', 'action', 'jeton', (SELECT jeton FROM jetons WHERE nom = 'ancienne'), 'indice', '0')) ->> 'code'
$$, 'notification_perimee', 'les boutons d''une notification antérieure sont périmés');
RESET ROLE;
UPDATE notifications SET cree_le = now() + interval '1 minute' WHERE id = (SELECT max(id) FROM notifications);
SET ROLE mizan_app;
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM notifications_a_preparer('telegram') WHERE objet = 'ligne_a_rapprocher' AND ligne_releve_id = pg_temp.ligne(1)
      AND utilisateur_id = pg_temp.u('Annul – Responsable 1')
$$, '0', 'une notification postérieure compte : pas de doublon');

-- Défaut du 2026-10-10 (chèque 9886778) rejoué : proposition rejetée (A-X),
-- autre facture confirmée (A-Y), annulation approuvée, puis rapprochement
-- manuel avec la facture rejetée au départ. L'historique reste entier.
RESET ROLE;
SELECT enregistrer_rapprochements(jsonb_build_object('releve_id', (SELECT id FROM releves_bancaires WHERE fichier_sha256 = repeat('6', 64)),
    'propositions', jsonb_build_array(jsonb_build_object('ligne_releve_id', pg_temp.ligne(3), 'cas', 'exact', 'score', 0.6, 'ecart', 0, 'auto', false,
        'affectations', jsonb_build_array(jsonb_build_object('facture_id', pg_temp.f('A-X'), 'montant', 150))))));
INSERT INTO decisions_rapprochement (proposition_id, decision, utilisateur_id, justification, canal)
VALUES (pg_temp.prop(3), 'rejeter', pg_temp.u('Annul – Validateur'), 'Rejet par erreur, pour le test', 'test');
SELECT rapprocher_manuellement(pg_temp.ligne(3), pg_temp.f('A-Y'), pg_temp.u('Annul – Validateur'), 'Chèque 5550555 pour A-Y', 'test');
INSERT INTO demandes_annulation (proposition_id, demande_par, justification) VALUES (pg_temp.prop(3), pg_temp.u('Annul – Responsable 1'), 'A-Y était une erreur');
INSERT INTO decisions_annulation (demande_id, decision, utilisateur_id, justification)
SELECT max(id), 'approuvee', pg_temp.u('Annul – Responsable 2'), 'Vérifié avec le relevé' FROM demandes_annulation;
SET ROLE mizan_app;
SELECT pg_temp.doit_reussir($$
    INSERT INTO jetons SELECT 'L3', n.jeton FROM creer_notification(jsonb_build_object('canal', 'telegram',
        'utilisateur_id', pg_temp.u('Annul – Responsable 1'), 'objet', 'ligne_a_rapprocher', 'ligne_releve_id', pg_temp.ligne(3),
        'contenu', '{}'::jsonb, 'actions', '[{"code": "rapprocher_autre"}]'::jsonb)) n
$$, 'notification de la ligne redevenue à rapprocher');
SELECT pg_temp.doit_valoir($$
    SELECT (pg_temp.ev('a11', '941', jsonb_build_object('type', 'action', 'jeton', (SELECT jeton FROM jetons WHERE nom = 'L3'), 'indice', '0')) ->> 'code')
        || '|' || (pg_temp.ev('a12', '941', '{"type": "texte", "texte": "A-X chèque 5550555 destiné à cette facture, vu avec le relevé"}') ->> 'code')
$$, 'justification_demandee|decision_enregistree', 'rapprochement manuel avec la facture rejetée au départ : accepté');
RESET ROLE;
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(f.numero || ':' || p.statut || '/' || r.statut, ',' ORDER BY p.id)
    FROM propositions_rapprochement p JOIN rapprochements r ON r.proposition_id = p.id JOIN factures f ON f.id = r.facture_id
    WHERE p.ligne_releve_id = pg_temp.ligne(3)
$$, 'A-X:rejete/rejete,A-Y:annule/annule,A-X:confirme/confirme', 'historique entier : rejet, annulation, puis nouveau lien actif');
SELECT pg_temp.doit_valoir($$SELECT etat FROM situation_paiement WHERE numero = 'A-X'$$, 'payee', 'A-X payée');
SELECT pg_temp.doit_echouer($$
    INSERT INTO rapprochements (facture_id, ligne_releve_id, montant_affecte, methode, statut, cree_par)
    VALUES (pg_temp.f('A-X'), pg_temp.ligne(3), 1, 'manuel', 'confirme', 'test')
$$, '23505', 'deux liens ACTIFS entre la même facture et la même ligne restent interdits');

-- Erreur interne : jamais renvoyée telle quelle ; détail au journal, référence à l'usager.
SET ROLE mizan_app;
SELECT pg_temp.doit_reussir($$
    INSERT INTO jetons SELECT 'interne', n.jeton FROM creer_notification(jsonb_build_object('canal', 'telegram',
        'utilisateur_id', pg_temp.u('Annul – Responsable 1'), 'objet', 'ligne_a_rapprocher', 'ligne_releve_id', pg_temp.ligne(1),
        'contenu', '{}'::jsonb, 'actions', '[{"code": "rapprocher_facture", "params": {"facture_id": "pas-un-nombre"}}]'::jsonb)) n
$$, 'notification dont l''action provoquera une erreur interne');
CREATE TEMP TABLE reponse_interne AS
SELECT pg_temp.ev('a14', '941', '{"type": "texte", "texte": "Justification suffisamment longue"}') AS r
FROM (SELECT pg_temp.ev('a13', '941', jsonb_build_object('type', 'action', 'jeton', (SELECT jeton FROM jetons WHERE nom = 'interne'), 'indice', '0'))) x;
SELECT pg_temp.doit_valoir($$
    SELECT (r ->> 'code') || '|' || (r ->> 'erreur') || '|' || (r ? 'motif')::text || '|' || (r ->> 'reference' IS NOT NULL)::text FROM reponse_interne
$$, 'decision_refusee|interne|false|true', 'erreur interne : aucun message technique, une référence');
RESET ROLE;
SELECT pg_temp.doit_valoir($$
    SELECT j.donnees_apres ->> 'sqlstate' FROM journal_audit j, reponse_interne x
    WHERE j.id = (x.r ->> 'reference')::bigint AND j.action = 'canal.erreur_interne'
$$, '22P02', 'détail technique gardé au journal d''audit');
SELECT pg_temp.doit_valoir($$
    SELECT (resultat ? 'motif')::text FROM evenements_entrants WHERE reference = 'a14'
$$, 'false', 'le détail technique n''est pas non plus dans le résultat de l''événement');

RESET ROLE;
ROLLBACK;
