-- migrate:up

-- Ordres de paiement (D-068, C-a1, C-b1) et contrôle « sortie sans ordre ».
-- Mizan propose un lot d'ordres ; le RIB de chaque ordre est le RIB ACTIF DU
-- RÉFÉRENTIEL (D-058), copié avec la référence de sa ligne. Un responsable
-- approuve ou refuse le lot (décision en ajout seul, par un canal).

-- 1. Paramètres. ----------------------------------------------------------------------
-- ordres.fenetre_jours : sa date de début est la DATE DE MISE EN SERVICE du
-- contrôle « sortie sans ordre » ; avant elle, le paramètre n'existe pas et
-- aucune sortie n'est contrôlée (les paiements du premier relevé sont
-- antérieurs aux ordres).
INSERT INTO parametres_controle (cle, valeur, unite, libelle, valide_du, justification) VALUES
    ('ordres.horizon_jours', 7, 'jours', 'Un lot d''ordres reprend les échéances des N prochains jours (et les retards)', '2026-01-01',
     'D-068 : lot hebdomadaire ; valeur illustrative'),
    ('ordres.fenetre_jours', 30, 'jours', 'Délai maximal entre l''approbation d''un ordre et le débit au relevé', '2026-10-01',
     'D-068 : mise en service du contrôle « sortie sans ordre » au 2026-10-01, après le dernier relevé importé');

-- 2. Lots, ordres, décisions. ------------------------------------------------------------
CREATE TABLE lots_paiement (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    statut              TEXT        NOT NULL DEFAULT 'propose',
    echeances_jusqu_au  DATE        NOT NULL,
    propose_le          TIMESTAMPTZ NOT NULL DEFAULT now(),
    decide_le           TIMESTAMPTZ,
    execution_n8n_id    TEXT,
    CONSTRAINT lots_paiement_statut_ck CHECK (statut IN ('propose', 'approuve', 'refuse')),
    CONSTRAINT lots_paiement_decision_ck CHECK ((statut = 'propose') = (decide_le IS NULL))
);
-- Un seul lot en attente de décision à la fois.
CREATE UNIQUE INDEX lots_paiement_un_propose_uk ON lots_paiement ((TRUE)) WHERE statut = 'propose';

CREATE TABLE ordres_paiement (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lot_id              BIGINT        NOT NULL REFERENCES lots_paiement (id),
    facture_id          BIGINT        NOT NULL REFERENCES factures (id),
    fournisseur_id      BIGINT        NOT NULL REFERENCES fournisseurs (id),
    -- Ligne du référentiel d'où vient le RIB (D-058), et sa copie.
    fournisseur_rib_id  BIGINT        NOT NULL REFERENCES fournisseur_ribs (id),
    rib                 TEXT          NOT NULL,
    beneficiaire        TEXT          NOT NULL,
    montant             NUMERIC(15,3) NOT NULL,
    devise              CHAR(3)       NOT NULL DEFAULT 'TND',
    -- Motif transmis à la banque : il revient dans le libellé du relevé.
    reference           TEXT          NOT NULL,
    CONSTRAINT ordres_paiement_rib_ck CHECK (rib ~ '^\d{20}$'),
    CONSTRAINT ordres_paiement_montant_ck CHECK (montant > 0),
    CONSTRAINT ordres_paiement_devise_ck CHECK (devise = 'TND'),
    CONSTRAINT ordres_paiement_lot_facture_uk UNIQUE (lot_id, facture_id)
);
CREATE INDEX ordres_paiement_facture_ix ON ordres_paiement (facture_id);
CREATE TRIGGER ordres_paiement_pas_de_modification BEFORE UPDATE OR DELETE ON ordres_paiement
    FOR EACH ROW EXECUTE FUNCTION refuser_modification();
CREATE TRIGGER ordres_paiement_pas_de_vidage BEFORE TRUNCATE ON ordres_paiement
    FOR EACH STATEMENT EXECUTE FUNCTION refuser_modification();

CREATE TABLE decisions_lot_paiement (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lot_id         BIGINT      NOT NULL UNIQUE REFERENCES lots_paiement (id),
    decision       TEXT        NOT NULL,
    utilisateur_id BIGINT      NOT NULL REFERENCES utilisateurs (id),
    justification  TEXT        NOT NULL,
    canal          TEXT,
    decide_le      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT decisions_lot_paiement_decision_ck CHECK (decision IN ('approuver', 'refuser'))
);
CREATE TRIGGER decisions_lot_paiement_pas_de_modification BEFORE UPDATE OR DELETE ON decisions_lot_paiement
    FOR EACH ROW EXECUTE FUNCTION refuser_modification();
CREATE TRIGGER decisions_lot_paiement_pas_de_vidage BEFORE TRUNCATE ON decisions_lot_paiement
    FOR EACH STATEMENT EXECUTE FUNCTION refuser_modification();

-- 3. Ordres en cours. ----------------------------------------------------------------------
-- Un ordre approuvé reste « en cours » pendant ordres.fenetre_jours après son
-- approbation, pour le montant pas encore payé depuis (règlements confirmés
-- de la facture sur des opérations datées du jour de l'approbation ou après).
CREATE VIEW ordres_en_cours AS
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

-- Montant encore à ordonner pour une facture : reste à payer, moins un
-- paiement déjà au relevé (proposé), moins les ordres approuvés non échus.
CREATE FUNCTION montant_a_ordonner(p_facture_id BIGINT, p_sauf_lot BIGINT DEFAULT NULL) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT s.reste_a_payer - s.paiement_propose
           - coalesce((SELECT sum(e.reste_a_executer) FROM ordres_en_cours e
                       WHERE e.facture_id = s.facture_id AND current_date <= e.expire_le
                         AND e.lot_id IS DISTINCT FROM p_sauf_lot), 0)
    FROM situation_paiement s WHERE s.facture_id = p_facture_id;
$$;

-- 4. Proposition d'un lot (appelée par n8n). ---------------------------------------------
-- Factures approuvées en TND, à échéance dans l'horizon (ou en retard, ou sans
-- échéance), d'un fournisseur actif qui a un RIB actif ; montant à ordonner
-- positif. Un lot déjà en attente est renvoyé tel quel (nouveau = false).
CREATE FUNCTION proposer_lot_paiement(p JSONB) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_lot     lots_paiement%ROWTYPE;
    v_jusqu   DATE := current_date + parametre_controle('ordres.horizon_jours')::INTEGER;
    v_bilan   JSONB;
BEGIN
    SELECT * INTO v_lot FROM lots_paiement WHERE statut = 'propose';
    IF FOUND THEN
        RETURN jsonb_build_object('lot_id', v_lot.id, 'nouveau', FALSE);
    END IF;
    WITH candidats AS (
        SELECT s.facture_id, s.fournisseur_id, r.id AS rib_id, r.rib, fo.raison_sociale AS beneficiaire,
               montant_a_ordonner(s.facture_id) AS montant, 'FACT ' || s.numero AS reference
        FROM situation_paiement s
        JOIN fournisseurs fo ON fo.id = s.fournisseur_id AND fo.actif
        JOIN fournisseur_ribs r ON r.fournisseur_id = s.fournisseur_id AND r.valide_au IS NULL
        WHERE s.devise = 'TND' AND (s.date_echeance IS NULL OR s.date_echeance <= v_jusqu)
    ), retenus AS (SELECT * FROM candidats WHERE montant > 0
    ), lot AS (
        INSERT INTO lots_paiement (echeances_jusqu_au, execution_n8n_id)
        SELECT v_jusqu, p ->> 'execution_n8n_id' WHERE EXISTS (SELECT 1 FROM retenus)
        RETURNING *
    ), ordres AS (
        INSERT INTO ordres_paiement (lot_id, facture_id, fournisseur_id, fournisseur_rib_id, rib, beneficiaire, montant, reference)
        SELECT lot.id, x.facture_id, x.fournisseur_id, x.rib_id, x.rib, x.beneficiaire, x.montant, x.reference
        FROM retenus x CROSS JOIN lot
        RETURNING montant
    )
    SELECT jsonb_build_object('lot_id', (SELECT id FROM lot), 'nouveau', EXISTS (SELECT 1 FROM lot),
                              'ordres', (SELECT count(*) FROM ordres), 'total', (SELECT sum(montant) FROM ordres),
                              'echeances_jusqu_au', v_jusqu)
    INTO v_bilan;
    IF NOT (v_bilan ->> 'nouveau')::BOOLEAN THEN
        RETURN v_bilan;
    END IF;
    SELECT * INTO v_lot FROM lots_paiement WHERE id = (v_bilan ->> 'lot_id')::BIGINT;
    INSERT INTO journal_audit (acteur, action, entite, entite_id, donnees_apres, execution_n8n_id)
    VALUES ('n8n:ordres', 'lot_paiement.propose', 'lots_paiement', v_lot.id::text, v_bilan, p ->> 'execution_n8n_id');
    RETURN v_bilan;
END;
$$;

-- 5. Décision sur un lot : responsable seulement (C-a1), justifiée. -----------------------
-- À l'approbation, chaque ordre est revérifié (MZ051) : facture encore
-- approuvée, RIB encore actif au référentiel, montant encore dû. Sinon le lot
-- est à refuser ; le suivant reprendra les factures.
CREATE FUNCTION decisions_lot_paiement_verifier() RETURNS trigger
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

CREATE FUNCTION decisions_lot_paiement_appliquer() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_statut TEXT := CASE NEW.decision WHEN 'approuver' THEN 'approuve' ELSE 'refuse' END;
BEGIN
    UPDATE lots_paiement SET statut = v_statut, decide_le = NEW.decide_le WHERE id = NEW.lot_id;
    INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_apres, commentaire)
    VALUES ('utilisateur:' || NEW.utilisateur_id, 'lot_paiement.' || NEW.decision, 'lots_paiement', NEW.lot_id::text, NEW.canal,
            jsonb_build_object('statut', v_statut, 'decision_id', NEW.id,
                               'ordres', (SELECT count(*) FROM ordres_paiement WHERE lot_id = NEW.lot_id),
                               'total', (SELECT sum(montant) FROM ordres_paiement WHERE lot_id = NEW.lot_id)),
            NEW.justification);
    RETURN NULL;
END;
$$;

CREATE TRIGGER decisions_lot_paiement_verification BEFORE INSERT ON decisions_lot_paiement
    FOR EACH ROW EXECUTE FUNCTION decisions_lot_paiement_verifier();
CREATE TRIGGER decisions_lot_paiement_application AFTER INSERT ON decisions_lot_paiement
    FOR EACH ROW EXECUTE FUNCTION decisions_lot_paiement_appliquer();

-- 6. Contrôle « sortie sans ordre ». -------------------------------------------------------
-- À chaque règlement confirmé (automatiquement, par une décision ou, plus
-- tard, à la main), sur une opération datée de la mise en service ou après :
-- il faut un ordre approuvé de la même facture, approuvé au plus tard le jour
-- de l'opération, dans la fenêtre, et les règlements de la facture depuis
-- l'approbation ne doivent pas dépasser l'ordre (tolérance d'écart). Sinon un
-- signalement est ouvert pour le responsable. Le rapprochement, lui, reste
-- confirmé : l'argent est déjà parti. Limite : le relevé ne montre pas le
-- compte crédité ; on vérifie l'existence de l'ordre, pas le RIB (D-068).
ALTER TABLE signalements_paiement DROP CONSTRAINT signalements_paiement_type_ck,
    ADD CONSTRAINT signalements_paiement_type_ck CHECK (type IN ('payee_non_approuvee', 'sortie_sans_facture', 'sortie_sans_ordre'));

CREATE FUNCTION controler_ordre_reglement() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_ligne     lignes_releve%ROWTYPE;
    v_fenetre   NUMERIC;
    v_tolerance NUMERIC;
    v_facture   factures%ROWTYPE;
BEGIN
    SELECT * INTO v_ligne FROM lignes_releve WHERE id = NEW.ligne_releve_id;
    SELECT valeur INTO v_fenetre FROM parametres_controle
    WHERE cle = 'ordres.fenetre_jours' AND valide_du <= v_ligne.date_operation
      AND (valide_au IS NULL OR valide_au > v_ligne.date_operation);
    IF v_fenetre IS NULL THEN
        RETURN NULL;   -- opération antérieure à la mise en service
    END IF;
    v_tolerance := parametre_controle('rapprochement.tolerance_ecart', v_ligne.date_operation);
    IF EXISTS (
        SELECT 1 FROM ordres_paiement o JOIN lots_paiement l ON l.id = o.lot_id AND l.statut = 'approuve'
        WHERE o.facture_id = NEW.facture_id
          AND l.decide_le::date <= v_ligne.date_operation
          AND v_ligne.date_operation <= l.decide_le::date + v_fenetre::INTEGER
          AND (SELECT sum(r.montant_affecte) FROM rapprochements r JOIN lignes_releve lr ON lr.id = r.ligne_releve_id
               WHERE r.facture_id = o.facture_id AND r.role = 'reglement' AND r.statut = 'confirme'
                 AND lr.date_operation BETWEEN l.decide_le::date AND v_ligne.date_operation) <= o.montant + v_tolerance) THEN
        RETURN NULL;
    END IF;
    SELECT * INTO v_facture FROM factures WHERE id = NEW.facture_id;
    INSERT INTO signalements_paiement (type, ligne_releve_id, facture_id, message, detail)
    VALUES ('sortie_sans_ordre', NEW.ligne_releve_id, NEW.facture_id,
            format('paiement de %s TND pour la facture %s sans ordre de paiement approuvé correspondant',
                   NEW.montant_affecte, v_facture.numero),
            jsonb_build_object('montant', NEW.montant_affecte, 'date_operation', v_ligne.date_operation,
                               'ordres_de_la_facture', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                                   'ordre_id', o.id, 'montant', o.montant, 'lot_statut', l.statut, 'decide_le', l.decide_le) ORDER BY o.id), '[]'::jsonb)
                                   FROM ordres_paiement o JOIN lots_paiement l ON l.id = o.lot_id WHERE o.facture_id = NEW.facture_id)))
    ON CONFLICT DO NOTHING;
    RETURN NULL;
END;
$$;

CREATE TRIGGER rapprochements_controle_ordre
    AFTER INSERT OR UPDATE OF statut ON rapprochements
    FOR EACH ROW WHEN (NEW.statut = 'confirme' AND NEW.role = 'reglement')
    EXECUTE FUNCTION controler_ordre_reglement();

-- 7. Restitution : ordres de paiement (lecture seule, D-068). -------------------------------
CREATE VIEW restitution.ordres_paiement AS
SELECT o.lot_id, l.statut AS statut_lot, l.propose_le, l.decide_le, o.id AS ordre_id,
       o.facture_id, f.numero, o.fournisseur_id, o.beneficiaire,
       o.rib AS rib_paiement, o.montant, o.devise, o.reference,
       e.paye_depuis, e.reste_a_executer, e.expire_le
FROM public.ordres_paiement o
JOIN public.lots_paiement l ON l.id = o.lot_id
JOIN public.factures f ON f.id = o.facture_id
LEFT JOIN public.ordres_en_cours e ON e.ordre_id = o.id;
COMMENT ON VIEW restitution.ordres_paiement IS
    'Ordres de paiement par lot. rib_paiement : RIB actif du référentiel au moment du lot (D-058), jamais celui lu sur la facture.';
GRANT SELECT ON restitution.ordres_paiement TO mizan_lecture;

-- Relevés importés : période, soldes, avancement du rapprochement. Le solde
-- final du dernier relevé sert de solde initial au relevé de démonstration.
CREATE VIEW restitution.releves AS
SELECT r.id AS releve_id, r.banque, r.devise, r.date_debut, r.date_fin, r.solde_initial, r.solde_final,
       r.fichier_nom, r.importe_le, r.rapproche_le,
       (SELECT count(*) FROM public.lignes_releve l WHERE l.releve_id = r.id) AS operations,
       (SELECT count(*) FROM public.signalements_paiement s JOIN public.lignes_releve l ON l.id = s.ligne_releve_id
        WHERE l.releve_id = r.id AND s.statut = 'ouvert') AS signalements_ouverts
FROM public.releves_bancaires r;
COMMENT ON VIEW restitution.releves IS 'Relevés bancaires importés (le RIB du compte de l''entreprise n''est pas exposé).';
GRANT SELECT ON restitution.releves TO mizan_lecture;

-- 8. Droits. -------------------------------------------------------------------------------
-- n8n propose les lots par la fonction prévue ; les décisions ne passent que
-- par un événement de canal (D-062).
GRANT SELECT ON lots_paiement, ordres_paiement, decisions_lot_paiement, ordres_en_cours TO mizan_app;
REVOKE EXECUTE ON FUNCTION proposer_lot_paiement(JSONB), decisions_lot_paiement_appliquer(),
    controler_ordre_reglement() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION proposer_lot_paiement(JSONB) TO mizan_app;

-- migrate:down

DROP VIEW IF EXISTS restitution.releves;
DROP VIEW restitution.ordres_paiement;
DROP TRIGGER rapprochements_controle_ordre ON rapprochements;
DROP FUNCTION controler_ordre_reglement();
DELETE FROM signalements_paiement WHERE type = 'sortie_sans_ordre';
ALTER TABLE signalements_paiement DROP CONSTRAINT signalements_paiement_type_ck,
    ADD CONSTRAINT signalements_paiement_type_ck CHECK (type IN ('payee_non_approuvee', 'sortie_sans_facture'));
DROP TABLE decisions_lot_paiement;
DROP FUNCTION decisions_lot_paiement_appliquer();
DROP FUNCTION decisions_lot_paiement_verifier();
DROP FUNCTION proposer_lot_paiement(JSONB);
DROP FUNCTION montant_a_ordonner(BIGINT, BIGINT);
DROP VIEW ordres_en_cours;
DROP TABLE ordres_paiement;
DROP TABLE lots_paiement;
DELETE FROM parametres_controle WHERE cle IN ('ordres.horizon_jours', 'ordres.fenetre_jours');
