-- migrate:up

-- Fonctions du workflow « Contrôles » (D-055) : réserver une facture extraite,
-- lire tout ce dont les règles ont besoin, enregistrer un passage complet.
-- Les règles elles-mêmes sont en JavaScript (src/controles/).

-- 1. Réservation : une exécution prend UNE facture à contrôler. ---------------
CREATE FUNCTION reserver_facture_a_controler(p_delai_reprise INTERVAL DEFAULT '15 minutes')
RETURNS TABLE (facture_id BIGINT)
LANGUAGE sql AS $$
    UPDATE factures f
    SET statut = 'en_controle', reservee_le = now()
    WHERE f.id = (
        SELECT c.id FROM factures c
        WHERE c.statut = 'extraite'
           OR (c.statut = 'en_controle' AND c.reservee_le < now() - p_delai_reprise)
        ORDER BY c.id
        LIMIT 1
        FOR UPDATE SKIP LOCKED
    )
    RETURNING f.id;
$$;

-- 2. Contexte des contrôles, en un seul document JSON. --------------------------
CREATE FUNCTION contexte_controles(p_facture_id BIGINT) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
    f            factures%ROWTYPE;
    v_extraction JSONB;
    v_origine    TEXT;
BEGIN
    SELECT * INTO f FROM factures WHERE id = p_facture_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'facture % introuvable', p_facture_id USING ERRCODE = 'MZ002';
    END IF;

    -- Dernière extraction exploitable ; pour une réutilisation, les alertes
    -- et signalements sont ceux de l'extraction d'origine.
    SELECT jsonb_build_object(
               'id', e.id, 'resultat', e.resultat, 'reutilise_de', e.reutilise_de,
               'methode_lecture', s.methode_lecture, 'alertes_source', s.alertes_source,
               'verifications_source', s.verifications_source, 'signalements_code', s.signalements_code,
               'propositions', s.propositions,
               'facture_origine_numero', e.donnees ->> 'facture_origine_numero')
    INTO v_extraction
    FROM extractions e JOIN extractions s ON s.id = coalesce(e.reutilise_de, e.id)
    WHERE e.facture_id = f.id AND e.resultat IN ('valide', 'reutilisee')
    ORDER BY e.id DESC LIMIT 1;
    v_origine := v_extraction ->> 'facture_origine_numero';

    RETURN jsonb_build_object(
        'aujourd_hui', current_date,
        'facture', (to_jsonb(f) - 'extraction_brute')
                   || jsonb_build_object('numero_normalise', normaliser_numero_facture(f.numero)),
        'lignes', (SELECT coalesce(jsonb_agg(to_jsonb(l) ORDER BY l.numero_ligne), '[]'::jsonb)
                   FROM lignes_facture l WHERE l.facture_id = f.id),
        'extraction', v_extraction,
        'referentiel', (
            SELECT coalesce(jsonb_agg(jsonb_build_object(
                       'id', fo.id, 'raison_sociale', fo.raison_sociale,
                       'matricule_fiscal', fo.matricule_fiscal, 'actif', fo.actif,
                       'ribs', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                                    'rib', r.rib, 'valide_du', r.valide_du, 'valide_au', r.valide_au)
                                    ORDER BY r.valide_du), '[]'::jsonb)
                                FROM fournisseur_ribs r WHERE r.fournisseur_id = fo.id))
                       ORDER BY fo.id), '[]'::jsonb)
            FROM fournisseurs fo),
        -- Candidats doublons et facture d'origine d'un avoir : le code décide.
        'autres_factures', (
            SELECT coalesce(jsonb_agg(jsonb_build_object(
                       'id', c.id, 'statut', c.statut, 'fournisseur_id', c.fournisseur_id,
                       'matricule_fiscal_lu', c.matricule_fiscal_lu, 'type_document', c.type_document,
                       'numero', c.numero, 'numero_normalise', normaliser_numero_facture(c.numero),
                       'date_facture', c.date_facture, 'montant_ttc', c.montant_ttc,
                       'fichier_sha256', c.fichier_sha256, 'recue_le', c.recue_le)
                       ORDER BY c.id), '[]'::jsonb)
            FROM factures c
            WHERE c.id <> f.id
              AND (c.fichier_sha256 = f.fichier_sha256
                   OR normaliser_numero_facture(c.numero) = normaliser_numero_facture(f.numero)
                   OR normaliser_numero_facture(c.numero) = normaliser_numero_facture(v_origine)
                   OR (c.montant_ttc = f.montant_ttc AND c.date_facture = f.date_facture))),
        -- Configuration fiscale en vigueur à la date de la facture (vide sans date).
        'config_fiscale', (
            SELECT coalesce(jsonb_object_agg(cle, jsonb_build_object(
                       'valeur', valeur, 'unite', unite, 'conditions', conditions, 'a_confirmer', a_confirmer)),
                   '{}'::jsonb)
            FROM config_fiscale
            WHERE valide_du <= f.date_facture AND (valide_au IS NULL OR valide_au > f.date_facture)),
        'parametres', parametres_controle_en_vigueur(),
        'regles', (SELECT jsonb_agg(jsonb_build_object('regle', regle, 'derogeable', derogeable) ORDER BY regle)
                   FROM regles_controle WHERE actif)
    );
END;
$$;

-- 3. Enregistrement d'un passage complet. --------------------------------------
-- p : { facture_id, fournisseur_id (identifié avec certitude, ou null),
--       execution_n8n_id, resultats: [{regle, version_regle, resultat, gravite,
--       message, detail}] }. Chaque règle active doit figurer une fois et une
-- seule (MZ021) : toutes les règles s'exécutent sur chaque facture (D-055).
-- Le statut découle de la gravité la plus forte, calculé ici.
CREATE FUNCTION enregistrer_controles(p JSONB) RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    v_facture     factures%ROWTYPE;
    v_passage     BIGINT;
    v_irregulieres TEXT;
    v_statut      TEXT;
    v_fournisseur BIGINT := (p ->> 'fournisseur_id')::BIGINT;
    v_bilan       JSONB;
BEGIN
    SELECT * INTO v_facture FROM factures WHERE id = (p ->> 'facture_id')::BIGINT FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'facture % introuvable', p ->> 'facture_id' USING ERRCODE = 'MZ002';
    END IF;
    IF v_facture.statut <> 'en_controle' THEN
        RAISE EXCEPTION 'facture % non réservée pour les contrôles (statut %)', v_facture.id, v_facture.statut
            USING ERRCODE = 'MZ003';
    END IF;

    SELECT string_agg(c.regle, ', ' ORDER BY c.regle) INTO v_irregulieres
    FROM regles_controle c
    WHERE c.actif AND (SELECT count(*) FROM jsonb_array_elements(coalesce(p -> 'resultats', '[]'::jsonb)) r
                       WHERE r ->> 'regle' = c.regle) <> 1;
    IF v_irregulieres IS NOT NULL THEN
        RAISE EXCEPTION 'passage incomplet ou en double pour : %', v_irregulieres USING ERRCODE = 'MZ021';
    END IF;

    v_passage := nextval('passages_controle_seq');
    INSERT INTO resultats_controles (facture_id, passage, regle, version_regle, resultat, gravite,
                                     message, detail, execution_n8n_id)
    SELECT v_facture.id, v_passage, r ->> 'regle', r ->> 'version_regle', r ->> 'resultat', r ->> 'gravite',
           r ->> 'message', coalesce(r -> 'detail', '{}'::jsonb), p ->> 'execution_n8n_id'
    FROM jsonb_array_elements(p -> 'resultats') r;

    SELECT CASE
               WHEN bool_or(resultat IN ('anomalie', 'erreur') AND gravite = 'bloquant') THEN 'bloquee'
               WHEN bool_or(resultat IN ('anomalie', 'erreur') AND gravite = 'avertissement') THEN 'anomalie'
               WHEN bool_or(resultat IN ('anomalie', 'erreur') AND gravite = 'validation') THEN 'a_valider'
               ELSE 'conforme'
           END,
           jsonb_build_object(
               'bloquant', count(*) FILTER (WHERE resultat IN ('anomalie', 'erreur') AND gravite = 'bloquant'),
               'avertissement', count(*) FILTER (WHERE resultat IN ('anomalie', 'erreur') AND gravite = 'avertissement'),
               'validation', count(*) FILTER (WHERE resultat IN ('anomalie', 'erreur') AND gravite = 'validation'),
               'regles_en_anomalie', coalesce(jsonb_agg(regle ORDER BY regle)
                                              FILTER (WHERE resultat IN ('anomalie', 'erreur') AND gravite <> 'info'),
                                              '[]'::jsonb))
    INTO v_statut, v_bilan
    FROM resultats_controles WHERE passage = v_passage;

    -- Un rattachement confirmé par une décision humaine n'est pas remplacé.
    UPDATE factures SET
        statut = v_statut,
        reservee_le = NULL,
        fournisseur_id = CASE WHEN fournisseur_source = 'decision' THEN fournisseur_id ELSE v_fournisseur END,
        fournisseur_source = CASE WHEN fournisseur_source = 'decision' THEN 'decision'
                                  WHEN v_fournisseur IS NULL THEN NULL ELSE 'controle' END
    WHERE id = v_facture.id;

    INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_avant, donnees_apres, execution_n8n_id)
    VALUES ('n8n:controles', 'facture.controlee', 'factures', v_facture.id::text, v_facture.canal_reception,
            jsonb_build_object('statut', v_facture.statut),
            jsonb_build_object('statut', v_statut, 'passage', v_passage) || v_bilan,
            p ->> 'execution_n8n_id');
    RETURN v_passage;
END;
$$;

GRANT EXECUTE ON FUNCTION
    reserver_facture_a_controler(INTERVAL),
    contexte_controles(BIGINT),
    enregistrer_controles(JSONB),
    parametres_controle_en_vigueur(DATE),
    parametre_controle(TEXT, DATE)
TO mizan_app;

-- migrate:down

DROP FUNCTION enregistrer_controles(JSONB);
DROP FUNCTION contexte_controles(BIGINT);
DROP FUNCTION reserver_facture_a_controler(INTERVAL);
