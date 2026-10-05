-- migrate:up

-- Réception, réservation et extraction des factures (docs/decisions.md
-- D-035, D-037, D-038, D-040).

-- 1. Factures : statut « en cours d'extraction », méthode « texte + LLM »,
--    référence de la source et horodatage de réservation. -------------------
ALTER TABLE factures DROP CONSTRAINT factures_statut_ck;
ALTER TABLE factures ADD CONSTRAINT factures_statut_ck CHECK (statut IN (
    'recue', 'en_extraction', 'extraite', 'erreur_extraction',
    'conforme', 'anomalie', 'bloquee',
    'validee', 'rejetee'
));

ALTER TABLE factures DROP CONSTRAINT factures_methode_ck;
ALTER TABLE factures ADD CONSTRAINT factures_methode_ck
    CHECK (methode_extraction IN ('texte_llm', 'ocr_llm', 'xml', 'manuelle'));

-- Identifiant de la pièce dans son canal : nom du fichier pour le dossier,
-- identifiant du message pour l'e-mail ou Telegram. NULL = nom du fichier.
ALTER TABLE factures ADD COLUMN reference_source TEXT;
-- Début de la réservation par une exécution (statut en_extraction).
ALTER TABLE factures ADD COLUMN reservee_le TIMESTAMPTZ;

-- Un même fichier relu (même canal, même référence, même contenu) n'est
-- enregistré qu'une fois. Un doublon sous un autre nom reste enregistré (D-013).
CREATE UNIQUE INDEX factures_reception_uk
    ON factures (canal_reception, (coalesce(reference_source, fichier_nom)), fichier_sha256);

CREATE INDEX factures_a_extraire_ix ON factures (id) WHERE statut IN ('recue', 'en_extraction');

-- 2. Historique des extractions (ajout seul). --------------------------------
CREATE TABLE extractions (
    id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    facture_id        BIGINT      NOT NULL REFERENCES factures (id),
    fichier_sha256    CHAR(64)    NOT NULL,
    -- valide : JSON conforme au schéma strict ; invalide : JSON non conforme ;
    -- erreur : pas de JSON exploitable ; reutilisee : copie d'une extraction
    -- valide du même fichier (aucun appel au LLM).
    resultat          TEXT        NOT NULL,
    -- Code renvoyé par le sous-workflow LLM (D-039) ou par la lecture du fichier.
    code_resultat     TEXT        NOT NULL,
    methode_lecture   TEXT,
    fournisseur_llm   TEXT,
    modele            TEXT,
    version_prompt    TEXT,
    empreinte_prompt  CHAR(64),
    duree_lecture_ms  INTEGER,
    duree_llm_ms      INTEGER,
    jetons_entree     INTEGER,
    jetons_sortie     INTEGER,
    tentatives        INTEGER,
    donnees           JSONB,
    erreurs           JSONB       NOT NULL DEFAULT '[]',
    reutilise_de      BIGINT      REFERENCES extractions (id),
    execution_n8n_id  TEXT,
    cree_le           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT extractions_sha256_ck CHECK (fichier_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT extractions_resultat_ck CHECK (resultat IN ('valide', 'invalide', 'erreur', 'reutilisee')),
    CONSTRAINT extractions_code_ck CHECK (code_resultat IN (
        'ok', 'reponse_illisible', 'erreur_fournisseur', 'quota_minute_epuise',
        'quota_journalier_epuise', 'erreur_lecture', 'erreur_ecriture', 'reutilisation'
    )),
    CONSTRAINT extractions_methode_ck CHECK (methode_lecture IN ('texte_pdf', 'ocr')),
    CONSTRAINT extractions_reutilisation_ck CHECK ((resultat = 'reutilisee') = (reutilise_de IS NOT NULL)),
    CONSTRAINT extractions_donnees_ck CHECK (resultat NOT IN ('valide', 'reutilisee') OR donnees IS NOT NULL),
    CONSTRAINT extractions_mesures_ck CHECK (
        coalesce(duree_lecture_ms, 0) >= 0 AND coalesce(duree_llm_ms, 0) >= 0
        AND coalesce(jetons_entree, 0) >= 0 AND coalesce(jetons_sortie, 0) >= 0
        AND coalesce(tentatives, 0) >= 0
    )
);

CREATE INDEX extractions_facture_ix ON extractions (facture_id);
CREATE INDEX extractions_valides_ix ON extractions (fichier_sha256, id DESC) WHERE resultat = 'valide';

-- Ajout seul, comme le journal d'audit (même limite : un administrateur peut
-- contourner le trigger, D-015).
CREATE FUNCTION refuser_modification() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% est en ajout seul : % interdit', TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'MZ001';
END;
$$;

CREATE TRIGGER extractions_pas_de_modification
    BEFORE UPDATE OR DELETE ON extractions
    FOR EACH ROW EXECUTE FUNCTION refuser_modification();
CREATE TRIGGER extractions_pas_de_vidage
    BEFORE TRUNCATE ON extractions
    FOR EACH STATEMENT EXECUTE FUNCTION refuser_modification();

-- 3. Réception : enregistre un fichier une seule fois. ------------------------
CREATE FUNCTION enregistrer_reception(
    p_canal          TEXT,
    p_reference      TEXT,
    p_format         TEXT,
    p_fichier_nom    TEXT,
    p_fichier_sha256 TEXT,
    p_execution      TEXT DEFAULT NULL
) RETURNS TABLE (facture_id BIGINT, nouvelle BOOLEAN)
LANGUAGE plpgsql AS $$
DECLARE
    v_id BIGINT;
BEGIN
    INSERT INTO factures (canal_reception, reference_source, format_source, fichier_nom, fichier_sha256)
    VALUES (p_canal, p_reference, p_format, p_fichier_nom, p_fichier_sha256)
    ON CONFLICT (canal_reception, (coalesce(reference_source, fichier_nom)), fichier_sha256) DO NOTHING
    RETURNING id INTO v_id;

    IF v_id IS NOT NULL THEN
        INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_apres, execution_n8n_id)
        VALUES ('n8n:reception', 'facture.recue', 'factures', v_id::text, p_canal,
                jsonb_build_object('fichier_nom', p_fichier_nom, 'fichier_sha256', p_fichier_sha256,
                                   'format_source', p_format),
                p_execution);
        RETURN QUERY SELECT v_id, TRUE;
    ELSE
        RETURN QUERY
            SELECT f.id, FALSE FROM factures f
            WHERE f.canal_reception = p_canal
              AND coalesce(f.reference_source, f.fichier_nom) = coalesce(p_reference, p_fichier_nom)
              AND f.fichier_sha256 = p_fichier_sha256;
    END IF;
END;
$$;

-- 4. Réservation : une exécution prend UNE facture à extraire. ----------------
-- FOR UPDATE SKIP LOCKED : une facture en cours de réservation par une autre
-- exécution est sautée. Une réservation plus ancienne que p_delai_reprise
-- (exécution interrompue) peut être reprise.
CREATE FUNCTION reserver_facture_a_extraire(p_delai_reprise INTERVAL DEFAULT '15 minutes')
RETURNS TABLE (
    facture_id      BIGINT,
    canal_reception TEXT,
    reference_source TEXT,
    fichier_nom     TEXT,
    fichier_sha256  CHAR(64),
    format_source   TEXT
)
LANGUAGE sql AS $$
    UPDATE factures f
    SET statut = 'en_extraction', reservee_le = now()
    WHERE f.id = (
        SELECT c.id FROM factures c
        WHERE c.statut = 'recue'
           OR (c.statut = 'en_extraction' AND c.reservee_le < now() - p_delai_reprise)
        ORDER BY c.id
        LIMIT 1
        FOR UPDATE SKIP LOCKED
    )
    RETURNING f.id, f.canal_reception, f.reference_source, f.fichier_nom, f.fichier_sha256, f.format_source;
$$;

-- Remet une facture réservée au statut « recue » (quota journalier épuisé).
CREATE FUNCTION liberer_facture(p_facture_id BIGINT) RETURNS BOOLEAN
LANGUAGE sql AS $$
    WITH liberee AS (
        UPDATE factures SET statut = 'recue', reservee_le = NULL
        WHERE id = p_facture_id AND statut = 'en_extraction'
        RETURNING id
    )
    SELECT count(*) = 1 FROM liberee;
$$;

-- Dernière extraction valide d'un même fichier (D-035, point 2).
CREATE FUNCTION extraction_valide_existante(p_fichier_sha256 TEXT)
RETURNS TABLE (extraction_id BIGINT, donnees JSONB, methode_lecture TEXT)
LANGUAGE sql STABLE AS $$
    SELECT e.id, e.donnees, e.methode_lecture FROM extractions e
    WHERE e.fichier_sha256 = p_fichier_sha256 AND e.resultat = 'valide'
    ORDER BY e.id DESC
    LIMIT 1;
$$;

-- 5. Enregistrement atomique d'une extraction. --------------------------------
-- p : objet JSON produit par le workflow (clés = colonnes d'extractions).
-- Valide ou réutilisée : la facture reçoit les champs extraits et ses lignes,
-- statut « extraite ». Sinon : statut « erreur_extraction ». Dans tous les cas,
-- l'extraction et une entrée au journal d'audit sont enregistrées.
CREATE FUNCTION enregistrer_extraction(p JSONB) RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    v_facture   factures%ROWTYPE;
    v_id        BIGINT;
    v_resultat  TEXT := p ->> 'resultat';
    v_donnees   JSONB := p -> 'donnees';
    v_reussie   BOOLEAN := (p ->> 'resultat') IN ('valide', 'reutilisee');
    v_methode   TEXT := p ->> 'methode_lecture';
BEGIN
    SELECT * INTO v_facture FROM factures WHERE id = (p ->> 'facture_id')::BIGINT FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'facture % introuvable', p ->> 'facture_id' USING ERRCODE = 'MZ002';
    END IF;
    IF v_facture.statut <> 'en_extraction' THEN
        RAISE EXCEPTION 'facture % non réservée (statut %)', v_facture.id, v_facture.statut
            USING ERRCODE = 'MZ003';
    END IF;

    INSERT INTO extractions (
        facture_id, fichier_sha256, resultat, code_resultat, methode_lecture,
        fournisseur_llm, modele, version_prompt, empreinte_prompt,
        duree_lecture_ms, duree_llm_ms, jetons_entree, jetons_sortie, tentatives,
        donnees, erreurs, reutilise_de, execution_n8n_id
    ) VALUES (
        v_facture.id, v_facture.fichier_sha256, v_resultat, p ->> 'code_resultat', v_methode,
        p ->> 'fournisseur_llm', p ->> 'modele', p ->> 'version_prompt', p ->> 'empreinte_prompt',
        (p ->> 'duree_lecture_ms')::INTEGER, (p ->> 'duree_llm_ms')::INTEGER,
        (p ->> 'jetons_entree')::INTEGER, (p ->> 'jetons_sortie')::INTEGER, (p ->> 'tentatives')::INTEGER,
        v_donnees, coalesce(p -> 'erreurs', '[]'::jsonb), (p ->> 'reutilise_de')::BIGINT, p ->> 'execution_n8n_id'
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
            extraction_brute    = v_donnees,
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
                            extraction_brute = v_donnees
        WHERE id = v_facture.id;
    END IF;

    INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_avant, donnees_apres, execution_n8n_id)
    VALUES (
        'n8n:extraction',
        CASE v_resultat
            WHEN 'valide' THEN 'facture.extraite'
            WHEN 'reutilisee' THEN 'facture.extraction_reutilisee'
            ELSE 'facture.erreur_extraction'
        END,
        'factures', v_facture.id::text, v_facture.canal_reception,
        jsonb_build_object('statut', v_facture.statut),
        jsonb_build_object('extraction_id', v_id, 'resultat', v_resultat,
                           'code_resultat', p ->> 'code_resultat', 'modele', p ->> 'modele'),
        p ->> 'execution_n8n_id'
    );

    RETURN v_id;
END;
$$;

-- 6. Droits du rôle applicatif. -----------------------------------------------
GRANT SELECT, INSERT ON extractions TO mizan_app;
GRANT EXECUTE ON FUNCTION
    enregistrer_reception(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT),
    reserver_facture_a_extraire(INTERVAL),
    liberer_facture(BIGINT),
    extraction_valide_existante(TEXT),
    enregistrer_extraction(JSONB)
TO mizan_app;

-- migrate:down

DROP FUNCTION enregistrer_extraction(JSONB);
DROP FUNCTION extraction_valide_existante(TEXT);
DROP FUNCTION liberer_facture(BIGINT);
DROP FUNCTION reserver_facture_a_extraire(INTERVAL);
DROP FUNCTION enregistrer_reception(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT);
DROP TABLE extractions;
DROP FUNCTION refuser_modification();
DROP INDEX factures_a_extraire_ix;
DROP INDEX factures_reception_uk;
ALTER TABLE factures DROP COLUMN reservee_le;
ALTER TABLE factures DROP COLUMN reference_source;
ALTER TABLE factures DROP CONSTRAINT factures_methode_ck;
ALTER TABLE factures ADD CONSTRAINT factures_methode_ck
    CHECK (methode_extraction IN ('ocr_llm', 'xml', 'manuelle'));
ALTER TABLE factures DROP CONSTRAINT factures_statut_ck;
ALTER TABLE factures ADD CONSTRAINT factures_statut_ck CHECK (statut IN (
    'recue', 'extraite', 'erreur_extraction',
    'conforme', 'anomalie', 'bloquee',
    'validee', 'rejetee'
));
