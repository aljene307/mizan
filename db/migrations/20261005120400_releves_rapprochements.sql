-- migrate:up

-- Un import de relevé bancaire (fichier CSV).
CREATE TABLE releves_bancaires (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    banque         TEXT          NOT NULL,
    rib_compte     TEXT          NOT NULL,
    devise         CHAR(3)       NOT NULL DEFAULT 'TND',
    date_debut     DATE          NOT NULL,
    date_fin       DATE          NOT NULL,
    solde_initial  NUMERIC(15,3),
    solde_final    NUMERIC(15,3),
    fichier_nom    TEXT          NOT NULL,
    -- Un même fichier ne peut pas être importé deux fois.
    fichier_sha256 CHAR(64)      NOT NULL,
    importe_le     TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT releves_bancaires_sha256_uk UNIQUE (fichier_sha256),
    CONSTRAINT releves_bancaires_sha256_ck CHECK (fichier_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT releves_bancaires_devise_ck CHECK (devise ~ '^[A-Z]{3}$'),
    CONSTRAINT releves_bancaires_periode_ck CHECK (date_fin >= date_debut)
);

CREATE TABLE lignes_releve (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    releve_id      BIGINT        NOT NULL REFERENCES releves_bancaires (id) ON DELETE CASCADE,
    numero_ligne   INTEGER       NOT NULL,
    date_operation DATE          NOT NULL,
    date_valeur    DATE,
    libelle        TEXT          NOT NULL,
    reference      TEXT,
    debit          NUMERIC(15,3) NOT NULL DEFAULT 0,
    credit         NUMERIC(15,3) NOT NULL DEFAULT 0,
    CONSTRAINT lignes_releve_numero_uk UNIQUE (releve_id, numero_ligne),
    CONSTRAINT lignes_releve_numero_ck CHECK (numero_ligne > 0),
    CONSTRAINT lignes_releve_montants_ck CHECK (debit >= 0 AND credit >= 0 AND NOT (debit > 0 AND credit > 0))
);

CREATE INDEX lignes_releve_date_ix ON lignes_releve (date_operation);

-- Lien facture <-> ligne de relevé. Une facture peut être payée en plusieurs
-- fois, et un virement peut régler plusieurs factures : montant_affecte
-- indique la part de la ligne de relevé attribuée à la facture.
CREATE TABLE rapprochements (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    facture_id      BIGINT        NOT NULL REFERENCES factures (id),
    ligne_releve_id BIGINT        NOT NULL REFERENCES lignes_releve (id),
    montant_affecte NUMERIC(15,3) NOT NULL,
    methode         TEXT          NOT NULL,
    -- Confiance de l'appariement automatique, entre 0 et 1.
    score           NUMERIC(5,4),
    statut          TEXT          NOT NULL DEFAULT 'propose',
    -- Écart constaté à l'appariement (calcul défini à l'étape 6).
    ecart           NUMERIC(15,3),
    commentaire     TEXT,
    cree_par        TEXT          NOT NULL,
    cree_le         TIMESTAMPTZ   NOT NULL DEFAULT now(),
    modifie_le      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT rapprochements_paire_uk UNIQUE (facture_id, ligne_releve_id),
    CONSTRAINT rapprochements_montant_ck CHECK (montant_affecte > 0),
    CONSTRAINT rapprochements_methode_ck CHECK (methode IN ('auto', 'manuel')),
    CONSTRAINT rapprochements_score_ck CHECK (score BETWEEN 0 AND 1),
    CONSTRAINT rapprochements_statut_ck CHECK (statut IN ('propose', 'confirme', 'rejete'))
);

CREATE INDEX rapprochements_ligne_releve_ix ON rapprochements (ligne_releve_id);

CREATE TRIGGER rapprochements_maj_modifie_le
    BEFORE UPDATE ON rapprochements
    FOR EACH ROW EXECUTE FUNCTION maj_modifie_le();

-- migrate:down

DROP TABLE rapprochements;
DROP TABLE lignes_releve;
DROP TABLE releves_bancaires;
