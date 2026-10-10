-- migrate:up

-- Annulation d'un rapprochement confirmé (D-075, D-077) : contre-passation au
-- sens du résultat. Demandée par un responsable, approuvée par un AUTRE
-- responsable (quatre yeux), justifiée, tracée ; rien n'est effacé : la
-- proposition et ses affectations passent à l'état « annule ». La ligne du
-- relevé redevient « à rapprocher » ; tant qu'elle n'est pas de nouveau
-- traitée, la facture dont le règlement a été annulé est exclue des ordres de
-- paiement (protection demandée par Mohamed), et l'échéancier le dit.

-- 1. État « annule ». ---------------------------------------------------------------------
ALTER TABLE propositions_rapprochement DROP CONSTRAINT propositions_rapprochement_statut_ck,
    ADD CONSTRAINT propositions_rapprochement_statut_ck CHECK (statut IN ('propose', 'confirme', 'rejete', 'annule'));
ALTER TABLE rapprochements DROP CONSTRAINT rapprochements_statut_ck,
    ADD CONSTRAINT rapprochements_statut_ck CHECK (statut IN ('propose', 'confirme', 'rejete', 'annule'));
-- Une seule proposition active (ouverte ou confirmée) par ligne.
DROP INDEX propositions_rapprochement_ligne_uk;
CREATE UNIQUE INDEX propositions_rapprochement_ligne_uk ON propositions_rapprochement (ligne_releve_id)
    WHERE statut NOT IN ('rejete', 'annule');

-- 2. Demandes et décisions (ajout seul). ---------------------------------------------------
CREATE TABLE demandes_annulation (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    proposition_id BIGINT      NOT NULL REFERENCES propositions_rapprochement (id),
    demande_par    BIGINT      NOT NULL REFERENCES utilisateurs (id),
    justification  TEXT        NOT NULL,
    canal          TEXT,
    demande_le     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX demandes_annulation_proposition_ix ON demandes_annulation (proposition_id);
CREATE TABLE decisions_annulation (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    demande_id     BIGINT      NOT NULL UNIQUE REFERENCES demandes_annulation (id),
    decision       TEXT        NOT NULL,
    utilisateur_id BIGINT      NOT NULL REFERENCES utilisateurs (id),
    justification  TEXT        NOT NULL,
    canal          TEXT,
    decide_le      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT decisions_annulation_decision_ck CHECK (decision IN ('approuvee', 'refusee'))
);
CREATE TRIGGER demandes_annulation_pas_de_modification BEFORE UPDATE OR DELETE ON demandes_annulation
    FOR EACH ROW EXECUTE FUNCTION refuser_modification();
CREATE TRIGGER demandes_annulation_pas_de_vidage BEFORE TRUNCATE ON demandes_annulation
    FOR EACH STATEMENT EXECUTE FUNCTION refuser_modification();
CREATE TRIGGER decisions_annulation_pas_de_modification BEFORE UPDATE OR DELETE ON decisions_annulation
    FOR EACH ROW EXECUTE FUNCTION refuser_modification();
CREATE TRIGGER decisions_annulation_pas_de_vidage BEFORE TRUNCATE ON decisions_annulation
    FOR EACH STATEMENT EXECUTE FUNCTION refuser_modification();

-- Demande : responsable, justification, proposition confirmée, aucune autre
-- demande en attente pour elle.
CREATE FUNCTION demandes_annulation_verifier() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM utilisateur_autorise(NEW.demande_par, ARRAY['responsable']);
    PERFORM verifier_justification(NEW.justification);
    PERFORM 1 FROM propositions_rapprochement WHERE id = NEW.proposition_id FOR UPDATE;
    IF (SELECT statut FROM propositions_rapprochement WHERE id = NEW.proposition_id) IS DISTINCT FROM 'confirme' THEN
        RAISE EXCEPTION 'proposition % : seul un rapprochement confirmé peut être annulé', NEW.proposition_id USING ERRCODE = 'MZ042';
    END IF;
    IF EXISTS (SELECT 1 FROM demandes_annulation d WHERE d.proposition_id = NEW.proposition_id
               AND NOT EXISTS (SELECT 1 FROM decisions_annulation x WHERE x.demande_id = d.id)) THEN
        RAISE EXCEPTION 'proposition % : une demande d''annulation est déjà en attente', NEW.proposition_id USING ERRCODE = 'MZ042';
    END IF;
    NEW.demande_le := now();
    RETURN NEW;
END;
$$;
CREATE FUNCTION demandes_annulation_tracer() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_apres, commentaire)
    VALUES ('utilisateur:' || NEW.demande_par, 'rapprochement.annulation_demandee', 'propositions_rapprochement',
            NEW.proposition_id::text, NEW.canal, jsonb_build_object('demande_id', NEW.id), NEW.justification);
    RETURN NULL;
END;
$$;
CREATE TRIGGER demandes_annulation_verification BEFORE INSERT ON demandes_annulation
    FOR EACH ROW EXECUTE FUNCTION demandes_annulation_verifier();
CREATE TRIGGER demandes_annulation_trace AFTER INSERT ON demandes_annulation
    FOR EACH ROW EXECUTE FUNCTION demandes_annulation_tracer();

-- Décision : un AUTRE responsable (MZ018), justification, demande en attente,
-- proposition encore confirmée.
CREATE FUNCTION decisions_annulation_verifier() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_demande demandes_annulation%ROWTYPE;
BEGIN
    SELECT * INTO v_demande FROM demandes_annulation WHERE id = NEW.demande_id;
    PERFORM utilisateur_autorise(NEW.utilisateur_id, ARRAY['responsable']);
    PERFORM verifier_justification(NEW.justification);
    IF NEW.utilisateur_id = v_demande.demande_par THEN
        RAISE EXCEPTION 'quatre yeux : le demandeur ne peut pas décider de sa propre demande' USING ERRCODE = 'MZ018';
    END IF;
    PERFORM 1 FROM propositions_rapprochement WHERE id = v_demande.proposition_id FOR UPDATE;
    IF NEW.decision = 'approuvee'
       AND (SELECT statut FROM propositions_rapprochement WHERE id = v_demande.proposition_id) IS DISTINCT FROM 'confirme' THEN
        RAISE EXCEPTION 'proposition % : plus confirmée', v_demande.proposition_id USING ERRCODE = 'MZ042';
    END IF;
    NEW.decide_le := now();
    RETURN NEW;
END;
$$;
CREATE FUNCTION decisions_annulation_appliquer() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_demande demandes_annulation%ROWTYPE;
BEGIN
    SELECT * INTO v_demande FROM demandes_annulation WHERE id = NEW.demande_id;
    IF NEW.decision = 'approuvee' THEN
        UPDATE propositions_rapprochement SET statut = 'annule' WHERE id = v_demande.proposition_id;
        UPDATE rapprochements SET statut = 'annule' WHERE proposition_id = v_demande.proposition_id;
    END IF;
    INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_apres, commentaire)
    VALUES ('utilisateur:' || NEW.utilisateur_id,
            CASE NEW.decision WHEN 'approuvee' THEN 'rapprochement.annule' ELSE 'rapprochement.annulation_refusee' END,
            'propositions_rapprochement', v_demande.proposition_id::text, NEW.canal,
            jsonb_build_object('demande_id', v_demande.id, 'decision_id', NEW.id, 'demande_par', v_demande.demande_par,
                               'factures', (SELECT jsonb_agg(jsonb_build_object('facture_id', r.facture_id, 'role', r.role,
                                                    'montant', r.montant_affecte) ORDER BY r.id)
                                            FROM rapprochements r WHERE r.proposition_id = v_demande.proposition_id)),
            NEW.justification);
    RETURN NULL;
END;
$$;
CREATE TRIGGER decisions_annulation_verification BEFORE INSERT ON decisions_annulation
    FOR EACH ROW EXECUTE FUNCTION decisions_annulation_verifier();
CREATE TRIGGER decisions_annulation_application AFTER INSERT ON decisions_annulation
    FOR EACH ROW EXECUTE FUNCTION decisions_annulation_appliquer();

-- 3. La ligne redevient « à rapprocher ». ------------------------------------------------
-- Proposition rejetée OU annulée ; aucune proposition active ; aucun
-- signalement, hors « sortie sans ordre » (lié à un règlement, il reste
-- ouvert pour le responsable sans bloquer la ligne).
CREATE OR REPLACE VIEW lignes_a_rapprocher AS
SELECT l.id AS ligne_releve_id, l.releve_id, l.numero_ligne, l.date_operation, l.libelle, l.debit,
       (SELECT array_agg(DISTINCT r.facture_id ORDER BY r.facture_id) FROM propositions_rapprochement x
        JOIN rapprochements r ON r.proposition_id = x.id
        WHERE x.ligne_releve_id = l.id AND x.statut IN ('rejete', 'annule')) AS factures_rejetees,
       CASE WHEN EXISTS (SELECT 1 FROM propositions_rapprochement x WHERE x.ligne_releve_id = l.id AND x.statut = 'annule')
            THEN 'rapprochement annulé' ELSE 'proposition rejetée' END AS motif
FROM lignes_releve l
WHERE l.debit > 0 AND l.categorie IS NULL
  AND EXISTS (SELECT 1 FROM propositions_rapprochement x WHERE x.ligne_releve_id = l.id AND x.statut IN ('rejete', 'annule'))
  AND NOT EXISTS (SELECT 1 FROM propositions_rapprochement x WHERE x.ligne_releve_id = l.id AND x.statut NOT IN ('rejete', 'annule'))
  AND NOT EXISTS (SELECT 1 FROM signalements_paiement s WHERE s.ligne_releve_id = l.id AND s.type <> 'sortie_sans_ordre');

-- 4. Protection : facture bloquée pour les ordres tant que la ligne n'est pas retraitée.
CREATE VIEW factures_bloquees_ordres AS
SELECT DISTINCT r.facture_id, a.ligne_releve_id
FROM rapprochements r
JOIN lignes_a_rapprocher a ON a.ligne_releve_id = r.ligne_releve_id
WHERE r.statut = 'annule' AND r.role = 'reglement';

-- Montant à ordonner : nul pour une facture bloquée (elle sort des lots).
CREATE OR REPLACE FUNCTION montant_a_ordonner(p_facture_id BIGINT, p_sauf_lot BIGINT DEFAULT NULL) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN EXISTS (SELECT 1 FROM factures_bloquees_ordres b WHERE b.facture_id = s.facture_id) THEN 0
           ELSE s.reste_a_payer - s.paiement_propose
                - coalesce((SELECT sum(e.reste_a_executer) FROM ordres_en_cours e
                            WHERE e.facture_id = s.facture_id AND current_date <= e.expire_le
                              AND e.lot_id IS DISTINCT FROM p_sauf_lot), 0) END
    FROM situation_paiement s WHERE s.facture_id = p_facture_id;
$$;

-- Approbation d'un lot : motif explicite pour une facture bloquée.
CREATE OR REPLACE FUNCTION decisions_lot_paiement_verifier() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_lot     lots_paiement%ROWTYPE;
    v_motif   TEXT;
BEGIN
    SELECT * INTO v_lot FROM lots_paiement WHERE id = NEW.lot_id FOR UPDATE;
    PERFORM utilisateur_autorise(NEW.utilisateur_id, ARRAY['responsable']);
    PERFORM verifier_justification(NEW.justification);
    IF v_lot.statut <> 'propose' THEN
        RAISE EXCEPTION 'lot % déjà %', v_lot.id, v_lot.statut USING ERRCODE = 'MZ042';
    END IF;
    IF NEW.decision = 'approuver' THEN
        SELECT string_agg(format('%s (%s)', o.reference,
                   CASE WHEN f.statut NOT IN ('conforme', 'validee') THEN 'facture plus approuvée'
                        WHEN r.valide_au IS NOT NULL THEN 'RIB plus actif au référentiel'
                        WHEN EXISTS (SELECT 1 FROM factures_bloquees_ordres b WHERE b.facture_id = o.facture_id)
                            THEN 'rapprochement annulé, ligne à retraiter'
                        ELSE 'montant plus dû' END), ', ' ORDER BY o.id)
        INTO v_motif
        FROM ordres_paiement o JOIN factures f ON f.id = o.facture_id JOIN fournisseur_ribs r ON r.id = o.fournisseur_rib_id
        WHERE o.lot_id = v_lot.id
          AND (f.statut NOT IN ('conforme', 'validee') OR r.valide_au IS NOT NULL
               OR o.montant > coalesce(montant_a_ordonner(o.facture_id, v_lot.id), 0));
        IF v_motif IS NOT NULL THEN
            RAISE EXCEPTION 'lot % à refuser, ordres périmés : %', v_lot.id, v_motif USING ERRCODE = 'MZ051';
        END IF;
    END IF;
    NEW.decide_le := now();
    RETURN NEW;
END;
$$;

-- 5. Restitution : motif du blocage dans l'échéancier ; lignes et demandes « à traiter ».
CREATE OR REPLACE VIEW restitution.echeancier AS
SELECT s.facture_id, s.numero, s.fournisseur_id, fo.raison_sociale AS fournisseur,
       f.date_facture, s.date_echeance,
       date_trunc('week', s.date_echeance)::date AS semaine_echeance,
       s.devise, s.montant_ttc, s.avoirs_imputes, s.regle, s.reste_a_payer, s.paiement_propose,
       s.etat, s.en_retard,
       CASE WHEN s.en_retard THEN current_date - s.date_echeance END AS jours_de_retard,
       rib.rib AS rib_paiement,
       CASE WHEN EXISTS (SELECT 1 FROM public.factures_bloquees_ordres b WHERE b.facture_id = s.facture_id)
            THEN 'exclue des ordres : rapprochement annulé, ligne à retraiter' END AS blocage
FROM public.situation_paiement s
JOIN public.factures f ON f.id = s.facture_id
JOIN public.fournisseurs fo ON fo.id = s.fournisseur_id
LEFT JOIN public.fournisseur_ribs rib ON rib.fournisseur_id = s.fournisseur_id AND rib.valide_au IS NULL
WHERE s.reste_a_payer > 0;

CREATE OR REPLACE VIEW restitution.a_traiter AS
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
WHERE NOT EXISTS (SELECT 1 FROM public.decisions_referentiel r WHERE r.demande_id = d.id)
UNION ALL
SELECT 'ligne_a_rapprocher', a.ligne_releve_id, a.libelle, NULL, a.debit,
       a.motif || coalesce(' ; facture(s) exclue(s) des ordres : '
           || (SELECT string_agg(fx.numero, ', ' ORDER BY fx.numero) FROM public.factures_bloquees_ordres b
               JOIN public.factures fx ON fx.id = b.facture_id WHERE b.ligne_releve_id = a.ligne_releve_id), ''),
       a.date_operation::timestamptz
FROM public.lignes_a_rapprocher a
UNION ALL
SELECT 'annulation_a_approuver', d.id, l.libelle, NULL, l.debit, 'demandée le ' || to_char(d.demande_le, 'YYYY-MM-DD'), d.demande_le
FROM public.demandes_annulation d
JOIN public.propositions_rapprochement p ON p.id = d.proposition_id
JOIN public.lignes_releve l ON l.id = p.ligne_releve_id
WHERE NOT EXISTS (SELECT 1 FROM public.decisions_annulation x WHERE x.demande_id = d.id);

-- 6. Droits. --------------------------------------------------------------------------------
-- Demandes et décisions : par le canal seulement (D-062).
GRANT SELECT ON demandes_annulation, decisions_annulation, factures_bloquees_ordres TO mizan_app;
REVOKE EXECUTE ON FUNCTION demandes_annulation_tracer(), decisions_annulation_appliquer() FROM PUBLIC;

-- migrate:down

-- Ordre imposé par les dépendances entre vues.
DROP VIEW restitution.a_traiter;
DROP VIEW restitution.echeancier CASCADE;   -- emporte restitution.tresorerie_prevue, recréée plus bas

CREATE OR REPLACE FUNCTION decisions_lot_paiement_verifier() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_lot     lots_paiement%ROWTYPE;
    v_motif   TEXT;
BEGIN
    SELECT * INTO v_lot FROM lots_paiement WHERE id = NEW.lot_id FOR UPDATE;
    PERFORM utilisateur_autorise(NEW.utilisateur_id, ARRAY['responsable']);
    PERFORM verifier_justification(NEW.justification);
    IF v_lot.statut <> 'propose' THEN
        RAISE EXCEPTION 'lot % déjà %', v_lot.id, v_lot.statut USING ERRCODE = 'MZ042';
    END IF;
    IF NEW.decision = 'approuver' THEN
        SELECT string_agg(format('%s (%s)', o.reference,
                   CASE WHEN f.statut NOT IN ('conforme', 'validee') THEN 'facture plus approuvée'
                        WHEN r.valide_au IS NOT NULL THEN 'RIB plus actif au référentiel'
                        ELSE 'montant plus dû' END), ', ' ORDER BY o.id)
        INTO v_motif
        FROM ordres_paiement o JOIN factures f ON f.id = o.facture_id JOIN fournisseur_ribs r ON r.id = o.fournisseur_rib_id
        WHERE o.lot_id = v_lot.id
          AND (f.statut NOT IN ('conforme', 'validee') OR r.valide_au IS NOT NULL
               OR o.montant > coalesce(montant_a_ordonner(o.facture_id, v_lot.id), 0));
        IF v_motif IS NOT NULL THEN
            RAISE EXCEPTION 'lot % à refuser, ordres périmés : %', v_lot.id, v_motif USING ERRCODE = 'MZ051';
        END IF;
    END IF;
    NEW.decide_le := now();
    RETURN NEW;
END;
$$;
CREATE OR REPLACE FUNCTION montant_a_ordonner(p_facture_id BIGINT, p_sauf_lot BIGINT DEFAULT NULL) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT s.reste_a_payer - s.paiement_propose
           - coalesce((SELECT sum(e.reste_a_executer) FROM ordres_en_cours e
                       WHERE e.facture_id = s.facture_id AND current_date <= e.expire_le
                         AND e.lot_id IS DISTINCT FROM p_sauf_lot), 0)
    FROM situation_paiement s WHERE s.facture_id = p_facture_id;
$$;
DROP VIEW factures_bloquees_ordres;

-- La colonne « motif » ne peut pas être retirée par CREATE OR REPLACE.
DROP VIEW lignes_a_rapprocher;
CREATE VIEW lignes_a_rapprocher AS
SELECT l.id AS ligne_releve_id, l.releve_id, l.numero_ligne, l.date_operation, l.libelle, l.debit,
       (SELECT array_agg(DISTINCT r.facture_id ORDER BY r.facture_id) FROM propositions_rapprochement x
        JOIN rapprochements r ON r.proposition_id = x.id
        WHERE x.ligne_releve_id = l.id AND x.statut = 'rejete') AS factures_rejetees
FROM lignes_releve l
WHERE l.debit > 0 AND l.categorie IS NULL
  AND EXISTS (SELECT 1 FROM propositions_rapprochement x WHERE x.ligne_releve_id = l.id AND x.statut = 'rejete')
  AND NOT EXISTS (SELECT 1 FROM propositions_rapprochement x WHERE x.ligne_releve_id = l.id AND x.statut <> 'rejete')
  AND NOT EXISTS (SELECT 1 FROM signalements_paiement s WHERE s.ligne_releve_id = l.id);
GRANT SELECT ON lignes_a_rapprocher TO mizan_app;

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
WHERE NOT EXISTS (SELECT 1 FROM public.decisions_referentiel r WHERE r.demande_id = d.id)
UNION ALL
SELECT 'ligne_a_rapprocher', a.ligne_releve_id, a.libelle, NULL, a.debit, 'proposition rejetée', a.date_operation::timestamptz
FROM public.lignes_a_rapprocher a;
COMMENT ON VIEW restitution.a_traiter IS
    'Factures à décider, rapprochements à confirmer, signalements ouverts, demandes sur le référentiel en attente.';
GRANT SELECT ON restitution.echeancier, restitution.tresorerie_prevue, restitution.a_traiter TO mizan_lecture;

DROP TABLE decisions_annulation;
DROP TABLE demandes_annulation;
DROP FUNCTION decisions_annulation_appliquer();
DROP FUNCTION decisions_annulation_verifier();
DROP FUNCTION demandes_annulation_tracer();
DROP FUNCTION demandes_annulation_verifier();
UPDATE rapprochements SET statut = 'confirme' WHERE statut = 'annule';
UPDATE propositions_rapprochement SET statut = 'confirme' WHERE statut = 'annule';
DROP INDEX propositions_rapprochement_ligne_uk;
CREATE UNIQUE INDEX propositions_rapprochement_ligne_uk ON propositions_rapprochement (ligne_releve_id) WHERE statut <> 'rejete';
ALTER TABLE rapprochements DROP CONSTRAINT rapprochements_statut_ck,
    ADD CONSTRAINT rapprochements_statut_ck CHECK (statut IN ('propose', 'confirme', 'rejete'));
ALTER TABLE propositions_rapprochement DROP CONSTRAINT propositions_rapprochement_statut_ck,
    ADD CONSTRAINT propositions_rapprochement_statut_ck CHECK (statut IN ('propose', 'confirme', 'rejete'));
