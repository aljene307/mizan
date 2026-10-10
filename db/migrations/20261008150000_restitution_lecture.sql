-- migrate:up

-- Restitution (D-068) : un schéma qui ne contient que des vues, et un rôle
-- mizan_lecture qui ne peut que les lire. Le tableau de bord (Grafana) et les
-- questions en langage naturel passent par ce rôle.

-- 1. Rôle de lecture. ----------------------------------------------------------
-- Créé sans connexion s'il n'existe pas encore ; le mot de passe et le droit
-- de connexion sont donnés par db/init/03-create-lecture-role.sh.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'mizan_lecture') THEN
        CREATE ROLE mizan_lecture NOLOGIN;
    END IF;
END;
$$;

-- Défense en profondeur, appliquée à chaque connexion du rôle : transaction en
-- lecture seule, requête et transaction inactive limitées dans le temps, peu
-- de connexions, et seules les vues de restitution visibles sans préfixe.
ALTER ROLE mizan_lecture NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 5;
ALTER ROLE mizan_lecture SET default_transaction_read_only = on;
ALTER ROLE mizan_lecture SET statement_timeout = '5s';
ALTER ROLE mizan_lecture SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE mizan_lecture SET search_path = restitution;

-- Le schéma public n'est plus utilisable par défaut (PUBLIC) : mizan_lecture
-- ne peut ni nommer une table, ni appeler une fonction de public. mizan_app
-- garde son droit explicite (D-018).
REVOKE USAGE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO mizan_app;

-- 2. Schéma de restitution. ---------------------------------------------------
-- Les vues s'exécutent avec les droits de leur propriétaire : mizan_lecture
-- n'a besoin d'aucun droit sur les tables. Aucune vue ne montre le RIB lu sur
-- une facture : le RIB de paiement est celui du référentiel (D-058).
CREATE SCHEMA restitution;

-- Échéancier : factures approuvées qui restent à payer.
CREATE VIEW restitution.echeancier AS
SELECT s.facture_id, s.numero, s.fournisseur_id, fo.raison_sociale AS fournisseur,
       f.date_facture, s.date_echeance,
       date_trunc('week', s.date_echeance)::date AS semaine_echeance,
       s.devise, s.montant_ttc, s.avoirs_imputes, s.regle, s.reste_a_payer, s.paiement_propose,
       s.etat, s.en_retard,
       CASE WHEN s.en_retard THEN current_date - s.date_echeance END AS jours_de_retard,
       rib.rib AS rib_paiement
FROM public.situation_paiement s
JOIN public.factures f ON f.id = s.facture_id
JOIN public.fournisseurs fo ON fo.id = s.fournisseur_id
LEFT JOIN public.fournisseur_ribs rib ON rib.fournisseur_id = s.fournisseur_id AND rib.valide_au IS NULL
WHERE s.reste_a_payer > 0;
COMMENT ON VIEW restitution.echeancier IS
    'Factures approuvées restant à payer. rib_paiement : RIB actif du référentiel, jamais celui lu sur la facture (D-058).';

-- Paiements confirmés : une ligne par facture réglée et par opération du relevé.
CREATE VIEW restitution.paiements AS
SELECT r.facture_id, f.numero, f.fournisseur_id, fo.raison_sociale AS fournisseur,
       l.date_operation, l.libelle, f.devise, r.montant_affecte AS montant,
       p.cas, p.methode, p.motif_ecart, r.ligne_releve_id
FROM public.rapprochements r
JOIN public.factures f ON f.id = r.facture_id
JOIN public.fournisseurs fo ON fo.id = f.fournisseur_id
JOIN public.lignes_releve l ON l.id = r.ligne_releve_id
LEFT JOIN public.propositions_rapprochement p ON p.id = r.proposition_id
WHERE r.role = 'reglement' AND r.statut = 'confirme';
COMMENT ON VIEW restitution.paiements IS
    'Règlements confirmés (avoir imputé compris dans le montant réglé, D-065).';

-- Trésorerie prévue, version simple : dernier solde du relevé, moins les
-- échéances à venir par semaine. Les échéances passées ou sans date tombent
-- dans la semaine en cours ; un paiement proposé est déjà dans le solde.
CREATE VIEW restitution.tresorerie_prevue AS
WITH dernier AS (
    SELECT solde_final, date_fin FROM public.releves_bancaires
    WHERE devise = 'TND' ORDER BY date_fin DESC, id DESC LIMIT 1
), semaines AS (
    SELECT greatest(date_trunc('week', coalesce(e.date_echeance, current_date)),
                    date_trunc('week', current_date))::date AS semaine,
           count(*) AS factures,
           sum(e.reste_a_payer - e.paiement_propose) AS sorties_prevues
    FROM restitution.echeancier e
    WHERE e.devise = 'TND' AND e.reste_a_payer > e.paiement_propose
    GROUP BY 1
)
SELECT s.semaine, s.factures, s.sorties_prevues,
       d.solde_final AS solde_releve, d.date_fin AS date_releve,
       d.solde_final - sum(s.sorties_prevues) OVER (ORDER BY s.semaine) AS solde_prevu_fin_semaine
FROM semaines s LEFT JOIN dernier d ON TRUE;
COMMENT ON VIEW restitution.tresorerie_prevue IS
    'Sorties connues seulement (factures approuvées en TND) : ni encaissements, ni salaires, ni loyer prévus.';

-- Montants de TVA imprimés sur les factures et avoirs approuvés, par mois.
-- Ce n'est pas la TVA déductible : la déductibilité relève des textes
-- officiels, non codés (D-020, D-068).
CREATE VIEW restitution.tva_factures AS
SELECT date_trunc('month', f.date_facture)::date AS mois, f.devise, f.type_document,
       count(*) AS documents,
       sum(f.montant_ht) AS montant_ht, sum(f.montant_tva) AS montant_tva, sum(f.montant_ttc) AS montant_ttc
FROM public.factures f
WHERE f.statut IN ('conforme', 'validee') AND f.date_facture IS NOT NULL
GROUP BY 1, 2, 3;
COMMENT ON VIEW restitution.tva_factures IS
    'TVA figurant sur les factures et avoirs approuvés (montants imprimés), pas la TVA déductible.';

-- Ce qui attend une décision humaine.
CREATE VIEW restitution.a_traiter AS
SELECT 'facture_a_decider'::text AS type, f.id AS reference_id,
       coalesce(f.numero, f.fichier_nom) AS objet, fo.raison_sociale AS fournisseur,
       f.montant_ttc AS montant, f.statut AS detail, f.modifie_le AS depuis
FROM public.factures f
LEFT JOIN public.fournisseurs fo ON fo.id = f.fournisseur_id
WHERE f.statut IN ('a_valider', 'anomalie', 'bloquee')
UNION ALL
SELECT 'rapprochement_a_confirmer', p.id, l.libelle, NULL, l.debit, p.cas, p.cree_le
FROM public.propositions_rapprochement p
JOIN public.lignes_releve l ON l.id = p.ligne_releve_id
WHERE p.statut = 'propose'
UNION ALL
SELECT 'signalement_ouvert', s.id, l.libelle, NULL, l.debit, s.type, s.cree_le
FROM public.signalements_paiement s
JOIN public.lignes_releve l ON l.id = s.ligne_releve_id
WHERE s.statut = 'ouvert'
UNION ALL
SELECT 'demande_referentiel', d.id, d.type_demande, fo.raison_sociale, NULL, NULL, d.demande_le
FROM public.demandes_referentiel d
LEFT JOIN public.fournisseurs fo ON fo.id = d.fournisseur_id
WHERE NOT EXISTS (SELECT 1 FROM public.decisions_referentiel r WHERE r.demande_id = d.id);
COMMENT ON VIEW restitution.a_traiter IS
    'Factures à décider, rapprochements à confirmer, signalements ouverts, demandes sur le référentiel en attente.';

-- 3. Droits : lecture des vues de restitution, rien d'autre. -------------------
GRANT USAGE ON SCHEMA restitution TO mizan_lecture;
GRANT SELECT ON ALL TABLES IN SCHEMA restitution TO mizan_lecture;

-- migrate:down

REVOKE ALL ON ALL TABLES IN SCHEMA restitution FROM mizan_lecture;
REVOKE USAGE ON SCHEMA restitution FROM mizan_lecture;
DROP SCHEMA restitution CASCADE;
GRANT USAGE ON SCHEMA public TO PUBLIC;
ALTER ROLE mizan_lecture RESET ALL;
-- Le rôle lui-même (commun à toutes les bases du serveur) est conservé.
