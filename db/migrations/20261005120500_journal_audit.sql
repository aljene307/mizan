-- migrate:up

-- Journal d'audit en ajout seul : insertions uniquement.
-- Limite : un administrateur de la base peut contourner le trigger
-- (voir docs/decisions.md D-015).
CREATE TABLE journal_audit (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- Forcé à l'heure du serveur par le trigger ci-dessous.
    horodatage       TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Qui : 'telegram:<identifiant>', 'n8n:<workflow>', 'admin'…
    acteur           TEXT        NOT NULL,
    -- Quoi : 'facture.validee', 'fournisseur.rib_modifie'…
    action           TEXT        NOT NULL,
    -- Sur quoi : nom de la table et identifiant de la ligne.
    entite           TEXT        NOT NULL,
    entite_id        TEXT,
    canal            TEXT,
    donnees_avant    JSONB,
    donnees_apres    JSONB,
    commentaire      TEXT,
    execution_n8n_id TEXT
);

CREATE INDEX journal_audit_entite_ix ON journal_audit (entite, entite_id);
CREATE INDEX journal_audit_horodatage_ix ON journal_audit (horodatage);

-- Refuse UPDATE, DELETE et TRUNCATE. Code d'erreur dédié : MZ001.
CREATE FUNCTION journal_audit_ajout_seul() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'journal_audit est en ajout seul : % interdit', TG_OP
        USING ERRCODE = 'MZ001';
END;
$$;

-- Empêche d'antidater une entrée : l'horodatage est celui du serveur.
CREATE FUNCTION journal_audit_horodater() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.horodatage := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER journal_audit_horodatage
    BEFORE INSERT ON journal_audit
    FOR EACH ROW EXECUTE FUNCTION journal_audit_horodater();

CREATE TRIGGER journal_audit_pas_de_modification
    BEFORE UPDATE OR DELETE ON journal_audit
    FOR EACH ROW EXECUTE FUNCTION journal_audit_ajout_seul();

CREATE TRIGGER journal_audit_pas_de_vidage
    BEFORE TRUNCATE ON journal_audit
    FOR EACH STATEMENT EXECUTE FUNCTION journal_audit_ajout_seul();

-- migrate:down

DROP TABLE journal_audit;
DROP FUNCTION journal_audit_horodater();
DROP FUNCTION journal_audit_ajout_seul();
