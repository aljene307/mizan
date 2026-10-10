-- migrate:up

-- D-085 : le contexte des contrôles transmet aussi le texte source de
-- l'extraction (celui de l'extraction d'origine pour une réutilisation).
-- Rien d'autre ne change dans la fonction.

CREATE OR REPLACE FUNCTION public.contexte_controles(p_facture_id bigint) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $$
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
               -- Texte source : la règle signalements_extraction (v2, D-085) y cherche la
               -- raison sociale décodée avant de ramener un signalement d'entité à « info ».
               'texte_source', s.texte_source,
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
                   OR (c.montant_ttc = f.montant_ttc AND c.date_facture = f.date_facture)
                   -- Historique du fournisseur (D-060) : mêmes 8 premiers caractères
                   -- alphanumériques du matricule lu (forme courte), ou même rattachement.
                   OR (f.matricule_fiscal_lu IS NOT NULL
                       AND left(regexp_replace(upper(c.matricule_fiscal_lu), '[^0-9A-Z]', '', 'g'), 8)
                         = left(regexp_replace(upper(f.matricule_fiscal_lu), '[^0-9A-Z]', '', 'g'), 8))
                   OR (f.fournisseur_id IS NOT NULL AND c.fournisseur_id = f.fournisseur_id))),
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

-- migrate:down

CREATE OR REPLACE FUNCTION public.contexte_controles(p_facture_id bigint) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $$
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
                   OR (c.montant_ttc = f.montant_ttc AND c.date_facture = f.date_facture)
                   -- Historique du fournisseur (D-060) : mêmes 8 premiers caractères
                   -- alphanumériques du matricule lu (forme courte), ou même rattachement.
                   OR (f.matricule_fiscal_lu IS NOT NULL
                       AND left(regexp_replace(upper(c.matricule_fiscal_lu), '[^0-9A-Z]', '', 'g'), 8)
                         = left(regexp_replace(upper(f.matricule_fiscal_lu), '[^0-9A-Z]', '', 'g'), 8))
                   OR (f.fournisseur_id IS NOT NULL AND c.fournisseur_id = f.fournisseur_id))),
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
