-- migrate:up

-- Paramètres fiscaux datés. Chaque valeur porte sa source et un indicateur
-- a_confirmer. Période [valide_du, valide_au) ; valide_au NULL = en vigueur.
-- Sources et limites : docs/decisions.md D-019 et D-020.
CREATE TABLE config_fiscale (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cle            TEXT          NOT NULL,
    valeur         NUMERIC(15,4) NOT NULL,
    unite          TEXT          NOT NULL,
    libelle        TEXT          NOT NULL,
    -- Conditions d'application (bornes de montant, type d'émetteur…).
    conditions     JSONB         NOT NULL DEFAULT '{}',
    valide_du      DATE          NOT NULL,
    valide_au      DATE,
    source_libelle TEXT          NOT NULL,
    source_url     TEXT,
    a_confirmer    BOOLEAN       NOT NULL DEFAULT TRUE,
    note           TEXT,
    cree_le        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT config_fiscale_unite_ck CHECK (unite IN ('pourcent', 'TND')),
    CONSTRAINT config_fiscale_periode_ck CHECK (valide_au IS NULL OR valide_au > valide_du),
    CONSTRAINT config_fiscale_sans_chevauchement EXCLUDE USING gist (
        cle WITH =,
        daterange(valide_du, valide_au, '[)') WITH &&
    )
);

-- Valeurs de départ. valide_du = 2026-01-01 : les valeurs ont été vérifiées
-- pour 2026 uniquement ; leur date d'entrée en vigueur n'a pas été recherchée.
INSERT INTO config_fiscale
    (cle, valeur, unite, libelle, conditions, valide_du, source_libelle, source_url, a_confirmer, note)
VALUES
    ('tva.taux_normal', 19, 'pourcent', 'TVA - taux normal', '{}', '2026-01-01',
     'Code de la TVA, art. 7 (texte consolidé non consulté) ; taux cité par la LF 2025 (loi n° 2024-48), art. 40, JORT n° 149 du 10/12/2024',
     'https://www.finances.gov.tn/sites/default/files/2024-12/LF2025.pdf', TRUE,
     'À confirmer sur le texte consolidé de l''art. 7 du Code de la TVA.'),

    ('tva.taux_intermediaire', 13, 'pourcent', 'TVA - taux intermédiaire', '{}', '2026-01-01',
     'Sources secondaires concordantes uniquement (aucun texte officiel consulté)',
     NULL, TRUE,
     'À confirmer : aucune source officielle consultée.'),

    ('tva.taux_reduit', 7, 'pourcent', 'TVA - taux réduit', '{}', '2026-01-01',
     'Code de la TVA, art. 7 (texte consolidé non consulté) ; taux cité par la LF 2026 (loi n° 2025-17), art. 46, JORT n° 148 du 12/12/2025',
     'https://www.finances.gov.tn/sites/default/files/2026-01/115725.pdf', TRUE,
     'À confirmer sur le texte consolidé de l''art. 7 du Code de la TVA.'),

    ('timbre.facture', 1.000, 'TND', 'Droit de timbre par facture (cas général)', '{}', '2026-01-01',
     'Code des droits d''enregistrement et de timbre, art. 117 (texte consolidé non consulté) ; montant cité par des sources secondaires',
     NULL, TRUE,
     'À confirmer. Exonération éventuelle des avoirs à vérifier (étape 4).'),

    ('timbre.facture.grande_surface.50_100', 1.500, 'TND',
     'Droit de timbre - facture émise par une grande surface commerciale, de 50 à 100 TND',
     '{"emetteur": "grande_surface", "montant_min_inclus": 50, "montant_max_inclus": 100}', '2026-01-01',
     'LF 2026 (loi n° 2025-17), art. 20, point 6 : art. 117, § I, n° 6 bis du CDET ; JORT n° 148 du 12/12/2025, p. 4233',
     'https://www.finances.gov.tn/sites/default/files/2026-01/115725.pdf', TRUE,
     'Montant confirmé par le JORT. À confirmer : date d''effet (supposée 01/01/2026) et montant de référence (HT ou TTC).'),

    ('timbre.facture.grande_surface.plus_100', 2.000, 'TND',
     'Droit de timbre - facture émise par une grande surface commerciale, plus de 100 TND',
     '{"emetteur": "grande_surface", "montant_min_exclu": 100}', '2026-01-01',
     'LF 2026 (loi n° 2025-17), art. 20, point 6 : art. 117, § I, n° 6 bis du CDET ; JORT n° 148 du 12/12/2025, p. 4233',
     'https://www.finances.gov.tn/sites/default/files/2026-01/115725.pdf', TRUE,
     'Montant confirmé par le JORT. À confirmer : date d''effet (supposée 01/01/2026) et montant de référence (HT ou TTC).');

-- migrate:down

DROP TABLE config_fiscale;
