-- migrate:up

-- Données d'une notification à préparer (D-062) : pour chaque candidat de
-- notifications_a_preparer(), tout ce dont src/decisions/notifications.js a
-- besoin, en un document JSON. Lecture seule ; ne connaît pas le canal au-delà
-- de l'adresse du destinataire.
CREATE FUNCTION donnees_notifications(p_canal TEXT) RETURNS SETOF JSONB
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'candidat', jsonb_build_object(
            'canal', p_canal, 'objet', c.objet, 'utilisateur_id', c.utilisateur_id, 'role', c.role,
            'passage_controle', c.passage_controle,
            'adresse', (SELECT a.adresse FROM adresses_canal a
                        WHERE a.utilisateur_id = c.utilisateur_id AND a.canal = p_canal AND a.active)),
        'facture', to_jsonb(f) - 'extraction_brute',
        -- Facture : son fournisseur ; demande de changement de RIB : celui de la demande.
        'fournisseur', (SELECT jsonb_build_object(
                            'raison_sociale', fo.raison_sociale, 'matricule_fiscal', fo.matricule_fiscal,
                            'rib_actif', (SELECT r.rib FROM fournisseur_ribs r WHERE r.fournisseur_id = fo.id AND r.valide_au IS NULL))
                        FROM fournisseurs fo
                        WHERE fo.id = CASE c.objet WHEN 'demande' THEN d.fournisseur_id ELSE f.fournisseur_id END),
        'resultats', coalesce((SELECT jsonb_agg(jsonb_build_object('regle', r.regle, 'resultat', r.resultat, 'gravite', r.gravite,
                                                                   'message', r.message, 'detail', r.detail) ORDER BY r.regle)
                               FROM resultats_controles r WHERE r.facture_id = c.facture_id AND r.passage = c.passage_controle), '[]'::jsonb),
        'regles', (SELECT jsonb_agg(jsonb_build_object('regle', g.regle, 'derogeable', g.derogeable) ORDER BY g.regle) FROM regles_controle g),
        'demande', CASE WHEN d.id IS NOT NULL THEN to_jsonb(d) || jsonb_build_object('demande_par_nom', u.nom) END,
        'methodes', (SELECT jsonb_agg(jsonb_build_object('code', m.code, 'type_demande', m.type_demande, 'libelle', m.libelle) ORDER BY m.code)
                     FROM methodes_verification m))
    FROM notifications_a_preparer(p_canal) c
    LEFT JOIN factures f ON f.id = c.facture_id
    LEFT JOIN demandes_referentiel d ON d.id = c.demande_id
    LEFT JOIN utilisateurs u ON u.id = d.demande_par
    ORDER BY c.objet DESC, c.facture_id, c.utilisateur_id;
$$;

REVOKE EXECUTE ON FUNCTION donnees_notifications(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION donnees_notifications(TEXT) TO mizan_app;

-- migrate:down

DROP FUNCTION donnees_notifications(TEXT);
