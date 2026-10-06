-- migrate:up

-- Version de la chaîne d'extraction (D-059) : identifie la configuration qui a
-- produit une extraction (prompt, schéma, paramètres, corrections par le code).
-- 'D-053' = configuration figée avant le lot de test. Une extraction n'est
-- réutilisée pour un même fichier que si elle vient de la MÊME version : une
-- extraction plus ancienne n'est jamais recopiée en silence.
ALTER TABLE extractions ADD COLUMN version_chaine TEXT;

DROP FUNCTION extraction_valide_existante(TEXT);
CREATE FUNCTION extraction_valide_existante(p_fichier_sha256 TEXT, p_version_chaine TEXT)
RETURNS TABLE (extraction_id BIGINT, donnees JSONB, methode_lecture TEXT)
LANGUAGE sql STABLE AS $$
    SELECT e.id, e.donnees, e.methode_lecture FROM extractions e
    WHERE e.fichier_sha256 = p_fichier_sha256 AND e.resultat = 'valide'
      AND e.version_chaine = p_version_chaine
    ORDER BY e.id DESC
    LIMIT 1;
$$;

-- Une réutilisation reprend la version de l'extraction d'origine.
CREATE OR REPLACE FUNCTION enregistrer_extraction(p JSONB) RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    v_facture   factures%ROWTYPE;
    v_source    extractions%ROWTYPE;
    v_id        BIGINT;
    v_resultat  TEXT := p ->> 'resultat';
    v_donnees   JSONB := p -> 'donnees';
    v_reussie   BOOLEAN := (p ->> 'resultat') IN ('valide', 'reutilisee');
    v_methode   TEXT := p ->> 'methode_lecture';
    v_alertes   JSONB := coalesce(p -> 'alertes_source', '[]'::jsonb);
    v_brutes    JSONB := p -> 'donnees_brutes';
    v_corrections  JSONB := p -> 'corrections_code';
    v_signalements JSONB := p -> 'signalements_code';
    v_propositions JSONB := p -> 'propositions';
    v_version      TEXT := p ->> 'version_chaine';
BEGIN
    SELECT * INTO v_facture FROM factures WHERE id = (p ->> 'facture_id')::BIGINT FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'facture % introuvable', p ->> 'facture_id' USING ERRCODE = 'MZ002';
    END IF;
    IF v_facture.statut <> 'en_extraction' THEN
        RAISE EXCEPTION 'facture % non réservée (statut %)', v_facture.id, v_facture.statut
            USING ERRCODE = 'MZ003';
    END IF;

    -- Une réutilisation reprend aussi la sortie brute, les corrections, les
    -- signalements et les propositions de l'extraction d'origine : une
    -- proposition de RIB ne doit pas disparaître pour un doublon.
    IF p ->> 'reutilise_de' IS NOT NULL THEN
        SELECT * INTO v_source FROM extractions WHERE id = (p ->> 'reutilise_de')::BIGINT;
        v_brutes       := coalesce(v_brutes, v_source.donnees_brutes);
        v_corrections  := coalesce(v_corrections, v_source.corrections_code);
        v_signalements := coalesce(v_signalements, v_source.signalements_code);
        v_propositions := coalesce(v_propositions, v_source.propositions);
        v_version      := coalesce(v_version, v_source.version_chaine);
    END IF;
    v_corrections  := coalesce(v_corrections, '[]'::jsonb);
    v_signalements := coalesce(v_signalements, '[]'::jsonb);
    v_propositions := coalesce(v_propositions, '[]'::jsonb);

    INSERT INTO extractions (
        facture_id, fichier_sha256, resultat, code_resultat, methode_lecture,
        fournisseur_llm, modele, version_prompt, empreinte_prompt, parametres_generation,
        duree_lecture_ms, duree_llm_ms, jetons_entree, jetons_sortie, jetons_reflexion, tentatives,
        donnees, erreurs, verifications_source, alertes_source, reutilise_de, execution_n8n_id, texte_source,
        donnees_brutes, corrections_code, signalements_code, propositions, version_chaine
    ) VALUES (
        v_facture.id, v_facture.fichier_sha256, v_resultat, p ->> 'code_resultat', v_methode,
        p ->> 'fournisseur_llm', p ->> 'modele', p ->> 'version_prompt', p ->> 'empreinte_prompt',
        p -> 'parametres_generation',
        (p ->> 'duree_lecture_ms')::INTEGER, (p ->> 'duree_llm_ms')::INTEGER,
        (p ->> 'jetons_entree')::INTEGER, (p ->> 'jetons_sortie')::INTEGER,
        (p ->> 'jetons_reflexion')::INTEGER, (p ->> 'tentatives')::INTEGER,
        v_donnees, coalesce(p -> 'erreurs', '[]'::jsonb),
        coalesce(p -> 'verifications_source', '[]'::jsonb), v_alertes,
        (p ->> 'reutilise_de')::BIGINT, p ->> 'execution_n8n_id', p ->> 'texte_source',
        v_brutes, v_corrections, v_signalements, v_propositions, v_version
    ) RETURNING id INTO v_id;

    IF v_reussie THEN
        UPDATE factures SET
            type_document       = v_donnees ->> 'type_document',
            numero              = v_donnees ->> 'numero',
            date_facture        = (v_donnees ->> 'date_facture')::DATE,
            date_echeance       = (v_donnees ->> 'date_echeance')::DATE,
            devise              = v_donnees ->> 'devise',
            montant_ht          = (v_donnees ->> 'montant_ht')::NUMERIC,
            montant_tva         = (v_donnees ->> 'montant_tva')::NUMERIC,
            droit_timbre        = (v_donnees ->> 'droit_timbre')::NUMERIC,
            montant_ttc         = (v_donnees ->> 'montant_ttc')::NUMERIC,
            matricule_fiscal_lu = v_donnees #>> '{fournisseur,matricule_fiscal}',
            raison_sociale_lue  = v_donnees #>> '{fournisseur,raison_sociale}',
            rib_facture         = v_donnees #>> '{fournisseur,rib}',
            methode_extraction  = CASE v_methode WHEN 'ocr' THEN 'ocr_llm' ELSE 'texte_llm' END,
            -- Sortie brute du modèle (avant corrections), si elle est connue.
            extraction_brute    = coalesce(v_brutes, v_donnees),
            statut              = 'extraite',
            reservee_le         = NULL
        WHERE id = v_facture.id;

        INSERT INTO lignes_facture (facture_id, numero_ligne, designation, quantite,
                                    prix_unitaire_ht, taux_tva, montant_ht)
        SELECT v_facture.id, l.rang::INTEGER, l.ligne ->> 'designation',
               (l.ligne ->> 'quantite')::NUMERIC, (l.ligne ->> 'prix_unitaire_ht')::NUMERIC,
               (l.ligne ->> 'taux_tva')::NUMERIC, (l.ligne ->> 'montant_ht')::NUMERIC
        FROM jsonb_array_elements(v_donnees -> 'lignes') WITH ORDINALITY AS l (ligne, rang);
    ELSE
        UPDATE factures SET statut = 'erreur_extraction', reservee_le = NULL,
                            extraction_brute = coalesce(v_brutes, v_donnees)
        WHERE id = v_facture.id;
    END IF;

    INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_avant, donnees_apres, execution_n8n_id)
    VALUES (
        'n8n:extraction',
        CASE
            WHEN v_resultat = 'valide' AND (jsonb_array_length(v_alertes) > 0
                 OR jsonb_array_length(v_signalements) > 0 OR jsonb_array_length(v_propositions) > 0)
                THEN 'facture.extraite_avec_alertes'
            WHEN v_resultat = 'valide' THEN 'facture.extraite'
            WHEN v_resultat = 'reutilisee' THEN 'facture.extraction_reutilisee'
            ELSE 'facture.erreur_extraction'
        END,
        'factures', v_facture.id::text, v_facture.canal_reception,
        jsonb_build_object('statut', v_facture.statut),
        jsonb_build_object('extraction_id', v_id, 'resultat', v_resultat,
                           'code_resultat', p ->> 'code_resultat', 'modele', p ->> 'modele',
                           'alertes_source', v_alertes, 'corrections_code', v_corrections,
                           'signalements_code', v_signalements, 'propositions', v_propositions,
                           'version_chaine', v_version),
        p ->> 'execution_n8n_id'
    );

    RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION extraction_valide_existante(TEXT, TEXT) TO mizan_app;

-- migrate:down

-- Rétablit la version de la migration 20261006100000.
CREATE OR REPLACE FUNCTION enregistrer_extraction(p JSONB) RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    v_facture   factures%ROWTYPE;
    v_source    extractions%ROWTYPE;
    v_id        BIGINT;
    v_resultat  TEXT := p ->> 'resultat';
    v_donnees   JSONB := p -> 'donnees';
    v_reussie   BOOLEAN := (p ->> 'resultat') IN ('valide', 'reutilisee');
    v_methode   TEXT := p ->> 'methode_lecture';
    v_alertes   JSONB := coalesce(p -> 'alertes_source', '[]'::jsonb);
    v_brutes    JSONB := p -> 'donnees_brutes';
    v_corrections  JSONB := p -> 'corrections_code';
    v_signalements JSONB := p -> 'signalements_code';
    v_propositions JSONB := p -> 'propositions';
BEGIN
    SELECT * INTO v_facture FROM factures WHERE id = (p ->> 'facture_id')::BIGINT FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'facture % introuvable', p ->> 'facture_id' USING ERRCODE = 'MZ002';
    END IF;
    IF v_facture.statut <> 'en_extraction' THEN
        RAISE EXCEPTION 'facture % non réservée (statut %)', v_facture.id, v_facture.statut
            USING ERRCODE = 'MZ003';
    END IF;

    -- Une réutilisation reprend aussi la sortie brute, les corrections, les
    -- signalements et les propositions de l'extraction d'origine : une
    -- proposition de RIB ne doit pas disparaître pour un doublon.
    IF p ->> 'reutilise_de' IS NOT NULL THEN
        SELECT * INTO v_source FROM extractions WHERE id = (p ->> 'reutilise_de')::BIGINT;
        v_brutes       := coalesce(v_brutes, v_source.donnees_brutes);
        v_corrections  := coalesce(v_corrections, v_source.corrections_code);
        v_signalements := coalesce(v_signalements, v_source.signalements_code);
        v_propositions := coalesce(v_propositions, v_source.propositions);
    END IF;
    v_corrections  := coalesce(v_corrections, '[]'::jsonb);
    v_signalements := coalesce(v_signalements, '[]'::jsonb);
    v_propositions := coalesce(v_propositions, '[]'::jsonb);

    INSERT INTO extractions (
        facture_id, fichier_sha256, resultat, code_resultat, methode_lecture,
        fournisseur_llm, modele, version_prompt, empreinte_prompt, parametres_generation,
        duree_lecture_ms, duree_llm_ms, jetons_entree, jetons_sortie, jetons_reflexion, tentatives,
        donnees, erreurs, verifications_source, alertes_source, reutilise_de, execution_n8n_id, texte_source,
        donnees_brutes, corrections_code, signalements_code, propositions
    ) VALUES (
        v_facture.id, v_facture.fichier_sha256, v_resultat, p ->> 'code_resultat', v_methode,
        p ->> 'fournisseur_llm', p ->> 'modele', p ->> 'version_prompt', p ->> 'empreinte_prompt',
        p -> 'parametres_generation',
        (p ->> 'duree_lecture_ms')::INTEGER, (p ->> 'duree_llm_ms')::INTEGER,
        (p ->> 'jetons_entree')::INTEGER, (p ->> 'jetons_sortie')::INTEGER,
        (p ->> 'jetons_reflexion')::INTEGER, (p ->> 'tentatives')::INTEGER,
        v_donnees, coalesce(p -> 'erreurs', '[]'::jsonb),
        coalesce(p -> 'verifications_source', '[]'::jsonb), v_alertes,
        (p ->> 'reutilise_de')::BIGINT, p ->> 'execution_n8n_id', p ->> 'texte_source',
        v_brutes, v_corrections, v_signalements, v_propositions
    ) RETURNING id INTO v_id;

    IF v_reussie THEN
        UPDATE factures SET
            type_document       = v_donnees ->> 'type_document',
            numero              = v_donnees ->> 'numero',
            date_facture        = (v_donnees ->> 'date_facture')::DATE,
            date_echeance       = (v_donnees ->> 'date_echeance')::DATE,
            devise              = v_donnees ->> 'devise',
            montant_ht          = (v_donnees ->> 'montant_ht')::NUMERIC,
            montant_tva         = (v_donnees ->> 'montant_tva')::NUMERIC,
            droit_timbre        = (v_donnees ->> 'droit_timbre')::NUMERIC,
            montant_ttc         = (v_donnees ->> 'montant_ttc')::NUMERIC,
            matricule_fiscal_lu = v_donnees #>> '{fournisseur,matricule_fiscal}',
            raison_sociale_lue  = v_donnees #>> '{fournisseur,raison_sociale}',
            rib_facture         = v_donnees #>> '{fournisseur,rib}',
            methode_extraction  = CASE v_methode WHEN 'ocr' THEN 'ocr_llm' ELSE 'texte_llm' END,
            -- Sortie brute du modèle (avant corrections), si elle est connue.
            extraction_brute    = coalesce(v_brutes, v_donnees),
            statut              = 'extraite',
            reservee_le         = NULL
        WHERE id = v_facture.id;

        INSERT INTO lignes_facture (facture_id, numero_ligne, designation, quantite,
                                    prix_unitaire_ht, taux_tva, montant_ht)
        SELECT v_facture.id, l.rang::INTEGER, l.ligne ->> 'designation',
               (l.ligne ->> 'quantite')::NUMERIC, (l.ligne ->> 'prix_unitaire_ht')::NUMERIC,
               (l.ligne ->> 'taux_tva')::NUMERIC, (l.ligne ->> 'montant_ht')::NUMERIC
        FROM jsonb_array_elements(v_donnees -> 'lignes') WITH ORDINALITY AS l (ligne, rang);
    ELSE
        UPDATE factures SET statut = 'erreur_extraction', reservee_le = NULL,
                            extraction_brute = coalesce(v_brutes, v_donnees)
        WHERE id = v_facture.id;
    END IF;

    INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_avant, donnees_apres, execution_n8n_id)
    VALUES (
        'n8n:extraction',
        CASE
            WHEN v_resultat = 'valide' AND (jsonb_array_length(v_alertes) > 0
                 OR jsonb_array_length(v_signalements) > 0 OR jsonb_array_length(v_propositions) > 0)
                THEN 'facture.extraite_avec_alertes'
            WHEN v_resultat = 'valide' THEN 'facture.extraite'
            WHEN v_resultat = 'reutilisee' THEN 'facture.extraction_reutilisee'
            ELSE 'facture.erreur_extraction'
        END,
        'factures', v_facture.id::text, v_facture.canal_reception,
        jsonb_build_object('statut', v_facture.statut),
        jsonb_build_object('extraction_id', v_id, 'resultat', v_resultat,
                           'code_resultat', p ->> 'code_resultat', 'modele', p ->> 'modele',
                           'alertes_source', v_alertes, 'corrections_code', v_corrections,
                           'signalements_code', v_signalements, 'propositions', v_propositions),
        p ->> 'execution_n8n_id'
    );

    RETURN v_id;
END;
$$;

DROP FUNCTION extraction_valide_existante(TEXT, TEXT);
CREATE FUNCTION extraction_valide_existante(p_fichier_sha256 TEXT)
RETURNS TABLE (extraction_id BIGINT, donnees JSONB, methode_lecture TEXT)
LANGUAGE sql STABLE AS $$
    SELECT e.id, e.donnees, e.methode_lecture FROM extractions e
    WHERE e.fichier_sha256 = p_fichier_sha256 AND e.resultat = 'valide'
    ORDER BY e.id DESC
    LIMIT 1;
$$;
GRANT EXECUTE ON FUNCTION extraction_valide_existante(TEXT) TO mizan_app;

ALTER TABLE extractions DROP COLUMN version_chaine;
