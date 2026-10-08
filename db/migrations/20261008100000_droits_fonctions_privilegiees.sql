-- migrate:up

-- Fonctions SECURITY DEFINER (D-063) : elles s'exécutent avec les droits de
-- leur propriétaire. PostgreSQL accorde par défaut le droit d'exécution à
-- PUBLIC ; il est retiré ici, et seul le rôle applicatif garde l'exécution
-- des fonctions de canal (accordée nommément par la migration 20261008090000).
-- La fonction de déclencheur n'a besoin d'aucun droit d'exécution : il est
-- vérifié à la création du déclencheur, pas à son déclenchement.
REVOKE EXECUTE ON FUNCTION
    decisions_referentiel_appliquer(),
    prendre_bail_canal(TEXT),
    rendre_bail_canal(TEXT, UUID, BIGINT),
    creer_notification(JSONB),
    marquer_notification(BIGINT, TEXT, TEXT),
    recevoir_evenement(JSONB)
FROM PUBLIC;

-- migrate:down

GRANT EXECUTE ON FUNCTION
    decisions_referentiel_appliquer(),
    prendre_bail_canal(TEXT),
    rendre_bail_canal(TEXT, UUID, BIGINT),
    creer_notification(JSONB),
    marquer_notification(BIGINT, TEXT, TEXT),
    recevoir_evenement(JSONB)
TO PUBLIC;
