-- migrate:up

-- Une facture ou un avoir reçu. Les champs extraits sont facultatifs : une
-- facture est enregistrée dès sa réception, puis complétée par l'extraction.
-- Les incohérences (HT + TVA + timbre <> TTC, doublons) ne sont pas bloquées
-- ici : elles sont détectées par les contrôles (resultats_controles).
CREATE TABLE factures (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- NULL tant que le fournisseur n'a pas été identifié.
    fournisseur_id      BIGINT      REFERENCES fournisseurs (id),
    type_document       TEXT        NOT NULL DEFAULT 'facture',
    -- Pour un avoir : la facture corrigée, si elle est connue.
    facture_origine_id  BIGINT      REFERENCES factures (id),
    numero              TEXT,
    date_facture        DATE,
    date_echeance       DATE,
    devise              CHAR(3)     NOT NULL DEFAULT 'TND',
    -- Montants positifs, tels qu'imprimés ; le sens vient de type_document.
    montant_ht          NUMERIC(15,3),
    montant_tva         NUMERIC(15,3),
    -- Montant attendu : voir config_fiscale (valeur à confirmer).
    droit_timbre        NUMERIC(15,3),
    montant_ttc         NUMERIC(15,3),
    -- Données lues sur le document, avant rapprochement avec fournisseurs.
    matricule_fiscal_lu TEXT,
    raison_sociale_lue  TEXT,
    rib_facture         TEXT,
    -- Réception
    canal_reception     TEXT        NOT NULL,
    format_source       TEXT        NOT NULL,
    fichier_nom         TEXT        NOT NULL,
    fichier_sha256      CHAR(64)    NOT NULL,
    -- Extraction
    methode_extraction  TEXT,
    extraction_brute    JSONB,
    statut              TEXT        NOT NULL DEFAULT 'recue',
    recue_le            TIMESTAMPTZ NOT NULL DEFAULT now(),
    cree_le             TIMESTAMPTZ NOT NULL DEFAULT now(),
    modifie_le          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT factures_type_document_ck CHECK (type_document IN ('facture', 'avoir')),
    CONSTRAINT factures_origine_avoir_ck CHECK (facture_origine_id IS NULL OR type_document = 'avoir'),
    CONSTRAINT factures_devise_ck CHECK (devise ~ '^[A-Z]{3}$'),
    CONSTRAINT factures_montants_positifs_ck CHECK (
        coalesce(montant_ht, 0) >= 0 AND coalesce(montant_tva, 0) >= 0
        AND coalesce(droit_timbre, 0) >= 0 AND coalesce(montant_ttc, 0) >= 0
    ),
    CONSTRAINT factures_canal_ck CHECK (canal_reception IN ('dossier', 'email', 'telegram')),
    CONSTRAINT factures_format_ck CHECK (format_source IN ('pdf', 'image', 'xml')),
    CONSTRAINT factures_sha256_ck CHECK (fichier_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT factures_methode_ck CHECK (methode_extraction IN ('ocr_llm', 'xml', 'manuelle')),
    CONSTRAINT factures_statut_ck CHECK (statut IN (
        'recue', 'extraite', 'erreur_extraction',
        'conforme', 'anomalie', 'bloquee',
        'validee', 'rejetee'
    ))
);

CREATE TRIGGER factures_maj_modifie_le
    BEFORE UPDATE ON factures
    FOR EACH ROW EXECUTE FUNCTION maj_modifie_le();

-- Recherche des doublons (index non uniques : un doublon doit être enregistré
-- puis signalé, voir docs/decisions.md D-013).
CREATE INDEX factures_doublon_numero_ix ON factures (fournisseur_id, type_document, numero);
CREATE INDEX factures_fichier_sha256_ix ON factures (fichier_sha256);
CREATE INDEX factures_statut_ix ON factures (statut);
CREATE INDEX factures_date_echeance_ix ON factures (date_echeance);

CREATE TABLE lignes_facture (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    facture_id       BIGINT        NOT NULL REFERENCES factures (id) ON DELETE CASCADE,
    numero_ligne     INTEGER       NOT NULL,
    designation      TEXT          NOT NULL,
    quantite         NUMERIC(18,6),
    prix_unitaire_ht NUMERIC(18,6),
    -- En pourcentage (19 = 19 %).
    taux_tva         NUMERIC(7,4),
    montant_ht       NUMERIC(15,3),
    montant_tva      NUMERIC(15,3),
    CONSTRAINT lignes_facture_numero_uk UNIQUE (facture_id, numero_ligne),
    CONSTRAINT lignes_facture_numero_ck CHECK (numero_ligne > 0),
    CONSTRAINT lignes_facture_taux_ck CHECK (taux_tva BETWEEN 0 AND 100)
);

-- migrate:down

DROP TABLE lignes_facture;
DROP TABLE factures;
