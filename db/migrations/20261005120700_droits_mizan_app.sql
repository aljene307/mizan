-- migrate:up

-- Rôle applicatif utilisé par n8n (voir docs/decisions.md D-018).
-- Créé sans connexion s'il n'existe pas encore ; le mot de passe et le droit
-- de connexion sont donnés par db/init/02-create-app-role.sh.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'mizan_app') THEN
        CREATE ROLE mizan_app NOLOGIN;
    END IF;
END;
$$;

GRANT USAGE ON SCHEMA public TO mizan_app;

-- Tables métier : lecture, ajout, modification. Jamais de suppression.
GRANT SELECT, INSERT, UPDATE ON
    fournisseurs, fournisseur_ribs,
    factures, lignes_facture,
    releves_bancaires, lignes_releve, rapprochements
TO mizan_app;

-- Résultats de contrôles et journal d'audit : ajout seul.
GRANT SELECT, INSERT ON resultats_controles, journal_audit TO mizan_app;

-- Configuration fiscale : lecture seule (modifiée par migration uniquement).
GRANT SELECT ON config_fiscale TO mizan_app;

-- migrate:down

REVOKE ALL ON
    fournisseurs, fournisseur_ribs,
    factures, lignes_facture,
    releves_bancaires, lignes_releve, rapprochements,
    resultats_controles, journal_audit, config_fiscale
FROM mizan_app;
REVOKE USAGE ON SCHEMA public FROM mizan_app;
