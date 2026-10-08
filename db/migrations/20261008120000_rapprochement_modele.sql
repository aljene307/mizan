-- migrate:up

-- Rapprochement bancaire (D-065) : import du relevé avec contrôle des soldes,
-- catégories d'opérations reconnues, propositions d'appariement (une
-- proposition peut régler plusieurs factures et imputer des avoirs),
-- signalements, décisions humaines tracées, situation de paiement calculée.
-- Seules les factures APPROUVÉES (conforme, validee — D-021) sont rapprochées.

-- 1. Paramètres. ----------------------------------------------------------------
INSERT INTO parametres_controle (cle, valeur, unite, libelle, valide_du, justification) VALUES
    ('rapprochement.tolerance_ecart', 5, 'TND', 'Écart toléré entre un paiement et le montant dû', '2026-01-01',
     'D-065 (C1) : au-delà, paiement partiel ou alerte ; en deçà, écart proposé avec un motif à qualifier.'),
    ('rapprochement.fenetre_jours', 180, 'jours', 'Délai maximal entre la date de facture et le paiement', '2026-01-01',
     'D-065 : au-delà, la facture n''est pas candidate.');

-- 2. Catégories d'opérations reconnues (lignes sans facture). --------------------
-- LIMITE (D-065) : une sortie frauduleuse dont le libellé imite une catégorie
-- connue n'est pas signalée. À réduire plus tard : montant habituel par
-- catégorie (colonnes prévues), fréquence attendue, bénéficiaire connu.
CREATE TABLE categories_operations (
    code              TEXT PRIMARY KEY,
    libelle           TEXT    NOT NULL,
    sens              TEXT    NOT NULL,
    -- Expression régulière (syntaxe JavaScript), ancrée au début du libellé.
    motif             TEXT    NOT NULL,
    -- Prévu pour réduire la limite ci-dessus ; non utilisé à ce stade.
    montant_habituel  NUMERIC(15,3),
    ecart_admis_pct   NUMERIC(5,2),
    actif             BOOLEAN NOT NULL DEFAULT TRUE,
    justification     TEXT    NOT NULL,
    CONSTRAINT categories_operations_sens_ck CHECK (sens IN ('debit', 'credit')),
    CONSTRAINT categories_operations_motif_ck CHECK (motif LIKE '^%')
);

INSERT INTO categories_operations (code, libelle, sens, motif, justification) VALUES
    ('loyer', 'Loyer des locaux', 'debit', '^PRLV LOYER\b', 'Prélèvement mensuel connu'),
    ('salaires', 'Salaires', 'debit', '^VIREMENT SALAIRES\b', 'Virement mensuel des salaires'),
    ('frais_tenue', 'Frais de tenue de compte', 'debit', '^FRAIS TENUE DE COMPTE\b', 'Frais bancaires mensuels'),
    ('commission_virement', 'Commission sur virement', 'debit', '^COMMISSION SUR VIREMENT\b', 'Frais bancaires par virement'),
    ('encaissement_client', 'Encaissement client', 'credit', '^VIR RECU\b', 'Les encaissements ne concernent pas les factures fournisseurs');

-- 3. Relevé : solde par ligne (contrôle d'intégrité), catégorie, rapprochement.
ALTER TABLE lignes_releve
    ADD COLUMN solde     NUMERIC(15,3),
    ADD COLUMN categorie TEXT REFERENCES categories_operations (code);
ALTER TABLE releves_bancaires ADD COLUMN rapproche_le TIMESTAMPTZ;

-- 4. Propositions d'appariement (une par ligne de relevé et hypothèse). ---------
CREATE TABLE propositions_rapprochement (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ligne_releve_id BIGINT        NOT NULL REFERENCES lignes_releve (id),
    cas             TEXT          NOT NULL,
    score           NUMERIC(5,4)  NOT NULL,
    raisons         JSONB         NOT NULL DEFAULT '[]',
    -- Montant de la ligne − montant dû (règlements − avoirs imputés).
    ecart           NUMERIC(15,3) NOT NULL DEFAULT 0,
    methode         TEXT          NOT NULL,
    statut          TEXT          NOT NULL,
    motif_ecart     TEXT,
    cree_le         TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT propositions_rapprochement_cas_ck CHECK (cas IN ('exact', 'groupe', 'partiel', 'net_avoir', 'ecart')),
    CONSTRAINT propositions_rapprochement_score_ck CHECK (score BETWEEN 0 AND 1),
    CONSTRAINT propositions_rapprochement_methode_ck CHECK (methode IN ('auto', 'manuel')),
    CONSTRAINT propositions_rapprochement_statut_ck CHECK (statut IN ('propose', 'confirme', 'rejete')),
    CONSTRAINT propositions_rapprochement_motif_ck CHECK (motif_ecart IN (
        'frais_bancaires', 'arrondi', 'retenue_source', 'escompte', 'autre'))
);
-- Une seule proposition ouverte ou confirmée par ligne.
CREATE UNIQUE INDEX propositions_rapprochement_ligne_uk ON propositions_rapprochement (ligne_releve_id)
    WHERE statut <> 'rejete';

ALTER TABLE rapprochements
    ADD COLUMN proposition_id BIGINT REFERENCES propositions_rapprochement (id),
    -- reglement : la ligne paie la facture ; imputation_avoir : l'avoir est déduit.
    ADD COLUMN role TEXT NOT NULL DEFAULT 'reglement',
    ADD CONSTRAINT rapprochements_role_ck CHECK (role IN ('reglement', 'imputation_avoir'));
CREATE INDEX rapprochements_proposition_ix ON rapprochements (proposition_id);

-- 5. Signalements. ----------------------------------------------------------------
CREATE TABLE signalements_paiement (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    type            TEXT        NOT NULL,
    ligne_releve_id BIGINT      NOT NULL REFERENCES lignes_releve (id),
    facture_id      BIGINT      REFERENCES factures (id),
    message         TEXT        NOT NULL,
    detail          JSONB       NOT NULL DEFAULT '{}',
    statut          TEXT        NOT NULL DEFAULT 'ouvert',
    cree_le         TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT signalements_paiement_type_ck CHECK (type IN ('payee_non_approuvee', 'sortie_sans_facture')),
    CONSTRAINT signalements_paiement_statut_ck CHECK (statut IN ('ouvert', 'classe'))
);
CREATE UNIQUE INDEX signalements_paiement_uk ON signalements_paiement (type, ligne_releve_id, coalesce(facture_id, 0));

-- 6. Décisions humaines (ajout seul) : même discipline que D-056. ------------------
CREATE TABLE decisions_rapprochement (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    proposition_id BIGINT      NOT NULL REFERENCES propositions_rapprochement (id),
    decision       TEXT        NOT NULL,
    motif_ecart    TEXT,
    utilisateur_id BIGINT      NOT NULL REFERENCES utilisateurs (id),
    justification  TEXT        NOT NULL,
    canal          TEXT,
    decide_le      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT decisions_rapprochement_decision_ck CHECK (decision IN ('confirmer', 'rejeter'))
);
CREATE TABLE decisions_signalement (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    signalement_id BIGINT      NOT NULL UNIQUE REFERENCES signalements_paiement (id),
    utilisateur_id BIGINT      NOT NULL REFERENCES utilisateurs (id),
    justification  TEXT        NOT NULL,
    canal          TEXT,
    decide_le      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TRIGGER decisions_rapprochement_pas_de_modification BEFORE UPDATE OR DELETE ON decisions_rapprochement
    FOR EACH ROW EXECUTE FUNCTION refuser_modification();
CREATE TRIGGER decisions_rapprochement_pas_de_vidage BEFORE TRUNCATE ON decisions_rapprochement
    FOR EACH STATEMENT EXECUTE FUNCTION refuser_modification();
CREATE TRIGGER decisions_signalement_pas_de_modification BEFORE UPDATE OR DELETE ON decisions_signalement
    FOR EACH ROW EXECUTE FUNCTION refuser_modification();
CREATE TRIGGER decisions_signalement_pas_de_vidage BEFORE TRUNCATE ON decisions_signalement
    FOR EACH STATEMENT EXECUTE FUNCTION refuser_modification();

-- Confirmer ou rejeter une proposition : validateur ou responsable (aucun
-- argent ne bouge) ; écart non nul confirmé : motif obligatoire (MZ043) ;
-- factures encore approuvées (MZ041) ; proposition encore ouverte (MZ042).
CREATE FUNCTION decisions_rapprochement_verifier() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_prop propositions_rapprochement%ROWTYPE;
BEGIN
    SELECT * INTO v_prop FROM propositions_rapprochement WHERE id = NEW.proposition_id FOR UPDATE;
    PERFORM utilisateur_autorise(NEW.utilisateur_id, ARRAY['validateur', 'responsable']);
    PERFORM verifier_justification(NEW.justification);
    IF v_prop.statut <> 'propose' THEN
        RAISE EXCEPTION 'proposition % déjà %', v_prop.id, v_prop.statut USING ERRCODE = 'MZ042';
    END IF;
    IF NEW.decision = 'confirmer' THEN
        IF v_prop.ecart <> 0 AND NEW.motif_ecart IS NULL THEN
            RAISE EXCEPTION 'écart de % TND : motif obligatoire', v_prop.ecart USING ERRCODE = 'MZ043';
        END IF;
        IF EXISTS (SELECT 1 FROM rapprochements r JOIN factures f ON f.id = r.facture_id
                   WHERE r.proposition_id = v_prop.id AND f.statut NOT IN ('conforme', 'validee')) THEN
            RAISE EXCEPTION 'une facture de la proposition n''est plus approuvée' USING ERRCODE = 'MZ041';
        END IF;
    END IF;
    NEW.decide_le := now();
    RETURN NEW;
END;
$$;

-- Applique la décision. SECURITY DEFINER : le rôle applicatif n'écrit pas
-- directement dans les propositions ni les rapprochements.
CREATE FUNCTION decisions_rapprochement_appliquer() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_statut TEXT := CASE NEW.decision WHEN 'confirmer' THEN 'confirme' ELSE 'rejete' END;
BEGIN
    UPDATE propositions_rapprochement SET statut = v_statut, motif_ecart = NEW.motif_ecart WHERE id = NEW.proposition_id;
    UPDATE rapprochements SET statut = v_statut, methode = 'manuel', commentaire = NEW.justification
    WHERE proposition_id = NEW.proposition_id;
    INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_apres, commentaire)
    VALUES ('utilisateur:' || NEW.utilisateur_id, 'rapprochement.' || NEW.decision, 'propositions_rapprochement',
            NEW.proposition_id::text, NEW.canal,
            jsonb_build_object('statut', v_statut, 'motif_ecart', NEW.motif_ecart, 'decision_id', NEW.id),
            NEW.justification);
    RETURN NULL;
END;
$$;

CREATE TRIGGER decisions_rapprochement_verification BEFORE INSERT ON decisions_rapprochement
    FOR EACH ROW EXECUTE FUNCTION decisions_rapprochement_verifier();
CREATE TRIGGER decisions_rapprochement_application AFTER INSERT ON decisions_rapprochement
    FOR EACH ROW EXECUTE FUNCTION decisions_rapprochement_appliquer();

-- Classer un signalement : responsable seulement (possible fraude), justifié.
CREATE FUNCTION decisions_signalement_verifier() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM utilisateur_autorise(NEW.utilisateur_id, ARRAY['responsable']);
    PERFORM verifier_justification(NEW.justification);
    IF (SELECT statut FROM signalements_paiement WHERE id = NEW.signalement_id) <> 'ouvert' THEN
        RAISE EXCEPTION 'signalement déjà classé' USING ERRCODE = 'MZ042';
    END IF;
    NEW.decide_le := now();
    RETURN NEW;
END;
$$;

CREATE FUNCTION decisions_signalement_appliquer() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    UPDATE signalements_paiement SET statut = 'classe' WHERE id = NEW.signalement_id;
    INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_apres, commentaire)
    VALUES ('utilisateur:' || NEW.utilisateur_id, 'signalement_paiement.classe', 'signalements_paiement',
            NEW.signalement_id::text, NEW.canal, jsonb_build_object('decision_id', NEW.id), NEW.justification);
    RETURN NULL;
END;
$$;

CREATE TRIGGER decisions_signalement_verification BEFORE INSERT ON decisions_signalement
    FOR EACH ROW EXECUTE FUNCTION decisions_signalement_verifier();
CREATE TRIGGER decisions_signalement_application AFTER INSERT ON decisions_signalement
    FOR EACH ROW EXECUTE FUNCTION decisions_signalement_appliquer();

-- 7. Import d'un relevé, avec contrôle des soldes (MZ040). --------------------------
-- p : { banque, rib_compte, devise, date_debut, date_fin, solde_initial,
--       solde_final, fichier_nom, fichier_sha256, execution_n8n_id,
--       lignes: [{ numero_ligne, date_operation, date_valeur, libelle,
--                  reference, debit, credit, solde }] }.
-- Un fichier déjà importé n'est pas réimporté (nouveau = false).
CREATE FUNCTION enregistrer_releve(p JSONB) RETURNS TABLE (releve_id BIGINT, nouveau BOOLEAN)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_id     BIGINT;
    v_solde  NUMERIC := (p ->> 'solde_initial')::NUMERIC;
    v_ligne  JSONB;
BEGIN
    SELECT id INTO v_id FROM releves_bancaires WHERE fichier_sha256 = p ->> 'fichier_sha256';
    IF FOUND THEN
        RETURN QUERY SELECT v_id, FALSE;
        RETURN;
    END IF;
    -- Intégrité : chaque solde = solde précédent + crédit − débit ; solde final.
    FOR v_ligne IN SELECT l FROM jsonb_array_elements(p -> 'lignes') l ORDER BY (l ->> 'numero_ligne')::INTEGER LOOP
        v_solde := v_solde + coalesce((v_ligne ->> 'credit')::NUMERIC, 0) - coalesce((v_ligne ->> 'debit')::NUMERIC, 0);
        IF v_ligne ->> 'solde' IS NOT NULL AND (v_ligne ->> 'solde')::NUMERIC <> v_solde THEN
            RAISE EXCEPTION 'ligne % : solde % attendu, % lu', v_ligne ->> 'numero_ligne', v_solde, v_ligne ->> 'solde'
                USING ERRCODE = 'MZ040';
        END IF;
    END LOOP;
    IF p ->> 'solde_final' IS NOT NULL AND (p ->> 'solde_final')::NUMERIC <> v_solde THEN
        RAISE EXCEPTION 'solde final % attendu, % lu', v_solde, p ->> 'solde_final' USING ERRCODE = 'MZ040';
    END IF;

    INSERT INTO releves_bancaires (banque, rib_compte, devise, date_debut, date_fin, solde_initial, solde_final,
                                   fichier_nom, fichier_sha256)
    VALUES (p ->> 'banque', p ->> 'rib_compte', coalesce(p ->> 'devise', 'TND'), (p ->> 'date_debut')::DATE,
            (p ->> 'date_fin')::DATE, (p ->> 'solde_initial')::NUMERIC, (p ->> 'solde_final')::NUMERIC,
            p ->> 'fichier_nom', p ->> 'fichier_sha256')
    RETURNING id INTO v_id;
    INSERT INTO lignes_releve (releve_id, numero_ligne, date_operation, date_valeur, libelle, reference, debit, credit, solde)
    SELECT v_id, (l ->> 'numero_ligne')::INTEGER, (l ->> 'date_operation')::DATE, (l ->> 'date_valeur')::DATE,
           l ->> 'libelle', l ->> 'reference', coalesce((l ->> 'debit')::NUMERIC, 0), coalesce((l ->> 'credit')::NUMERIC, 0),
           (l ->> 'solde')::NUMERIC
    FROM jsonb_array_elements(p -> 'lignes') l;
    INSERT INTO journal_audit (acteur, action, entite, entite_id, donnees_apres, execution_n8n_id)
    VALUES ('n8n:releve', 'releve.importe', 'releves_bancaires', v_id::text,
            jsonb_build_object('fichier_nom', p ->> 'fichier_nom', 'lignes', jsonb_array_length(p -> 'lignes'),
                               'solde_final', p ->> 'solde_final'),
            p ->> 'execution_n8n_id');
    RETURN QUERY SELECT v_id, TRUE;
END;
$$;

-- 8. Contexte de l'appariement, en un document JSON (le code décide). ----------------
CREATE FUNCTION contexte_rapprochement(p_releve_id BIGINT) RETURNS JSONB
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'releve', (SELECT to_jsonb(r) FROM releves_bancaires r WHERE r.id = p_releve_id),
        -- Lignes pas encore traitées : sans catégorie, sans proposition ouverte
        -- ou confirmée, sans signalement.
        'lignes', (SELECT coalesce(jsonb_agg(to_jsonb(l) ORDER BY l.numero_ligne), '[]'::jsonb)
                   FROM lignes_releve l
                   WHERE l.releve_id = p_releve_id AND l.categorie IS NULL
                     AND NOT EXISTS (SELECT 1 FROM propositions_rapprochement x WHERE x.ligne_releve_id = l.id AND x.statut <> 'rejete')
                     AND NOT EXISTS (SELECT 1 FROM signalements_paiement s WHERE s.ligne_releve_id = l.id)),
        -- Propositions déjà rejetées : à ne pas reproposer telles quelles.
        'rejetees', (SELECT coalesce(jsonb_agg(jsonb_build_object('ligne_releve_id', x.ligne_releve_id,
                                         'factures', (SELECT jsonb_agg(r.facture_id ORDER BY r.facture_id) FROM rapprochements r WHERE r.proposition_id = x.id))), '[]'::jsonb)
                     FROM propositions_rapprochement x JOIN lignes_releve l ON l.id = x.ligne_releve_id
                     WHERE l.releve_id = p_releve_id AND x.statut = 'rejete'),
        'factures', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                         'id', f.id, 'statut', f.statut, 'type_document', f.type_document, 'numero', f.numero,
                         'numero_normalise', normaliser_numero_facture(f.numero), 'date_facture', f.date_facture,
                         'date_echeance', f.date_echeance, 'devise', f.devise, 'montant_ttc', f.montant_ttc,
                         'fournisseur_id', f.fournisseur_id, 'raison_sociale', coalesce(fo.raison_sociale, f.raison_sociale_lue),
                         'fichier_sha256', f.fichier_sha256,
                         'origine_numero', (SELECT e.donnees ->> 'facture_origine_numero' FROM extractions e
                                            WHERE e.facture_id = f.id AND e.resultat IN ('valide', 'reutilisee') ORDER BY e.id DESC LIMIT 1),
                         'deja_paye', (SELECT coalesce(sum(r.montant_affecte), 0) FROM rapprochements r
                                       WHERE r.facture_id = f.id AND r.statut = 'confirme' AND r.role = 'reglement'))
                         ORDER BY f.id), '[]'::jsonb)
                     FROM factures f LEFT JOIN fournisseurs fo ON fo.id = f.fournisseur_id
                     WHERE f.statut NOT IN ('recue', 'en_extraction', 'erreur_extraction') AND f.montant_ttc IS NOT NULL),
        'categories', (SELECT coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'sens', c.sens, 'motif', c.motif) ORDER BY c.code), '[]'::jsonb)
                       FROM categories_operations c WHERE c.actif),
        'parametres', parametres_controle_en_vigueur()
    );
$$;

-- 9. Enregistrement d'un passage de rapprochement. ---------------------------------------
-- p : { releve_id, execution_n8n_id,
--       categories: [{ ligne_releve_id, categorie }],
--       propositions: [{ ligne_releve_id, cas, score, raisons, ecart, auto,
--                        affectations: [{ facture_id, montant, role }] }],
--       signalements: [{ type, ligne_releve_id, facture_id, message, detail }] }.
-- Garanties : seules des factures approuvées reçoivent une affectation
-- (MZ041) ; une confirmation automatique n'est admise que pour un cas
-- « exact », une seule facture, sans écart (MZ044).
CREATE FUNCTION enregistrer_rapprochements(p JSONB) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_prop   JSONB;
    v_id     BIGINT;
    v_statut TEXT;
    v_bilan  JSONB;
BEGIN
    UPDATE lignes_releve l SET categorie = c ->> 'categorie'
    FROM jsonb_array_elements(coalesce(p -> 'categories', '[]'::jsonb)) c
    WHERE l.id = (c ->> 'ligne_releve_id')::BIGINT AND l.categorie IS NULL;

    FOR v_prop IN SELECT x FROM jsonb_array_elements(coalesce(p -> 'propositions', '[]'::jsonb)) x LOOP
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_prop -> 'affectations') a JOIN factures f ON f.id = (a ->> 'facture_id')::BIGINT
                   WHERE f.statut NOT IN ('conforme', 'validee')) THEN
            RAISE EXCEPTION 'ligne % : affectation à une facture non approuvée', v_prop ->> 'ligne_releve_id' USING ERRCODE = 'MZ041';
        END IF;
        v_statut := CASE WHEN (v_prop ->> 'auto')::BOOLEAN THEN 'confirme' ELSE 'propose' END;
        IF v_statut = 'confirme' AND (v_prop ->> 'cas' <> 'exact' OR jsonb_array_length(v_prop -> 'affectations') <> 1
                                      OR (v_prop ->> 'ecart')::NUMERIC <> 0) THEN
            RAISE EXCEPTION 'ligne % : confirmation automatique réservée au cas exact', v_prop ->> 'ligne_releve_id'
                USING ERRCODE = 'MZ044';
        END IF;
        INSERT INTO propositions_rapprochement (ligne_releve_id, cas, score, raisons, ecart, methode, statut)
        VALUES ((v_prop ->> 'ligne_releve_id')::BIGINT, v_prop ->> 'cas', (v_prop ->> 'score')::NUMERIC,
                coalesce(v_prop -> 'raisons', '[]'::jsonb), coalesce((v_prop ->> 'ecart')::NUMERIC, 0),
                CASE WHEN v_statut = 'confirme' THEN 'auto' ELSE 'manuel' END, v_statut)
        RETURNING id INTO v_id;
        INSERT INTO rapprochements (facture_id, ligne_releve_id, montant_affecte, methode, score, statut, ecart, cree_par, proposition_id, role)
        SELECT (a ->> 'facture_id')::BIGINT, (v_prop ->> 'ligne_releve_id')::BIGINT, (a ->> 'montant')::NUMERIC,
               CASE WHEN v_statut = 'confirme' THEN 'auto' ELSE 'manuel' END, (v_prop ->> 'score')::NUMERIC, v_statut,
               coalesce((v_prop ->> 'ecart')::NUMERIC, 0), 'n8n:rapprochement', v_id, coalesce(a ->> 'role', 'reglement')
        FROM jsonb_array_elements(v_prop -> 'affectations') a;
    END LOOP;

    INSERT INTO signalements_paiement (type, ligne_releve_id, facture_id, message, detail)
    SELECT s ->> 'type', (s ->> 'ligne_releve_id')::BIGINT, (s ->> 'facture_id')::BIGINT, s ->> 'message', coalesce(s -> 'detail', '{}'::jsonb)
    FROM jsonb_array_elements(coalesce(p -> 'signalements', '[]'::jsonb)) s
    ON CONFLICT DO NOTHING;

    UPDATE releves_bancaires SET rapproche_le = now() WHERE id = (p ->> 'releve_id')::BIGINT;
    v_bilan := jsonb_build_object(
        'categorisees', jsonb_array_length(coalesce(p -> 'categories', '[]'::jsonb)),
        'confirmees_auto', (SELECT count(*) FROM jsonb_array_elements(coalesce(p -> 'propositions', '[]'::jsonb)) x WHERE (x ->> 'auto')::BOOLEAN),
        'a_confirmer', (SELECT count(*) FROM jsonb_array_elements(coalesce(p -> 'propositions', '[]'::jsonb)) x WHERE NOT (x ->> 'auto')::BOOLEAN),
        'signalements', jsonb_array_length(coalesce(p -> 'signalements', '[]'::jsonb)));
    INSERT INTO journal_audit (acteur, action, entite, entite_id, donnees_apres, execution_n8n_id)
    VALUES ('n8n:rapprochement', 'releve.rapproche', 'releves_bancaires', p ->> 'releve_id', v_bilan, p ->> 'execution_n8n_id');
    RETURN v_bilan;
END;
$$;

-- 10. Situation de paiement, calculée (D, sous-choix 1). --------------------------------
-- Factures approuvées. Convention (celle du relevé synthétique) : une
-- affectation « reglement » porte le montant RÉGLÉ de la facture, avoir
-- compris ; l'avoir imputé est enregistré à part (« imputation_avoir ») et
-- explique que la sortie d'argent soit plus faible. Donc : réglé = somme des
-- règlements confirmés ; reste = TTC − réglé ; avoirs imputés : information.
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
    -- Avoirs imputés sur cette facture lors d'un paiement net.
    SELECT sum(r2.montant_affecte) AS impute FROM rapprochements r1
    JOIN rapprochements r2 ON r2.proposition_id = r1.proposition_id AND r2.role = 'imputation_avoir' AND r2.statut = 'confirme'
    WHERE r1.facture_id = f.id AND r1.role = 'reglement' AND r1.statut = 'confirme') av ON TRUE
LEFT JOIN LATERAL (
    SELECT sum(r.montant_affecte) AS paye FROM rapprochements r
    WHERE r.facture_id = f.id AND r.role = 'reglement' AND r.statut = 'confirme') pa ON TRUE
WHERE f.type_document = 'facture' AND f.statut IN ('conforme', 'validee');

-- 11. Droits (D-065). -----------------------------------------------------------------
-- Le rapprochement ne s'écrit que par les fonctions ci-dessus ; les décisions,
-- comme les autres (D-062), ne passeront que par un événement de canal.
REVOKE INSERT, UPDATE ON rapprochements, releves_bancaires, lignes_releve FROM mizan_app;
GRANT SELECT ON categories_operations, propositions_rapprochement, signalements_paiement,
    decisions_rapprochement, decisions_signalement, situation_paiement TO mizan_app;
REVOKE EXECUTE ON FUNCTION decisions_rapprochement_appliquer(), decisions_signalement_appliquer(),
    enregistrer_releve(JSONB), enregistrer_rapprochements(JSONB), contexte_rapprochement(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION enregistrer_releve(JSONB), enregistrer_rapprochements(JSONB), contexte_rapprochement(BIGINT) TO mizan_app;

-- migrate:down

GRANT INSERT, UPDATE ON rapprochements, releves_bancaires, lignes_releve TO mizan_app;
DROP VIEW situation_paiement;
DROP FUNCTION enregistrer_rapprochements(JSONB);
DROP FUNCTION contexte_rapprochement(BIGINT);
DROP FUNCTION enregistrer_releve(JSONB);
DROP TABLE decisions_signalement;
DROP TABLE decisions_rapprochement;
DROP FUNCTION decisions_signalement_appliquer();
DROP FUNCTION decisions_signalement_verifier();
DROP FUNCTION decisions_rapprochement_appliquer();
DROP FUNCTION decisions_rapprochement_verifier();
DROP TABLE signalements_paiement;
DROP INDEX rapprochements_proposition_ix;
ALTER TABLE rapprochements DROP CONSTRAINT rapprochements_role_ck, DROP COLUMN role, DROP COLUMN proposition_id;
DROP TABLE propositions_rapprochement;
ALTER TABLE releves_bancaires DROP COLUMN rapproche_le;
ALTER TABLE lignes_releve DROP COLUMN categorie, DROP COLUMN solde;
DROP TABLE categories_operations;
DELETE FROM parametres_controle WHERE cle IN ('rapprochement.tolerance_ecart', 'rapprochement.fenetre_jours');
