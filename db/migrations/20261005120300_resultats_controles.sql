-- migrate:up

-- Une ligne par exécution d'une règle de contrôle sur une facture.
-- Les exécutions successives sont conservées (historique).
CREATE TABLE resultats_controles (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    facture_id       BIGINT      NOT NULL REFERENCES factures (id),
    -- Code de la règle, ex. 'coherence_ht_tva_ttc', 'changement_rib'.
    regle            TEXT        NOT NULL,
    version_regle    TEXT        NOT NULL,
    resultat         TEXT        NOT NULL,
    gravite          TEXT        NOT NULL,
    -- Message lisible, affiché au validateur.
    message          TEXT,
    -- Détail de l'anomalie : valeurs attendues et constatées.
    detail           JSONB       NOT NULL DEFAULT '{}',
    execution_n8n_id TEXT,
    execute_le       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT resultats_controles_resultat_ck CHECK (resultat IN ('ok', 'anomalie', 'erreur')),
    CONSTRAINT resultats_controles_gravite_ck CHECK (gravite IN ('info', 'avertissement', 'bloquant'))
);

CREATE INDEX resultats_controles_facture_ix ON resultats_controles (facture_id, execute_le DESC);
CREATE INDEX resultats_controles_regle_ix ON resultats_controles (regle, resultat);

-- migrate:down

DROP TABLE resultats_controles;
