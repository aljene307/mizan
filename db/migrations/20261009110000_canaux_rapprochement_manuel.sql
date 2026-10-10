-- migrate:up

-- Le canal porte le rapprochement manuel d'une ligne rejetée (D-068, D1) :
-- nouvel objet de notification (validateurs et responsables), trois actions
-- (rapprocher d'une facture proposée, d'une facture désignée par son numéro,
-- signaler « aucune facture ») et leur péremption. Fonctions de
-- 20261008170000, complétées par remplacements vérifiés ; le reste inchangé.

ALTER TABLE notifications
    ADD COLUMN ligne_releve_id BIGINT REFERENCES lignes_releve (id),
    DROP CONSTRAINT notifications_objet_ck,
    ADD CONSTRAINT notifications_objet_ck CHECK (
        (objet = 'facture' AND facture_id IS NOT NULL AND demande_id IS NULL)
        OR (objet = 'demande' AND demande_id IS NOT NULL)
        OR (objet = 'rapprochement' AND proposition_id IS NOT NULL)
        OR (objet = 'signalement' AND signalement_id IS NOT NULL)
        OR (objet = 'synthese' AND releve_id IS NOT NULL)
        OR (objet = 'lot_paiement' AND lot_id IS NOT NULL)
        OR (objet = 'ligne_a_rapprocher' AND ligne_releve_id IS NOT NULL));
CREATE INDEX notifications_ligne_ix ON notifications (ligne_releve_id, utilisateur_id, canal);

-- Nouvelle signature : la fonction et celle qui en dépend sont recréées.
DROP FUNCTION donnees_notifications(TEXT);
DROP FUNCTION notifications_a_preparer(TEXT);

CREATE FUNCTION notifications_a_preparer(p_canal TEXT) RETURNS TABLE (
    objet TEXT, facture_id BIGINT, demande_id BIGINT, proposition_id BIGINT, signalement_id BIGINT, releve_id BIGINT,
    utilisateur_id BIGINT, role TEXT, statut_facture TEXT, passage_controle BIGINT, lot_id BIGINT, ligne_releve_id BIGINT)
LANGUAGE sql STABLE AS $$
    WITH destinataires AS (
        SELECT u.id, u.role FROM utilisateurs u
        JOIN adresses_canal a ON a.utilisateur_id = u.id AND a.canal = p_canal AND a.active
        WHERE u.actif),
    factures_en_attente AS (
        SELECT f.id, f.statut, (SELECT max(r.passage) FROM resultats_controles r WHERE r.facture_id = f.id) AS passage
        FROM factures f WHERE f.statut IN ('a_valider', 'anomalie', 'bloquee'))
    SELECT 'facture', fa.id, NULL::BIGINT, NULL::BIGINT, NULL::BIGINT, NULL::BIGINT, d.id, d.role, fa.statut, fa.passage, NULL::BIGINT, NULL::BIGINT
    FROM factures_en_attente fa JOIN destinataires d
      ON fa.statut <> 'bloquee' OR d.role = 'responsable'
    WHERE NOT EXISTS (
        SELECT 1 FROM notifications n
        WHERE n.facture_id = fa.id AND n.utilisateur_id = d.id AND n.canal = p_canal
          AND n.statut_facture = fa.statut AND n.passage_controle IS NOT DISTINCT FROM fa.passage
          AND n.expire_le > now()
          AND (n.etat = 'envoyee' OR (n.etat = 'a_envoyer' AND n.cree_le > now() - interval '10 minutes')))
    UNION ALL
    SELECT 'demande', dr.facture_id, dr.id, NULL, NULL, NULL, d.id, d.role, NULL, NULL, NULL, NULL
    FROM demandes_referentiel dr JOIN destinataires d
      ON d.role = 'responsable' AND d.id <> dr.demande_par   -- quatre yeux
    WHERE NOT EXISTS (SELECT 1 FROM decisions_referentiel x WHERE x.demande_id = dr.id)
      AND NOT EXISTS (
        SELECT 1 FROM notifications n
        WHERE n.demande_id = dr.id AND n.utilisateur_id = d.id AND n.canal = p_canal AND n.expire_le > now()
          AND (n.etat = 'envoyee' OR (n.etat = 'a_envoyer' AND n.cree_le > now() - interval '10 minutes')))
    UNION ALL
    -- Propositions de rapprochement à confirmer : validateurs et responsables (D-065).
    SELECT 'rapprochement', NULL, NULL, p.id, NULL, l.releve_id, d.id, d.role, NULL, NULL, NULL, NULL
    FROM propositions_rapprochement p JOIN lignes_releve l ON l.id = p.ligne_releve_id JOIN destinataires d ON TRUE
    WHERE p.statut = 'propose'
      AND NOT EXISTS (SELECT 1 FROM notifications n WHERE n.proposition_id = p.id AND n.utilisateur_id = d.id
                        AND n.canal = p_canal AND n.expire_le > now() AND (n.etat = 'envoyee' OR (n.etat = 'a_envoyer' AND n.cree_le > now() - interval '10 minutes')))
    UNION ALL
    -- Signalements ouverts : responsables seulement (D-065).
    SELECT 'signalement', s.facture_id, NULL, NULL, s.id, l.releve_id, d.id, d.role, NULL, NULL, NULL, NULL
    FROM signalements_paiement s JOIN lignes_releve l ON l.id = s.ligne_releve_id JOIN destinataires d ON d.role = 'responsable'
    WHERE s.statut = 'ouvert'
      AND NOT EXISTS (SELECT 1 FROM notifications n WHERE n.signalement_id = s.id AND n.utilisateur_id = d.id
                        AND n.canal = p_canal AND n.expire_le > now() AND (n.etat = 'envoyee' OR (n.etat = 'a_envoyer' AND n.cree_le > now() - interval '10 minutes')))
    UNION ALL
    -- Synthèse : une par passage de rapprochement d'un relevé et par destinataire.
    SELECT 'synthese', NULL, NULL, NULL, NULL, r.id, d.id, d.role, NULL, NULL, NULL, NULL
    FROM releves_bancaires r JOIN destinataires d ON TRUE
    WHERE r.rapproche_le IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM notifications n WHERE n.objet = 'synthese' AND n.releve_id = r.id AND n.utilisateur_id = d.id
                        AND n.canal = p_canal AND n.cree_le >= r.rapproche_le AND (n.etat = 'envoyee' OR (n.etat = 'a_envoyer' AND n.cree_le > now() - interval '10 minutes')))
    UNION ALL
    -- Lot d'ordres de paiement en attente : responsables seulement (D-068, C-a1).
    SELECT 'lot_paiement', NULL, NULL, NULL, NULL, NULL, d.id, d.role, NULL, NULL, lp.id, NULL
    FROM lots_paiement lp JOIN destinataires d ON d.role = 'responsable'
    WHERE lp.statut = 'propose'
      AND NOT EXISTS (SELECT 1 FROM notifications n WHERE n.lot_id = lp.id AND n.utilisateur_id = d.id
                        AND n.canal = p_canal AND n.expire_le > now() AND (n.etat = 'envoyee' OR (n.etat = 'a_envoyer' AND n.cree_le > now() - interval '10 minutes')))
    UNION ALL
    -- Ligne dont la proposition a été rejetée : validateurs et responsables (D-068, D1).
    SELECT 'ligne_a_rapprocher', NULL, NULL, NULL, NULL, a.releve_id, d.id, d.role, NULL, NULL, NULL, a.ligne_releve_id
    FROM lignes_a_rapprocher a JOIN destinataires d ON TRUE
    WHERE NOT EXISTS (SELECT 1 FROM notifications n WHERE n.objet = 'ligne_a_rapprocher' AND n.ligne_releve_id = a.ligne_releve_id
                        AND n.utilisateur_id = d.id AND n.canal = p_canal AND n.expire_le > now() AND (n.etat = 'envoyee' OR (n.etat = 'a_envoyer' AND n.cree_le > now() - interval '10 minutes')));
$$;

CREATE OR REPLACE FUNCTION creer_notification(p JSONB) RETURNS TABLE (notification_id BIGINT, jeton TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    -- 32 caractères hexadécimaux (UUID v4, 122 bits aléatoires) : un bouton
    -- Telegram porte au plus 64 octets (jeton, séparateur et indice).
    v_jeton   TEXT := replace(gen_random_uuid()::text, '-', '');
    v_id      BIGINT;
    v_canal   TEXT := p ->> 'canal';
    v_facture factures%ROWTYPE;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM adresses_canal a JOIN utilisateurs u ON u.id = a.utilisateur_id
                   WHERE a.utilisateur_id = (p ->> 'utilisateur_id')::BIGINT AND a.canal = v_canal AND a.active AND u.actif) THEN
        RAISE EXCEPTION 'destinataire non inscrit sur le canal %', v_canal USING ERRCODE = 'MZ030';
    END IF;
    IF p ->> 'objet' = 'facture' THEN
        SELECT * INTO v_facture FROM factures WHERE id = (p ->> 'facture_id')::BIGINT;
        IF v_facture.statut IS DISTINCT FROM p ->> 'statut_facture' THEN
            RAISE EXCEPTION 'la facture n''est plus au statut notifié' USING ERRCODE = 'MZ031';
        END IF;
    END IF;
    IF p ->> 'objet' = 'rapprochement'
       AND (SELECT statut FROM propositions_rapprochement WHERE id = (p ->> 'proposition_id')::BIGINT) IS DISTINCT FROM 'propose' THEN
        RAISE EXCEPTION 'la proposition n''est plus ouverte' USING ERRCODE = 'MZ031';
    END IF;
    IF p ->> 'objet' = 'signalement'
       AND (SELECT statut FROM signalements_paiement WHERE id = (p ->> 'signalement_id')::BIGINT) IS DISTINCT FROM 'ouvert' THEN
        RAISE EXCEPTION 'le signalement n''est plus ouvert' USING ERRCODE = 'MZ031';
    END IF;
    IF p ->> 'objet' = 'lot_paiement'
       AND (SELECT statut FROM lots_paiement WHERE id = (p ->> 'lot_id')::BIGINT) IS DISTINCT FROM 'propose' THEN
        RAISE EXCEPTION 'le lot n''est plus en attente' USING ERRCODE = 'MZ031';
    END IF;
    IF p ->> 'objet' = 'ligne_a_rapprocher'
       AND NOT EXISTS (SELECT 1 FROM lignes_a_rapprocher WHERE ligne_releve_id = (p ->> 'ligne_releve_id')::BIGINT) THEN
        RAISE EXCEPTION 'la ligne n''est plus à rapprocher' USING ERRCODE = 'MZ031';
    END IF;
    IF jsonb_typeof(p -> 'actions') <> 'array' OR EXISTS (
        SELECT 1 FROM jsonb_array_elements(p -> 'actions') a
        WHERE a ->> 'code' NOT IN ('valider', 'rejeter', 'renvoyer_aux_controles', 'confirmer_fournisseur',
                                   'demander_changement_rib', 'demander_creation_fournisseur', 'approuver', 'refuser',
                                   'confirmer_rapprochement', 'rejeter_rapprochement', 'classer_signalement',
                                   'approuver_lot', 'refuser_lot',
                                   'rapprocher_facture', 'rapprocher_autre', 'signaler_sans_facture')) THEN
        RAISE EXCEPTION 'action inconnue dans la notification' USING ERRCODE = 'MZ032';
    END IF;
    INSERT INTO notifications (canal, utilisateur_id, objet, facture_id, demande_id, proposition_id, signalement_id, releve_id, lot_id, ligne_releve_id,
                               statut_facture, passage_controle, actions, contenu, jeton_empreinte, expire_le)
    VALUES (v_canal, (p ->> 'utilisateur_id')::BIGINT, p ->> 'objet', (p ->> 'facture_id')::BIGINT,
            (p ->> 'demande_id')::BIGINT, (p ->> 'proposition_id')::BIGINT, (p ->> 'signalement_id')::BIGINT,
            (p ->> 'releve_id')::BIGINT, (p ->> 'lot_id')::BIGINT, (p ->> 'ligne_releve_id')::BIGINT, p ->> 'statut_facture', (p ->> 'passage_controle')::BIGINT,
            p -> 'actions', p -> 'contenu', encode(sha256(convert_to(v_jeton, 'UTF8')), 'hex'),
            now() + make_interval(days => parametre_controle('notification.validite_jours')::INTEGER))
    RETURNING id INTO v_id;
    RETURN QUERY SELECT v_id, v_jeton;
END;
$$;

CREATE OR REPLACE FUNCTION recevoir_evenement(p JSONB) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_canal    TEXT := p ->> 'canal';
    v_adresse  TEXT := p ->> 'adresse';
    v_type     TEXT := coalesce(p ->> 'type', 'autre');
    v_util     utilisateurs%ROWTYPE;
    v_code     codes_inscription%ROWTYPE;
    v_notif    notifications%ROWTYPE;
    v_attente  actions_en_attente%ROWTYPE;
    v_action   JSONB;
    v_facture  factures%ROWTYPE;
    v_passage  BIGINT;
    v_res      JSONB;
    v_id       BIGINT;
BEGIN
    IF EXISTS (SELECT 1 FROM evenements_entrants WHERE canal = v_canal AND reference = p ->> 'reference') THEN
        RETURN jsonb_build_object('code', 'deja_traite');
    END IF;

    SELECT u.* INTO v_util FROM utilisateurs u JOIN adresses_canal a ON a.utilisateur_id = u.id
    WHERE a.canal = v_canal AND a.adresse = v_adresse AND a.active AND u.actif;

    IF v_type = 'inscription' THEN
        SELECT * INTO v_code FROM codes_inscription
        WHERE canal = v_canal AND code_empreinte = encode(sha256(convert_to(coalesce(p ->> 'code', ''), 'UTF8')), 'hex')
        FOR UPDATE;
        IF NOT FOUND OR v_code.utilise_le IS NOT NULL OR v_code.expire_le < now() THEN
            v_res := jsonb_build_object('code', 'inscription_refusee');
        ELSIF EXISTS (SELECT 1 FROM adresses_canal WHERE canal = v_canal AND adresse = v_adresse) THEN
            v_res := jsonb_build_object('code', 'adresse_deja_inscrite');
        ELSE
            UPDATE codes_inscription SET utilise_le = now() WHERE id = v_code.id;
            UPDATE adresses_canal SET active = FALSE WHERE utilisateur_id = v_code.utilisateur_id AND canal = v_canal;
            INSERT INTO adresses_canal (utilisateur_id, canal, adresse) VALUES (v_code.utilisateur_id, v_canal, v_adresse);
            INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_apres)
            VALUES ('utilisateur:' || v_code.utilisateur_id, 'utilisateur.adresse_inscrite', 'utilisateurs',
                    v_code.utilisateur_id::text, v_canal, jsonb_build_object('adresse', v_adresse, 'code_id', v_code.id));
            v_res := jsonb_build_object('code', 'inscription_reussie',
                                        'nom', (SELECT nom FROM utilisateurs WHERE id = v_code.utilisateur_id));
        END IF;

    ELSIF v_util.id IS NULL THEN
        -- Expéditeur inconnu : rien n'est fait, l'événement est tracé.
        v_res := jsonb_build_object('code', 'expediteur_inconnu');

    ELSIF v_type = 'action' THEN
        SELECT * INTO v_notif FROM notifications
        WHERE canal = v_canal AND jeton_empreinte = encode(sha256(convert_to(coalesce(p ->> 'jeton', ''), 'UTF8')), 'hex');
        -- Indice strictement entier et positif (en JSONB, -1 désignerait le dernier élément).
        v_action := CASE WHEN coalesce(p ->> 'indice', '') ~ '^\d{1,3}$'
                         THEN v_notif.actions -> ((p ->> 'indice')::INTEGER) END;
        IF v_notif.id IS NULL THEN
            v_res := jsonb_build_object('code', 'bouton_inconnu');
        ELSIF v_notif.utilisateur_id <> v_util.id THEN
            -- Le bouton ne suffit pas : il faut être le destinataire.
            v_res := jsonb_build_object('code', 'pas_destinataire');
            INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_apres)
            VALUES ('utilisateur:' || v_util.id, 'canal.bouton_d_un_autre', 'notifications', v_notif.id::text, v_canal,
                    jsonb_build_object('destinataire', v_notif.utilisateur_id));
        ELSIF v_notif.expire_le < now() THEN
            v_res := jsonb_build_object('code', 'notification_expiree');
        ELSIF v_action IS NULL THEN
            v_res := jsonb_build_object('code', 'action_inconnue');
        ELSE
            IF v_notif.objet = 'facture' THEN
                SELECT * INTO v_facture FROM factures WHERE id = v_notif.facture_id;
                v_passage := (SELECT max(passage) FROM resultats_controles WHERE facture_id = v_notif.facture_id);
            END IF;
            IF v_notif.objet = 'facture' AND (v_facture.statut IS DISTINCT FROM v_notif.statut_facture
                                               OR v_passage IS DISTINCT FROM v_notif.passage_controle) THEN
                v_res := jsonb_build_object('code', 'notification_perimee', 'statut', v_facture.statut);
            ELSIF v_notif.objet = 'demande' AND EXISTS (SELECT 1 FROM decisions_referentiel WHERE demande_id = v_notif.demande_id) THEN
                v_res := jsonb_build_object('code', 'notification_perimee');
            ELSIF v_notif.objet = 'rapprochement'
                  AND (SELECT statut FROM propositions_rapprochement WHERE id = v_notif.proposition_id) <> 'propose' THEN
                v_res := jsonb_build_object('code', 'notification_perimee');
            ELSIF v_notif.objet = 'signalement'
                  AND (SELECT statut FROM signalements_paiement WHERE id = v_notif.signalement_id) <> 'ouvert' THEN
                v_res := jsonb_build_object('code', 'notification_perimee');
            ELSIF v_notif.objet = 'lot_paiement'
                  AND (SELECT statut FROM lots_paiement WHERE id = v_notif.lot_id) <> 'propose' THEN
                v_res := jsonb_build_object('code', 'notification_perimee');
            ELSIF v_notif.objet = 'ligne_a_rapprocher'
                  AND NOT EXISTS (SELECT 1 FROM lignes_a_rapprocher WHERE ligne_releve_id = v_notif.ligne_releve_id) THEN
                v_res := jsonb_build_object('code', 'notification_perimee');
            ELSE
                UPDATE actions_en_attente SET conclue_le = now(), resultat = 'remplacee'
                WHERE utilisateur_id = v_util.id AND canal = v_canal AND conclue_le IS NULL;
                INSERT INTO actions_en_attente (notification_id, utilisateur_id, canal, adresse, indice_action, expire_le)
                VALUES (v_notif.id, v_util.id, v_canal, v_adresse, (p ->> 'indice')::INTEGER,
                        now() + make_interval(mins => parametre_controle('justification.delai_minutes')::INTEGER));
                v_res := jsonb_build_object('code', 'justification_demandee', 'action', v_action,
                                            'contenu', v_notif.contenu,
                                            'delai_minutes', parametre_controle('justification.delai_minutes'));
            END IF;
        END IF;

    ELSIF v_type = 'texte' THEN
        SELECT * INTO v_attente FROM actions_en_attente
        WHERE utilisateur_id = v_util.id AND canal = v_canal AND conclue_le IS NULL FOR UPDATE;
        IF v_attente.id IS NULL THEN
            v_res := jsonb_build_object('code', 'aucune_action_en_attente');
        ELSIF v_attente.expire_le < now() OR v_attente.adresse <> v_adresse THEN
            UPDATE actions_en_attente SET conclue_le = now(), resultat = 'expiree' WHERE id = v_attente.id;
            v_res := jsonb_build_object('code', 'justification_trop_tard');
        ELSE
            SELECT * INTO v_notif FROM notifications WHERE id = v_attente.notification_id;
            v_action := v_notif.actions -> v_attente.indice_action;
            BEGIN
                v_id := appliquer_action(v_notif, v_action, v_util.id, p ->> 'texte', v_canal);
                v_res := jsonb_build_object('code', 'decision_enregistree', 'action', v_action, 'id', v_id,
                                            'statut', (SELECT statut FROM factures WHERE id = v_notif.facture_id));
            EXCEPTION WHEN OTHERS THEN
                -- Refus de la base (rôle, justification, règle non dérogeable,
                -- quatre yeux…) : rien n'est appliqué, le motif est renvoyé.
                v_res := jsonb_build_object('code', 'decision_refusee', 'action', v_action,
                                            'erreur', SQLSTATE, 'motif', SQLERRM);
            END;
            UPDATE actions_en_attente SET conclue_le = now(), resultat = v_res ->> 'code' WHERE id = v_attente.id;
        END IF;

    ELSE
        v_res := jsonb_build_object('code', 'non_compris');
    END IF;

    INSERT INTO evenements_entrants (canal, reference, adresse, type, resultat)
    VALUES (v_canal, p ->> 'reference', v_adresse, v_type, v_res);
    RETURN v_res;
END;
$$;

CREATE OR REPLACE FUNCTION appliquer_action(p_notif notifications, p_action JSONB, p_utilisateur BIGINT, p_texte TEXT, p_canal TEXT)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_code    TEXT := p_action ->> 'code';
    v_params  JSONB := coalesce(p_action -> 'params', '{}'::jsonb);
    v_facture factures%ROWTYPE;
    v_id      BIGINT;
BEGIN
    SELECT * INTO v_facture FROM factures WHERE id = p_notif.facture_id;
    IF v_code IN ('valider', 'rejeter', 'renvoyer_aux_controles', 'confirmer_fournisseur') THEN
        INSERT INTO decisions_humaines (facture_id, utilisateur_id, decision, justification, corrections, canal)
        VALUES (p_notif.facture_id, p_utilisateur,
                CASE v_code WHEN 'valider' THEN 'valider' WHEN 'rejeter' THEN 'rejeter' ELSE 'renvoyer_aux_controles' END,
                p_texte,
                CASE WHEN v_code = 'confirmer_fournisseur'
                     THEN jsonb_build_object('fournisseur_id', (v_params ->> 'fournisseur_id')::BIGINT) ELSE '{}'::jsonb END,
                p_canal)
        RETURNING id INTO v_id;
    ELSIF v_code = 'demander_changement_rib' THEN
        INSERT INTO demandes_referentiel (type_demande, fournisseur_id, facture_id, donnees, demande_par, justification, canal)
        VALUES ('changement_rib', v_facture.fournisseur_id, v_facture.id, jsonb_build_object('rib', v_params ->> 'rib'),
                p_utilisateur, p_texte, p_canal)
        RETURNING id INTO v_id;
    ELSIF v_code = 'demander_creation_fournisseur' THEN
        INSERT INTO demandes_referentiel (type_demande, facture_id, donnees, demande_par, justification, canal)
        VALUES ('creation_fournisseur', v_facture.id, v_params, p_utilisateur, p_texte, p_canal)
        RETURNING id INTO v_id;
    ELSIF v_code IN ('approuver', 'refuser') THEN
        INSERT INTO decisions_referentiel (demande_id, decision, utilisateur_id, methode_verification, justification, canal)
        VALUES (p_notif.demande_id, CASE v_code WHEN 'approuver' THEN 'approuvee' ELSE 'refusee' END, p_utilisateur,
                v_params ->> 'methode_verification', p_texte, p_canal)
        RETURNING id INTO v_id;
    ELSIF v_code IN ('confirmer_rapprochement', 'rejeter_rapprochement') THEN
        INSERT INTO decisions_rapprochement (proposition_id, decision, motif_ecart, utilisateur_id, justification, canal)
        VALUES (p_notif.proposition_id, CASE v_code WHEN 'confirmer_rapprochement' THEN 'confirmer' ELSE 'rejeter' END,
                v_params ->> 'motif_ecart', p_utilisateur, p_texte, p_canal)
        RETURNING id INTO v_id;
    ELSIF v_code = 'classer_signalement' THEN
        INSERT INTO decisions_signalement (signalement_id, utilisateur_id, justification, canal)
        VALUES (p_notif.signalement_id, p_utilisateur, p_texte, p_canal)
        RETURNING id INTO v_id;
    ELSIF v_code IN ('approuver_lot', 'refuser_lot') THEN
        INSERT INTO decisions_lot_paiement (lot_id, decision, utilisateur_id, justification, canal)
        VALUES (p_notif.lot_id, CASE v_code WHEN 'approuver_lot' THEN 'approuver' ELSE 'refuser' END,
                p_utilisateur, p_texte, p_canal)
        RETURNING id INTO v_id;
    ELSIF v_code = 'rapprocher_facture' THEN
        v_id := rapprocher_manuellement(p_notif.ligne_releve_id, (v_params ->> 'facture_id')::BIGINT, p_utilisateur, p_texte, p_canal);
    ELSIF v_code = 'rapprocher_autre' THEN
        -- La réponse commence par le numéro de la facture, puis la justification.
        v_id := rapprocher_manuellement(p_notif.ligne_releve_id,
                    facture_par_numero(rtrim(split_part(btrim(coalesce(p_texte, '')), ' ', 1), ':;,.')),
                    p_utilisateur, p_texte, p_canal);
    ELSIF v_code = 'signaler_sans_facture' THEN
        v_id := signaler_ligne_sans_facture(p_notif.ligne_releve_id, p_utilisateur, p_texte, p_canal);
    ELSE
        RAISE EXCEPTION 'action « % » inconnue', v_code USING ERRCODE = 'MZ032';
    END IF;
    RETURN v_id;
END;
$$;

CREATE FUNCTION donnees_notifications(p_canal TEXT) RETURNS SETOF JSONB
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'candidat', jsonb_build_object(
            'canal', p_canal, 'objet', c.objet, 'utilisateur_id', c.utilisateur_id, 'role', c.role,
            'passage_controle', c.passage_controle, 'proposition_id', c.proposition_id,
            'signalement_id', c.signalement_id, 'releve_id', c.releve_id, 'lot_id', c.lot_id, 'ligne_releve_id', c.ligne_releve_id,
            'adresse', (SELECT a.adresse FROM adresses_canal a
                        WHERE a.utilisateur_id = c.utilisateur_id AND a.canal = p_canal AND a.active)),
        'facture', to_jsonb(f) - 'extraction_brute',
        -- Facture : son fournisseur ; demande de changement de RIB : celui de la demande.
        'fournisseur', (SELECT jsonb_build_object(
                            'raison_sociale', fo.raison_sociale, 'matricule_fiscal', fo.matricule_fiscal,
                            'rib_actif', (SELECT r.rib FROM fournisseur_ribs r WHERE r.fournisseur_id = fo.id AND r.valide_au IS NULL))
                        FROM fournisseurs fo
                        WHERE fo.id = CASE c.objet WHEN 'demande' THEN d.fournisseur_id ELSE f.fournisseur_id END),
        'resultats', coalesce((SELECT jsonb_agg(jsonb_build_object('regle', r.regle, 'resultat', r.resultat, 'gravite', r.gravite,
                                                                   'message', r.message, 'detail', r.detail) ORDER BY r.regle)
                               FROM resultats_controles r WHERE r.facture_id = c.facture_id AND r.passage = c.passage_controle), '[]'::jsonb),
        'regles', (SELECT jsonb_agg(jsonb_build_object('regle', g.regle, 'derogeable', g.derogeable) ORDER BY g.regle) FROM regles_controle g),
        'demande', CASE WHEN d.id IS NOT NULL THEN to_jsonb(d) || jsonb_build_object('demande_par_nom', u.nom) END,
        'proposition', (SELECT jsonb_build_object(
                'id', x.id, 'cas', x.cas, 'score', x.score, 'raisons', x.raisons, 'ecart', x.ecart,
                'ligne', (SELECT to_jsonb(l) FROM lignes_releve l WHERE l.id = x.ligne_releve_id),
                'affectations', (SELECT jsonb_agg(jsonb_build_object(
                    'facture_id', ff.id, 'numero', ff.numero, 'type_document', ff.type_document, 'statut', ff.statut,
                    'montant_ttc', ff.montant_ttc, 'devise', ff.devise, 'montant', r.montant_affecte, 'role', r.role,
                    'raison_sociale', coalesce(fo2.raison_sociale, ff.raison_sociale_lue)) ORDER BY r.role DESC, ff.id)
                    FROM rapprochements r JOIN factures ff ON ff.id = r.facture_id LEFT JOIN fournisseurs fo2 ON fo2.id = ff.fournisseur_id
                    WHERE r.proposition_id = x.id))
            FROM propositions_rapprochement x WHERE x.id = c.proposition_id),
        'signalement', (SELECT jsonb_build_object(
                'id', s.id, 'type', s.type, 'message', s.message, 'detail', s.detail,
                'ligne', (SELECT to_jsonb(l) FROM lignes_releve l WHERE l.id = s.ligne_releve_id))
            FROM signalements_paiement s WHERE s.id = c.signalement_id),
        'synthese', CASE WHEN c.objet = 'synthese' THEN (SELECT jsonb_build_object(
                'releve', jsonb_build_object('fichier_nom', rb.fichier_nom, 'date_debut', rb.date_debut, 'date_fin', rb.date_fin,
                                             'lignes', (SELECT count(*) FROM lignes_releve l WHERE l.releve_id = rb.id)),
                'bilan', (SELECT j.donnees_apres FROM journal_audit j WHERE j.action = 'releve.rapproche' AND j.entite_id = rb.id::text
                          ORDER BY j.id DESC LIMIT 1),
                'en_attente', jsonb_build_object(
                    'propositions', (SELECT count(*) FROM propositions_rapprochement x JOIN lignes_releve l ON l.id = x.ligne_releve_id
                                     WHERE l.releve_id = rb.id AND x.statut = 'propose'),
                    'signalements', (SELECT count(*) FROM signalements_paiement s JOIN lignes_releve l ON l.id = s.ligne_releve_id
                                     WHERE l.releve_id = rb.id AND s.statut = 'ouvert')),
                'factures_en_retard', (SELECT count(*) FROM situation_paiement sp WHERE sp.en_retard))
            FROM releves_bancaires rb WHERE rb.id = c.releve_id) END,
        'lot', (SELECT jsonb_build_object(
                'id', lp.id, 'echeances_jusqu_au', lp.echeances_jusqu_au, 'propose_le', lp.propose_le,
                'ordres', (SELECT jsonb_agg(jsonb_build_object(
                    'facture_id', o.facture_id, 'numero', fx.numero, 'date_echeance', fx.date_echeance,
                    'beneficiaire', o.beneficiaire, 'rib', o.rib, 'montant', o.montant, 'reference', o.reference)
                    ORDER BY fx.date_echeance NULLS FIRST, o.id)
                    FROM ordres_paiement o JOIN factures fx ON fx.id = o.facture_id WHERE o.lot_id = lp.id))
            FROM lots_paiement lp WHERE lp.id = c.lot_id),
        'ligne_a_rapprocher', (SELECT jsonb_build_object(
                'ligne', jsonb_build_object('id', a.ligne_releve_id, 'date_operation', a.date_operation, 'libelle', a.libelle, 'debit', a.debit),
                'candidats', (SELECT coalesce(jsonb_agg(x ORDER BY x.distance, x.date_echeance NULLS LAST, x.facture_id), '[]'::jsonb) FROM (
                    SELECT s.facture_id, s.numero, s.date_echeance, coalesce(fo3.raison_sociale, '') AS raison_sociale,
                           s.reste_a_payer - s.paiement_propose AS a_payer,
                           abs(s.reste_a_payer - s.paiement_propose - a.debit) AS distance
                    FROM situation_paiement s LEFT JOIN fournisseurs fo3 ON fo3.id = s.fournisseur_id
                    WHERE s.devise = 'TND' AND s.reste_a_payer - s.paiement_propose > 0
                      AND NOT (s.facture_id = ANY (coalesce(a.factures_rejetees, '{}')))
                    ORDER BY abs(s.reste_a_payer - s.paiement_propose - a.debit), s.facture_id LIMIT 30) x))
            FROM lignes_a_rapprocher a WHERE a.ligne_releve_id = c.ligne_releve_id),
        'methodes', (SELECT jsonb_agg(jsonb_build_object('code', m.code, 'type_demande', m.type_demande, 'libelle', m.libelle) ORDER BY m.code)
                     FROM methodes_verification m))
    FROM notifications_a_preparer(p_canal) c
    LEFT JOIN factures f ON f.id = c.facture_id
    LEFT JOIN demandes_referentiel d ON d.id = c.demande_id
    LEFT JOIN utilisateurs u ON u.id = d.demande_par
    ORDER BY c.objet DESC, c.facture_id, c.utilisateur_id;
$$;

GRANT EXECUTE ON FUNCTION notifications_a_preparer(TEXT) TO mizan_app;
REVOKE EXECUTE ON FUNCTION donnees_notifications(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION donnees_notifications(TEXT) TO mizan_app;

-- migrate:down

-- Rétablit les versions de la migration 20261008170000.
DROP FUNCTION donnees_notifications(TEXT);
DROP FUNCTION notifications_a_preparer(TEXT);
DELETE FROM notifications WHERE objet = 'ligne_a_rapprocher';
DROP INDEX notifications_ligne_ix;
ALTER TABLE notifications
    DROP CONSTRAINT notifications_objet_ck,
    ADD CONSTRAINT notifications_objet_ck CHECK (
        (objet = 'facture' AND facture_id IS NOT NULL AND demande_id IS NULL)
        OR (objet = 'demande' AND demande_id IS NOT NULL)
        OR (objet = 'rapprochement' AND proposition_id IS NOT NULL)
        OR (objet = 'signalement' AND signalement_id IS NOT NULL)
        OR (objet = 'synthese' AND releve_id IS NOT NULL)
        OR (objet = 'lot_paiement' AND lot_id IS NOT NULL)),
    DROP COLUMN ligne_releve_id;

CREATE FUNCTION notifications_a_preparer(p_canal TEXT) RETURNS TABLE (
    objet TEXT, facture_id BIGINT, demande_id BIGINT, proposition_id BIGINT, signalement_id BIGINT, releve_id BIGINT,
    utilisateur_id BIGINT, role TEXT, statut_facture TEXT, passage_controle BIGINT, lot_id BIGINT)
LANGUAGE sql STABLE AS $$
    WITH destinataires AS (
        SELECT u.id, u.role FROM utilisateurs u
        JOIN adresses_canal a ON a.utilisateur_id = u.id AND a.canal = p_canal AND a.active
        WHERE u.actif),
    factures_en_attente AS (
        SELECT f.id, f.statut, (SELECT max(r.passage) FROM resultats_controles r WHERE r.facture_id = f.id) AS passage
        FROM factures f WHERE f.statut IN ('a_valider', 'anomalie', 'bloquee'))
    SELECT 'facture', fa.id, NULL::BIGINT, NULL::BIGINT, NULL::BIGINT, NULL::BIGINT, d.id, d.role, fa.statut, fa.passage, NULL::BIGINT
    FROM factures_en_attente fa JOIN destinataires d
      ON fa.statut <> 'bloquee' OR d.role = 'responsable'
    WHERE NOT EXISTS (
        SELECT 1 FROM notifications n
        WHERE n.facture_id = fa.id AND n.utilisateur_id = d.id AND n.canal = p_canal
          AND n.statut_facture = fa.statut AND n.passage_controle IS NOT DISTINCT FROM fa.passage
          AND n.expire_le > now()
          AND (n.etat = 'envoyee' OR (n.etat = 'a_envoyer' AND n.cree_le > now() - interval '10 minutes')))
    UNION ALL
    SELECT 'demande', dr.facture_id, dr.id, NULL, NULL, NULL, d.id, d.role, NULL, NULL, NULL
    FROM demandes_referentiel dr JOIN destinataires d
      ON d.role = 'responsable' AND d.id <> dr.demande_par   -- quatre yeux
    WHERE NOT EXISTS (SELECT 1 FROM decisions_referentiel x WHERE x.demande_id = dr.id)
      AND NOT EXISTS (
        SELECT 1 FROM notifications n
        WHERE n.demande_id = dr.id AND n.utilisateur_id = d.id AND n.canal = p_canal AND n.expire_le > now()
          AND (n.etat = 'envoyee' OR (n.etat = 'a_envoyer' AND n.cree_le > now() - interval '10 minutes')))
    UNION ALL
    -- Propositions de rapprochement à confirmer : validateurs et responsables (D-065).
    SELECT 'rapprochement', NULL, NULL, p.id, NULL, l.releve_id, d.id, d.role, NULL, NULL, NULL
    FROM propositions_rapprochement p JOIN lignes_releve l ON l.id = p.ligne_releve_id JOIN destinataires d ON TRUE
    WHERE p.statut = 'propose'
      AND NOT EXISTS (SELECT 1 FROM notifications n WHERE n.proposition_id = p.id AND n.utilisateur_id = d.id
                        AND n.canal = p_canal AND n.expire_le > now() AND (n.etat = 'envoyee' OR (n.etat = 'a_envoyer' AND n.cree_le > now() - interval '10 minutes')))
    UNION ALL
    -- Signalements ouverts : responsables seulement (D-065).
    SELECT 'signalement', s.facture_id, NULL, NULL, s.id, l.releve_id, d.id, d.role, NULL, NULL, NULL
    FROM signalements_paiement s JOIN lignes_releve l ON l.id = s.ligne_releve_id JOIN destinataires d ON d.role = 'responsable'
    WHERE s.statut = 'ouvert'
      AND NOT EXISTS (SELECT 1 FROM notifications n WHERE n.signalement_id = s.id AND n.utilisateur_id = d.id
                        AND n.canal = p_canal AND n.expire_le > now() AND (n.etat = 'envoyee' OR (n.etat = 'a_envoyer' AND n.cree_le > now() - interval '10 minutes')))
    UNION ALL
    -- Synthèse : une par passage de rapprochement d'un relevé et par destinataire.
    SELECT 'synthese', NULL, NULL, NULL, NULL, r.id, d.id, d.role, NULL, NULL, NULL
    FROM releves_bancaires r JOIN destinataires d ON TRUE
    WHERE r.rapproche_le IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM notifications n WHERE n.objet = 'synthese' AND n.releve_id = r.id AND n.utilisateur_id = d.id
                        AND n.canal = p_canal AND n.cree_le >= r.rapproche_le AND (n.etat = 'envoyee' OR (n.etat = 'a_envoyer' AND n.cree_le > now() - interval '10 minutes')))
    UNION ALL
    -- Lot d'ordres de paiement en attente : responsables seulement (D-068, C-a1).
    SELECT 'lot_paiement', NULL, NULL, NULL, NULL, NULL, d.id, d.role, NULL, NULL, lp.id
    FROM lots_paiement lp JOIN destinataires d ON d.role = 'responsable'
    WHERE lp.statut = 'propose'
      AND NOT EXISTS (SELECT 1 FROM notifications n WHERE n.lot_id = lp.id AND n.utilisateur_id = d.id
                        AND n.canal = p_canal AND n.expire_le > now() AND (n.etat = 'envoyee' OR (n.etat = 'a_envoyer' AND n.cree_le > now() - interval '10 minutes')));
$$;

CREATE OR REPLACE FUNCTION creer_notification(p JSONB) RETURNS TABLE (notification_id BIGINT, jeton TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    -- 32 caractères hexadécimaux (UUID v4, 122 bits aléatoires) : un bouton
    -- Telegram porte au plus 64 octets (jeton, séparateur et indice).
    v_jeton   TEXT := replace(gen_random_uuid()::text, '-', '');
    v_id      BIGINT;
    v_canal   TEXT := p ->> 'canal';
    v_facture factures%ROWTYPE;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM adresses_canal a JOIN utilisateurs u ON u.id = a.utilisateur_id
                   WHERE a.utilisateur_id = (p ->> 'utilisateur_id')::BIGINT AND a.canal = v_canal AND a.active AND u.actif) THEN
        RAISE EXCEPTION 'destinataire non inscrit sur le canal %', v_canal USING ERRCODE = 'MZ030';
    END IF;
    IF p ->> 'objet' = 'facture' THEN
        SELECT * INTO v_facture FROM factures WHERE id = (p ->> 'facture_id')::BIGINT;
        IF v_facture.statut IS DISTINCT FROM p ->> 'statut_facture' THEN
            RAISE EXCEPTION 'la facture n''est plus au statut notifié' USING ERRCODE = 'MZ031';
        END IF;
    END IF;
    IF p ->> 'objet' = 'rapprochement'
       AND (SELECT statut FROM propositions_rapprochement WHERE id = (p ->> 'proposition_id')::BIGINT) IS DISTINCT FROM 'propose' THEN
        RAISE EXCEPTION 'la proposition n''est plus ouverte' USING ERRCODE = 'MZ031';
    END IF;
    IF p ->> 'objet' = 'signalement'
       AND (SELECT statut FROM signalements_paiement WHERE id = (p ->> 'signalement_id')::BIGINT) IS DISTINCT FROM 'ouvert' THEN
        RAISE EXCEPTION 'le signalement n''est plus ouvert' USING ERRCODE = 'MZ031';
    END IF;
    IF p ->> 'objet' = 'lot_paiement'
       AND (SELECT statut FROM lots_paiement WHERE id = (p ->> 'lot_id')::BIGINT) IS DISTINCT FROM 'propose' THEN
        RAISE EXCEPTION 'le lot n''est plus en attente' USING ERRCODE = 'MZ031';
    END IF;
    IF jsonb_typeof(p -> 'actions') <> 'array' OR EXISTS (
        SELECT 1 FROM jsonb_array_elements(p -> 'actions') a
        WHERE a ->> 'code' NOT IN ('valider', 'rejeter', 'renvoyer_aux_controles', 'confirmer_fournisseur',
                                   'demander_changement_rib', 'demander_creation_fournisseur', 'approuver', 'refuser',
                                   'confirmer_rapprochement', 'rejeter_rapprochement', 'classer_signalement',
                                   'approuver_lot', 'refuser_lot')) THEN
        RAISE EXCEPTION 'action inconnue dans la notification' USING ERRCODE = 'MZ032';
    END IF;
    INSERT INTO notifications (canal, utilisateur_id, objet, facture_id, demande_id, proposition_id, signalement_id, releve_id, lot_id,
                               statut_facture, passage_controle, actions, contenu, jeton_empreinte, expire_le)
    VALUES (v_canal, (p ->> 'utilisateur_id')::BIGINT, p ->> 'objet', (p ->> 'facture_id')::BIGINT,
            (p ->> 'demande_id')::BIGINT, (p ->> 'proposition_id')::BIGINT, (p ->> 'signalement_id')::BIGINT,
            (p ->> 'releve_id')::BIGINT, (p ->> 'lot_id')::BIGINT, p ->> 'statut_facture', (p ->> 'passage_controle')::BIGINT,
            p -> 'actions', p -> 'contenu', encode(sha256(convert_to(v_jeton, 'UTF8')), 'hex'),
            now() + make_interval(days => parametre_controle('notification.validite_jours')::INTEGER))
    RETURNING id INTO v_id;
    RETURN QUERY SELECT v_id, v_jeton;
END;
$$;

CREATE OR REPLACE FUNCTION recevoir_evenement(p JSONB) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_canal    TEXT := p ->> 'canal';
    v_adresse  TEXT := p ->> 'adresse';
    v_type     TEXT := coalesce(p ->> 'type', 'autre');
    v_util     utilisateurs%ROWTYPE;
    v_code     codes_inscription%ROWTYPE;
    v_notif    notifications%ROWTYPE;
    v_attente  actions_en_attente%ROWTYPE;
    v_action   JSONB;
    v_facture  factures%ROWTYPE;
    v_passage  BIGINT;
    v_res      JSONB;
    v_id       BIGINT;
BEGIN
    IF EXISTS (SELECT 1 FROM evenements_entrants WHERE canal = v_canal AND reference = p ->> 'reference') THEN
        RETURN jsonb_build_object('code', 'deja_traite');
    END IF;

    SELECT u.* INTO v_util FROM utilisateurs u JOIN adresses_canal a ON a.utilisateur_id = u.id
    WHERE a.canal = v_canal AND a.adresse = v_adresse AND a.active AND u.actif;

    IF v_type = 'inscription' THEN
        SELECT * INTO v_code FROM codes_inscription
        WHERE canal = v_canal AND code_empreinte = encode(sha256(convert_to(coalesce(p ->> 'code', ''), 'UTF8')), 'hex')
        FOR UPDATE;
        IF NOT FOUND OR v_code.utilise_le IS NOT NULL OR v_code.expire_le < now() THEN
            v_res := jsonb_build_object('code', 'inscription_refusee');
        ELSIF EXISTS (SELECT 1 FROM adresses_canal WHERE canal = v_canal AND adresse = v_adresse) THEN
            v_res := jsonb_build_object('code', 'adresse_deja_inscrite');
        ELSE
            UPDATE codes_inscription SET utilise_le = now() WHERE id = v_code.id;
            UPDATE adresses_canal SET active = FALSE WHERE utilisateur_id = v_code.utilisateur_id AND canal = v_canal;
            INSERT INTO adresses_canal (utilisateur_id, canal, adresse) VALUES (v_code.utilisateur_id, v_canal, v_adresse);
            INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_apres)
            VALUES ('utilisateur:' || v_code.utilisateur_id, 'utilisateur.adresse_inscrite', 'utilisateurs',
                    v_code.utilisateur_id::text, v_canal, jsonb_build_object('adresse', v_adresse, 'code_id', v_code.id));
            v_res := jsonb_build_object('code', 'inscription_reussie',
                                        'nom', (SELECT nom FROM utilisateurs WHERE id = v_code.utilisateur_id));
        END IF;

    ELSIF v_util.id IS NULL THEN
        -- Expéditeur inconnu : rien n'est fait, l'événement est tracé.
        v_res := jsonb_build_object('code', 'expediteur_inconnu');

    ELSIF v_type = 'action' THEN
        SELECT * INTO v_notif FROM notifications
        WHERE canal = v_canal AND jeton_empreinte = encode(sha256(convert_to(coalesce(p ->> 'jeton', ''), 'UTF8')), 'hex');
        -- Indice strictement entier et positif (en JSONB, -1 désignerait le dernier élément).
        v_action := CASE WHEN coalesce(p ->> 'indice', '') ~ '^\d{1,3}$'
                         THEN v_notif.actions -> ((p ->> 'indice')::INTEGER) END;
        IF v_notif.id IS NULL THEN
            v_res := jsonb_build_object('code', 'bouton_inconnu');
        ELSIF v_notif.utilisateur_id <> v_util.id THEN
            -- Le bouton ne suffit pas : il faut être le destinataire.
            v_res := jsonb_build_object('code', 'pas_destinataire');
            INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_apres)
            VALUES ('utilisateur:' || v_util.id, 'canal.bouton_d_un_autre', 'notifications', v_notif.id::text, v_canal,
                    jsonb_build_object('destinataire', v_notif.utilisateur_id));
        ELSIF v_notif.expire_le < now() THEN
            v_res := jsonb_build_object('code', 'notification_expiree');
        ELSIF v_action IS NULL THEN
            v_res := jsonb_build_object('code', 'action_inconnue');
        ELSE
            IF v_notif.objet = 'facture' THEN
                SELECT * INTO v_facture FROM factures WHERE id = v_notif.facture_id;
                v_passage := (SELECT max(passage) FROM resultats_controles WHERE facture_id = v_notif.facture_id);
            END IF;
            IF v_notif.objet = 'facture' AND (v_facture.statut IS DISTINCT FROM v_notif.statut_facture
                                               OR v_passage IS DISTINCT FROM v_notif.passage_controle) THEN
                v_res := jsonb_build_object('code', 'notification_perimee', 'statut', v_facture.statut);
            ELSIF v_notif.objet = 'demande' AND EXISTS (SELECT 1 FROM decisions_referentiel WHERE demande_id = v_notif.demande_id) THEN
                v_res := jsonb_build_object('code', 'notification_perimee');
            ELSIF v_notif.objet = 'rapprochement'
                  AND (SELECT statut FROM propositions_rapprochement WHERE id = v_notif.proposition_id) <> 'propose' THEN
                v_res := jsonb_build_object('code', 'notification_perimee');
            ELSIF v_notif.objet = 'signalement'
                  AND (SELECT statut FROM signalements_paiement WHERE id = v_notif.signalement_id) <> 'ouvert' THEN
                v_res := jsonb_build_object('code', 'notification_perimee');
            ELSIF v_notif.objet = 'lot_paiement'
                  AND (SELECT statut FROM lots_paiement WHERE id = v_notif.lot_id) <> 'propose' THEN
                v_res := jsonb_build_object('code', 'notification_perimee');
            ELSE
                UPDATE actions_en_attente SET conclue_le = now(), resultat = 'remplacee'
                WHERE utilisateur_id = v_util.id AND canal = v_canal AND conclue_le IS NULL;
                INSERT INTO actions_en_attente (notification_id, utilisateur_id, canal, adresse, indice_action, expire_le)
                VALUES (v_notif.id, v_util.id, v_canal, v_adresse, (p ->> 'indice')::INTEGER,
                        now() + make_interval(mins => parametre_controle('justification.delai_minutes')::INTEGER));
                v_res := jsonb_build_object('code', 'justification_demandee', 'action', v_action,
                                            'contenu', v_notif.contenu,
                                            'delai_minutes', parametre_controle('justification.delai_minutes'));
            END IF;
        END IF;

    ELSIF v_type = 'texte' THEN
        SELECT * INTO v_attente FROM actions_en_attente
        WHERE utilisateur_id = v_util.id AND canal = v_canal AND conclue_le IS NULL FOR UPDATE;
        IF v_attente.id IS NULL THEN
            v_res := jsonb_build_object('code', 'aucune_action_en_attente');
        ELSIF v_attente.expire_le < now() OR v_attente.adresse <> v_adresse THEN
            UPDATE actions_en_attente SET conclue_le = now(), resultat = 'expiree' WHERE id = v_attente.id;
            v_res := jsonb_build_object('code', 'justification_trop_tard');
        ELSE
            SELECT * INTO v_notif FROM notifications WHERE id = v_attente.notification_id;
            v_action := v_notif.actions -> v_attente.indice_action;
            BEGIN
                v_id := appliquer_action(v_notif, v_action, v_util.id, p ->> 'texte', v_canal);
                v_res := jsonb_build_object('code', 'decision_enregistree', 'action', v_action, 'id', v_id,
                                            'statut', (SELECT statut FROM factures WHERE id = v_notif.facture_id));
            EXCEPTION WHEN OTHERS THEN
                -- Refus de la base (rôle, justification, règle non dérogeable,
                -- quatre yeux…) : rien n'est appliqué, le motif est renvoyé.
                v_res := jsonb_build_object('code', 'decision_refusee', 'action', v_action,
                                            'erreur', SQLSTATE, 'motif', SQLERRM);
            END;
            UPDATE actions_en_attente SET conclue_le = now(), resultat = v_res ->> 'code' WHERE id = v_attente.id;
        END IF;

    ELSE
        v_res := jsonb_build_object('code', 'non_compris');
    END IF;

    INSERT INTO evenements_entrants (canal, reference, adresse, type, resultat)
    VALUES (v_canal, p ->> 'reference', v_adresse, v_type, v_res);
    RETURN v_res;
END;
$$;

CREATE OR REPLACE FUNCTION appliquer_action(p_notif notifications, p_action JSONB, p_utilisateur BIGINT, p_texte TEXT, p_canal TEXT)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_code    TEXT := p_action ->> 'code';
    v_params  JSONB := coalesce(p_action -> 'params', '{}'::jsonb);
    v_facture factures%ROWTYPE;
    v_id      BIGINT;
BEGIN
    SELECT * INTO v_facture FROM factures WHERE id = p_notif.facture_id;
    IF v_code IN ('valider', 'rejeter', 'renvoyer_aux_controles', 'confirmer_fournisseur') THEN
        INSERT INTO decisions_humaines (facture_id, utilisateur_id, decision, justification, corrections, canal)
        VALUES (p_notif.facture_id, p_utilisateur,
                CASE v_code WHEN 'valider' THEN 'valider' WHEN 'rejeter' THEN 'rejeter' ELSE 'renvoyer_aux_controles' END,
                p_texte,
                CASE WHEN v_code = 'confirmer_fournisseur'
                     THEN jsonb_build_object('fournisseur_id', (v_params ->> 'fournisseur_id')::BIGINT) ELSE '{}'::jsonb END,
                p_canal)
        RETURNING id INTO v_id;
    ELSIF v_code = 'demander_changement_rib' THEN
        INSERT INTO demandes_referentiel (type_demande, fournisseur_id, facture_id, donnees, demande_par, justification, canal)
        VALUES ('changement_rib', v_facture.fournisseur_id, v_facture.id, jsonb_build_object('rib', v_params ->> 'rib'),
                p_utilisateur, p_texte, p_canal)
        RETURNING id INTO v_id;
    ELSIF v_code = 'demander_creation_fournisseur' THEN
        INSERT INTO demandes_referentiel (type_demande, facture_id, donnees, demande_par, justification, canal)
        VALUES ('creation_fournisseur', v_facture.id, v_params, p_utilisateur, p_texte, p_canal)
        RETURNING id INTO v_id;
    ELSIF v_code IN ('approuver', 'refuser') THEN
        INSERT INTO decisions_referentiel (demande_id, decision, utilisateur_id, methode_verification, justification, canal)
        VALUES (p_notif.demande_id, CASE v_code WHEN 'approuver' THEN 'approuvee' ELSE 'refusee' END, p_utilisateur,
                v_params ->> 'methode_verification', p_texte, p_canal)
        RETURNING id INTO v_id;
    ELSIF v_code IN ('confirmer_rapprochement', 'rejeter_rapprochement') THEN
        INSERT INTO decisions_rapprochement (proposition_id, decision, motif_ecart, utilisateur_id, justification, canal)
        VALUES (p_notif.proposition_id, CASE v_code WHEN 'confirmer_rapprochement' THEN 'confirmer' ELSE 'rejeter' END,
                v_params ->> 'motif_ecart', p_utilisateur, p_texte, p_canal)
        RETURNING id INTO v_id;
    ELSIF v_code = 'classer_signalement' THEN
        INSERT INTO decisions_signalement (signalement_id, utilisateur_id, justification, canal)
        VALUES (p_notif.signalement_id, p_utilisateur, p_texte, p_canal)
        RETURNING id INTO v_id;
    ELSIF v_code IN ('approuver_lot', 'refuser_lot') THEN
        INSERT INTO decisions_lot_paiement (lot_id, decision, utilisateur_id, justification, canal)
        VALUES (p_notif.lot_id, CASE v_code WHEN 'approuver_lot' THEN 'approuver' ELSE 'refuser' END,
                p_utilisateur, p_texte, p_canal)
        RETURNING id INTO v_id;
    ELSE
        RAISE EXCEPTION 'action « % » inconnue', v_code USING ERRCODE = 'MZ032';
    END IF;
    RETURN v_id;
END;
$$;

CREATE FUNCTION donnees_notifications(p_canal TEXT) RETURNS SETOF JSONB
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'candidat', jsonb_build_object(
            'canal', p_canal, 'objet', c.objet, 'utilisateur_id', c.utilisateur_id, 'role', c.role,
            'passage_controle', c.passage_controle, 'proposition_id', c.proposition_id,
            'signalement_id', c.signalement_id, 'releve_id', c.releve_id, 'lot_id', c.lot_id,
            'adresse', (SELECT a.adresse FROM adresses_canal a
                        WHERE a.utilisateur_id = c.utilisateur_id AND a.canal = p_canal AND a.active)),
        'facture', to_jsonb(f) - 'extraction_brute',
        -- Facture : son fournisseur ; demande de changement de RIB : celui de la demande.
        'fournisseur', (SELECT jsonb_build_object(
                            'raison_sociale', fo.raison_sociale, 'matricule_fiscal', fo.matricule_fiscal,
                            'rib_actif', (SELECT r.rib FROM fournisseur_ribs r WHERE r.fournisseur_id = fo.id AND r.valide_au IS NULL))
                        FROM fournisseurs fo
                        WHERE fo.id = CASE c.objet WHEN 'demande' THEN d.fournisseur_id ELSE f.fournisseur_id END),
        'resultats', coalesce((SELECT jsonb_agg(jsonb_build_object('regle', r.regle, 'resultat', r.resultat, 'gravite', r.gravite,
                                                                   'message', r.message, 'detail', r.detail) ORDER BY r.regle)
                               FROM resultats_controles r WHERE r.facture_id = c.facture_id AND r.passage = c.passage_controle), '[]'::jsonb),
        'regles', (SELECT jsonb_agg(jsonb_build_object('regle', g.regle, 'derogeable', g.derogeable) ORDER BY g.regle) FROM regles_controle g),
        'demande', CASE WHEN d.id IS NOT NULL THEN to_jsonb(d) || jsonb_build_object('demande_par_nom', u.nom) END,
        'proposition', (SELECT jsonb_build_object(
                'id', x.id, 'cas', x.cas, 'score', x.score, 'raisons', x.raisons, 'ecart', x.ecart,
                'ligne', (SELECT to_jsonb(l) FROM lignes_releve l WHERE l.id = x.ligne_releve_id),
                'affectations', (SELECT jsonb_agg(jsonb_build_object(
                    'facture_id', ff.id, 'numero', ff.numero, 'type_document', ff.type_document, 'statut', ff.statut,
                    'montant_ttc', ff.montant_ttc, 'devise', ff.devise, 'montant', r.montant_affecte, 'role', r.role,
                    'raison_sociale', coalesce(fo2.raison_sociale, ff.raison_sociale_lue)) ORDER BY r.role DESC, ff.id)
                    FROM rapprochements r JOIN factures ff ON ff.id = r.facture_id LEFT JOIN fournisseurs fo2 ON fo2.id = ff.fournisseur_id
                    WHERE r.proposition_id = x.id))
            FROM propositions_rapprochement x WHERE x.id = c.proposition_id),
        'signalement', (SELECT jsonb_build_object(
                'id', s.id, 'type', s.type, 'message', s.message, 'detail', s.detail,
                'ligne', (SELECT to_jsonb(l) FROM lignes_releve l WHERE l.id = s.ligne_releve_id))
            FROM signalements_paiement s WHERE s.id = c.signalement_id),
        'synthese', CASE WHEN c.objet = 'synthese' THEN (SELECT jsonb_build_object(
                'releve', jsonb_build_object('fichier_nom', rb.fichier_nom, 'date_debut', rb.date_debut, 'date_fin', rb.date_fin,
                                             'lignes', (SELECT count(*) FROM lignes_releve l WHERE l.releve_id = rb.id)),
                'bilan', (SELECT j.donnees_apres FROM journal_audit j WHERE j.action = 'releve.rapproche' AND j.entite_id = rb.id::text
                          ORDER BY j.id DESC LIMIT 1),
                'en_attente', jsonb_build_object(
                    'propositions', (SELECT count(*) FROM propositions_rapprochement x JOIN lignes_releve l ON l.id = x.ligne_releve_id
                                     WHERE l.releve_id = rb.id AND x.statut = 'propose'),
                    'signalements', (SELECT count(*) FROM signalements_paiement s JOIN lignes_releve l ON l.id = s.ligne_releve_id
                                     WHERE l.releve_id = rb.id AND s.statut = 'ouvert')),
                'factures_en_retard', (SELECT count(*) FROM situation_paiement sp WHERE sp.en_retard))
            FROM releves_bancaires rb WHERE rb.id = c.releve_id) END,
        'lot', (SELECT jsonb_build_object(
                'id', lp.id, 'echeances_jusqu_au', lp.echeances_jusqu_au, 'propose_le', lp.propose_le,
                'ordres', (SELECT jsonb_agg(jsonb_build_object(
                    'facture_id', o.facture_id, 'numero', fx.numero, 'date_echeance', fx.date_echeance,
                    'beneficiaire', o.beneficiaire, 'rib', o.rib, 'montant', o.montant, 'reference', o.reference)
                    ORDER BY fx.date_echeance NULLS FIRST, o.id)
                    FROM ordres_paiement o JOIN factures fx ON fx.id = o.facture_id WHERE o.lot_id = lp.id))
            FROM lots_paiement lp WHERE lp.id = c.lot_id),
        'methodes', (SELECT jsonb_agg(jsonb_build_object('code', m.code, 'type_demande', m.type_demande, 'libelle', m.libelle) ORDER BY m.code)
                     FROM methodes_verification m))
    FROM notifications_a_preparer(p_canal) c
    LEFT JOIN factures f ON f.id = c.facture_id
    LEFT JOIN demandes_referentiel d ON d.id = c.demande_id
    LEFT JOIN utilisateurs u ON u.id = d.demande_par
    ORDER BY c.objet DESC, c.facture_id, c.utilisateur_id;
$$;

GRANT EXECUTE ON FUNCTION notifications_a_preparer(TEXT) TO mizan_app;
REVOKE EXECUTE ON FUNCTION donnees_notifications(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION donnees_notifications(TEXT) TO mizan_app;
