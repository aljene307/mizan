-- migrate:up

-- Situation de paiement (D-065) : une facture dont un paiement figure au
-- relevé mais attend encore une confirmation humaine n'est plus montrée « en
-- retard ». Nouvel état « paiement_propose » et montant proposé. Constat de la
-- démonstration du 2026-10-08 (D023 et D024 affichées en retard).
DROP VIEW situation_paiement;
CREATE VIEW situation_paiement AS
SELECT f.id AS facture_id, f.numero, f.fournisseur_id, f.statut, f.date_echeance, f.devise, f.montant_ttc,
       coalesce(av.impute, 0) AS avoirs_imputes,
       coalesce(pa.paye, 0) AS regle,
       f.montant_ttc - coalesce(pa.paye, 0) AS reste_a_payer,
       coalesce(pr.propose, 0) AS paiement_propose,
       CASE
           WHEN f.montant_ttc - coalesce(pa.paye, 0) < 0 THEN 'payee_en_trop'
           WHEN f.montant_ttc - coalesce(pa.paye, 0) = 0 THEN 'payee'
           -- Reste à payer, mais un paiement du relevé attend une confirmation.
           WHEN coalesce(pr.propose, 0) > 0 THEN 'paiement_propose'
           WHEN coalesce(pa.paye, 0) > 0 THEN 'partiellement_payee'
           ELSE 'non_payee'
       END AS etat,
       (f.date_echeance < current_date AND f.montant_ttc - coalesce(pa.paye, 0) > 0
        AND coalesce(pr.propose, 0) = 0) AS en_retard
FROM factures f
LEFT JOIN LATERAL (
    SELECT sum(r2.montant_affecte) AS impute FROM rapprochements r1
    JOIN rapprochements r2 ON r2.proposition_id = r1.proposition_id AND r2.role = 'imputation_avoir' AND r2.statut = 'confirme'
    WHERE r1.facture_id = f.id AND r1.role = 'reglement' AND r1.statut = 'confirme') av ON TRUE
LEFT JOIN LATERAL (
    SELECT sum(r.montant_affecte) AS paye FROM rapprochements r
    WHERE r.facture_id = f.id AND r.role = 'reglement' AND r.statut = 'confirme') pa ON TRUE
LEFT JOIN LATERAL (
    SELECT sum(r.montant_affecte) AS propose FROM rapprochements r
    WHERE r.facture_id = f.id AND r.role = 'reglement' AND r.statut = 'propose') pr ON TRUE
WHERE f.type_document = 'facture' AND f.statut IN ('conforme', 'validee');

GRANT SELECT ON situation_paiement TO mizan_app;

-- migrate:down

DROP VIEW situation_paiement;
CREATE VIEW situation_paiement AS
SELECT f.id AS facture_id, f.numero, f.fournisseur_id, f.statut, f.date_echeance, f.devise, f.montant_ttc,
       coalesce(av.impute, 0) AS avoirs_imputes,
       coalesce(pa.paye, 0) AS regle,
       f.montant_ttc - coalesce(pa.paye, 0) AS reste_a_payer,
       CASE
           WHEN coalesce(pa.paye, 0) = 0 THEN 'non_payee'
           WHEN f.montant_ttc - coalesce(pa.paye, 0) > 0 THEN 'partiellement_payee'
           WHEN f.montant_ttc - coalesce(pa.paye, 0) = 0 THEN 'payee'
           ELSE 'payee_en_trop'
       END AS etat,
       (f.date_echeance < current_date AND f.montant_ttc - coalesce(pa.paye, 0) > 0) AS en_retard
FROM factures f
LEFT JOIN LATERAL (
    SELECT sum(r2.montant_affecte) AS impute FROM rapprochements r1
    JOIN rapprochements r2 ON r2.proposition_id = r1.proposition_id AND r2.role = 'imputation_avoir' AND r2.statut = 'confirme'
    WHERE r1.facture_id = f.id AND r1.role = 'reglement' AND r1.statut = 'confirme') av ON TRUE
LEFT JOIN LATERAL (
    SELECT sum(r.montant_affecte) AS paye FROM rapprochements r
    WHERE r.facture_id = f.id AND r.role = 'reglement' AND r.statut = 'confirme') pa ON TRUE
WHERE f.type_document = 'facture' AND f.statut IN ('conforme', 'validee');
GRANT SELECT ON situation_paiement TO mizan_app;
