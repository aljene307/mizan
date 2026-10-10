-- migrate:up

-- Correctif (2026-10-09) : la vue ordres_en_cours appelait parametre_controle(),
-- fonction qui s'exécute avec les droits et le chemin de recherche de
-- L'UTILISATEUR (et non du propriétaire de la vue). Pour mizan_lecture
-- (search_path = restitution, schéma public fermé), elle ne trouvait pas
-- parametres_controle_en_vigueur() : « npm run generer-releve-demo » échouait.
-- Règle désormais : les vues lues par mizan_lecture n'appellent aucune
-- fonction hors du catalogue ; une table est lue par la vue, avec les droits
-- de son propriétaire. Testé dans 07_restitution.sql et par une vraie
-- connexion (lancer.sh, tests d'intégration).
CREATE OR REPLACE VIEW ordres_en_cours AS
SELECT o.id AS ordre_id, o.lot_id, o.facture_id, o.montant, l.decide_le::date AS approuve_le,
       l.decide_le::date + (SELECT pc.valeur FROM parametres_controle pc
                            WHERE pc.cle = 'ordres.fenetre_jours' AND pc.valide_du <= l.decide_le::date
                              AND (pc.valide_au IS NULL OR pc.valide_au > l.decide_le::date))::INTEGER AS expire_le,
       coalesce(p.paye, 0)::NUMERIC(15,3) AS paye_depuis,
       greatest(o.montant - coalesce(p.paye, 0), 0)::NUMERIC(15,3) AS reste_a_executer
FROM ordres_paiement o
JOIN lots_paiement l ON l.id = o.lot_id AND l.statut = 'approuve'
LEFT JOIN LATERAL (
    SELECT sum(r.montant_affecte) AS paye FROM rapprochements r JOIN lignes_releve lr ON lr.id = r.ligne_releve_id
    WHERE r.facture_id = o.facture_id AND r.role = 'reglement' AND r.statut = 'confirme'
      AND lr.date_operation >= l.decide_le::date) p ON TRUE;

-- migrate:down

CREATE OR REPLACE VIEW ordres_en_cours AS
SELECT o.id AS ordre_id, o.lot_id, o.facture_id, o.montant, l.decide_le::date AS approuve_le,
       l.decide_le::date + parametre_controle('ordres.fenetre_jours', l.decide_le::date)::INTEGER AS expire_le,
       coalesce(p.paye, 0)::NUMERIC(15,3) AS paye_depuis,
       greatest(o.montant - coalesce(p.paye, 0), 0)::NUMERIC(15,3) AS reste_a_executer
FROM ordres_paiement o
JOIN lots_paiement l ON l.id = o.lot_id AND l.statut = 'approuve'
LEFT JOIN LATERAL (
    SELECT sum(r.montant_affecte) AS paye FROM rapprochements r JOIN lignes_releve lr ON lr.id = r.ligne_releve_id
    WHERE r.facture_id = o.facture_id AND r.role = 'reglement' AND r.statut = 'confirme'
      AND lr.date_operation >= l.decide_le::date) p ON TRUE;
