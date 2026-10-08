-- Tests de la couche « canal » (D-062) : bail d'interrogation, inscription par
-- code, notifications, protection des boutons, justification, idempotence,
-- quatre yeux à travers un canal. Préparation par l'administrateur ; actions
-- sous le rôle applicatif, comme n8n. Transaction annulée à la fin.
\set ON_ERROR_STOP on
\set VERBOSITY terse
BEGIN;
SET ROLE mizan_app;
\ir 00_outils.sql
-- Jetons des notifications, gardés pour simuler les boutons.
CREATE TEMP TABLE jetons (nom TEXT PRIMARY KEY, notification_id BIGINT, jeton TEXT);
RESET ROLE;
\o /dev/null

-- Données de départ (administrateur) -----------------------------------------------
-- Isolement : les adresses réelles déjà inscrites ne reçoivent rien pendant le test
-- (désactivées dans la transaction, annulée à la fin).
UPDATE adresses_canal SET active = FALSE;
-- État du canal remis à zéro (le workflow réel peut détenir le bail en ce moment).
UPDATE etats_canal SET curseur = 0, bail_jeton = NULL, bail_jusqu_a = NULL WHERE canal = 'telegram';
UPDATE factures SET statut = 'erreur_extraction', reservee_le = NULL WHERE statut IN ('recue', 'en_extraction', 'extraite', 'en_controle');
INSERT INTO utilisateurs (nom, role, fictif) VALUES
    ('Canal – Responsable A', 'responsable', TRUE), ('Canal – Responsable B', 'responsable', TRUE),
    ('Canal – Validateur', 'validateur', TRUE);
INSERT INTO utilisateurs (nom, role, actif, fictif) VALUES ('Canal – Inactif', 'responsable', FALSE, TRUE);
WITH f AS (INSERT INTO fournisseurs (raison_sociale, matricule_fiscal) VALUES ('Fournisseur Canal', '9912377K') RETURNING id)
INSERT INTO fournisseur_ribs (fournisseur_id, rib, valide_du) SELECT id, '99001000000000000165', '2026-01-01' FROM f;

CREATE FUNCTION pg_temp.u(p_nom TEXT) RETURNS BIGINT LANGUAGE sql AS $f$ SELECT id FROM utilisateurs WHERE nom = p_nom $f$;
CREATE FUNCTION pg_temp.f(p_nom TEXT) RETURNS BIGINT LANGUAGE sql AS $f$ SELECT id FROM factures WHERE fichier_nom = p_nom $f$;
CREATE FUNCTION pg_temp.facture(p_nom TEXT, p_statut TEXT, p_ecarts JSONB) RETURNS VOID LANGUAGE sql AS $f$
    INSERT INTO factures (fichier_nom, statut, numero, fournisseur_id, rib_facture, canal_reception, format_source, fichier_sha256, montant_ttc)
    VALUES (p_nom, p_statut, p_nom, (SELECT id FROM fournisseurs WHERE matricule_fiscal = '9912377K'), '99003000000000000269',
            'dossier', 'pdf', encode(sha256(convert_to(p_nom, 'UTF8')), 'hex'), 100);
    INSERT INTO resultats_controles (facture_id, passage, regle, version_regle, resultat, gravite)
    SELECT (SELECT id FROM factures WHERE fichier_nom = p_nom), currval('passages_controle_seq'), c.regle, '1',
           coalesce(p_ecarts -> c.regle ->> 0, 'ok'), coalesce(p_ecarts -> c.regle ->> 1, 'info')
    FROM (SELECT nextval('passages_controle_seq')) n, regles_controle c;
$f$;
SELECT pg_temp.facture('N-seuil', 'a_valider', '{"seuil_validation": ["anomalie", "validation"]}');
SELECT pg_temp.facture('N-rib', 'bloquee', '{"changement_rib": ["anomalie", "bloquant"]}');
SELECT pg_temp.facture('N-tva', 'bloquee', '{"coherence_tva": ["anomalie", "bloquant"]}');
SELECT creer_code_inscription(pg_temp.u('Canal – Responsable A'), 'telegram', 'code-secret-A');
SELECT creer_code_inscription(pg_temp.u('Canal – Responsable B'), 'telegram', 'code-secret-B');
SELECT creer_code_inscription(pg_temp.u('Canal – Validateur'), 'telegram', 'code-secret-V');
SELECT creer_code_inscription(pg_temp.u('Canal – Responsable A'), 'telegram', 'code-expire');
UPDATE codes_inscription SET expire_le = now() - interval '1 minute'
WHERE code_empreinte = encode(sha256(convert_to('code-expire', 'UTF8')), 'hex');

-- Événement entrant simulé ; renvoie le code du résultat.
CREATE FUNCTION pg_temp.ev(p_ref TEXT, p_adresse TEXT, p_type TEXT, p_extra JSONB DEFAULT '{}') RETURNS TEXT LANGUAGE sql AS $f$
    SELECT recevoir_evenement(jsonb_build_object('canal', 'telegram', 'reference', p_ref, 'adresse', p_adresse, 'type', p_type) || p_extra) ->> 'code'
$f$;
-- Bouton : jeton de la notification nommée et indice de l'action.
CREATE FUNCTION pg_temp.bouton(p_ref TEXT, p_adresse TEXT, p_notif TEXT, p_indice TEXT) RETURNS TEXT LANGUAGE sql AS $f$
    SELECT pg_temp.ev(p_ref, p_adresse, 'action', jsonb_build_object('jeton', (SELECT jeton FROM jetons WHERE nom = p_notif), 'indice', p_indice))
$f$;
CREATE FUNCTION pg_temp.texte(p_ref TEXT, p_adresse TEXT, p_texte TEXT) RETURNS TEXT LANGUAGE sql AS $f$
    SELECT pg_temp.ev(p_ref, p_adresse, 'texte', jsonb_build_object('texte', p_texte))
$f$;
-- Notification créée par le rôle applicatif, jeton gardé.
CREATE FUNCTION pg_temp.notifier(p_nom TEXT, p_utilisateur TEXT, p_facture TEXT, p_actions JSONB) RETURNS VOID LANGUAGE sql AS $f$
    INSERT INTO jetons SELECT p_nom, n.notification_id, n.jeton FROM creer_notification(jsonb_build_object(
        'canal', 'telegram', 'utilisateur_id', pg_temp.u(p_utilisateur), 'objet', 'facture', 'facture_id', pg_temp.f(p_facture),
        'statut_facture', (SELECT statut FROM factures WHERE fichier_nom = p_facture),
        'passage_controle', (SELECT max(passage) FROM resultats_controles WHERE facture_id = pg_temp.f(p_facture)),
        'actions', p_actions, 'contenu', jsonb_build_object('titre', p_facture))) n;
    SELECT marquer_notification((SELECT notification_id FROM jetons WHERE nom = p_nom), 'msg-' || p_nom);
$f$;

SET ROLE mizan_app;

-- Bail d'interrogation ------------------------------------------------------------------
SELECT pg_temp.doit_valoir($$SELECT count(*)::text FROM prendre_bail_canal('telegram')$$, '1', 'le bail libre est pris');
SELECT pg_temp.doit_valoir($$SELECT count(*)::text FROM prendre_bail_canal('telegram')$$, '0',
    'deux interrogations ne se chevauchent pas : le bail détenu n''est pas repris');
SELECT pg_temp.doit_valoir($$SELECT rendre_bail_canal('telegram', gen_random_uuid(), 99)::text$$, 'false',
    'un bail qui n''est plus détenu ne peut pas être rendu');
SELECT pg_temp.doit_valoir($$SELECT rendre_bail_canal('telegram', (SELECT bail_jeton FROM etats_canal WHERE canal = 'telegram'), 42)::text$$,
    'true', 'le détenteur rend le bail et avance le curseur');
SELECT pg_temp.doit_valoir($$
    SELECT curseur || '|' || (SELECT rendre_bail_canal('telegram', b.bail_jeton, 10)) || '|'
           || (SELECT curseur FROM etats_canal WHERE canal = 'telegram')
    FROM prendre_bail_canal('telegram') b
$$, '42|true|42', 'le curseur ne recule jamais');
SELECT pg_temp.doit_echouer($$UPDATE etats_canal SET curseur = 0$$, '42501', 'l''état du canal ne se modifie que par les fonctions');

-- Inscription par code (B1) ----------------------------------------------------------
SELECT pg_temp.doit_echouer($$SELECT creer_code_inscription(1, 'telegram', 'x')$$, '42501',
    'seul l''administrateur crée un code d''inscription');
SELECT pg_temp.doit_valoir($$SELECT pg_temp.ev('1', '111', 'inscription', '{"code": "code-secret-A"}')$$, 'inscription_reussie',
    'inscription avec un code valide');
SELECT pg_temp.doit_valoir($$SELECT pg_temp.ev('1', '111', 'inscription', '{"code": "code-secret-A"}')$$, 'deja_traite',
    'un même événement n''est traité qu''une fois');
SELECT pg_temp.doit_valoir($$SELECT pg_temp.ev('2', '999', 'inscription', '{"code": "code-secret-A"}')$$, 'inscription_refusee',
    'un code ne sert qu''une fois');
SELECT pg_temp.doit_valoir($$SELECT pg_temp.ev('3', '999', 'inscription', '{"code": "code-expire"}')$$, 'inscription_refusee',
    'un code expiré est refusé');
SELECT pg_temp.doit_valoir($$SELECT pg_temp.ev('4', '999', 'inscription', '{"code": "devine"}')$$, 'inscription_refusee',
    'un code inconnu est refusé');
SELECT pg_temp.doit_reussir($$
    SELECT pg_temp.ev('5', '222', 'inscription', '{"code": "code-secret-V"}');
    SELECT pg_temp.ev('6', '333', 'inscription', '{"code": "code-secret-B"}');
$$, 'inscription du validateur et du second responsable');
SELECT pg_temp.doit_valoir($$
    SELECT count(*)::text FROM journal_audit WHERE action = 'utilisateur.adresse_inscrite'
      AND entite_id IN (SELECT id::text FROM utilisateurs WHERE nom LIKE 'Canal – %')
$$, '3', 'chaque inscription est tracée au journal');
SELECT pg_temp.doit_valoir($$SELECT pg_temp.ev('7', '999', 'texte', '{"texte": "valider tout"}')$$, 'expediteur_inconnu',
    'un inconnu n''obtient rien');
SELECT pg_temp.doit_valoir($$SELECT count(*)::text FROM evenements_entrants WHERE adresse = '999'$$, '4',
    'les événements d''inconnus sont tracés');
SELECT pg_temp.doit_echouer($$INSERT INTO adresses_canal (utilisateur_id, canal, adresse) VALUES (1, 'telegram', '666')$$, '42501',
    'une adresse ne s''inscrit pas sans code');

-- Notifications à préparer --------------------------------------------------------------
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(f.fichier_nom || ':' || u.nom, ', ' ORDER BY f.fichier_nom, u.nom)
    FROM notifications_a_preparer('telegram') n JOIN factures f ON f.id = n.facture_id JOIN utilisateurs u ON u.id = n.utilisateur_id
    WHERE f.fichier_nom LIKE 'N-%'
$$, 'N-rib:Canal – Responsable A, N-rib:Canal – Responsable B, N-seuil:Canal – Responsable A, N-seuil:Canal – Responsable B, N-seuil:Canal – Validateur, N-tva:Canal – Responsable A, N-tva:Canal – Responsable B',
    'facture bloquée : responsables seulement ; à valider : tous les inscrits');
SELECT pg_temp.doit_valoir($$
    SELECT concat_ws('|', d -> 'candidat' ->> 'adresse', d -> 'candidat' ->> 'role', d -> 'facture' ->> 'statut',
                     d -> 'fournisseur' ->> 'rib_actif', jsonb_array_length(d -> 'resultats'), jsonb_array_length(d -> 'regles'),
                     d -> 'facture' ? 'extraction_brute', d -> 'demande')
    FROM donnees_notifications('telegram') d
    WHERE d -> 'facture' ->> 'fichier_nom' = 'N-seuil' AND d -> 'candidat' ->> 'role' = 'validateur'
$$, '222|validateur|a_valider|99001000000000000165|22|22|f|null',
    'données d''une notification : adresse du destinataire, facture, RIB du référentiel, dernier passage, catalogue');
SELECT pg_temp.doit_echouer($$
    SELECT creer_notification(jsonb_build_object('canal', 'telegram', 'utilisateur_id', pg_temp.u('Canal – Inactif'), 'objet', 'facture',
        'facture_id', pg_temp.f('N-seuil'), 'statut_facture', 'a_valider', 'actions', '[]'::jsonb, 'contenu', '{}'::jsonb))
$$, 'MZ030', 'pas de notification à un utilisateur non inscrit');
SELECT pg_temp.doit_echouer($$
    SELECT creer_notification(jsonb_build_object('canal', 'telegram', 'utilisateur_id', pg_temp.u('Canal – Validateur'), 'objet', 'facture',
        'facture_id', pg_temp.f('N-seuil'), 'statut_facture', 'anomalie', 'actions', '[]'::jsonb, 'contenu', '{}'::jsonb))
$$, 'MZ031', 'pas de notification pour un état qui n''est plus celui de la facture');
SELECT pg_temp.doit_echouer($$
    SELECT creer_notification(jsonb_build_object('canal', 'telegram', 'utilisateur_id', pg_temp.u('Canal – Validateur'), 'objet', 'facture',
        'facture_id', pg_temp.f('N-seuil'), 'statut_facture', 'a_valider', 'actions', '[{"code": "payer"}]'::jsonb, 'contenu', '{}'::jsonb))
$$, 'MZ032', 'une action hors du vocabulaire est refusée');
SELECT pg_temp.doit_reussir($$
    SELECT pg_temp.notifier('seuil-V', 'Canal – Validateur', 'N-seuil', '[{"code": "valider"}, {"code": "rejeter"}]');
    SELECT pg_temp.notifier('seuil-A', 'Canal – Responsable A', 'N-seuil', '[{"code": "valider"}, {"code": "rejeter"}]');
    SELECT pg_temp.notifier('rib-A', 'Canal – Responsable A', 'N-rib',
        '[{"code": "valider"}, {"code": "demander_changement_rib", "params": {"rib": "99003000000000000269"}}]');
    SELECT pg_temp.notifier('tva-A', 'Canal – Responsable A', 'N-tva', '[{"code": "valider"}]');
$$, 'notifications créées et marquées envoyées');
SELECT pg_temp.doit_valoir($$
    SELECT (SELECT count(*) FROM notifications_a_preparer('telegram') n
            WHERE n.facture_id = pg_temp.f('N-seuil') AND n.utilisateur_id = pg_temp.u('Canal – Validateur'))::text
           || '|' || length((SELECT jeton FROM jetons WHERE nom = 'seuil-V'))
           || '|' || (SELECT (jeton_empreinte <> (SELECT jeton FROM jetons WHERE nom = 'seuil-V'))::text FROM notifications
                      WHERE id = (SELECT notification_id FROM jetons WHERE nom = 'seuil-V'))
$$, '0|32|true', 'une notification envoyée n''est pas renvoyée ; jeton de 32 caractères, seule son empreinte est gardée');
SELECT pg_temp.doit_echouer($$UPDATE notifications SET utilisateur_id = 1$$, '42501', 'une notification ne se modifie pas');

-- Protection des boutons -------------------------------------------------------------------
SELECT pg_temp.doit_valoir($$SELECT pg_temp.bouton('10', '111', 'seuil-V', '0')$$, 'pas_destinataire',
    'le bouton d''une autre personne ne suffit pas : il faut être le destinataire');
SELECT pg_temp.doit_valoir($$SELECT count(*)::text FROM journal_audit WHERE action = 'canal.bouton_d_un_autre'
    AND entite_id = (SELECT notification_id::text FROM jetons WHERE nom = 'seuil-V')$$, '1',
    'la tentative est tracée');
SELECT pg_temp.doit_valoir($$SELECT pg_temp.ev('11', '222', 'action', '{"jeton": "forge", "indice": "0"}')$$, 'bouton_inconnu',
    'un jeton inventé est refusé');
SELECT pg_temp.doit_valoir($$SELECT pg_temp.bouton('12', '222', 'seuil-V', '-1')$$, 'action_inconnue',
    'un indice négatif n''est pas accepté');
SELECT pg_temp.doit_valoir($$SELECT pg_temp.bouton('13', '222', 'seuil-V', '5')$$, 'action_inconnue',
    'un indice hors de la liste n''est pas accepté');
SELECT pg_temp.doit_valoir($$SELECT pg_temp.texte('14', '222', 'Je valide la facture N-seuil')$$, 'aucune_action_en_attente',
    'un texte sans bouton préalable ne décide rien');

-- Justification ------------------------------------------------------------------------
SELECT pg_temp.doit_valoir($$SELECT pg_temp.bouton('15', '222', 'seuil-V', '0')$$, 'justification_demandee',
    'le destinataire touche « valider » : la justification est demandée');
SELECT pg_temp.doit_valoir($$SELECT pg_temp.texte('16', '222', 'ok')$$, 'decision_refusee',
    'justification trop courte : refusée par la base, rien n''est appliqué');
SELECT pg_temp.doit_valoir($$SELECT statut FROM factures WHERE id = pg_temp.f('N-seuil')$$, 'a_valider', 'la facture n''a pas changé');
SELECT pg_temp.doit_valoir($$SELECT pg_temp.bouton('17', '222', 'seuil-V', '0')$$, 'justification_demandee', 'nouvel essai');
SELECT pg_temp.doit_valoir($$SELECT pg_temp.texte('18', '222', 'Montant conforme au bon de commande n° 42')$$, 'decision_enregistree',
    'la justification du destinataire, dans le délai, applique la décision');
SELECT pg_temp.doit_valoir($$
    SELECT f.statut || '|' || d.canal || '|' || (d.utilisateur_id = pg_temp.u('Canal – Validateur'))::text
    FROM factures f JOIN decisions_humaines d ON d.facture_id = f.id WHERE f.id = pg_temp.f('N-seuil')
$$, 'validee|telegram|true', 'décision du destinataire, canal tracé');
SELECT pg_temp.doit_valoir($$SELECT pg_temp.texte('18', '222', 'Montant conforme au bon de commande n° 42')$$, 'deja_traite',
    'le même message relu ne décide pas deux fois');
SELECT pg_temp.doit_valoir($$SELECT pg_temp.bouton('19', '111', 'seuil-A', '1')$$, 'notification_perimee',
    'un bouton dont la facture a changé d''état ne vaut plus');

SELECT pg_temp.doit_valoir($$SELECT pg_temp.bouton('20', '111', 'tva-A', '0')$$, 'justification_demandee', 'bouton « valider » sur N-tva');
RESET ROLE;
UPDATE actions_en_attente SET expire_le = now() - interval '1 minute' WHERE conclue_le IS NULL;
SET ROLE mizan_app;
SELECT pg_temp.doit_valoir($$SELECT pg_temp.texte('21', '111', 'Écart de TVA confirmé par le fournisseur')$$, 'justification_trop_tard',
    'une justification après le délai n''est pas appliquée');

-- Règle non dérogeable et quatre yeux, à travers le canal -----------------------------------
SELECT pg_temp.doit_valoir($$SELECT pg_temp.bouton('22', '111', 'rib-A', '0')$$, 'justification_demandee', 'bouton « valider » sur N-rib');
SELECT pg_temp.doit_valoir($$
    SELECT r ->> 'code' || '|' || (r ->> 'erreur') FROM recevoir_evenement(jsonb_build_object('canal', 'telegram', 'reference', '23',
        'adresse', '111', 'type', 'texte', 'texte', 'Le fournisseur a confirmé par téléphone')) r
$$, 'decision_refusee|MZ015', 'même avec le bouton, un changement de RIB ne se valide pas (règle non dérogeable)');
SELECT pg_temp.doit_reussir($$
    SELECT pg_temp.bouton('24', '111', 'rib-A', '1');
    SELECT pg_temp.texte('25', '111', 'Nouveau RIB indiqué sur la facture N-rib');
$$, 'demande de changement de RIB par le responsable A, par le canal');
SELECT pg_temp.doit_valoir($$
    SELECT string_agg(u.nom, ', ') FROM notifications_a_preparer('telegram') n JOIN utilisateurs u ON u.id = n.utilisateur_id
    WHERE n.objet = 'demande'
$$, 'Canal – Responsable B', 'quatre yeux : la demande n''est notifiée qu''aux autres responsables');
SELECT pg_temp.doit_valoir($$
    SELECT concat_ws('|', d -> 'candidat' ->> 'adresse', d -> 'demande' ->> 'type_demande', d -> 'demande' ->> 'demande_par_nom',
                     d -> 'demande' -> 'donnees' ->> 'rib', d -> 'fournisseur' ->> 'rib_actif', jsonb_array_length(d -> 'methodes'))
    FROM donnees_notifications('telegram') d WHERE d -> 'candidat' ->> 'objet' = 'demande'
$$, '333|changement_rib|Canal – Responsable A|99003000000000000269|99001000000000000165|6',
    'données d''une demande : demandeur, RIB demandé, RIB actuel du fournisseur, méthodes de vérification');
SELECT pg_temp.doit_reussir($$
    INSERT INTO jetons SELECT 'demande-B', n.notification_id, n.jeton FROM creer_notification(jsonb_build_object(
        'canal', 'telegram', 'utilisateur_id', pg_temp.u('Canal – Responsable B'), 'objet', 'demande',
        'demande_id', (SELECT max(id) FROM demandes_referentiel), 'facture_id', pg_temp.f('N-rib'),
        'actions', '[{"code": "approuver", "params": {"methode_verification": "rib_rappel_contact_connu"}}, {"code": "refuser"}]'::jsonb,
        'contenu', '{}'::jsonb)) n;
    SELECT pg_temp.bouton('26', '333', 'demande-B', '0');
    SELECT pg_temp.texte('27', '333', 'Fournisseur rappelé au numéro du référentiel');
$$, 'approbation par le responsable B, par le canal, avec méthode de vérification');
SELECT pg_temp.doit_valoir($$
    SELECT (SELECT rib FROM fournisseur_ribs r JOIN fournisseurs fo ON fo.id = r.fournisseur_id
            WHERE fo.matricule_fiscal = '9912377K' AND r.valide_au IS NULL)
           || '|' || (SELECT statut FROM factures WHERE id = pg_temp.f('N-rib'))
           || '|' || (SELECT canal FROM decisions_referentiel ORDER BY id DESC LIMIT 1)
$$, '99003000000000000269|extraite|telegram', 'RIB changé, facture renvoyée aux contrôles, canal tracé');
SELECT pg_temp.doit_echouer($$
    INSERT INTO decisions_referentiel (demande_id, decision, utilisateur_id, justification)
    VALUES ((SELECT max(id) FROM demandes_referentiel), 'refusee', 1, 'Décision sans canal ni notification')
$$, '42501', 'aucune décision sur le référentiel sans passer par un canal');

RESET ROLE;
ROLLBACK;
