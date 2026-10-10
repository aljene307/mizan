-- migrate:up
-- Erreurs des workflows n8n (D-086). Le workflow « Mizan – Erreurs » (Error
-- Trigger) enregistre chaque erreur d'une exécution automatique, puis
-- prévient les responsables sur Telegram : un message court et générique, au
-- plus un par workflow et par intervalle (paramètre) ; les erreurs suivantes
-- sont seulement enregistrées. Le message technique est masqué par le
-- workflow (src/erreurs.js), puis de nouveau ici, et tronqué : la base ne
-- garde jamais un jeton de bot, une clé Gemini ni un mot de passe d'URL.

-- 1. Paramètre. -------------------------------------------------------------------------
INSERT INTO parametres_controle (cle, valeur, unite, libelle, valide_du, justification) VALUES
    ('erreurs.intervalle_notification', 60, 'minutes', 'Intervalle minimal entre deux messages d''erreur pour un même workflow',
     '2026-01-01', 'D-086 : « Réponses Telegram » tourne chaque minute ; une panne ne doit pas envoyer un message par minute');

-- 2. Journal des erreurs, en ajout seul. ------------------------------------------------------
CREATE TABLE erreurs_workflow (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    survenue_le      TIMESTAMPTZ NOT NULL DEFAULT now(),
    workflow_id      TEXT,
    workflow_nom     TEXT        NOT NULL,
    noeud            TEXT,
    execution_n8n_id TEXT,
    mode             TEXT,
    message          TEXT        NOT NULL,
    -- Décidé à l'enregistrement : un message part-il aux responsables ?
    notifiee         BOOLEAN     NOT NULL,
    CONSTRAINT erreurs_workflow_nom_ck CHECK (btrim(workflow_nom) <> ''),
    CONSTRAINT erreurs_workflow_message_ck CHECK (char_length(message) <= 500)
);
CREATE INDEX erreurs_workflow_ix ON erreurs_workflow (workflow_nom, survenue_le);
CREATE TRIGGER erreurs_workflow_pas_de_modification BEFORE UPDATE OR DELETE ON erreurs_workflow
    FOR EACH ROW EXECUTE FUNCTION refuser_modification();
CREATE TRIGGER erreurs_workflow_pas_de_vidage BEFORE TRUNCATE ON erreurs_workflow
    FOR EACH STATEMENT EXECUTE FUNCTION refuser_modification();

-- Masquage des secrets dans un texte (mêmes formes que src/erreurs.js).
CREATE FUNCTION masquer_secrets(p TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
    SELECT regexp_replace(regexp_replace(regexp_replace(regexp_replace(coalesce(p, ''),
        '[0-9]+:[A-Za-z0-9_-]{30,}', '***', 'g'),                       -- jeton de bot Telegram
        'AIza[0-9A-Za-z_-]{20,}', '***', 'g'),                          -- clé d'API Google
        '(//[^\s:/@]+:)[^\s@/]+@', '\1***@', 'g'),                       -- mot de passe dans une URL
        '([?&](key|token|password|api_key|apikey)=)[^&\s]+', '\1***', 'gi'); -- secret en paramètre d'URL
$$;

-- Enregistre une erreur : p = { workflow_id, workflow_nom, noeud,
-- execution_n8n_id, mode, message }. Renvoie { erreur_id, notifier,
-- survenue_le, intervalle_minutes, destinataires } : adresses Telegram actives des responsables réels actifs,
-- vides si un message est déjà parti pour ce workflow dans l'intervalle.
CREATE FUNCTION signaler_erreur_workflow(p JSONB) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_nom      TEXT := left(coalesce(nullif(btrim(p ->> 'workflow_nom'), ''), 'workflow inconnu'), 200);
    v_notifier BOOLEAN;
    v_id       BIGINT;
    v_le       TIMESTAMPTZ;
    v_minutes  INTEGER := parametre_controle('erreurs.intervalle_notification')::INTEGER;
BEGIN
    -- Deux erreurs simultanées du même workflow : une seule décide d'envoyer.
    PERFORM pg_advisory_xact_lock(hashtext('erreurs_workflow:' || v_nom));
    v_notifier := NOT EXISTS (
        SELECT 1 FROM erreurs_workflow
        WHERE workflow_nom = v_nom AND notifiee
          AND survenue_le > now() - make_interval(mins => v_minutes));
    INSERT INTO erreurs_workflow (workflow_id, workflow_nom, noeud, execution_n8n_id, mode, message, notifiee)
    VALUES (left(p ->> 'workflow_id', 100), v_nom, left(p ->> 'noeud', 200), left(p ->> 'execution_n8n_id', 100),
            left(p ->> 'mode', 50), left(masquer_secrets(coalesce(nullif(p ->> 'message', ''), 'erreur sans message')), 500),
            v_notifier)
    RETURNING id, survenue_le INTO v_id, v_le;
    RETURN jsonb_build_object(
        'erreur_id', v_id,
        'notifier', v_notifier,
        'survenue_le', v_le,
        'intervalle_minutes', v_minutes,
        'destinataires', CASE WHEN v_notifier THEN coalesce((
            SELECT jsonb_agg(a.adresse ORDER BY u.id)
            FROM utilisateurs u JOIN adresses_canal a ON a.utilisateur_id = u.id AND a.active AND a.canal = 'telegram'
            WHERE u.role = 'responsable' AND u.actif AND NOT u.fictif), '[]'::jsonb) ELSE '[]'::jsonb END);
END;
$$;
REVOKE EXECUTE ON FUNCTION signaler_erreur_workflow(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION signaler_erreur_workflow(JSONB) TO mizan_app;

-- 3. Restitution : erreurs récentes, sans le message technique. -----------------------------------
CREATE VIEW restitution.erreurs_workflow AS
SELECT id AS erreur_id, survenue_le, workflow_nom, noeud, notifiee
FROM public.erreurs_workflow;
GRANT SELECT ON restitution.erreurs_workflow TO mizan_lecture;

-- migrate:down
DROP VIEW restitution.erreurs_workflow;
DROP FUNCTION signaler_erreur_workflow(JSONB);
DROP FUNCTION masquer_secrets(TEXT);
DROP TABLE erreurs_workflow;
DELETE FROM parametres_controle WHERE cle = 'erreurs.intervalle_notification';
