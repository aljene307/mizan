-- migrate:up

-- Notifications et réponses par un canal (D-062). La décision ne connaît
-- aucun canal : un canal (Telegram aujourd'hui, l'e-mail demain) ne fait que
-- présenter une notification, transmettre un événement entrant, et afficher
-- la réponse. Tout ce qui autorise une décision est ici, en base.
--
-- Protection des boutons : une notification porte un JETON aléatoire (seule
-- son empreinte SHA-256 est gardée) et la liste de ses actions. Un bouton ne
-- porte que « jeton + numéro d'action ». Pour décider, il faut en plus :
-- l'adresse d'où vient l'événement (fournie par le canal, pas par le bouton)
-- doit être celle du DESTINATAIRE de la notification ; la facture doit être
-- encore dans l'état notifié (même statut, même passage de contrôle) ; la
-- notification ne doit pas être expirée ; puis une justification doit être
-- envoyée par la même personne, depuis la même adresse, dans le délai.

-- 1. Paramètres : nouvelles unités et durées. ---------------------------------
ALTER TABLE parametres_controle DROP CONSTRAINT parametres_controle_unite_ck;
ALTER TABLE parametres_controle ADD CONSTRAINT parametres_controle_unite_ck
    CHECK (unite IN ('TND', 'millimes', 'caracteres', 'jours', 'minutes', 'secondes'));
INSERT INTO parametres_controle (cle, valeur, unite, libelle, valide_du, justification) VALUES
    ('notification.validite_jours', 7, 'jours', 'Durée de validité d''une notification', '2026-01-01',
     'D-062 : au-delà, les boutons ne valent plus ; une nouvelle notification est envoyée si la facture attend encore.'),
    ('justification.delai_minutes', 10, 'minutes', 'Délai pour envoyer la justification après un bouton', '2026-01-01',
     'D-062 : une réponse tardive n''est pas appliquée.'),
    ('inscription.validite_minutes', 30, 'minutes', 'Durée de validité d''un code d''inscription', '2026-01-01',
     'D-062 (B1) : code à usage unique.'),
    ('canal.bail_secondes', 90, 'secondes', 'Durée du bail d''interrogation d''un canal', '2026-01-01',
     'D-062 : deux interrogations ne se chevauchent pas ; le bail expire si une exécution s''interrompt.');

-- 2. Adresses des utilisateurs sur un canal. -------------------------------------
-- La colonne utilisateurs.telegram_id (jamais remplie) est remplacée par une
-- table indépendante du canal.
ALTER TABLE utilisateurs DROP COLUMN telegram_id;

CREATE TABLE adresses_canal (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    utilisateur_id BIGINT      NOT NULL REFERENCES utilisateurs (id),
    canal          TEXT        NOT NULL,
    -- Telegram : identifiant numérique de l'utilisateur (from.id), fourni par
    -- Telegram ; e-mail : adresse.
    adresse        TEXT        NOT NULL,
    active         BOOLEAN     NOT NULL DEFAULT TRUE,
    inscrite_le    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT adresses_canal_canal_ck CHECK (canal IN ('telegram')),
    CONSTRAINT adresses_canal_uk UNIQUE (canal, adresse)
);
CREATE UNIQUE INDEX adresses_canal_utilisateur_uk ON adresses_canal (utilisateur_id, canal) WHERE active;

-- Codes d'inscription à usage unique (B1). Créés par l'administrateur ; seule
-- l'empreinte du code est gardée.
CREATE TABLE codes_inscription (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    utilisateur_id BIGINT      NOT NULL REFERENCES utilisateurs (id),
    canal          TEXT        NOT NULL,
    code_empreinte CHAR(64)    NOT NULL UNIQUE,
    cree_le        TIMESTAMPTZ NOT NULL DEFAULT now(),
    expire_le      TIMESTAMPTZ NOT NULL,
    utilise_le     TIMESTAMPTZ,
    CONSTRAINT codes_inscription_canal_ck CHECK (canal IN ('telegram'))
);

-- 3. Notifications. ---------------------------------------------------------------
CREATE TABLE notifications (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    canal            TEXT        NOT NULL,
    utilisateur_id   BIGINT      NOT NULL REFERENCES utilisateurs (id),
    objet            TEXT        NOT NULL,
    facture_id       BIGINT      REFERENCES factures (id),
    demande_id       BIGINT      REFERENCES demandes_referentiel (id),
    -- État notifié : une action n'est valable que si la facture y est encore.
    statut_facture   TEXT,
    passage_controle BIGINT,
    -- [{ code, libelle, params }] ; un bouton porte seulement l'indice.
    actions          JSONB       NOT NULL,
    -- Contenu présenté (indépendant du canal), conservé pour l'audit.
    contenu          JSONB       NOT NULL,
    jeton_empreinte  CHAR(64)    NOT NULL UNIQUE,
    etat             TEXT        NOT NULL DEFAULT 'a_envoyer',
    reference_canal  TEXT,
    erreur           TEXT,
    cree_le          TIMESTAMPTZ NOT NULL DEFAULT now(),
    envoyee_le       TIMESTAMPTZ,
    expire_le        TIMESTAMPTZ NOT NULL,
    CONSTRAINT notifications_canal_ck CHECK (canal IN ('telegram')),
    CONSTRAINT notifications_objet_ck CHECK (
        (objet = 'facture' AND facture_id IS NOT NULL AND demande_id IS NULL)
        OR (objet = 'demande' AND demande_id IS NOT NULL)),
    CONSTRAINT notifications_etat_ck CHECK (etat IN ('a_envoyer', 'envoyee', 'echec')),
    CONSTRAINT notifications_actions_ck CHECK (jsonb_typeof(actions) = 'array')
);
CREATE INDEX notifications_facture_ix ON notifications (facture_id, utilisateur_id, canal);
CREATE INDEX notifications_demande_ix ON notifications (demande_id, utilisateur_id, canal);

-- Action ouverte par un bouton, en attente de la justification.
CREATE TABLE actions_en_attente (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    notification_id BIGINT      NOT NULL REFERENCES notifications (id),
    utilisateur_id  BIGINT      NOT NULL REFERENCES utilisateurs (id),
    canal           TEXT        NOT NULL,
    adresse         TEXT        NOT NULL,
    indice_action   INTEGER     NOT NULL,
    ouverte_le      TIMESTAMPTZ NOT NULL DEFAULT now(),
    expire_le       TIMESTAMPTZ NOT NULL,
    conclue_le      TIMESTAMPTZ,
    resultat        TEXT
);
-- Une seule action ouverte à la fois par personne et par canal.
CREATE UNIQUE INDEX actions_en_attente_ouverte_uk ON actions_en_attente (utilisateur_id, canal) WHERE conclue_le IS NULL;

-- Événements entrants, une fois chacun (idempotence) : trace de tout ce qui
-- est reçu, y compris d'inconnus, avec le résultat du traitement.
CREATE TABLE evenements_entrants (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    canal      TEXT        NOT NULL,
    -- Identifiant de l'événement dans le canal (Telegram : update_id).
    reference  TEXT        NOT NULL,
    adresse    TEXT,
    type       TEXT        NOT NULL,
    recu_le    TIMESTAMPTZ NOT NULL DEFAULT now(),
    resultat   JSONB       NOT NULL,
    CONSTRAINT evenements_entrants_uk UNIQUE (canal, reference),
    CONSTRAINT evenements_entrants_type_ck CHECK (type IN ('inscription', 'action', 'texte', 'autre'))
);
CREATE TRIGGER evenements_entrants_pas_de_modification
    BEFORE UPDATE OR DELETE ON evenements_entrants
    FOR EACH ROW EXECUTE FUNCTION refuser_modification();

-- État d'interrogation d'un canal : curseur (Telegram : prochain update_id)
-- et bail exclusif, pour que deux interrogations ne se chevauchent pas.
CREATE TABLE etats_canal (
    canal         TEXT PRIMARY KEY,
    curseur       BIGINT      NOT NULL DEFAULT 0,
    bail_jeton    UUID,
    bail_jusqu_a  TIMESTAMPTZ,
    CONSTRAINT etats_canal_canal_ck CHECK (canal IN ('telegram'))
);
INSERT INTO etats_canal (canal) VALUES ('telegram');

-- Canal d'origine des demandes et décisions sur le référentiel (audit).
ALTER TABLE demandes_referentiel ADD COLUMN canal TEXT;
ALTER TABLE decisions_referentiel ADD COLUMN canal TEXT;

-- 4. Bail d'interrogation. ----------------------------------------------------------
-- Renvoie un jeton si le bail est libre (ou expiré), sinon aucune ligne.
CREATE FUNCTION prendre_bail_canal(p_canal TEXT) RETURNS TABLE (bail_jeton UUID, curseur BIGINT)
SECURITY DEFINER SET search_path = public, pg_temp
LANGUAGE sql AS $$
    UPDATE etats_canal e
    SET bail_jeton = gen_random_uuid(),
        bail_jusqu_a = now() + make_interval(secs => parametre_controle('canal.bail_secondes'))
    WHERE e.canal = p_canal AND (e.bail_jusqu_a IS NULL OR e.bail_jusqu_a < now())
    RETURNING e.bail_jeton, e.curseur;
$$;

-- Rend le bail et avance le curseur (jamais en arrière). Faux si le bail
-- n'est plus détenu (expiré puis repris) : rien n'est modifié.
CREATE FUNCTION rendre_bail_canal(p_canal TEXT, p_bail_jeton UUID, p_curseur BIGINT) RETURNS BOOLEAN
SECURITY DEFINER SET search_path = public, pg_temp
LANGUAGE sql AS $$
    WITH rendu AS (
        UPDATE etats_canal SET curseur = greatest(curseur, p_curseur), bail_jeton = NULL, bail_jusqu_a = NULL
        WHERE canal = p_canal AND bail_jeton = p_bail_jeton
        RETURNING 1)
    SELECT count(*) = 1 FROM rendu;
$$;

-- 5. Notifications à envoyer. -------------------------------------------------------
-- Candidats : factures en attente d'une personne, et demandes sur le
-- référentiel sans décision ; un candidat par destinataire inscrit sur le
-- canal, s'il n'a pas déjà une notification valable pour cet état.
CREATE FUNCTION notifications_a_preparer(p_canal TEXT) RETURNS TABLE (
    objet TEXT, facture_id BIGINT, demande_id BIGINT, utilisateur_id BIGINT, role TEXT,
    statut_facture TEXT, passage_controle BIGINT)
LANGUAGE sql STABLE AS $$
    WITH destinataires AS (
        SELECT u.id, u.role FROM utilisateurs u
        JOIN adresses_canal a ON a.utilisateur_id = u.id AND a.canal = p_canal AND a.active
        WHERE u.actif),
    factures_en_attente AS (
        SELECT f.id, f.statut, (SELECT max(r.passage) FROM resultats_controles r WHERE r.facture_id = f.id) AS passage
        FROM factures f WHERE f.statut IN ('a_valider', 'anomalie', 'bloquee'))
    SELECT 'facture', fa.id, NULL::BIGINT, d.id, d.role, fa.statut, fa.passage
    FROM factures_en_attente fa JOIN destinataires d
      ON fa.statut <> 'bloquee' OR d.role = 'responsable'
    WHERE NOT EXISTS (
        SELECT 1 FROM notifications n
        WHERE n.facture_id = fa.id AND n.utilisateur_id = d.id AND n.canal = p_canal
          AND n.statut_facture = fa.statut AND n.passage_controle IS NOT DISTINCT FROM fa.passage
          AND n.expire_le > now()
          AND (n.etat = 'envoyee' OR (n.etat = 'a_envoyer' AND n.cree_le > now() - interval '10 minutes')))
    UNION ALL
    SELECT 'demande', dr.facture_id, dr.id, d.id, d.role, NULL, NULL
    FROM demandes_referentiel dr JOIN destinataires d
      ON d.role = 'responsable' AND d.id <> dr.demande_par   -- quatre yeux
    WHERE NOT EXISTS (SELECT 1 FROM decisions_referentiel x WHERE x.demande_id = dr.id)
      AND NOT EXISTS (
        SELECT 1 FROM notifications n
        WHERE n.demande_id = dr.id AND n.utilisateur_id = d.id AND n.canal = p_canal AND n.expire_le > now()
          AND (n.etat = 'envoyee' OR (n.etat = 'a_envoyer' AND n.cree_le > now() - interval '10 minutes')));
$$;

-- Crée une notification et renvoie son jeton EN CLAIR, une seule fois (seule
-- l'empreinte est gardée). Le contenu et les actions sont préparés par le
-- code (src/), sans rien connaître du canal ; la base vérifie que le
-- destinataire est inscrit et que l'état notifié est l'état courant.
CREATE FUNCTION creer_notification(p JSONB) RETURNS TABLE (notification_id BIGINT, jeton TEXT)
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
    IF jsonb_typeof(p -> 'actions') <> 'array' OR EXISTS (
        SELECT 1 FROM jsonb_array_elements(p -> 'actions') a
        WHERE a ->> 'code' NOT IN ('valider', 'rejeter', 'renvoyer_aux_controles', 'confirmer_fournisseur',
                                   'demander_changement_rib', 'demander_creation_fournisseur', 'approuver', 'refuser')) THEN
        RAISE EXCEPTION 'action inconnue dans la notification' USING ERRCODE = 'MZ032';
    END IF;
    INSERT INTO notifications (canal, utilisateur_id, objet, facture_id, demande_id, statut_facture, passage_controle,
                               actions, contenu, jeton_empreinte, expire_le)
    VALUES (v_canal, (p ->> 'utilisateur_id')::BIGINT, p ->> 'objet', (p ->> 'facture_id')::BIGINT,
            (p ->> 'demande_id')::BIGINT, p ->> 'statut_facture', (p ->> 'passage_controle')::BIGINT,
            p -> 'actions', p -> 'contenu', encode(sha256(convert_to(v_jeton, 'UTF8')), 'hex'),
            now() + make_interval(days => parametre_controle('notification.validite_jours')::INTEGER))
    RETURNING id INTO v_id;
    RETURN QUERY SELECT v_id, v_jeton;
END;
$$;

CREATE FUNCTION marquer_notification(p_id BIGINT, p_reference TEXT, p_erreur TEXT DEFAULT NULL) RETURNS VOID
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
    UPDATE notifications
    SET etat = CASE WHEN p_erreur IS NULL THEN 'envoyee' ELSE 'echec' END,
        reference_canal = p_reference, erreur = p_erreur,
        envoyee_le = CASE WHEN p_erreur IS NULL THEN now() END
    WHERE id = p_id AND etat = 'a_envoyer';
$$;

-- 6. Événements entrants. --------------------------------------------------------------
-- p : { canal, reference, adresse, type: inscription|action|texte|autre,
--       code (inscription), jeton + indice (action), texte (texte) }.
-- Renvoie { code, ... } : la couche de canal en fait un message.
CREATE FUNCTION recevoir_evenement(p JSONB) RETURNS JSONB
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

-- Applique une action justifiée : la seule voie par laquelle un canal crée
-- une décision ou une demande. Les déclencheurs de D-056 vérifient ensuite
-- rôle, justification, règles non dérogeables et quatre yeux.
CREATE FUNCTION appliquer_action(p_notif notifications, p_action JSONB, p_utilisateur BIGINT, p_texte TEXT, p_canal TEXT)
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
    ELSE
        RAISE EXCEPTION 'action « % » inconnue', v_code USING ERRCODE = 'MZ032';
    END IF;
    RETURN v_id;
END;
$$;

-- 7. Code d'inscription (administrateur seulement : non accordé à mizan_app).
CREATE FUNCTION creer_code_inscription(p_utilisateur BIGINT, p_canal TEXT, p_code TEXT) RETURNS BIGINT
LANGUAGE sql AS $$
    INSERT INTO codes_inscription (utilisateur_id, canal, code_empreinte, expire_le)
    VALUES (p_utilisateur, p_canal, encode(sha256(convert_to(p_code, 'UTF8')), 'hex'),
            now() + make_interval(mins => parametre_controle('inscription.validite_minutes')::INTEGER))
    RETURNING id;
$$;

-- 8. Droits (D-062). ---------------------------------------------------------------
-- Une décision ne passe plus que par un événement de canal authentifié
-- (recevoir_evenement) : le rôle applicatif ne peut plus insérer directement
-- une décision ou une demande.
REVOKE INSERT ON decisions_humaines, demandes_referentiel, decisions_referentiel FROM mizan_app;
REVOKE EXECUTE ON FUNCTION creer_code_inscription(BIGINT, TEXT, TEXT), appliquer_action(notifications, JSONB, BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT SELECT ON adresses_canal, notifications, actions_en_attente, evenements_entrants, etats_canal TO mizan_app;
GRANT EXECUTE ON FUNCTION prendre_bail_canal(TEXT), rendre_bail_canal(TEXT, UUID, BIGINT),
    notifications_a_preparer(TEXT), creer_notification(JSONB), marquer_notification(BIGINT, TEXT, TEXT),
    recevoir_evenement(JSONB) TO mizan_app;

-- migrate:down

GRANT INSERT ON decisions_humaines, demandes_referentiel, decisions_referentiel TO mizan_app;
DROP FUNCTION creer_code_inscription(BIGINT, TEXT, TEXT);
DROP FUNCTION recevoir_evenement(JSONB);
DROP FUNCTION appliquer_action(notifications, JSONB, BIGINT, TEXT, TEXT);
DROP FUNCTION marquer_notification(BIGINT, TEXT, TEXT);
DROP FUNCTION creer_notification(JSONB);
DROP FUNCTION notifications_a_preparer(TEXT);
DROP FUNCTION rendre_bail_canal(TEXT, UUID, BIGINT);
DROP FUNCTION prendre_bail_canal(TEXT);
ALTER TABLE decisions_referentiel DROP COLUMN canal;
ALTER TABLE demandes_referentiel DROP COLUMN canal;
DROP TABLE etats_canal;
DROP TABLE evenements_entrants;
DROP TABLE actions_en_attente;
DROP TABLE notifications;
DROP TABLE codes_inscription;
DROP TABLE adresses_canal;
ALTER TABLE utilisateurs ADD COLUMN telegram_id TEXT UNIQUE;
DELETE FROM parametres_controle WHERE cle IN ('notification.validite_jours', 'justification.delai_minutes',
                                              'inscription.validite_minutes', 'canal.bail_secondes');
ALTER TABLE parametres_controle DROP CONSTRAINT parametres_controle_unite_ck;
ALTER TABLE parametres_controle ADD CONSTRAINT parametres_controle_unite_ck
    CHECK (unite IN ('TND', 'millimes', 'caracteres'));
