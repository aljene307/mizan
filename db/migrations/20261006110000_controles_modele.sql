-- migrate:up

-- Modèle des contrôles déterministes et de leurs suites humaines
-- (docs/decisions.md D-055, D-056) : statuts et transitions autorisées,
-- catalogue des règles, paramètres de contrôle, utilisateurs, décisions
-- humaines tracées, demandes de modification du référentiel (création de
-- fournisseur, changement de RIB) avec méthode de vérification et quatre yeux.

-- 1. Statuts de facture et transitions autorisées. ----------------------------
ALTER TABLE factures DROP CONSTRAINT factures_statut_ck;
ALTER TABLE factures ADD CONSTRAINT factures_statut_ck CHECK (statut IN (
    'recue', 'en_extraction', 'extraite', 'erreur_extraction',
    'en_controle', 'conforme', 'a_valider', 'anomalie', 'bloquee',
    'validee', 'rejetee'
));

-- Origine du rattachement au fournisseur : par les contrôles (matricule
-- reconnu) ou par une décision humaine (fournisseur probable confirmé, C1).
ALTER TABLE factures ADD COLUMN fournisseur_source TEXT;
ALTER TABLE factures ADD CONSTRAINT factures_fournisseur_source_ck
    CHECK (fournisseur_source IN ('controle', 'decision'));

CREATE INDEX factures_a_controler_ix ON factures (id) WHERE statut IN ('extraite', 'en_controle');

-- « systeme » : faite par un workflow ; « decision » : seulement à la suite
-- d'une décision humaine enregistrée dans la même transaction.
CREATE TABLE transitions_statut (
    de   TEXT NOT NULL,
    vers TEXT NOT NULL,
    par  TEXT NOT NULL,
    PRIMARY KEY (de, vers),
    CONSTRAINT transitions_statut_par_ck CHECK (par IN ('systeme', 'decision'))
);

INSERT INTO transitions_statut (de, vers, par) VALUES
    ('recue', 'en_extraction', 'systeme'),
    ('en_extraction', 'recue', 'systeme'),
    ('en_extraction', 'extraite', 'systeme'),
    ('en_extraction', 'erreur_extraction', 'systeme'),
    ('extraite', 'en_controle', 'systeme'),
    ('en_controle', 'extraite', 'systeme'),
    ('en_controle', 'conforme', 'systeme'),
    ('en_controle', 'a_valider', 'systeme'),
    ('en_controle', 'anomalie', 'systeme'),
    ('en_controle', 'bloquee', 'systeme'),
    ('a_valider', 'validee', 'decision'),
    ('a_valider', 'rejetee', 'decision'),
    ('a_valider', 'extraite', 'decision'),
    ('anomalie', 'validee', 'decision'),
    ('anomalie', 'rejetee', 'decision'),
    ('anomalie', 'extraite', 'decision'),
    ('bloquee', 'validee', 'decision'),
    ('bloquee', 'rejetee', 'decision'),
    ('bloquee', 'extraite', 'decision'),
    ('erreur_extraction', 'recue', 'decision'),
    ('erreur_extraction', 'rejetee', 'decision');

-- 2. Utilisateurs (validation humaine). Gérés par l'administrateur seulement.
CREATE TABLE utilisateurs (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nom         TEXT        NOT NULL,
    role        TEXT        NOT NULL,
    -- Rempli à l'étape 5 (validation par Telegram).
    telegram_id TEXT        UNIQUE,
    actif       BOOLEAN     NOT NULL DEFAULT TRUE,
    -- Compte de démonstration, clairement fictif.
    fictif      BOOLEAN     NOT NULL DEFAULT FALSE,
    cree_le     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT utilisateurs_role_ck CHECK (role IN ('validateur', 'responsable')),
    CONSTRAINT utilisateurs_nom_ck CHECK (btrim(nom) <> '')
);

-- 3. Catalogue des règles de contrôle. ----------------------------------------
-- Une règle non dérogeable ne peut pas être levée par une simple décision :
-- la facture est rejetée, ou corrigée puis contrôlée de nouveau.
CREATE TABLE regles_controle (
    regle       TEXT    PRIMARY KEY,
    libelle     TEXT    NOT NULL,
    derogeable  BOOLEAN NOT NULL,
    actif       BOOLEAN NOT NULL DEFAULT TRUE
);

INSERT INTO regles_controle (regle, libelle, derogeable) VALUES
    ('champs_obligatoires', 'Numéro, date, montants et matricule présents', TRUE),
    ('matricule_format', 'Matricule fiscal au format reconnu', TRUE),
    ('fournisseur_inconnu', 'Fournisseur présent dans le référentiel', TRUE),
    ('incoherence_identite', 'Matricule, RIB et raison sociale désignent le même fournisseur', FALSE),
    ('matricule_lecture_probable', 'Matricule inconnu mais très proche d''un matricule connu', TRUE),
    ('matricule_suffixe', 'Suffixe du matricule (code TVA, catégorie, établissement)', TRUE),
    ('rib_cle', 'Clé du RIB valide', TRUE),
    ('changement_rib', 'RIB identique au RIB actif du fournisseur', FALSE),
    ('identifiants_absents_du_texte', 'Identifiants extraits présents dans le texte source', TRUE),
    ('plusieurs_rib', 'Un seul RIB valide dans le texte source', TRUE),
    ('doublon_fichier', 'Fichier déjà reçu (même empreinte)', FALSE),
    ('doublon_numero', 'Facture déjà reçue (même fournisseur, type et numéro)', FALSE),
    ('doublon_probable', 'Facture probablement déjà reçue (montant et date identiques)', TRUE),
    ('coherence_lignes', 'Quantité × prix = montant de ligne ; somme des lignes = HT', TRUE),
    ('coherence_tva', 'TVA recalculée par taux', TRUE),
    ('coherence_ttc', 'HT + TVA + timbre = TTC', TRUE),
    ('droit_timbre', 'Droit de timbre attendu', TRUE),
    ('devise', 'Facture en dinars (TND)', TRUE),
    ('dates', 'Dates de facture et d''échéance plausibles', TRUE),
    ('avoir_origine', 'Facture d''origine d''un avoir connue', TRUE),
    ('signalements_extraction', 'Signalements des corrections par le code', TRUE),
    ('seuil_validation', 'TTC sous le seuil de validation', TRUE);

-- 4. Résultats de contrôle : passage, nouvelles valeurs, ajout seul. ----------
CREATE SEQUENCE passages_controle_seq;

ALTER TABLE resultats_controles
    -- Numéro du passage de contrôle : toutes les règles d'un passage le partagent.
    ADD COLUMN passage BIGINT NOT NULL,
    ADD CONSTRAINT resultats_controles_regle_fk FOREIGN KEY (regle) REFERENCES regles_controle (regle),
    ADD CONSTRAINT resultats_controles_passage_uk UNIQUE (passage, regle),
    DROP CONSTRAINT resultats_controles_resultat_ck,
    ADD CONSTRAINT resultats_controles_resultat_ck
        CHECK (resultat IN ('ok', 'anomalie', 'erreur', 'non_applicable')),
    DROP CONSTRAINT resultats_controles_gravite_ck,
    -- « validation » : facture saine mais soumise à validation (seuil).
    ADD CONSTRAINT resultats_controles_gravite_ck
        CHECK (gravite IN ('info', 'validation', 'avertissement', 'bloquant'));

CREATE INDEX resultats_controles_passage_ix ON resultats_controles (facture_id, passage DESC);

CREATE TRIGGER resultats_controles_pas_de_modification
    BEFORE UPDATE OR DELETE ON resultats_controles
    FOR EACH ROW EXECUTE FUNCTION refuser_modification();
CREATE TRIGGER resultats_controles_pas_de_vidage
    BEFORE TRUNCATE ON resultats_controles
    FOR EACH STATEMENT EXECUTE FUNCTION refuser_modification();

-- 5. Paramètres de contrôle datés (précision 3 de D-055). ----------------------
-- Modifiés par migration seulement, comme config_fiscale.
CREATE TABLE parametres_controle (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cle           TEXT          NOT NULL,
    valeur        NUMERIC(15,3) NOT NULL,
    unite         TEXT          NOT NULL,
    libelle       TEXT          NOT NULL,
    valide_du     DATE          NOT NULL,
    valide_au     DATE,
    justification TEXT          NOT NULL,
    cree_le       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT parametres_controle_unite_ck CHECK (unite IN ('TND', 'millimes', 'caracteres')),
    CONSTRAINT parametres_controle_valeur_ck CHECK (valeur >= 0),
    CONSTRAINT parametres_controle_periode_ck CHECK (valide_au IS NULL OR valide_au > valide_du),
    CONSTRAINT parametres_controle_sans_chevauchement EXCLUDE USING gist (
        cle WITH =,
        daterange(valide_du, valide_au, '[)') WITH &&
    )
);

INSERT INTO parametres_controle (cle, valeur, unite, libelle, valide_du, justification) VALUES
    ('seuil_validation_ttc', 20000, 'TND', 'Seuil de validation humaine (TTC)', '2026-01-01',
     'Provisoire (D-028) : seuil définitif à l''étape 5 ; les données synthétiques restent justes entre 15 000 et 40 000 TND.'),
    ('tolerance.ttc_millimes', 0, 'millimes', 'Écart toléré sur HT + TVA + timbre = TTC', '2026-01-01',
     'D-055, B2 : valeurs toutes imprimées, aucun arrondi à tolérer.'),
    ('tolerance.tva_millimes_par_ligne', 1, 'millimes', 'Écart toléré sur la TVA d''un taux, par ligne à ce taux', '2026-01-01',
     'D-055, B2 : TVA arrondie ligne à ligne ou par taux selon le fournisseur.'),
    ('tolerance.ligne_millimes', 1, 'millimes', 'Écart toléré sur quantité × prix unitaire', '2026-01-01',
     'D-055, B2 : prix unitaire imprimé arrondi.'),
    ('justification.longueur_min', 15, 'caracteres', 'Longueur minimale d''une justification', '2026-01-01',
     'D-056 : une justification doit dire pourquoi, pas seulement « ok ».');

-- Paramètres en vigueur à une date, sous forme { clé: valeur }.
CREATE FUNCTION parametres_controle_en_vigueur(p_date DATE DEFAULT current_date) RETURNS JSONB
LANGUAGE sql STABLE AS $$
    SELECT coalesce(jsonb_object_agg(cle, valeur), '{}'::jsonb)
    FROM parametres_controle
    WHERE valide_du <= p_date AND (valide_au IS NULL OR valide_au > p_date);
$$;

-- Un paramètre en vigueur ; erreur MZ017 s'il n'existe pas.
CREATE FUNCTION parametre_controle(p_cle TEXT, p_date DATE DEFAULT current_date) RETURNS NUMERIC
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v NUMERIC;
BEGIN
    v := (parametres_controle_en_vigueur(p_date) ->> p_cle)::NUMERIC;
    IF v IS NULL THEN
        RAISE EXCEPTION 'paramètre de contrôle « % » absent au %', p_cle, p_date USING ERRCODE = 'MZ017';
    END IF;
    RETURN v;
END;
$$;

-- 6. Décisions humaines sur une facture (ajout seul). --------------------------
-- Insérer une décision EST l'action : un déclencheur la vérifie (rôle,
-- justification, règles non dérogeables), change le statut de la facture et
-- l'écrit au journal d'audit, dans la même transaction.
CREATE TABLE decisions_humaines (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    facture_id      BIGINT      NOT NULL REFERENCES factures (id),
    utilisateur_id  BIGINT      NOT NULL REFERENCES utilisateurs (id),
    decision        TEXT        NOT NULL,
    -- Calculés par le déclencheur (valeurs fournies ignorées).
    statut_avant    TEXT,
    statut_apres    TEXT,
    passage_controle BIGINT,
    justification   TEXT        NOT NULL,
    -- Corrections apportées avec la décision ; seule clé admise pour
    -- l'instant : fournisseur_id (fournisseur probable confirmé, C1).
    corrections     JSONB       NOT NULL DEFAULT '{}',
    -- Décision créée automatiquement après une demande approuvée.
    demande_id      BIGINT,
    canal           TEXT,
    transaction_id  xid8,
    decide_le       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT decisions_humaines_decision_ck CHECK (decision IN (
        'valider', 'rejeter', 'renvoyer_aux_controles', 'relancer_extraction'
    )),
    CONSTRAINT decisions_humaines_corrections_ck CHECK (jsonb_typeof(corrections) = 'object')
);

CREATE INDEX decisions_humaines_facture_ix ON decisions_humaines (facture_id, id DESC);

CREATE TRIGGER decisions_humaines_pas_de_modification
    BEFORE UPDATE OR DELETE ON decisions_humaines
    FOR EACH ROW EXECUTE FUNCTION refuser_modification();
CREATE TRIGGER decisions_humaines_pas_de_vidage
    BEFORE TRUNCATE ON decisions_humaines
    FOR EACH STATEMENT EXECUTE FUNCTION refuser_modification();

-- Utilisateur actif ou erreur MZ012 ; rôle exigé ou erreur MZ014.
CREATE FUNCTION utilisateur_autorise(p_id BIGINT, p_roles TEXT[]) RETURNS utilisateurs
LANGUAGE plpgsql STABLE AS $$
DECLARE
    u utilisateurs%ROWTYPE;
BEGIN
    SELECT * INTO u FROM utilisateurs WHERE id = p_id;
    IF NOT FOUND OR NOT u.actif THEN
        RAISE EXCEPTION 'utilisateur % inconnu ou inactif', p_id USING ERRCODE = 'MZ012';
    END IF;
    IF NOT (u.role = ANY (p_roles)) THEN
        RAISE EXCEPTION 'rôle « % » insuffisant (attendu : %)', u.role, array_to_string(p_roles, ' ou ')
            USING ERRCODE = 'MZ014';
    END IF;
    RETURN u;
END;
$$;

-- Justification d'au moins justification.longueur_min caractères (MZ013).
CREATE FUNCTION verifier_justification(p_texte TEXT) RETURNS VOID
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF length(btrim(coalesce(p_texte, ''))) < parametre_controle('justification.longueur_min') THEN
        RAISE EXCEPTION 'justification obligatoire d''au moins % caractères',
            parametre_controle('justification.longueur_min') USING ERRCODE = 'MZ013';
    END IF;
END;
$$;

CREATE FUNCTION decisions_humaines_verifier() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_facture factures%ROWTYPE;
    v_roles   TEXT[] := ARRAY['validateur', 'responsable'];
    v_regles  TEXT;
BEGIN
    SELECT * INTO v_facture FROM factures WHERE id = NEW.facture_id FOR UPDATE;
    NEW.statut_avant := v_facture.statut;
    NEW.statut_apres := CASE NEW.decision
        WHEN 'valider' THEN 'validee'
        WHEN 'rejeter' THEN 'rejetee'
        WHEN 'renvoyer_aux_controles' THEN 'extraite'
        WHEN 'relancer_extraction' THEN 'recue'
    END;
    NEW.passage_controle := (SELECT max(passage) FROM resultats_controles WHERE facture_id = NEW.facture_id);
    NEW.transaction_id := pg_current_xact_id();
    NEW.decide_le := now();

    -- Sortie de « bloquee », renvoi aux contrôles, relance : responsable seulement.
    IF v_facture.statut = 'bloquee' OR NEW.decision IN ('renvoyer_aux_controles', 'relancer_extraction') THEN
        v_roles := ARRAY['responsable'];
    END IF;
    PERFORM utilisateur_autorise(NEW.utilisateur_id, v_roles);
    PERFORM verifier_justification(NEW.justification);

    IF NOT EXISTS (SELECT 1 FROM transitions_statut t
                   WHERE t.de = NEW.statut_avant AND t.vers = NEW.statut_apres AND t.par = 'decision') THEN
        RAISE EXCEPTION 'décision « % » impossible pour une facture au statut « % »', NEW.decision, NEW.statut_avant
            USING ERRCODE = 'MZ010';
    END IF;

    -- Règles non dérogeables : pas de validation, seulement rejet ou correction.
    IF NEW.decision = 'valider' THEN
        SELECT string_agg(r.regle, ', ' ORDER BY r.regle) INTO v_regles
        FROM resultats_controles r JOIN regles_controle c ON c.regle = r.regle
        WHERE r.facture_id = NEW.facture_id AND r.passage = NEW.passage_controle
          AND r.resultat IN ('anomalie', 'erreur') AND r.gravite = 'bloquant' AND NOT c.derogeable;
        IF v_regles IS NOT NULL THEN
            RAISE EXCEPTION 'règle(s) non dérogeable(s) : % ; rejeter ou corriger puis renvoyer aux contrôles', v_regles
                USING ERRCODE = 'MZ015';
        END IF;
    END IF;

    IF EXISTS (SELECT 1 FROM jsonb_object_keys(NEW.corrections) k WHERE k <> 'fournisseur_id')
       OR (NEW.corrections ? 'fournisseur_id' AND NEW.decision <> 'renvoyer_aux_controles') THEN
        RAISE EXCEPTION 'correction non admise : seule « fournisseur_id », avec un renvoi aux contrôles'
            USING ERRCODE = 'MZ016';
    END IF;
    IF NEW.corrections ? 'fournisseur_id' AND NOT EXISTS (
        SELECT 1 FROM fournisseurs WHERE id = (NEW.corrections ->> 'fournisseur_id')::BIGINT AND actif) THEN
        RAISE EXCEPTION 'fournisseur % inconnu ou inactif', NEW.corrections ->> 'fournisseur_id' USING ERRCODE = 'MZ016';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION decisions_humaines_appliquer() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE factures SET
        statut = NEW.statut_apres,
        reservee_le = NULL,
        fournisseur_id = CASE WHEN NEW.corrections ? 'fournisseur_id'
                              THEN (NEW.corrections ->> 'fournisseur_id')::BIGINT ELSE fournisseur_id END,
        fournisseur_source = CASE WHEN NEW.corrections ? 'fournisseur_id'
                                  THEN 'decision' ELSE fournisseur_source END
    WHERE id = NEW.facture_id;

    INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_avant, donnees_apres, commentaire)
    VALUES ('utilisateur:' || NEW.utilisateur_id, 'facture.decision.' || NEW.decision, 'factures', NEW.facture_id::text,
            NEW.canal, jsonb_build_object('statut', NEW.statut_avant),
            jsonb_build_object('statut', NEW.statut_apres, 'decision_id', NEW.id, 'passage_controle', NEW.passage_controle,
                               'corrections', NEW.corrections, 'demande_id', NEW.demande_id),
            NEW.justification);
    RETURN NULL;
END;
$$;

CREATE TRIGGER decisions_humaines_verification
    BEFORE INSERT ON decisions_humaines
    FOR EACH ROW EXECUTE FUNCTION decisions_humaines_verifier();
CREATE TRIGGER decisions_humaines_application
    AFTER INSERT ON decisions_humaines
    FOR EACH ROW EXECUTE FUNCTION decisions_humaines_appliquer();

-- 7. Garde des transitions de statut pour le rôle applicatif. -------------------
-- Toute transition absente de transitions_statut est refusée (MZ010). Une
-- transition « decision » exige une décision humaine enregistrée dans la même
-- transaction (MZ011). Limite (comme D-015) : l'administrateur de la base
-- n'est pas soumis à cette garde.
CREATE FUNCTION factures_garder_transition() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_par TEXT;
BEGIN
    IF NEW.statut IS NOT DISTINCT FROM OLD.statut OR current_user <> 'mizan_app' THEN
        RETURN NEW;
    END IF;
    SELECT par INTO v_par FROM transitions_statut WHERE de = OLD.statut AND vers = NEW.statut;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'transition de statut interdite : % → %', OLD.statut, NEW.statut USING ERRCODE = 'MZ010';
    END IF;
    IF v_par = 'decision' AND NOT EXISTS (
        SELECT 1 FROM decisions_humaines d
        WHERE d.facture_id = NEW.id AND d.statut_avant = OLD.statut AND d.statut_apres = NEW.statut
          AND d.transaction_id = pg_current_xact_id()) THEN
        RAISE EXCEPTION 'transition % → % réservée à une décision humaine enregistrée', OLD.statut, NEW.statut
            USING ERRCODE = 'MZ011';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER factures_garde_transition
    BEFORE UPDATE OF statut ON factures
    FOR EACH ROW EXECUTE FUNCTION factures_garder_transition();

-- 8. Demandes de modification du référentiel (ajout seul). ---------------------
-- Création d'un fournisseur ou changement de RIB : même discipline, car le
-- faux fournisseur et le faux RIB sont deux formes de la même fraude.
CREATE TABLE methodes_verification (
    code         TEXT PRIMARY KEY,
    type_demande TEXT NOT NULL,
    libelle      TEXT NOT NULL,
    CONSTRAINT methodes_verification_type_ck CHECK (type_demande IN ('creation_fournisseur', 'changement_rib'))
);

INSERT INTO methodes_verification (code, type_demande, libelle) VALUES
    ('rib_rappel_contact_connu', 'changement_rib',
     'Rappel du fournisseur à un contact déjà enregistré (jamais celui indiqué sur la facture ou la demande)'),
    ('rib_attestation_bancaire', 'changement_rib',
     'Attestation de RIB émise par la banque, vérifiée auprès du fournisseur par un contact déjà enregistré'),
    ('rib_courrier_signe_verifie', 'changement_rib',
     'Courrier signé du fournisseur, confirmé par un contact déjà enregistré'),
    ('creation_identifiant_fiscal_verifie', 'creation_fournisseur',
     'Matricule fiscal et raison sociale vérifiés auprès d''une source officielle'),
    ('creation_attestation_bancaire', 'creation_fournisseur',
     'Attestation de RIB émise par la banque au nom du fournisseur'),
    ('creation_contact_independant', 'creation_fournisseur',
     'Fournisseur joint par un contact trouvé indépendamment de la facture');

CREATE TABLE demandes_referentiel (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    type_demande   TEXT        NOT NULL,
    -- Changement de RIB : fournisseur concerné. Création : NULL.
    fournisseur_id BIGINT      REFERENCES fournisseurs (id),
    -- Facture à l'origine de la demande, renvoyée aux contrôles si approuvée.
    facture_id     BIGINT      REFERENCES factures (id),
    -- Création : raison_sociale, matricule_fiscal (forme courte), rib, banque,
    -- adresse. Changement : rib, banque.
    donnees        JSONB       NOT NULL,
    -- RIB actif au moment de la demande (changement de RIB).
    rib_actuel     TEXT,
    demande_par    BIGINT      NOT NULL REFERENCES utilisateurs (id),
    justification  TEXT        NOT NULL,
    demande_le     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT demandes_referentiel_type_ck CHECK (type_demande IN ('creation_fournisseur', 'changement_rib')),
    CONSTRAINT demandes_referentiel_fournisseur_ck
        CHECK ((type_demande = 'changement_rib') = (fournisseur_id IS NOT NULL))
);

CREATE TABLE decisions_referentiel (
    id                   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- Une seule décision par demande.
    demande_id           BIGINT      NOT NULL UNIQUE REFERENCES demandes_referentiel (id),
    decision             TEXT        NOT NULL,
    utilisateur_id       BIGINT      NOT NULL REFERENCES utilisateurs (id),
    methode_verification TEXT        REFERENCES methodes_verification (code),
    justification        TEXT        NOT NULL,
    decide_le            TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT decisions_referentiel_decision_ck CHECK (decision IN ('approuvee', 'refusee')),
    CONSTRAINT decisions_referentiel_methode_ck CHECK (decision = 'refusee' OR methode_verification IS NOT NULL)
);

CREATE TRIGGER demandes_referentiel_pas_de_modification
    BEFORE UPDATE OR DELETE ON demandes_referentiel
    FOR EACH ROW EXECUTE FUNCTION refuser_modification();
CREATE TRIGGER demandes_referentiel_pas_de_vidage
    BEFORE TRUNCATE ON demandes_referentiel
    FOR EACH STATEMENT EXECUTE FUNCTION refuser_modification();
CREATE TRIGGER decisions_referentiel_pas_de_modification
    BEFORE UPDATE OR DELETE ON decisions_referentiel
    FOR EACH ROW EXECUTE FUNCTION refuser_modification();
CREATE TRIGGER decisions_referentiel_pas_de_vidage
    BEFORE TRUNCATE ON decisions_referentiel
    FOR EACH STATEMENT EXECUTE FUNCTION refuser_modification();

-- Clé RIB : 97 − ((18 premiers chiffres × 100) mod 97), comme src/rib.js
-- (D-027). Utilisée seulement pour refuser un RIB faux dans le référentiel.
CREATE FUNCTION rib_cle_valide(p_rib TEXT) RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE AS $$
    SELECT p_rib ~ '^\d{20}$'
       AND lpad((97 - (left(p_rib, 18)::NUMERIC * 100) % 97)::TEXT, 2, '0') = right(p_rib, 2);
$$;

-- Erreurs : MZ012 (utilisateur), MZ013 (justification), MZ019 (données).
CREATE FUNCTION demandes_referentiel_verifier() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_rib TEXT := NEW.donnees ->> 'rib';
BEGIN
    PERFORM utilisateur_autorise(NEW.demande_par, ARRAY['validateur', 'responsable']);
    PERFORM verifier_justification(NEW.justification);
    NEW.demande_le := now();
    IF v_rib IS NOT NULL AND NOT rib_cle_valide(v_rib) THEN
        RAISE EXCEPTION 'RIB « % » invalide (20 chiffres, clé vérifiée)', v_rib USING ERRCODE = 'MZ019';
    END IF;
    IF NEW.type_demande = 'creation_fournisseur' THEN
        IF btrim(coalesce(NEW.donnees ->> 'raison_sociale', '')) = ''
           OR coalesce(NEW.donnees ->> 'matricule_fiscal', '') !~ '^\d{7}[A-Z]$' THEN
            RAISE EXCEPTION 'création : raison sociale et matricule fiscal court (7 chiffres + lettre) obligatoires'
                USING ERRCODE = 'MZ019';
        END IF;
        IF EXISTS (SELECT 1 FROM fournisseurs WHERE matricule_fiscal = NEW.donnees ->> 'matricule_fiscal') THEN
            RAISE EXCEPTION 'fournisseur % déjà présent dans le référentiel', NEW.donnees ->> 'matricule_fiscal'
                USING ERRCODE = 'MZ019';
        END IF;
    ELSE
        IF v_rib IS NULL THEN
            RAISE EXCEPTION 'changement de RIB : nouveau RIB obligatoire' USING ERRCODE = 'MZ019';
        END IF;
        NEW.rib_actuel := (SELECT rib FROM fournisseur_ribs WHERE fournisseur_id = NEW.fournisseur_id AND valide_au IS NULL);
        IF NEW.rib_actuel = v_rib THEN
            RAISE EXCEPTION 'le RIB demandé est déjà le RIB actif' USING ERRCODE = 'MZ019';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION demandes_referentiel_journaliser() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO journal_audit (acteur, action, entite, entite_id, donnees_apres, commentaire)
    VALUES ('utilisateur:' || NEW.demande_par, 'referentiel.demande.' || NEW.type_demande,
            'demandes_referentiel', NEW.id::text,
            jsonb_build_object('fournisseur_id', NEW.fournisseur_id, 'facture_id', NEW.facture_id,
                               'donnees', NEW.donnees, 'rib_actuel', NEW.rib_actuel),
            NEW.justification);
    RETURN NULL;
END;
$$;

CREATE TRIGGER demandes_referentiel_verification
    BEFORE INSERT ON demandes_referentiel
    FOR EACH ROW EXECUTE FUNCTION demandes_referentiel_verifier();
CREATE TRIGGER demandes_referentiel_journal
    AFTER INSERT ON demandes_referentiel
    FOR EACH ROW EXECUTE FUNCTION demandes_referentiel_journaliser();

-- Responsable, quatre yeux (MZ018), méthode du bon type (MZ019).
CREATE FUNCTION decisions_referentiel_verifier() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_demande demandes_referentiel%ROWTYPE;
BEGIN
    SELECT * INTO v_demande FROM demandes_referentiel WHERE id = NEW.demande_id;
    PERFORM utilisateur_autorise(NEW.utilisateur_id, ARRAY['responsable']);
    PERFORM verifier_justification(NEW.justification);
    IF NEW.utilisateur_id = v_demande.demande_par THEN
        RAISE EXCEPTION 'quatre yeux : la personne qui décide doit être différente de celle qui a demandé'
            USING ERRCODE = 'MZ018';
    END IF;
    IF NEW.methode_verification IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM methodes_verification
        WHERE code = NEW.methode_verification AND type_demande = v_demande.type_demande) THEN
        RAISE EXCEPTION 'méthode « % » inadaptée à une demande « % »', NEW.methode_verification, v_demande.type_demande
            USING ERRCODE = 'MZ019';
    END IF;
    NEW.decide_le := now();
    RETURN NEW;
END;
$$;

-- Applique une demande approuvée. SECURITY DEFINER : le rôle applicatif ne
-- peut plus écrire dans fournisseurs ni fournisseur_ribs (D-056) ; seule une
-- décision approuvée, vérifiée ci-dessus, modifie le référentiel.
CREATE FUNCTION decisions_referentiel_appliquer() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_demande     demandes_referentiel%ROWTYPE;
    v_fournisseur BIGINT;
    v_ancien      fournisseur_ribs%ROWTYPE;
    v_facture     BIGINT;
    v_texte       TEXT;
BEGIN
    SELECT * INTO v_demande FROM demandes_referentiel WHERE id = NEW.demande_id;
    v_texte := format('Demande n° %s (%s) %s : %s', v_demande.id, v_demande.type_demande,
                      CASE NEW.decision WHEN 'approuvee' THEN 'approuvée' ELSE 'refusée' END, NEW.justification);

    IF NEW.decision = 'approuvee' THEN
        IF v_demande.type_demande = 'creation_fournisseur' THEN
            INSERT INTO fournisseurs (raison_sociale, matricule_fiscal, adresse)
            VALUES (v_demande.donnees ->> 'raison_sociale', v_demande.donnees ->> 'matricule_fiscal',
                    v_demande.donnees ->> 'adresse')
            RETURNING id INTO v_fournisseur;
            IF v_demande.donnees ? 'rib' THEN
                INSERT INTO fournisseur_ribs (fournisseur_id, rib, banque, origine)
                VALUES (v_fournisseur, v_demande.donnees ->> 'rib', v_demande.donnees ->> 'banque', 'facture');
            END IF;
            INSERT INTO journal_audit (acteur, action, entite, entite_id, donnees_apres, commentaire)
            VALUES ('utilisateur:' || NEW.utilisateur_id, 'fournisseur.cree', 'fournisseurs', v_fournisseur::text,
                    jsonb_build_object('demande_id', v_demande.id, 'demande_par', v_demande.demande_par,
                                       'methode_verification', NEW.methode_verification, 'donnees', v_demande.donnees),
                    NEW.justification);
        ELSE
            v_fournisseur := v_demande.fournisseur_id;
            SELECT * INTO v_ancien FROM fournisseur_ribs
            WHERE fournisseur_id = v_fournisseur AND valide_au IS NULL FOR UPDATE;
            IF FOUND THEN
                IF v_ancien.valide_du >= current_date THEN
                    RAISE EXCEPTION 'le RIB actif date d''aujourd''hui : changement à refaire demain'
                        USING ERRCODE = 'MZ020';
                END IF;
                UPDATE fournisseur_ribs SET valide_au = current_date WHERE id = v_ancien.id;
            END IF;
            INSERT INTO fournisseur_ribs (fournisseur_id, rib, banque, origine)
            VALUES (v_fournisseur, v_demande.donnees ->> 'rib', v_demande.donnees ->> 'banque', 'facture');
            INSERT INTO journal_audit (acteur, action, entite, entite_id, donnees_avant, donnees_apres, commentaire)
            VALUES ('utilisateur:' || NEW.utilisateur_id, 'fournisseur.rib_modifie', 'fournisseurs', v_fournisseur::text,
                    jsonb_build_object('rib', v_ancien.rib),
                    jsonb_build_object('rib', v_demande.donnees ->> 'rib', 'demande_id', v_demande.id,
                                       'demande_par', v_demande.demande_par,
                                       'methode_verification', NEW.methode_verification),
                    NEW.justification);
        END IF;

        -- Renvoi aux contrôles : la facture de la demande et, pour un
        -- changement de RIB, les autres factures bloquées de ce fournisseur.
        FOR v_facture IN
            SELECT f.id FROM factures f
            WHERE f.statut IN ('bloquee', 'anomalie', 'a_valider')
              AND (f.id = v_demande.facture_id
                   OR (v_demande.type_demande = 'changement_rib' AND f.fournisseur_id = v_fournisseur
                       AND f.statut = 'bloquee'))
            ORDER BY f.id
        LOOP
            INSERT INTO decisions_humaines (facture_id, utilisateur_id, decision, justification, corrections, demande_id)
            VALUES (v_facture, NEW.utilisateur_id, 'renvoyer_aux_controles', v_texte,
                    CASE WHEN v_demande.type_demande = 'creation_fournisseur' AND v_facture = v_demande.facture_id
                         THEN jsonb_build_object('fournisseur_id', v_fournisseur) ELSE '{}'::jsonb END,
                    v_demande.id);
        END LOOP;
    ELSE
        INSERT INTO journal_audit (acteur, action, entite, entite_id, donnees_apres, commentaire)
        VALUES ('utilisateur:' || NEW.utilisateur_id, 'referentiel.demande_refusee', 'demandes_referentiel',
                v_demande.id::text, jsonb_build_object('demande_par', v_demande.demande_par), NEW.justification);
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER decisions_referentiel_verification
    BEFORE INSERT ON decisions_referentiel
    FOR EACH ROW EXECUTE FUNCTION decisions_referentiel_verifier();
CREATE TRIGGER decisions_referentiel_application
    AFTER INSERT ON decisions_referentiel
    FOR EACH ROW EXECUTE FUNCTION decisions_referentiel_appliquer();

-- 9. Droits du rôle applicatif (D-056). -----------------------------------------
-- Le référentiel ne se modifie plus que par une demande approuvée.
REVOKE INSERT, UPDATE ON fournisseurs, fournisseur_ribs FROM mizan_app;
GRANT SELECT ON transitions_statut, utilisateurs, regles_controle, parametres_controle,
    methodes_verification TO mizan_app;
GRANT SELECT, INSERT ON decisions_humaines, demandes_referentiel, decisions_referentiel TO mizan_app;
GRANT USAGE ON SEQUENCE passages_controle_seq TO mizan_app;

-- migrate:down

GRANT INSERT, UPDATE ON fournisseurs, fournisseur_ribs TO mizan_app;
DROP TABLE decisions_referentiel;
DROP TABLE demandes_referentiel;
DROP TABLE methodes_verification;
DROP FUNCTION decisions_referentiel_appliquer();
DROP FUNCTION decisions_referentiel_verifier();
DROP FUNCTION demandes_referentiel_journaliser();
DROP FUNCTION demandes_referentiel_verifier();
DROP FUNCTION rib_cle_valide(TEXT);
DROP TRIGGER factures_garde_transition ON factures;
DROP FUNCTION factures_garder_transition();
DROP TABLE decisions_humaines;
DROP FUNCTION decisions_humaines_appliquer();
DROP FUNCTION decisions_humaines_verifier();
DROP FUNCTION verifier_justification(TEXT);
DROP FUNCTION utilisateur_autorise(BIGINT, TEXT[]);
DROP FUNCTION parametre_controle(TEXT, DATE);
DROP FUNCTION parametres_controle_en_vigueur(DATE);
DROP TABLE parametres_controle;
DROP TRIGGER resultats_controles_pas_de_vidage ON resultats_controles;
DROP TRIGGER resultats_controles_pas_de_modification ON resultats_controles;
DROP INDEX resultats_controles_passage_ix;
ALTER TABLE resultats_controles
    DROP CONSTRAINT resultats_controles_gravite_ck,
    ADD CONSTRAINT resultats_controles_gravite_ck CHECK (gravite IN ('info', 'avertissement', 'bloquant')),
    DROP CONSTRAINT resultats_controles_resultat_ck,
    ADD CONSTRAINT resultats_controles_resultat_ck CHECK (resultat IN ('ok', 'anomalie', 'erreur')),
    DROP CONSTRAINT resultats_controles_passage_uk,
    DROP CONSTRAINT resultats_controles_regle_fk,
    DROP COLUMN passage;
DROP SEQUENCE passages_controle_seq;
DROP TABLE regles_controle;
DROP TABLE utilisateurs;
DROP TABLE transitions_statut;
DROP INDEX factures_a_controler_ix;
ALTER TABLE factures DROP CONSTRAINT factures_fournisseur_source_ck;
ALTER TABLE factures DROP COLUMN fournisseur_source;
ALTER TABLE factures DROP CONSTRAINT factures_statut_ck;
ALTER TABLE factures ADD CONSTRAINT factures_statut_ck CHECK (statut IN (
    'recue', 'en_extraction', 'extraite', 'erreur_extraction',
    'conforme', 'anomalie', 'bloquee',
    'validee', 'rejetee'
));
