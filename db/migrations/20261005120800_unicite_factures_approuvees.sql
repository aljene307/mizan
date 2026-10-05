-- migrate:up

-- Filet de sécurité contre les doublons (docs/decisions.md D-021) : deux
-- factures approuvées ne peuvent pas avoir le même fournisseur, le même type
-- de document et le même numéro, même si le contrôle de l'étape 4 a un bug.

-- Forme normalisée d'un numéro de facture : majuscules, sans espaces.
-- Le contrôle JavaScript des doublons (src/, étape 4) doit appliquer la même
-- normalisation au minimum.
CREATE FUNCTION normaliser_numero_facture(numero text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN upper(regexp_replace(numero, '[[:space:]]', '', 'g'));

-- Une facture approuvée (conforme ou validée) doit être rattachée à un
-- fournisseur et avoir un numéro ; sinon l'index ci-dessous ne la protégerait
-- pas (deux NULL ne sont jamais égaux pour un index unique).
ALTER TABLE factures ADD CONSTRAINT factures_approuvee_identifiee_ck CHECK (
    statut NOT IN ('conforme', 'validee')
    OR (fournisseur_id IS NOT NULL AND numero IS NOT NULL AND btrim(numero) <> '')
);

CREATE UNIQUE INDEX factures_approuvees_uk
    ON factures (fournisseur_id, type_document, normaliser_numero_facture(numero))
    WHERE statut IN ('conforme', 'validee');

-- migrate:down

DROP INDEX factures_approuvees_uk;
ALTER TABLE factures DROP CONSTRAINT factures_approuvee_identifiee_ck;
DROP FUNCTION normaliser_numero_facture(text);
