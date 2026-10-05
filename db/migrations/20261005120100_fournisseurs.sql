-- migrate:up

CREATE TABLE fournisseurs (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    raison_sociale   TEXT        NOT NULL,
    -- Stocké normalisé (majuscules, sans espace). Le contrôle de format est
    -- fait en JavaScript (src/), à partir d'une source officielle (étape 4).
    matricule_fiscal TEXT        NOT NULL,
    adresse          TEXT,
    ville            TEXT,
    email            TEXT,
    telephone        TEXT,
    actif            BOOLEAN     NOT NULL DEFAULT TRUE,
    cree_le          TIMESTAMPTZ NOT NULL DEFAULT now(),
    modifie_le       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT fournisseurs_matricule_fiscal_uk UNIQUE (matricule_fiscal),
    CONSTRAINT fournisseurs_raison_sociale_ck CHECK (btrim(raison_sociale) <> '')
);

CREATE TRIGGER fournisseurs_maj_modifie_le
    BEFORE UPDATE ON fournisseurs
    FOR EACH ROW EXECUTE FUNCTION maj_modifie_le();

-- Historique des RIB : une ligne par RIB, période [valide_du, valide_au).
-- valide_au est exclu ; NULL = RIB actif.
CREATE TABLE fournisseur_ribs (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fournisseur_id BIGINT      NOT NULL REFERENCES fournisseurs (id),
    rib            TEXT        NOT NULL,
    banque         TEXT,
    valide_du      DATE        NOT NULL DEFAULT current_date,
    valide_au      DATE,
    origine        TEXT        NOT NULL DEFAULT 'saisie',
    cree_le        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT fournisseur_ribs_periode_ck CHECK (valide_au IS NULL OR valide_au > valide_du),
    CONSTRAINT fournisseur_ribs_origine_ck CHECK (origine IN ('saisie', 'facture', 'import'))
);

-- Un seul RIB actif par fournisseur.
CREATE UNIQUE INDEX fournisseur_ribs_actif_uk
    ON fournisseur_ribs (fournisseur_id) WHERE valide_au IS NULL;
CREATE INDEX fournisseur_ribs_rib_ix ON fournisseur_ribs (rib);

-- migrate:down

DROP TABLE fournisseur_ribs;
DROP TABLE fournisseurs;
