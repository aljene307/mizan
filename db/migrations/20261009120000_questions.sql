-- migrate:up

-- Questions en langage naturel par catalogue fermé (D-068, B2). Une question
-- reçue par le canal (« /q … ») est mise en file ; le workflow « Questions »
-- la fait classer par le modèle (catalogue seulement), exécute la requête du
-- catalogue avec le rôle mizan_lecture, répond, puis conclut la question.
-- La table garde la trace : texte, question du catalogue retenue, paramètres,
-- code de réponse. recevoir_evenement() : version de 20261009110000 avec la
-- seule branche « question » ajoutée.

-- 1. Paramètres. ------------------------------------------------------------------------
ALTER TABLE parametres_controle DROP CONSTRAINT parametres_controle_unite_ck,
    ADD CONSTRAINT parametres_controle_unite_ck CHECK (unite IN ('TND', 'millimes', 'caracteres', 'jours', 'minutes', 'secondes', 'nombre'));
INSERT INTO parametres_controle (cle, valeur, unite, libelle, valide_du, justification) VALUES
    ('questions.longueur_max', 500, 'caracteres', 'Longueur maximale d''une question', '2026-01-01',
     'D-068 : une question courte suffit ; limite le texte envoyé au modèle'),
    ('questions.max_par_heure', 20, 'nombre', 'Questions par utilisateur et par heure', '2026-01-01',
     'D-068 : maîtrise du coût et du quota du modèle ; valeur illustrative');

ALTER TABLE evenements_entrants DROP CONSTRAINT evenements_entrants_type_ck,
    ADD CONSTRAINT evenements_entrants_type_ck CHECK (type IN ('inscription', 'action', 'texte', 'question', 'autre'));

-- 2. File des questions. ------------------------------------------------------------------
CREATE TABLE questions (
    id                 BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    utilisateur_id     BIGINT      NOT NULL REFERENCES utilisateurs (id),
    canal              TEXT        NOT NULL,
    adresse            TEXT        NOT NULL,
    reference          TEXT,
    texte              TEXT        NOT NULL,
    recue_le           TIMESTAMPTZ NOT NULL DEFAULT now(),
    statut             TEXT        NOT NULL DEFAULT 'a_traiter',
    prise_le           TIMESTAMPTZ,
    traitee_le         TIMESTAMPTZ,
    -- Résultat : question du catalogue retenue, paramètres validés, code.
    question_catalogue TEXT,
    parametres         JSONB,
    code_reponse       TEXT,
    erreur             TEXT,
    execution_n8n_id   TEXT,
    CONSTRAINT questions_statut_ck CHECK (statut IN ('a_traiter', 'en_cours', 'repondue', 'echec'))
);
CREATE INDEX questions_file_ix ON questions (statut, id);
CREATE INDEX questions_utilisateur_ix ON questions (utilisateur_id, recue_le);
CREATE TRIGGER questions_pas_de_suppression BEFORE DELETE ON questions
    FOR EACH ROW EXECUTE FUNCTION refuser_modification();
CREATE TRIGGER questions_pas_de_vidage BEFORE TRUNCATE ON questions
    FOR EACH STATEMENT EXECUTE FUNCTION refuser_modification();

-- Prend jusqu'à p_limite questions à traiter (et celles restées « en cours »
-- plus de 10 minutes : exécution interrompue). Utilisateur encore actif.
CREATE FUNCTION prendre_questions(p_limite INTEGER) RETURNS TABLE (
    question_id BIGINT, texte TEXT, canal TEXT, adresse TEXT, role TEXT)
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
    WITH prises AS (
        SELECT q.id FROM questions q JOIN utilisateurs u ON u.id = q.utilisateur_id AND u.actif
        WHERE q.statut = 'a_traiter' OR (q.statut = 'en_cours' AND q.prise_le < now() - interval '10 minutes')
        ORDER BY q.id LIMIT p_limite FOR UPDATE OF q SKIP LOCKED
    ), maj AS (
        UPDATE questions q SET statut = 'en_cours', prise_le = now() FROM prises WHERE q.id = prises.id
        RETURNING q.id, q.texte, q.canal, q.adresse, q.utilisateur_id
    )
    SELECT m.id, m.texte, m.canal, m.adresse, u.role FROM maj m JOIN utilisateurs u ON u.id = m.utilisateur_id ORDER BY m.id;
$$;

-- Conclut une question prise : p = { question_id, question_catalogue,
-- parametres, code_reponse, envoyee, erreur, execution_n8n_id }.
CREATE FUNCTION conclure_question(p JSONB) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_statut TEXT := CASE WHEN (p ->> 'envoyee')::BOOLEAN THEN 'repondue' ELSE 'echec' END;
BEGIN
    UPDATE questions SET statut = v_statut, traitee_le = now(),
        question_catalogue = p ->> 'question_catalogue', parametres = p -> 'parametres',
        code_reponse = p ->> 'code_reponse', erreur = left(p ->> 'erreur', 500), execution_n8n_id = p ->> 'execution_n8n_id'
    WHERE id = (p ->> 'question_id')::BIGINT AND statut = 'en_cours';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'question % : pas en cours de traitement', p ->> 'question_id' USING ERRCODE = 'MZ042';
    END IF;
    RETURN v_statut;
END;
$$;

-- 3. Réception par le canal. -------------------------------------------------------------
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

    ELSIF v_type = 'question' THEN
        -- Question en langage naturel (D-068, B2) : mise en file, traitée par
        -- le workflow « Questions ». Longueur et nombre par heure limités.
        IF length(btrim(coalesce(p ->> 'texte', ''))) = 0
           OR length(p ->> 'texte') > parametre_controle('questions.longueur_max') THEN
            v_res := jsonb_build_object('code', 'question_refusee', 'motif', 'longueur',
                                        'longueur_max', parametre_controle('questions.longueur_max'));
        ELSIF (SELECT count(*) FROM questions q WHERE q.utilisateur_id = v_util.id AND q.recue_le > now() - interval '1 hour')
              >= parametre_controle('questions.max_par_heure') THEN
            v_res := jsonb_build_object('code', 'question_refusee', 'motif', 'quota',
                                        'max_par_heure', parametre_controle('questions.max_par_heure'));
        ELSE
            INSERT INTO questions (utilisateur_id, canal, adresse, texte, reference)
            VALUES (v_util.id, v_canal, v_adresse, btrim(p ->> 'texte'), p ->> 'reference')
            RETURNING id INTO v_id;
            v_res := jsonb_build_object('code', 'question_recue', 'question_id', v_id);
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

-- 4. Droits. --------------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION prendre_questions(INTEGER), conclure_question(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION prendre_questions(INTEGER), conclure_question(JSONB) TO mizan_app;

-- migrate:down

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

DROP FUNCTION conclure_question(JSONB);
DROP FUNCTION prendre_questions(INTEGER);
DROP TABLE questions;
UPDATE evenements_entrants SET type = 'autre' WHERE type = 'question';
ALTER TABLE evenements_entrants DROP CONSTRAINT evenements_entrants_type_ck,
    ADD CONSTRAINT evenements_entrants_type_ck CHECK (type IN ('inscription', 'action', 'texte', 'autre'));
DELETE FROM parametres_controle WHERE cle IN ('questions.longueur_max', 'questions.max_par_heure');
ALTER TABLE parametres_controle DROP CONSTRAINT parametres_controle_unite_ck,
    ADD CONSTRAINT parametres_controle_unite_ck CHECK (unite IN ('TND', 'millimes', 'caracteres', 'jours', 'minutes', 'secondes'));
