-- migrate:up

-- btree_gist : permet la contrainte d'exclusion de config_fiscale
-- (pas deux valeurs pour la même clé sur des périodes qui se chevauchent).
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- Met à jour la colonne modifie_le à chaque UPDATE.
CREATE FUNCTION maj_modifie_le() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.modifie_le := now();
    RETURN NEW;
END;
$$;

-- migrate:down

DROP FUNCTION maj_modifie_le();
DROP EXTENSION IF EXISTS btree_gist;
