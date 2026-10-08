\restrict dbmate

-- Dumped from database version 18.6 (Debian 18.6-1.pgdg13+2)
-- Dumped by pg_dump version 18.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: btree_gist; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;


--
-- Name: EXTENSION btree_gist; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION btree_gist IS 'support for indexing common datatypes in GiST';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id bigint NOT NULL,
    canal text NOT NULL,
    utilisateur_id bigint NOT NULL,
    objet text NOT NULL,
    facture_id bigint,
    demande_id bigint,
    statut_facture text,
    passage_controle bigint,
    actions jsonb NOT NULL,
    contenu jsonb NOT NULL,
    jeton_empreinte character(64) NOT NULL,
    etat text DEFAULT 'a_envoyer'::text NOT NULL,
    reference_canal text,
    erreur text,
    cree_le timestamp with time zone DEFAULT now() NOT NULL,
    envoyee_le timestamp with time zone,
    expire_le timestamp with time zone NOT NULL,
    CONSTRAINT notifications_actions_ck CHECK ((jsonb_typeof(actions) = 'array'::text)),
    CONSTRAINT notifications_canal_ck CHECK ((canal = 'telegram'::text)),
    CONSTRAINT notifications_etat_ck CHECK ((etat = ANY (ARRAY['a_envoyer'::text, 'envoyee'::text, 'echec'::text]))),
    CONSTRAINT notifications_objet_ck CHECK ((((objet = 'facture'::text) AND (facture_id IS NOT NULL) AND (demande_id IS NULL)) OR ((objet = 'demande'::text) AND (demande_id IS NOT NULL))))
);


--
-- Name: appliquer_action(public.notifications, jsonb, bigint, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.appliquer_action(p_notif public.notifications, p_action jsonb, p_utilisateur bigint, p_texte text, p_canal text) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_code    TEXT := p_action ->> 'code';
    v_params  JSONB := coalesce(p_action -> 'params', '{}'::jsonb);
    v_facture factures%ROWTYPE;
    v_id      BIGINT;
BEGIN
    SELECT * INTO v_facture FROM factures WHERE id = p_notif.facture_id;
    IF v_code IN ('valider', 'rejeter', 'renvoyer_aux_controles', 'confirmer_fournisseur') THEN
        INSERT INTO decisions_humaines (facture_id, utilisateur_id, decision, justification, corrections, canal)
        VALUES (p_notif.facture_id, p_utilisateur,
                CASE v_code WHEN 'valider' THEN 'valider' WHEN 'rejeter' THEN 'rejeter' ELSE 'renvoyer_aux_controles' END,
                p_texte,
                CASE WHEN v_code = 'confirmer_fournisseur'
                     THEN jsonb_build_object('fournisseur_id', (v_params ->> 'fournisseur_id')::BIGINT) ELSE '{}'::jsonb END,
                p_canal)
        RETURNING id INTO v_id;
    ELSIF v_code = 'demander_changement_rib' THEN
        INSERT INTO demandes_referentiel (type_demande, fournisseur_id, facture_id, donnees, demande_par, justification, canal)
        VALUES ('changement_rib', v_facture.fournisseur_id, v_facture.id, jsonb_build_object('rib', v_params ->> 'rib'),
                p_utilisateur, p_texte, p_canal)
        RETURNING id INTO v_id;
    ELSIF v_code = 'demander_creation_fournisseur' THEN
        INSERT INTO demandes_referentiel (type_demande, facture_id, donnees, demande_par, justification, canal)
        VALUES ('creation_fournisseur', v_facture.id, v_params, p_utilisateur, p_texte, p_canal)
        RETURNING id INTO v_id;
    ELSIF v_code IN ('approuver', 'refuser') THEN
        INSERT INTO decisions_referentiel (demande_id, decision, utilisateur_id, methode_verification, justification, canal)
        VALUES (p_notif.demande_id, CASE v_code WHEN 'approuver' THEN 'approuvee' ELSE 'refusee' END, p_utilisateur,
                v_params ->> 'methode_verification', p_texte, p_canal)
        RETURNING id INTO v_id;
    ELSE
        RAISE EXCEPTION 'action « % » inconnue', v_code USING ERRCODE = 'MZ032';
    END IF;
    RETURN v_id;
END;
$$;


--
-- Name: contexte_controles(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contexte_controles(p_facture_id bigint) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    f            factures%ROWTYPE;
    v_extraction JSONB;
    v_origine    TEXT;
BEGIN
    SELECT * INTO f FROM factures WHERE id = p_facture_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'facture % introuvable', p_facture_id USING ERRCODE = 'MZ002';
    END IF;

    -- Dernière extraction exploitable ; pour une réutilisation, les alertes
    -- et signalements sont ceux de l'extraction d'origine.
    SELECT jsonb_build_object(
               'id', e.id, 'resultat', e.resultat, 'reutilise_de', e.reutilise_de,
               'methode_lecture', s.methode_lecture, 'alertes_source', s.alertes_source,
               'verifications_source', s.verifications_source, 'signalements_code', s.signalements_code,
               'propositions', s.propositions,
               'facture_origine_numero', e.donnees ->> 'facture_origine_numero')
    INTO v_extraction
    FROM extractions e JOIN extractions s ON s.id = coalesce(e.reutilise_de, e.id)
    WHERE e.facture_id = f.id AND e.resultat IN ('valide', 'reutilisee')
    ORDER BY e.id DESC LIMIT 1;
    v_origine := v_extraction ->> 'facture_origine_numero';

    RETURN jsonb_build_object(
        'aujourd_hui', current_date,
        'facture', (to_jsonb(f) - 'extraction_brute')
                   || jsonb_build_object('numero_normalise', normaliser_numero_facture(f.numero)),
        'lignes', (SELECT coalesce(jsonb_agg(to_jsonb(l) ORDER BY l.numero_ligne), '[]'::jsonb)
                   FROM lignes_facture l WHERE l.facture_id = f.id),
        'extraction', v_extraction,
        'referentiel', (
            SELECT coalesce(jsonb_agg(jsonb_build_object(
                       'id', fo.id, 'raison_sociale', fo.raison_sociale,
                       'matricule_fiscal', fo.matricule_fiscal, 'actif', fo.actif,
                       'ribs', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                                    'rib', r.rib, 'valide_du', r.valide_du, 'valide_au', r.valide_au)
                                    ORDER BY r.valide_du), '[]'::jsonb)
                                FROM fournisseur_ribs r WHERE r.fournisseur_id = fo.id))
                       ORDER BY fo.id), '[]'::jsonb)
            FROM fournisseurs fo),
        -- Candidats doublons et facture d'origine d'un avoir : le code décide.
        'autres_factures', (
            SELECT coalesce(jsonb_agg(jsonb_build_object(
                       'id', c.id, 'statut', c.statut, 'fournisseur_id', c.fournisseur_id,
                       'matricule_fiscal_lu', c.matricule_fiscal_lu, 'type_document', c.type_document,
                       'numero', c.numero, 'numero_normalise', normaliser_numero_facture(c.numero),
                       'date_facture', c.date_facture, 'montant_ttc', c.montant_ttc,
                       'fichier_sha256', c.fichier_sha256, 'recue_le', c.recue_le)
                       ORDER BY c.id), '[]'::jsonb)
            FROM factures c
            WHERE c.id <> f.id
              AND (c.fichier_sha256 = f.fichier_sha256
                   OR normaliser_numero_facture(c.numero) = normaliser_numero_facture(f.numero)
                   OR normaliser_numero_facture(c.numero) = normaliser_numero_facture(v_origine)
                   OR (c.montant_ttc = f.montant_ttc AND c.date_facture = f.date_facture)
                   -- Historique du fournisseur (D-060) : mêmes 8 premiers caractères
                   -- alphanumériques du matricule lu (forme courte), ou même rattachement.
                   OR (f.matricule_fiscal_lu IS NOT NULL
                       AND left(regexp_replace(upper(c.matricule_fiscal_lu), '[^0-9A-Z]', '', 'g'), 8)
                         = left(regexp_replace(upper(f.matricule_fiscal_lu), '[^0-9A-Z]', '', 'g'), 8))
                   OR (f.fournisseur_id IS NOT NULL AND c.fournisseur_id = f.fournisseur_id))),
        -- Configuration fiscale en vigueur à la date de la facture (vide sans date).
        'config_fiscale', (
            SELECT coalesce(jsonb_object_agg(cle, jsonb_build_object(
                       'valeur', valeur, 'unite', unite, 'conditions', conditions, 'a_confirmer', a_confirmer)),
                   '{}'::jsonb)
            FROM config_fiscale
            WHERE valide_du <= f.date_facture AND (valide_au IS NULL OR valide_au > f.date_facture)),
        'parametres', parametres_controle_en_vigueur(),
        'regles', (SELECT jsonb_agg(jsonb_build_object('regle', regle, 'derogeable', derogeable) ORDER BY regle)
                   FROM regles_controle WHERE actif)
    );
END;
$$;


--
-- Name: creer_code_inscription(bigint, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.creer_code_inscription(p_utilisateur bigint, p_canal text, p_code text) RETURNS bigint
    LANGUAGE sql
    AS $$
    INSERT INTO codes_inscription (utilisateur_id, canal, code_empreinte, expire_le)
    VALUES (p_utilisateur, p_canal, encode(sha256(convert_to(p_code, 'UTF8')), 'hex'),
            now() + make_interval(mins => parametre_controle('inscription.validite_minutes')::INTEGER))
    RETURNING id;
$$;


--
-- Name: creer_notification(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.creer_notification(p jsonb) RETURNS TABLE(notification_id bigint, jeton text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    -- 32 caractères hexadécimaux (UUID v4, 122 bits aléatoires) : un bouton
    -- Telegram porte au plus 64 octets (jeton, séparateur et indice).
    v_jeton   TEXT := replace(gen_random_uuid()::text, '-', '');
    v_id      BIGINT;
    v_canal   TEXT := p ->> 'canal';
    v_facture factures%ROWTYPE;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM adresses_canal a JOIN utilisateurs u ON u.id = a.utilisateur_id
                   WHERE a.utilisateur_id = (p ->> 'utilisateur_id')::BIGINT AND a.canal = v_canal AND a.active AND u.actif) THEN
        RAISE EXCEPTION 'destinataire non inscrit sur le canal %', v_canal USING ERRCODE = 'MZ030';
    END IF;
    IF p ->> 'objet' = 'facture' THEN
        SELECT * INTO v_facture FROM factures WHERE id = (p ->> 'facture_id')::BIGINT;
        IF v_facture.statut IS DISTINCT FROM p ->> 'statut_facture' THEN
            RAISE EXCEPTION 'la facture n''est plus au statut notifié' USING ERRCODE = 'MZ031';
        END IF;
    END IF;
    IF jsonb_typeof(p -> 'actions') <> 'array' OR EXISTS (
        SELECT 1 FROM jsonb_array_elements(p -> 'actions') a
        WHERE a ->> 'code' NOT IN ('valider', 'rejeter', 'renvoyer_aux_controles', 'confirmer_fournisseur',
                                   'demander_changement_rib', 'demander_creation_fournisseur', 'approuver', 'refuser')) THEN
        RAISE EXCEPTION 'action inconnue dans la notification' USING ERRCODE = 'MZ032';
    END IF;
    INSERT INTO notifications (canal, utilisateur_id, objet, facture_id, demande_id, statut_facture, passage_controle,
                               actions, contenu, jeton_empreinte, expire_le)
    VALUES (v_canal, (p ->> 'utilisateur_id')::BIGINT, p ->> 'objet', (p ->> 'facture_id')::BIGINT,
            (p ->> 'demande_id')::BIGINT, p ->> 'statut_facture', (p ->> 'passage_controle')::BIGINT,
            p -> 'actions', p -> 'contenu', encode(sha256(convert_to(v_jeton, 'UTF8')), 'hex'),
            now() + make_interval(days => parametre_controle('notification.validite_jours')::INTEGER))
    RETURNING id INTO v_id;
    RETURN QUERY SELECT v_id, v_jeton;
END;
$$;


--
-- Name: decisions_humaines_appliquer(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.decisions_humaines_appliquer() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: decisions_humaines_verifier(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.decisions_humaines_verifier() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: decisions_referentiel_appliquer(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.decisions_referentiel_appliquer() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: decisions_referentiel_verifier(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.decisions_referentiel_verifier() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: demandes_referentiel_journaliser(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.demandes_referentiel_journaliser() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: demandes_referentiel_verifier(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.demandes_referentiel_verifier() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
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
$_$;


--
-- Name: donnees_notifications(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.donnees_notifications(p_canal text) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
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


--
-- Name: enregistrer_controles(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enregistrer_controles(p jsonb) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_facture     factures%ROWTYPE;
    v_passage     BIGINT;
    v_irregulieres TEXT;
    v_statut      TEXT;
    v_fournisseur BIGINT := (p ->> 'fournisseur_id')::BIGINT;
    v_bilan       JSONB;
BEGIN
    SELECT * INTO v_facture FROM factures WHERE id = (p ->> 'facture_id')::BIGINT FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'facture % introuvable', p ->> 'facture_id' USING ERRCODE = 'MZ002';
    END IF;
    IF v_facture.statut <> 'en_controle' THEN
        RAISE EXCEPTION 'facture % non réservée pour les contrôles (statut %)', v_facture.id, v_facture.statut
            USING ERRCODE = 'MZ003';
    END IF;

    SELECT string_agg(c.regle, ', ' ORDER BY c.regle) INTO v_irregulieres
    FROM regles_controle c
    WHERE c.actif AND (SELECT count(*) FROM jsonb_array_elements(coalesce(p -> 'resultats', '[]'::jsonb)) r
                       WHERE r ->> 'regle' = c.regle) <> 1;
    IF v_irregulieres IS NOT NULL THEN
        RAISE EXCEPTION 'passage incomplet ou en double pour : %', v_irregulieres USING ERRCODE = 'MZ021';
    END IF;

    v_passage := nextval('passages_controle_seq');
    INSERT INTO resultats_controles (facture_id, passage, regle, version_regle, resultat, gravite,
                                     message, detail, execution_n8n_id)
    SELECT v_facture.id, v_passage, r ->> 'regle', r ->> 'version_regle', r ->> 'resultat', r ->> 'gravite',
           r ->> 'message', coalesce(r -> 'detail', '{}'::jsonb), p ->> 'execution_n8n_id'
    FROM jsonb_array_elements(p -> 'resultats') r;

    SELECT CASE
               WHEN bool_or(resultat IN ('anomalie', 'erreur') AND gravite = 'bloquant') THEN 'bloquee'
               WHEN bool_or(resultat IN ('anomalie', 'erreur') AND gravite = 'avertissement') THEN 'anomalie'
               WHEN bool_or(resultat IN ('anomalie', 'erreur') AND gravite = 'validation') THEN 'a_valider'
               ELSE 'conforme'
           END,
           jsonb_build_object(
               'bloquant', count(*) FILTER (WHERE resultat IN ('anomalie', 'erreur') AND gravite = 'bloquant'),
               'avertissement', count(*) FILTER (WHERE resultat IN ('anomalie', 'erreur') AND gravite = 'avertissement'),
               'validation', count(*) FILTER (WHERE resultat IN ('anomalie', 'erreur') AND gravite = 'validation'),
               'regles_en_anomalie', coalesce(jsonb_agg(regle ORDER BY regle)
                                              FILTER (WHERE resultat IN ('anomalie', 'erreur') AND gravite <> 'info'),
                                              '[]'::jsonb))
    INTO v_statut, v_bilan
    FROM resultats_controles WHERE passage = v_passage;

    -- Un rattachement confirmé par une décision humaine n'est pas remplacé.
    UPDATE factures SET
        statut = v_statut,
        reservee_le = NULL,
        fournisseur_id = CASE WHEN fournisseur_source = 'decision' THEN fournisseur_id ELSE v_fournisseur END,
        fournisseur_source = CASE WHEN fournisseur_source = 'decision' THEN 'decision'
                                  WHEN v_fournisseur IS NULL THEN NULL ELSE 'controle' END
    WHERE id = v_facture.id;

    INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_avant, donnees_apres, execution_n8n_id)
    VALUES ('n8n:controles', 'facture.controlee', 'factures', v_facture.id::text, v_facture.canal_reception,
            jsonb_build_object('statut', v_facture.statut),
            jsonb_build_object('statut', v_statut, 'passage', v_passage) || v_bilan,
            p ->> 'execution_n8n_id');
    RETURN v_passage;
END;
$$;


--
-- Name: enregistrer_extraction(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enregistrer_extraction(p jsonb) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_facture   factures%ROWTYPE;
    v_source    extractions%ROWTYPE;
    v_id        BIGINT;
    v_resultat  TEXT := p ->> 'resultat';
    v_donnees   JSONB := p -> 'donnees';
    v_reussie   BOOLEAN := (p ->> 'resultat') IN ('valide', 'reutilisee');
    v_methode   TEXT := p ->> 'methode_lecture';
    v_alertes   JSONB := coalesce(p -> 'alertes_source', '[]'::jsonb);
    v_brutes    JSONB := p -> 'donnees_brutes';
    v_corrections  JSONB := p -> 'corrections_code';
    v_signalements JSONB := p -> 'signalements_code';
    v_propositions JSONB := p -> 'propositions';
    v_version      TEXT := p ->> 'version_chaine';
BEGIN
    SELECT * INTO v_facture FROM factures WHERE id = (p ->> 'facture_id')::BIGINT FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'facture % introuvable', p ->> 'facture_id' USING ERRCODE = 'MZ002';
    END IF;
    IF v_facture.statut <> 'en_extraction' THEN
        RAISE EXCEPTION 'facture % non réservée (statut %)', v_facture.id, v_facture.statut
            USING ERRCODE = 'MZ003';
    END IF;

    -- Une réutilisation reprend aussi la sortie brute, les corrections, les
    -- signalements et les propositions de l'extraction d'origine : une
    -- proposition de RIB ne doit pas disparaître pour un doublon.
    IF p ->> 'reutilise_de' IS NOT NULL THEN
        SELECT * INTO v_source FROM extractions WHERE id = (p ->> 'reutilise_de')::BIGINT;
        v_brutes       := coalesce(v_brutes, v_source.donnees_brutes);
        v_corrections  := coalesce(v_corrections, v_source.corrections_code);
        v_signalements := coalesce(v_signalements, v_source.signalements_code);
        v_propositions := coalesce(v_propositions, v_source.propositions);
        v_version      := coalesce(v_version, v_source.version_chaine);
    END IF;
    v_corrections  := coalesce(v_corrections, '[]'::jsonb);
    v_signalements := coalesce(v_signalements, '[]'::jsonb);
    v_propositions := coalesce(v_propositions, '[]'::jsonb);

    INSERT INTO extractions (
        facture_id, fichier_sha256, resultat, code_resultat, methode_lecture,
        fournisseur_llm, modele, version_prompt, empreinte_prompt, parametres_generation,
        duree_lecture_ms, duree_llm_ms, jetons_entree, jetons_sortie, jetons_reflexion, tentatives,
        donnees, erreurs, verifications_source, alertes_source, reutilise_de, execution_n8n_id, texte_source,
        donnees_brutes, corrections_code, signalements_code, propositions, version_chaine
    ) VALUES (
        v_facture.id, v_facture.fichier_sha256, v_resultat, p ->> 'code_resultat', v_methode,
        p ->> 'fournisseur_llm', p ->> 'modele', p ->> 'version_prompt', p ->> 'empreinte_prompt',
        p -> 'parametres_generation',
        (p ->> 'duree_lecture_ms')::INTEGER, (p ->> 'duree_llm_ms')::INTEGER,
        (p ->> 'jetons_entree')::INTEGER, (p ->> 'jetons_sortie')::INTEGER,
        (p ->> 'jetons_reflexion')::INTEGER, (p ->> 'tentatives')::INTEGER,
        v_donnees, coalesce(p -> 'erreurs', '[]'::jsonb),
        coalesce(p -> 'verifications_source', '[]'::jsonb), v_alertes,
        (p ->> 'reutilise_de')::BIGINT, p ->> 'execution_n8n_id', p ->> 'texte_source',
        v_brutes, v_corrections, v_signalements, v_propositions, v_version
    ) RETURNING id INTO v_id;

    IF v_reussie THEN
        UPDATE factures SET
            type_document       = v_donnees ->> 'type_document',
            numero              = v_donnees ->> 'numero',
            date_facture        = (v_donnees ->> 'date_facture')::DATE,
            date_echeance       = (v_donnees ->> 'date_echeance')::DATE,
            devise              = v_donnees ->> 'devise',
            montant_ht          = (v_donnees ->> 'montant_ht')::NUMERIC,
            montant_tva         = (v_donnees ->> 'montant_tva')::NUMERIC,
            droit_timbre        = (v_donnees ->> 'droit_timbre')::NUMERIC,
            montant_ttc         = (v_donnees ->> 'montant_ttc')::NUMERIC,
            matricule_fiscal_lu = v_donnees #>> '{fournisseur,matricule_fiscal}',
            raison_sociale_lue  = v_donnees #>> '{fournisseur,raison_sociale}',
            rib_facture         = v_donnees #>> '{fournisseur,rib}',
            methode_extraction  = CASE v_methode WHEN 'ocr' THEN 'ocr_llm' ELSE 'texte_llm' END,
            -- Sortie brute du modèle (avant corrections), si elle est connue.
            extraction_brute    = coalesce(v_brutes, v_donnees),
            statut              = 'extraite',
            reservee_le         = NULL
        WHERE id = v_facture.id;

        INSERT INTO lignes_facture (facture_id, numero_ligne, designation, quantite,
                                    prix_unitaire_ht, taux_tva, montant_ht)
        SELECT v_facture.id, l.rang::INTEGER, l.ligne ->> 'designation',
               (l.ligne ->> 'quantite')::NUMERIC, (l.ligne ->> 'prix_unitaire_ht')::NUMERIC,
               (l.ligne ->> 'taux_tva')::NUMERIC, (l.ligne ->> 'montant_ht')::NUMERIC
        FROM jsonb_array_elements(v_donnees -> 'lignes') WITH ORDINALITY AS l (ligne, rang);
    ELSE
        UPDATE factures SET statut = 'erreur_extraction', reservee_le = NULL,
                            extraction_brute = coalesce(v_brutes, v_donnees)
        WHERE id = v_facture.id;
    END IF;

    INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_avant, donnees_apres, execution_n8n_id)
    VALUES (
        'n8n:extraction',
        CASE
            WHEN v_resultat = 'valide' AND (jsonb_array_length(v_alertes) > 0
                 OR jsonb_array_length(v_signalements) > 0 OR jsonb_array_length(v_propositions) > 0)
                THEN 'facture.extraite_avec_alertes'
            WHEN v_resultat = 'valide' THEN 'facture.extraite'
            WHEN v_resultat = 'reutilisee' THEN 'facture.extraction_reutilisee'
            ELSE 'facture.erreur_extraction'
        END,
        'factures', v_facture.id::text, v_facture.canal_reception,
        jsonb_build_object('statut', v_facture.statut),
        jsonb_build_object('extraction_id', v_id, 'resultat', v_resultat,
                           'code_resultat', p ->> 'code_resultat', 'modele', p ->> 'modele',
                           'alertes_source', v_alertes, 'corrections_code', v_corrections,
                           'signalements_code', v_signalements, 'propositions', v_propositions,
                           'version_chaine', v_version),
        p ->> 'execution_n8n_id'
    );

    RETURN v_id;
END;
$$;


--
-- Name: enregistrer_reception(text, text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enregistrer_reception(p_canal text, p_reference text, p_format text, p_fichier_nom text, p_fichier_sha256 text, p_execution text DEFAULT NULL::text) RETURNS TABLE(facture_id bigint, nouvelle boolean)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id BIGINT;
BEGIN
    INSERT INTO factures (canal_reception, reference_source, format_source, fichier_nom, fichier_sha256)
    VALUES (p_canal, p_reference, p_format, p_fichier_nom, p_fichier_sha256)
    ON CONFLICT (canal_reception, (coalesce(reference_source, fichier_nom)), fichier_sha256) DO NOTHING
    RETURNING id INTO v_id;

    IF v_id IS NOT NULL THEN
        INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_apres, execution_n8n_id)
        VALUES ('n8n:reception', 'facture.recue', 'factures', v_id::text, p_canal,
                jsonb_build_object('fichier_nom', p_fichier_nom, 'fichier_sha256', p_fichier_sha256,
                                   'format_source', p_format),
                p_execution);
        RETURN QUERY SELECT v_id, TRUE;
    ELSE
        RETURN QUERY
            SELECT f.id, FALSE FROM factures f
            WHERE f.canal_reception = p_canal
              AND coalesce(f.reference_source, f.fichier_nom) = coalesce(p_reference, p_fichier_nom)
              AND f.fichier_sha256 = p_fichier_sha256;
    END IF;
END;
$$;


--
-- Name: extraction_valide_existante(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.extraction_valide_existante(p_fichier_sha256 text, p_version_chaine text) RETURNS TABLE(extraction_id bigint, donnees jsonb, methode_lecture text)
    LANGUAGE sql STABLE
    AS $$
    SELECT e.id, e.donnees, e.methode_lecture FROM extractions e
    WHERE e.fichier_sha256 = p_fichier_sha256 AND e.resultat = 'valide'
      AND e.version_chaine = p_version_chaine
    ORDER BY e.id DESC
    LIMIT 1;
$$;


--
-- Name: factures_garder_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.factures_garder_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: journal_audit_ajout_seul(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.journal_audit_ajout_seul() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION 'journal_audit est en ajout seul : % interdit', TG_OP
        USING ERRCODE = 'MZ001';
END;
$$;


--
-- Name: journal_audit_horodater(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.journal_audit_horodater() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.horodatage := now();
    RETURN NEW;
END;
$$;


--
-- Name: liberer_facture(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.liberer_facture(p_facture_id bigint) RETURNS boolean
    LANGUAGE sql
    AS $$
    WITH liberee AS (
        UPDATE factures SET statut = 'recue', reservee_le = NULL
        WHERE id = p_facture_id AND statut = 'en_extraction'
        RETURNING id
    )
    SELECT count(*) = 1 FROM liberee;
$$;


--
-- Name: maj_modifie_le(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.maj_modifie_le() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.modifie_le := now();
    RETURN NEW;
END;
$$;


--
-- Name: marquer_notification(bigint, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marquer_notification(p_id bigint, p_reference text, p_erreur text DEFAULT NULL::text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
    UPDATE notifications
    SET etat = CASE WHEN p_erreur IS NULL THEN 'envoyee' ELSE 'echec' END,
        reference_canal = p_reference, erreur = p_erreur,
        envoyee_le = CASE WHEN p_erreur IS NULL THEN now() END
    WHERE id = p_id AND etat = 'a_envoyer';
$$;


--
-- Name: normaliser_numero_facture(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.normaliser_numero_facture(numero text) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    RETURN upper(regexp_replace(numero, '[[:space:]]'::text, ''::text, 'g'::text));


--
-- Name: notifications_a_preparer(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notifications_a_preparer(p_canal text) RETURNS TABLE(objet text, facture_id bigint, demande_id bigint, utilisateur_id bigint, role text, statut_facture text, passage_controle bigint)
    LANGUAGE sql STABLE
    AS $$
    WITH destinataires AS (
        SELECT u.id, u.role FROM utilisateurs u
        JOIN adresses_canal a ON a.utilisateur_id = u.id AND a.canal = p_canal AND a.active
        WHERE u.actif),
    factures_en_attente AS (
        SELECT f.id, f.statut, (SELECT max(r.passage) FROM resultats_controles r WHERE r.facture_id = f.id) AS passage
        FROM factures f WHERE f.statut IN ('a_valider', 'anomalie', 'bloquee'))
    SELECT 'facture', fa.id, NULL::BIGINT, d.id, d.role, fa.statut, fa.passage
    FROM factures_en_attente fa JOIN destinataires d
      ON fa.statut <> 'bloquee' OR d.role = 'responsable'
    WHERE NOT EXISTS (
        SELECT 1 FROM notifications n
        WHERE n.facture_id = fa.id AND n.utilisateur_id = d.id AND n.canal = p_canal
          AND n.statut_facture = fa.statut AND n.passage_controle IS NOT DISTINCT FROM fa.passage
          AND n.expire_le > now()
          AND (n.etat = 'envoyee' OR (n.etat = 'a_envoyer' AND n.cree_le > now() - interval '10 minutes')))
    UNION ALL
    SELECT 'demande', dr.facture_id, dr.id, d.id, d.role, NULL, NULL
    FROM demandes_referentiel dr JOIN destinataires d
      ON d.role = 'responsable' AND d.id <> dr.demande_par   -- quatre yeux
    WHERE NOT EXISTS (SELECT 1 FROM decisions_referentiel x WHERE x.demande_id = dr.id)
      AND NOT EXISTS (
        SELECT 1 FROM notifications n
        WHERE n.demande_id = dr.id AND n.utilisateur_id = d.id AND n.canal = p_canal AND n.expire_le > now()
          AND (n.etat = 'envoyee' OR (n.etat = 'a_envoyer' AND n.cree_le > now() - interval '10 minutes')));
$$;


--
-- Name: parametre_controle(text, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.parametre_controle(p_cle text, p_date date DEFAULT CURRENT_DATE) RETURNS numeric
    LANGUAGE plpgsql STABLE
    AS $$
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


--
-- Name: parametres_controle_en_vigueur(date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.parametres_controle_en_vigueur(p_date date DEFAULT CURRENT_DATE) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
    SELECT coalesce(jsonb_object_agg(cle, valeur), '{}'::jsonb)
    FROM parametres_controle
    WHERE valide_du <= p_date AND (valide_au IS NULL OR valide_au > p_date);
$$;


--
-- Name: prendre_bail_canal(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prendre_bail_canal(p_canal text) RETURNS TABLE(bail_jeton uuid, curseur bigint)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
    UPDATE etats_canal e
    SET bail_jeton = gen_random_uuid(),
        bail_jusqu_a = now() + make_interval(secs => parametre_controle('canal.bail_secondes'))
    WHERE e.canal = p_canal AND (e.bail_jusqu_a IS NULL OR e.bail_jusqu_a < now())
    RETURNING e.bail_jeton, e.curseur;
$$;


--
-- Name: recevoir_evenement(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recevoir_evenement(p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
DECLARE
    v_canal    TEXT := p ->> 'canal';
    v_adresse  TEXT := p ->> 'adresse';
    v_type     TEXT := coalesce(p ->> 'type', 'autre');
    v_util     utilisateurs%ROWTYPE;
    v_code     codes_inscription%ROWTYPE;
    v_notif    notifications%ROWTYPE;
    v_attente  actions_en_attente%ROWTYPE;
    v_action   JSONB;
    v_facture  factures%ROWTYPE;
    v_passage  BIGINT;
    v_res      JSONB;
    v_id       BIGINT;
BEGIN
    IF EXISTS (SELECT 1 FROM evenements_entrants WHERE canal = v_canal AND reference = p ->> 'reference') THEN
        RETURN jsonb_build_object('code', 'deja_traite');
    END IF;

    SELECT u.* INTO v_util FROM utilisateurs u JOIN adresses_canal a ON a.utilisateur_id = u.id
    WHERE a.canal = v_canal AND a.adresse = v_adresse AND a.active AND u.actif;

    IF v_type = 'inscription' THEN
        SELECT * INTO v_code FROM codes_inscription
        WHERE canal = v_canal AND code_empreinte = encode(sha256(convert_to(coalesce(p ->> 'code', ''), 'UTF8')), 'hex')
        FOR UPDATE;
        IF NOT FOUND OR v_code.utilise_le IS NOT NULL OR v_code.expire_le < now() THEN
            v_res := jsonb_build_object('code', 'inscription_refusee');
        ELSIF EXISTS (SELECT 1 FROM adresses_canal WHERE canal = v_canal AND adresse = v_adresse) THEN
            v_res := jsonb_build_object('code', 'adresse_deja_inscrite');
        ELSE
            UPDATE codes_inscription SET utilise_le = now() WHERE id = v_code.id;
            UPDATE adresses_canal SET active = FALSE WHERE utilisateur_id = v_code.utilisateur_id AND canal = v_canal;
            INSERT INTO adresses_canal (utilisateur_id, canal, adresse) VALUES (v_code.utilisateur_id, v_canal, v_adresse);
            INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_apres)
            VALUES ('utilisateur:' || v_code.utilisateur_id, 'utilisateur.adresse_inscrite', 'utilisateurs',
                    v_code.utilisateur_id::text, v_canal, jsonb_build_object('adresse', v_adresse, 'code_id', v_code.id));
            v_res := jsonb_build_object('code', 'inscription_reussie',
                                        'nom', (SELECT nom FROM utilisateurs WHERE id = v_code.utilisateur_id));
        END IF;

    ELSIF v_util.id IS NULL THEN
        -- Expéditeur inconnu : rien n'est fait, l'événement est tracé.
        v_res := jsonb_build_object('code', 'expediteur_inconnu');

    ELSIF v_type = 'action' THEN
        SELECT * INTO v_notif FROM notifications
        WHERE canal = v_canal AND jeton_empreinte = encode(sha256(convert_to(coalesce(p ->> 'jeton', ''), 'UTF8')), 'hex');
        -- Indice strictement entier et positif (en JSONB, -1 désignerait le dernier élément).
        v_action := CASE WHEN coalesce(p ->> 'indice', '') ~ '^\d{1,3}$'
                         THEN v_notif.actions -> ((p ->> 'indice')::INTEGER) END;
        IF v_notif.id IS NULL THEN
            v_res := jsonb_build_object('code', 'bouton_inconnu');
        ELSIF v_notif.utilisateur_id <> v_util.id THEN
            -- Le bouton ne suffit pas : il faut être le destinataire.
            v_res := jsonb_build_object('code', 'pas_destinataire');
            INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_apres)
            VALUES ('utilisateur:' || v_util.id, 'canal.bouton_d_un_autre', 'notifications', v_notif.id::text, v_canal,
                    jsonb_build_object('destinataire', v_notif.utilisateur_id));
        ELSIF v_notif.expire_le < now() THEN
            v_res := jsonb_build_object('code', 'notification_expiree');
        ELSIF v_action IS NULL THEN
            v_res := jsonb_build_object('code', 'action_inconnue');
        ELSE
            IF v_notif.objet = 'facture' THEN
                SELECT * INTO v_facture FROM factures WHERE id = v_notif.facture_id;
                v_passage := (SELECT max(passage) FROM resultats_controles WHERE facture_id = v_notif.facture_id);
            END IF;
            IF v_notif.objet = 'facture' AND (v_facture.statut IS DISTINCT FROM v_notif.statut_facture
                                               OR v_passage IS DISTINCT FROM v_notif.passage_controle) THEN
                v_res := jsonb_build_object('code', 'notification_perimee', 'statut', v_facture.statut);
            ELSIF v_notif.objet = 'demande' AND EXISTS (SELECT 1 FROM decisions_referentiel WHERE demande_id = v_notif.demande_id) THEN
                v_res := jsonb_build_object('code', 'notification_perimee');
            ELSE
                UPDATE actions_en_attente SET conclue_le = now(), resultat = 'remplacee'
                WHERE utilisateur_id = v_util.id AND canal = v_canal AND conclue_le IS NULL;
                INSERT INTO actions_en_attente (notification_id, utilisateur_id, canal, adresse, indice_action, expire_le)
                VALUES (v_notif.id, v_util.id, v_canal, v_adresse, (p ->> 'indice')::INTEGER,
                        now() + make_interval(mins => parametre_controle('justification.delai_minutes')::INTEGER));
                v_res := jsonb_build_object('code', 'justification_demandee', 'action', v_action,
                                            'contenu', v_notif.contenu,
                                            'delai_minutes', parametre_controle('justification.delai_minutes'));
            END IF;
        END IF;

    ELSIF v_type = 'texte' THEN
        SELECT * INTO v_attente FROM actions_en_attente
        WHERE utilisateur_id = v_util.id AND canal = v_canal AND conclue_le IS NULL FOR UPDATE;
        IF v_attente.id IS NULL THEN
            v_res := jsonb_build_object('code', 'aucune_action_en_attente');
        ELSIF v_attente.expire_le < now() OR v_attente.adresse <> v_adresse THEN
            UPDATE actions_en_attente SET conclue_le = now(), resultat = 'expiree' WHERE id = v_attente.id;
            v_res := jsonb_build_object('code', 'justification_trop_tard');
        ELSE
            SELECT * INTO v_notif FROM notifications WHERE id = v_attente.notification_id;
            v_action := v_notif.actions -> v_attente.indice_action;
            BEGIN
                v_id := appliquer_action(v_notif, v_action, v_util.id, p ->> 'texte', v_canal);
                v_res := jsonb_build_object('code', 'decision_enregistree', 'action', v_action, 'id', v_id,
                                            'statut', (SELECT statut FROM factures WHERE id = v_notif.facture_id));
            EXCEPTION WHEN OTHERS THEN
                -- Refus de la base (rôle, justification, règle non dérogeable,
                -- quatre yeux…) : rien n'est appliqué, le motif est renvoyé.
                v_res := jsonb_build_object('code', 'decision_refusee', 'action', v_action,
                                            'erreur', SQLSTATE, 'motif', SQLERRM);
            END;
            UPDATE actions_en_attente SET conclue_le = now(), resultat = v_res ->> 'code' WHERE id = v_attente.id;
        END IF;

    ELSE
        v_res := jsonb_build_object('code', 'non_compris');
    END IF;

    INSERT INTO evenements_entrants (canal, reference, adresse, type, resultat)
    VALUES (v_canal, p ->> 'reference', v_adresse, v_type, v_res);
    RETURN v_res;
END;
$_$;


--
-- Name: refuser_modification(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refuser_modification() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION '% est en ajout seul : % interdit', TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'MZ001';
END;
$$;


--
-- Name: rendre_bail_canal(text, uuid, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rendre_bail_canal(p_canal text, p_bail_jeton uuid, p_curseur bigint) RETURNS boolean
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
    WITH rendu AS (
        UPDATE etats_canal SET curseur = greatest(curseur, p_curseur), bail_jeton = NULL, bail_jusqu_a = NULL
        WHERE canal = p_canal AND bail_jeton = p_bail_jeton
        RETURNING 1)
    SELECT count(*) = 1 FROM rendu;
$$;


--
-- Name: reserver_facture_a_controler(interval); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reserver_facture_a_controler(p_delai_reprise interval DEFAULT '00:15:00'::interval) RETURNS TABLE(facture_id bigint)
    LANGUAGE sql
    AS $$
    UPDATE factures f
    SET statut = 'en_controle', reservee_le = now()
    WHERE f.id = (
        SELECT c.id FROM factures c
        WHERE c.statut = 'extraite'
           OR (c.statut = 'en_controle' AND c.reservee_le < now() - p_delai_reprise)
        ORDER BY c.id
        LIMIT 1
        FOR UPDATE SKIP LOCKED
    )
    RETURNING f.id;
$$;


--
-- Name: reserver_facture_a_extraire(interval); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reserver_facture_a_extraire(p_delai_reprise interval DEFAULT '00:15:00'::interval) RETURNS TABLE(facture_id bigint, canal_reception text, reference_source text, fichier_nom text, fichier_sha256 character, format_source text)
    LANGUAGE sql
    AS $$
    UPDATE factures f
    SET statut = 'en_extraction', reservee_le = now()
    WHERE f.id = (
        SELECT c.id FROM factures c
        WHERE c.statut = 'recue'
           OR (c.statut = 'en_extraction' AND c.reservee_le < now() - p_delai_reprise)
        ORDER BY c.id
        LIMIT 1
        FOR UPDATE SKIP LOCKED
    )
    RETURNING f.id, f.canal_reception, f.reference_source, f.fichier_nom, f.fichier_sha256, f.format_source;
$$;


--
-- Name: rib_cle_valide(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rib_cle_valide(p_rib text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $_$
    SELECT p_rib ~ '^\d{20}$'
       AND lpad((97 - (left(p_rib, 18)::NUMERIC * 100) % 97)::TEXT, 2, '0') = right(p_rib, 2);
$_$;


--
-- Name: ribs_referentiel(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ribs_referentiel() RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
    SELECT coalesce(jsonb_object_agg(f.matricule_fiscal, r.rib), '{}'::jsonb)
    FROM fournisseurs f
    JOIN fournisseur_ribs r ON r.fournisseur_id = f.id
    WHERE f.actif AND r.valide_au IS NULL AND r.valide_du <= CURRENT_DATE;
$$;


--
-- Name: utilisateurs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.utilisateurs (
    id bigint NOT NULL,
    nom text NOT NULL,
    role text NOT NULL,
    actif boolean DEFAULT true NOT NULL,
    fictif boolean DEFAULT false NOT NULL,
    cree_le timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT utilisateurs_nom_ck CHECK ((btrim(nom) <> ''::text)),
    CONSTRAINT utilisateurs_role_ck CHECK ((role = ANY (ARRAY['validateur'::text, 'responsable'::text])))
);


--
-- Name: utilisateur_autorise(bigint, text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.utilisateur_autorise(p_id bigint, p_roles text[]) RETURNS public.utilisateurs
    LANGUAGE plpgsql STABLE
    AS $$
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


--
-- Name: verifier_justification(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.verifier_justification(p_texte text) RETURNS void
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    IF length(btrim(coalesce(p_texte, ''))) < parametre_controle('justification.longueur_min') THEN
        RAISE EXCEPTION 'justification obligatoire d''au moins % caractères',
            parametre_controle('justification.longueur_min') USING ERRCODE = 'MZ013';
    END IF;
END;
$$;


--
-- Name: actions_en_attente; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.actions_en_attente (
    id bigint NOT NULL,
    notification_id bigint NOT NULL,
    utilisateur_id bigint NOT NULL,
    canal text NOT NULL,
    adresse text NOT NULL,
    indice_action integer NOT NULL,
    ouverte_le timestamp with time zone DEFAULT now() NOT NULL,
    expire_le timestamp with time zone NOT NULL,
    conclue_le timestamp with time zone,
    resultat text
);


--
-- Name: actions_en_attente_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.actions_en_attente ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.actions_en_attente_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: adresses_canal; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.adresses_canal (
    id bigint NOT NULL,
    utilisateur_id bigint NOT NULL,
    canal text NOT NULL,
    adresse text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    inscrite_le timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT adresses_canal_canal_ck CHECK ((canal = 'telegram'::text))
);


--
-- Name: adresses_canal_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.adresses_canal ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.adresses_canal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: codes_inscription; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.codes_inscription (
    id bigint NOT NULL,
    utilisateur_id bigint NOT NULL,
    canal text NOT NULL,
    code_empreinte character(64) NOT NULL,
    cree_le timestamp with time zone DEFAULT now() NOT NULL,
    expire_le timestamp with time zone NOT NULL,
    utilise_le timestamp with time zone,
    CONSTRAINT codes_inscription_canal_ck CHECK ((canal = 'telegram'::text))
);


--
-- Name: codes_inscription_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.codes_inscription ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.codes_inscription_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: config_fiscale; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.config_fiscale (
    id bigint NOT NULL,
    cle text NOT NULL,
    valeur numeric(15,4) NOT NULL,
    unite text NOT NULL,
    libelle text NOT NULL,
    conditions jsonb DEFAULT '{}'::jsonb NOT NULL,
    valide_du date NOT NULL,
    valide_au date,
    source_libelle text NOT NULL,
    source_url text,
    a_confirmer boolean DEFAULT true NOT NULL,
    note text,
    cree_le timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT config_fiscale_periode_ck CHECK (((valide_au IS NULL) OR (valide_au > valide_du))),
    CONSTRAINT config_fiscale_unite_ck CHECK ((unite = ANY (ARRAY['pourcent'::text, 'TND'::text])))
);


--
-- Name: config_fiscale_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.config_fiscale ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.config_fiscale_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: decisions_humaines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.decisions_humaines (
    id bigint NOT NULL,
    facture_id bigint NOT NULL,
    utilisateur_id bigint NOT NULL,
    decision text NOT NULL,
    statut_avant text,
    statut_apres text,
    passage_controle bigint,
    justification text NOT NULL,
    corrections jsonb DEFAULT '{}'::jsonb NOT NULL,
    demande_id bigint,
    canal text,
    transaction_id xid8,
    decide_le timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT decisions_humaines_corrections_ck CHECK ((jsonb_typeof(corrections) = 'object'::text)),
    CONSTRAINT decisions_humaines_decision_ck CHECK ((decision = ANY (ARRAY['valider'::text, 'rejeter'::text, 'renvoyer_aux_controles'::text, 'relancer_extraction'::text])))
);


--
-- Name: decisions_humaines_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.decisions_humaines ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.decisions_humaines_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: decisions_referentiel; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.decisions_referentiel (
    id bigint NOT NULL,
    demande_id bigint NOT NULL,
    decision text NOT NULL,
    utilisateur_id bigint NOT NULL,
    methode_verification text,
    justification text NOT NULL,
    decide_le timestamp with time zone DEFAULT now() NOT NULL,
    canal text,
    CONSTRAINT decisions_referentiel_decision_ck CHECK ((decision = ANY (ARRAY['approuvee'::text, 'refusee'::text]))),
    CONSTRAINT decisions_referentiel_methode_ck CHECK (((decision = 'refusee'::text) OR (methode_verification IS NOT NULL)))
);


--
-- Name: decisions_referentiel_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.decisions_referentiel ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.decisions_referentiel_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: demandes_referentiel; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.demandes_referentiel (
    id bigint NOT NULL,
    type_demande text NOT NULL,
    fournisseur_id bigint,
    facture_id bigint,
    donnees jsonb NOT NULL,
    rib_actuel text,
    demande_par bigint NOT NULL,
    justification text NOT NULL,
    demande_le timestamp with time zone DEFAULT now() NOT NULL,
    canal text,
    CONSTRAINT demandes_referentiel_fournisseur_ck CHECK (((type_demande = 'changement_rib'::text) = (fournisseur_id IS NOT NULL))),
    CONSTRAINT demandes_referentiel_type_ck CHECK ((type_demande = ANY (ARRAY['creation_fournisseur'::text, 'changement_rib'::text])))
);


--
-- Name: demandes_referentiel_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.demandes_referentiel ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.demandes_referentiel_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: etats_canal; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.etats_canal (
    canal text NOT NULL,
    curseur bigint DEFAULT 0 NOT NULL,
    bail_jeton uuid,
    bail_jusqu_a timestamp with time zone,
    CONSTRAINT etats_canal_canal_ck CHECK ((canal = 'telegram'::text))
);


--
-- Name: evenements_entrants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.evenements_entrants (
    id bigint NOT NULL,
    canal text NOT NULL,
    reference text NOT NULL,
    adresse text,
    type text NOT NULL,
    recu_le timestamp with time zone DEFAULT now() NOT NULL,
    resultat jsonb NOT NULL,
    CONSTRAINT evenements_entrants_type_ck CHECK ((type = ANY (ARRAY['inscription'::text, 'action'::text, 'texte'::text, 'autre'::text])))
);


--
-- Name: evenements_entrants_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.evenements_entrants ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.evenements_entrants_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: extractions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.extractions (
    id bigint NOT NULL,
    facture_id bigint NOT NULL,
    fichier_sha256 character(64) NOT NULL,
    resultat text NOT NULL,
    code_resultat text NOT NULL,
    methode_lecture text,
    fournisseur_llm text,
    modele text,
    version_prompt text,
    empreinte_prompt character(64),
    duree_lecture_ms integer,
    duree_llm_ms integer,
    jetons_entree integer,
    jetons_sortie integer,
    tentatives integer,
    donnees jsonb,
    erreurs jsonb DEFAULT '[]'::jsonb NOT NULL,
    reutilise_de bigint,
    execution_n8n_id text,
    cree_le timestamp with time zone DEFAULT now() NOT NULL,
    parametres_generation jsonb,
    jetons_reflexion integer,
    verifications_source jsonb DEFAULT '[]'::jsonb NOT NULL,
    alertes_source jsonb DEFAULT '[]'::jsonb NOT NULL,
    texte_source text,
    donnees_brutes jsonb,
    corrections_code jsonb DEFAULT '[]'::jsonb NOT NULL,
    signalements_code jsonb DEFAULT '[]'::jsonb NOT NULL,
    propositions jsonb DEFAULT '[]'::jsonb NOT NULL,
    version_chaine text,
    CONSTRAINT extractions_code_ck CHECK ((code_resultat = ANY (ARRAY['ok'::text, 'reponse_illisible'::text, 'erreur_fournisseur'::text, 'quota_minute_epuise'::text, 'quota_journalier_epuise'::text, 'erreur_lecture'::text, 'erreur_ecriture'::text, 'reutilisation'::text]))),
    CONSTRAINT extractions_donnees_ck CHECK (((resultat <> ALL (ARRAY['valide'::text, 'reutilisee'::text])) OR (donnees IS NOT NULL))),
    CONSTRAINT extractions_mesures_ck CHECK (((COALESCE(duree_lecture_ms, 0) >= 0) AND (COALESCE(duree_llm_ms, 0) >= 0) AND (COALESCE(jetons_entree, 0) >= 0) AND (COALESCE(jetons_sortie, 0) >= 0) AND (COALESCE(tentatives, 0) >= 0))),
    CONSTRAINT extractions_methode_ck CHECK ((methode_lecture = ANY (ARRAY['texte_pdf'::text, 'ocr'::text]))),
    CONSTRAINT extractions_reflexion_ck CHECK ((COALESCE(jetons_reflexion, 0) >= 0)),
    CONSTRAINT extractions_resultat_ck CHECK ((resultat = ANY (ARRAY['valide'::text, 'invalide'::text, 'erreur'::text, 'reutilisee'::text]))),
    CONSTRAINT extractions_reutilisation_ck CHECK (((resultat = 'reutilisee'::text) = (reutilise_de IS NOT NULL))),
    CONSTRAINT extractions_sha256_ck CHECK ((fichier_sha256 ~ '^[0-9a-f]{64}$'::text))
);


--
-- Name: extractions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.extractions ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.extractions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: factures; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.factures (
    id bigint NOT NULL,
    fournisseur_id bigint,
    type_document text DEFAULT 'facture'::text NOT NULL,
    facture_origine_id bigint,
    numero text,
    date_facture date,
    date_echeance date,
    devise character(3) DEFAULT 'TND'::bpchar NOT NULL,
    montant_ht numeric(15,3),
    montant_tva numeric(15,3),
    droit_timbre numeric(15,3),
    montant_ttc numeric(15,3),
    matricule_fiscal_lu text,
    raison_sociale_lue text,
    rib_facture text,
    canal_reception text NOT NULL,
    format_source text NOT NULL,
    fichier_nom text NOT NULL,
    fichier_sha256 character(64) NOT NULL,
    methode_extraction text,
    extraction_brute jsonb,
    statut text DEFAULT 'recue'::text NOT NULL,
    recue_le timestamp with time zone DEFAULT now() NOT NULL,
    cree_le timestamp with time zone DEFAULT now() NOT NULL,
    modifie_le timestamp with time zone DEFAULT now() NOT NULL,
    reference_source text,
    reservee_le timestamp with time zone,
    fournisseur_source text,
    CONSTRAINT factures_approuvee_identifiee_ck CHECK (((statut <> ALL (ARRAY['conforme'::text, 'validee'::text])) OR ((fournisseur_id IS NOT NULL) AND (numero IS NOT NULL) AND (btrim(numero) <> ''::text)))),
    CONSTRAINT factures_canal_ck CHECK ((canal_reception = ANY (ARRAY['dossier'::text, 'email'::text, 'telegram'::text]))),
    CONSTRAINT factures_devise_ck CHECK ((devise ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT factures_format_ck CHECK ((format_source = ANY (ARRAY['pdf'::text, 'image'::text, 'xml'::text]))),
    CONSTRAINT factures_fournisseur_source_ck CHECK ((fournisseur_source = ANY (ARRAY['controle'::text, 'decision'::text]))),
    CONSTRAINT factures_methode_ck CHECK ((methode_extraction = ANY (ARRAY['texte_llm'::text, 'ocr_llm'::text, 'xml'::text, 'manuelle'::text]))),
    CONSTRAINT factures_montants_positifs_ck CHECK (((COALESCE(montant_ht, (0)::numeric) >= (0)::numeric) AND (COALESCE(montant_tva, (0)::numeric) >= (0)::numeric) AND (COALESCE(droit_timbre, (0)::numeric) >= (0)::numeric) AND (COALESCE(montant_ttc, (0)::numeric) >= (0)::numeric))),
    CONSTRAINT factures_origine_avoir_ck CHECK (((facture_origine_id IS NULL) OR (type_document = 'avoir'::text))),
    CONSTRAINT factures_sha256_ck CHECK ((fichier_sha256 ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT factures_statut_ck CHECK ((statut = ANY (ARRAY['recue'::text, 'en_extraction'::text, 'extraite'::text, 'erreur_extraction'::text, 'en_controle'::text, 'conforme'::text, 'a_valider'::text, 'anomalie'::text, 'bloquee'::text, 'validee'::text, 'rejetee'::text]))),
    CONSTRAINT factures_type_document_ck CHECK ((type_document = ANY (ARRAY['facture'::text, 'avoir'::text])))
);


--
-- Name: factures_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.factures ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.factures_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: fournisseur_ribs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fournisseur_ribs (
    id bigint NOT NULL,
    fournisseur_id bigint NOT NULL,
    rib text NOT NULL,
    banque text,
    valide_du date DEFAULT CURRENT_DATE NOT NULL,
    valide_au date,
    origine text DEFAULT 'saisie'::text NOT NULL,
    cree_le timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT fournisseur_ribs_origine_ck CHECK ((origine = ANY (ARRAY['saisie'::text, 'facture'::text, 'import'::text]))),
    CONSTRAINT fournisseur_ribs_periode_ck CHECK (((valide_au IS NULL) OR (valide_au > valide_du)))
);


--
-- Name: fournisseur_ribs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.fournisseur_ribs ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.fournisseur_ribs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: fournisseurs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fournisseurs (
    id bigint NOT NULL,
    raison_sociale text NOT NULL,
    matricule_fiscal text NOT NULL,
    adresse text,
    ville text,
    email text,
    telephone text,
    actif boolean DEFAULT true NOT NULL,
    cree_le timestamp with time zone DEFAULT now() NOT NULL,
    modifie_le timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT fournisseurs_raison_sociale_ck CHECK ((btrim(raison_sociale) <> ''::text))
);


--
-- Name: fournisseurs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.fournisseurs ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.fournisseurs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: journal_audit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.journal_audit (
    id bigint NOT NULL,
    horodatage timestamp with time zone DEFAULT now() NOT NULL,
    acteur text NOT NULL,
    action text NOT NULL,
    entite text NOT NULL,
    entite_id text,
    canal text,
    donnees_avant jsonb,
    donnees_apres jsonb,
    commentaire text,
    execution_n8n_id text
);


--
-- Name: journal_audit_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.journal_audit ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.journal_audit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: lignes_facture; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lignes_facture (
    id bigint NOT NULL,
    facture_id bigint NOT NULL,
    numero_ligne integer NOT NULL,
    designation text NOT NULL,
    quantite numeric(18,6),
    prix_unitaire_ht numeric(18,6),
    taux_tva numeric(7,4),
    montant_ht numeric(15,3),
    montant_tva numeric(15,3),
    CONSTRAINT lignes_facture_numero_ck CHECK ((numero_ligne > 0)),
    CONSTRAINT lignes_facture_taux_ck CHECK (((taux_tva >= (0)::numeric) AND (taux_tva <= (100)::numeric)))
);


--
-- Name: lignes_facture_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.lignes_facture ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.lignes_facture_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: lignes_releve; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lignes_releve (
    id bigint NOT NULL,
    releve_id bigint NOT NULL,
    numero_ligne integer NOT NULL,
    date_operation date NOT NULL,
    date_valeur date,
    libelle text NOT NULL,
    reference text,
    debit numeric(15,3) DEFAULT 0 NOT NULL,
    credit numeric(15,3) DEFAULT 0 NOT NULL,
    CONSTRAINT lignes_releve_montants_ck CHECK (((debit >= (0)::numeric) AND (credit >= (0)::numeric) AND (NOT ((debit > (0)::numeric) AND (credit > (0)::numeric))))),
    CONSTRAINT lignes_releve_numero_ck CHECK ((numero_ligne > 0))
);


--
-- Name: lignes_releve_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.lignes_releve ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.lignes_releve_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: methodes_verification; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.methodes_verification (
    code text NOT NULL,
    type_demande text NOT NULL,
    libelle text NOT NULL,
    CONSTRAINT methodes_verification_type_ck CHECK ((type_demande = ANY (ARRAY['creation_fournisseur'::text, 'changement_rib'::text])))
);


--
-- Name: notifications_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.notifications ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.notifications_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: parametres_controle; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.parametres_controle (
    id bigint NOT NULL,
    cle text NOT NULL,
    valeur numeric(15,3) NOT NULL,
    unite text NOT NULL,
    libelle text NOT NULL,
    valide_du date NOT NULL,
    valide_au date,
    justification text NOT NULL,
    cree_le timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT parametres_controle_periode_ck CHECK (((valide_au IS NULL) OR (valide_au > valide_du))),
    CONSTRAINT parametres_controle_unite_ck CHECK ((unite = ANY (ARRAY['TND'::text, 'millimes'::text, 'caracteres'::text, 'jours'::text, 'minutes'::text, 'secondes'::text]))),
    CONSTRAINT parametres_controle_valeur_ck CHECK ((valeur >= (0)::numeric))
);


--
-- Name: parametres_controle_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.parametres_controle ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.parametres_controle_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: passages_controle_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.passages_controle_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rapprochements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rapprochements (
    id bigint NOT NULL,
    facture_id bigint NOT NULL,
    ligne_releve_id bigint NOT NULL,
    montant_affecte numeric(15,3) NOT NULL,
    methode text NOT NULL,
    score numeric(5,4),
    statut text DEFAULT 'propose'::text NOT NULL,
    ecart numeric(15,3),
    commentaire text,
    cree_par text NOT NULL,
    cree_le timestamp with time zone DEFAULT now() NOT NULL,
    modifie_le timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT rapprochements_methode_ck CHECK ((methode = ANY (ARRAY['auto'::text, 'manuel'::text]))),
    CONSTRAINT rapprochements_montant_ck CHECK ((montant_affecte > (0)::numeric)),
    CONSTRAINT rapprochements_score_ck CHECK (((score >= (0)::numeric) AND (score <= (1)::numeric))),
    CONSTRAINT rapprochements_statut_ck CHECK ((statut = ANY (ARRAY['propose'::text, 'confirme'::text, 'rejete'::text])))
);


--
-- Name: rapprochements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.rapprochements ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.rapprochements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: regles_controle; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.regles_controle (
    regle text NOT NULL,
    libelle text NOT NULL,
    derogeable boolean NOT NULL,
    actif boolean DEFAULT true NOT NULL
);


--
-- Name: releves_bancaires; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.releves_bancaires (
    id bigint NOT NULL,
    banque text NOT NULL,
    rib_compte text NOT NULL,
    devise character(3) DEFAULT 'TND'::bpchar NOT NULL,
    date_debut date NOT NULL,
    date_fin date NOT NULL,
    solde_initial numeric(15,3),
    solde_final numeric(15,3),
    fichier_nom text NOT NULL,
    fichier_sha256 character(64) NOT NULL,
    importe_le timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT releves_bancaires_devise_ck CHECK ((devise ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT releves_bancaires_periode_ck CHECK ((date_fin >= date_debut)),
    CONSTRAINT releves_bancaires_sha256_ck CHECK ((fichier_sha256 ~ '^[0-9a-f]{64}$'::text))
);


--
-- Name: releves_bancaires_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.releves_bancaires ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.releves_bancaires_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: resultats_controles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resultats_controles (
    id bigint NOT NULL,
    facture_id bigint NOT NULL,
    regle text NOT NULL,
    version_regle text NOT NULL,
    resultat text NOT NULL,
    gravite text NOT NULL,
    message text,
    detail jsonb DEFAULT '{}'::jsonb NOT NULL,
    execution_n8n_id text,
    execute_le timestamp with time zone DEFAULT now() NOT NULL,
    passage bigint NOT NULL,
    CONSTRAINT resultats_controles_gravite_ck CHECK ((gravite = ANY (ARRAY['info'::text, 'validation'::text, 'avertissement'::text, 'bloquant'::text]))),
    CONSTRAINT resultats_controles_resultat_ck CHECK ((resultat = ANY (ARRAY['ok'::text, 'anomalie'::text, 'erreur'::text, 'non_applicable'::text])))
);


--
-- Name: resultats_controles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.resultats_controles ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.resultats_controles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: transitions_statut; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.transitions_statut (
    de text NOT NULL,
    vers text NOT NULL,
    par text NOT NULL,
    CONSTRAINT transitions_statut_par_ck CHECK ((par = ANY (ARRAY['systeme'::text, 'decision'::text])))
);


--
-- Name: utilisateurs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.utilisateurs ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.utilisateurs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: actions_en_attente actions_en_attente_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.actions_en_attente
    ADD CONSTRAINT actions_en_attente_pkey PRIMARY KEY (id);


--
-- Name: adresses_canal adresses_canal_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.adresses_canal
    ADD CONSTRAINT adresses_canal_pkey PRIMARY KEY (id);


--
-- Name: adresses_canal adresses_canal_uk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.adresses_canal
    ADD CONSTRAINT adresses_canal_uk UNIQUE (canal, adresse);


--
-- Name: codes_inscription codes_inscription_code_empreinte_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.codes_inscription
    ADD CONSTRAINT codes_inscription_code_empreinte_key UNIQUE (code_empreinte);


--
-- Name: codes_inscription codes_inscription_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.codes_inscription
    ADD CONSTRAINT codes_inscription_pkey PRIMARY KEY (id);


--
-- Name: config_fiscale config_fiscale_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.config_fiscale
    ADD CONSTRAINT config_fiscale_pkey PRIMARY KEY (id);


--
-- Name: config_fiscale config_fiscale_sans_chevauchement; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.config_fiscale
    ADD CONSTRAINT config_fiscale_sans_chevauchement EXCLUDE USING gist (cle WITH =, daterange(valide_du, valide_au, '[)'::text) WITH &&);


--
-- Name: decisions_humaines decisions_humaines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions_humaines
    ADD CONSTRAINT decisions_humaines_pkey PRIMARY KEY (id);


--
-- Name: decisions_referentiel decisions_referentiel_demande_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions_referentiel
    ADD CONSTRAINT decisions_referentiel_demande_id_key UNIQUE (demande_id);


--
-- Name: decisions_referentiel decisions_referentiel_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions_referentiel
    ADD CONSTRAINT decisions_referentiel_pkey PRIMARY KEY (id);


--
-- Name: demandes_referentiel demandes_referentiel_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.demandes_referentiel
    ADD CONSTRAINT demandes_referentiel_pkey PRIMARY KEY (id);


--
-- Name: etats_canal etats_canal_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.etats_canal
    ADD CONSTRAINT etats_canal_pkey PRIMARY KEY (canal);


--
-- Name: evenements_entrants evenements_entrants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evenements_entrants
    ADD CONSTRAINT evenements_entrants_pkey PRIMARY KEY (id);


--
-- Name: evenements_entrants evenements_entrants_uk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evenements_entrants
    ADD CONSTRAINT evenements_entrants_uk UNIQUE (canal, reference);


--
-- Name: extractions extractions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.extractions
    ADD CONSTRAINT extractions_pkey PRIMARY KEY (id);


--
-- Name: factures factures_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.factures
    ADD CONSTRAINT factures_pkey PRIMARY KEY (id);


--
-- Name: fournisseur_ribs fournisseur_ribs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fournisseur_ribs
    ADD CONSTRAINT fournisseur_ribs_pkey PRIMARY KEY (id);


--
-- Name: fournisseurs fournisseurs_matricule_fiscal_uk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fournisseurs
    ADD CONSTRAINT fournisseurs_matricule_fiscal_uk UNIQUE (matricule_fiscal);


--
-- Name: fournisseurs fournisseurs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fournisseurs
    ADD CONSTRAINT fournisseurs_pkey PRIMARY KEY (id);


--
-- Name: journal_audit journal_audit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_audit
    ADD CONSTRAINT journal_audit_pkey PRIMARY KEY (id);


--
-- Name: lignes_facture lignes_facture_numero_uk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lignes_facture
    ADD CONSTRAINT lignes_facture_numero_uk UNIQUE (facture_id, numero_ligne);


--
-- Name: lignes_facture lignes_facture_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lignes_facture
    ADD CONSTRAINT lignes_facture_pkey PRIMARY KEY (id);


--
-- Name: lignes_releve lignes_releve_numero_uk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lignes_releve
    ADD CONSTRAINT lignes_releve_numero_uk UNIQUE (releve_id, numero_ligne);


--
-- Name: lignes_releve lignes_releve_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lignes_releve
    ADD CONSTRAINT lignes_releve_pkey PRIMARY KEY (id);


--
-- Name: methodes_verification methodes_verification_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.methodes_verification
    ADD CONSTRAINT methodes_verification_pkey PRIMARY KEY (code);


--
-- Name: notifications notifications_jeton_empreinte_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_jeton_empreinte_key UNIQUE (jeton_empreinte);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: parametres_controle parametres_controle_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parametres_controle
    ADD CONSTRAINT parametres_controle_pkey PRIMARY KEY (id);


--
-- Name: parametres_controle parametres_controle_sans_chevauchement; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parametres_controle
    ADD CONSTRAINT parametres_controle_sans_chevauchement EXCLUDE USING gist (cle WITH =, daterange(valide_du, valide_au, '[)'::text) WITH &&);


--
-- Name: rapprochements rapprochements_paire_uk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rapprochements
    ADD CONSTRAINT rapprochements_paire_uk UNIQUE (facture_id, ligne_releve_id);


--
-- Name: rapprochements rapprochements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rapprochements
    ADD CONSTRAINT rapprochements_pkey PRIMARY KEY (id);


--
-- Name: regles_controle regles_controle_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.regles_controle
    ADD CONSTRAINT regles_controle_pkey PRIMARY KEY (regle);


--
-- Name: releves_bancaires releves_bancaires_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.releves_bancaires
    ADD CONSTRAINT releves_bancaires_pkey PRIMARY KEY (id);


--
-- Name: releves_bancaires releves_bancaires_sha256_uk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.releves_bancaires
    ADD CONSTRAINT releves_bancaires_sha256_uk UNIQUE (fichier_sha256);


--
-- Name: resultats_controles resultats_controles_passage_uk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resultats_controles
    ADD CONSTRAINT resultats_controles_passage_uk UNIQUE (passage, regle);


--
-- Name: resultats_controles resultats_controles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resultats_controles
    ADD CONSTRAINT resultats_controles_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: transitions_statut transitions_statut_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transitions_statut
    ADD CONSTRAINT transitions_statut_pkey PRIMARY KEY (de, vers);


--
-- Name: utilisateurs utilisateurs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utilisateurs
    ADD CONSTRAINT utilisateurs_pkey PRIMARY KEY (id);


--
-- Name: actions_en_attente_ouverte_uk; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX actions_en_attente_ouverte_uk ON public.actions_en_attente USING btree (utilisateur_id, canal) WHERE (conclue_le IS NULL);


--
-- Name: adresses_canal_utilisateur_uk; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX adresses_canal_utilisateur_uk ON public.adresses_canal USING btree (utilisateur_id, canal) WHERE active;


--
-- Name: decisions_humaines_facture_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX decisions_humaines_facture_ix ON public.decisions_humaines USING btree (facture_id, id DESC);


--
-- Name: extractions_facture_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX extractions_facture_ix ON public.extractions USING btree (facture_id);


--
-- Name: extractions_valides_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX extractions_valides_ix ON public.extractions USING btree (fichier_sha256, id DESC) WHERE (resultat = 'valide'::text);


--
-- Name: factures_a_controler_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX factures_a_controler_ix ON public.factures USING btree (id) WHERE (statut = ANY (ARRAY['extraite'::text, 'en_controle'::text]));


--
-- Name: factures_a_extraire_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX factures_a_extraire_ix ON public.factures USING btree (id) WHERE (statut = ANY (ARRAY['recue'::text, 'en_extraction'::text]));


--
-- Name: factures_approuvees_uk; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX factures_approuvees_uk ON public.factures USING btree (fournisseur_id, type_document, public.normaliser_numero_facture(numero)) WHERE (statut = ANY (ARRAY['conforme'::text, 'validee'::text]));


--
-- Name: factures_date_echeance_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX factures_date_echeance_ix ON public.factures USING btree (date_echeance);


--
-- Name: factures_doublon_numero_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX factures_doublon_numero_ix ON public.factures USING btree (fournisseur_id, type_document, numero);


--
-- Name: factures_fichier_sha256_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX factures_fichier_sha256_ix ON public.factures USING btree (fichier_sha256);


--
-- Name: factures_reception_uk; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX factures_reception_uk ON public.factures USING btree (canal_reception, COALESCE(reference_source, fichier_nom), fichier_sha256);


--
-- Name: factures_statut_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX factures_statut_ix ON public.factures USING btree (statut);


--
-- Name: fournisseur_ribs_actif_uk; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX fournisseur_ribs_actif_uk ON public.fournisseur_ribs USING btree (fournisseur_id) WHERE (valide_au IS NULL);


--
-- Name: fournisseur_ribs_rib_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fournisseur_ribs_rib_ix ON public.fournisseur_ribs USING btree (rib);


--
-- Name: journal_audit_entite_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX journal_audit_entite_ix ON public.journal_audit USING btree (entite, entite_id);


--
-- Name: journal_audit_horodatage_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX journal_audit_horodatage_ix ON public.journal_audit USING btree (horodatage);


--
-- Name: lignes_releve_date_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lignes_releve_date_ix ON public.lignes_releve USING btree (date_operation);


--
-- Name: notifications_demande_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_demande_ix ON public.notifications USING btree (demande_id, utilisateur_id, canal);


--
-- Name: notifications_facture_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_facture_ix ON public.notifications USING btree (facture_id, utilisateur_id, canal);


--
-- Name: rapprochements_ligne_releve_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rapprochements_ligne_releve_ix ON public.rapprochements USING btree (ligne_releve_id);


--
-- Name: resultats_controles_facture_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resultats_controles_facture_ix ON public.resultats_controles USING btree (facture_id, execute_le DESC);


--
-- Name: resultats_controles_passage_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resultats_controles_passage_ix ON public.resultats_controles USING btree (facture_id, passage DESC);


--
-- Name: resultats_controles_regle_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resultats_controles_regle_ix ON public.resultats_controles USING btree (regle, resultat);


--
-- Name: decisions_humaines decisions_humaines_application; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER decisions_humaines_application AFTER INSERT ON public.decisions_humaines FOR EACH ROW EXECUTE FUNCTION public.decisions_humaines_appliquer();


--
-- Name: decisions_humaines decisions_humaines_pas_de_modification; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER decisions_humaines_pas_de_modification BEFORE DELETE OR UPDATE ON public.decisions_humaines FOR EACH ROW EXECUTE FUNCTION public.refuser_modification();


--
-- Name: decisions_humaines decisions_humaines_pas_de_vidage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER decisions_humaines_pas_de_vidage BEFORE TRUNCATE ON public.decisions_humaines FOR EACH STATEMENT EXECUTE FUNCTION public.refuser_modification();


--
-- Name: decisions_humaines decisions_humaines_verification; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER decisions_humaines_verification BEFORE INSERT ON public.decisions_humaines FOR EACH ROW EXECUTE FUNCTION public.decisions_humaines_verifier();


--
-- Name: decisions_referentiel decisions_referentiel_application; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER decisions_referentiel_application AFTER INSERT ON public.decisions_referentiel FOR EACH ROW EXECUTE FUNCTION public.decisions_referentiel_appliquer();


--
-- Name: decisions_referentiel decisions_referentiel_pas_de_modification; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER decisions_referentiel_pas_de_modification BEFORE DELETE OR UPDATE ON public.decisions_referentiel FOR EACH ROW EXECUTE FUNCTION public.refuser_modification();


--
-- Name: decisions_referentiel decisions_referentiel_pas_de_vidage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER decisions_referentiel_pas_de_vidage BEFORE TRUNCATE ON public.decisions_referentiel FOR EACH STATEMENT EXECUTE FUNCTION public.refuser_modification();


--
-- Name: decisions_referentiel decisions_referentiel_verification; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER decisions_referentiel_verification BEFORE INSERT ON public.decisions_referentiel FOR EACH ROW EXECUTE FUNCTION public.decisions_referentiel_verifier();


--
-- Name: demandes_referentiel demandes_referentiel_journal; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER demandes_referentiel_journal AFTER INSERT ON public.demandes_referentiel FOR EACH ROW EXECUTE FUNCTION public.demandes_referentiel_journaliser();


--
-- Name: demandes_referentiel demandes_referentiel_pas_de_modification; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER demandes_referentiel_pas_de_modification BEFORE DELETE OR UPDATE ON public.demandes_referentiel FOR EACH ROW EXECUTE FUNCTION public.refuser_modification();


--
-- Name: demandes_referentiel demandes_referentiel_pas_de_vidage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER demandes_referentiel_pas_de_vidage BEFORE TRUNCATE ON public.demandes_referentiel FOR EACH STATEMENT EXECUTE FUNCTION public.refuser_modification();


--
-- Name: demandes_referentiel demandes_referentiel_verification; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER demandes_referentiel_verification BEFORE INSERT ON public.demandes_referentiel FOR EACH ROW EXECUTE FUNCTION public.demandes_referentiel_verifier();


--
-- Name: evenements_entrants evenements_entrants_pas_de_modification; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER evenements_entrants_pas_de_modification BEFORE DELETE OR UPDATE ON public.evenements_entrants FOR EACH ROW EXECUTE FUNCTION public.refuser_modification();


--
-- Name: extractions extractions_pas_de_modification; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER extractions_pas_de_modification BEFORE DELETE OR UPDATE ON public.extractions FOR EACH ROW EXECUTE FUNCTION public.refuser_modification();


--
-- Name: extractions extractions_pas_de_vidage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER extractions_pas_de_vidage BEFORE TRUNCATE ON public.extractions FOR EACH STATEMENT EXECUTE FUNCTION public.refuser_modification();


--
-- Name: factures factures_garde_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER factures_garde_transition BEFORE UPDATE OF statut ON public.factures FOR EACH ROW EXECUTE FUNCTION public.factures_garder_transition();


--
-- Name: factures factures_maj_modifie_le; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER factures_maj_modifie_le BEFORE UPDATE ON public.factures FOR EACH ROW EXECUTE FUNCTION public.maj_modifie_le();


--
-- Name: fournisseurs fournisseurs_maj_modifie_le; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER fournisseurs_maj_modifie_le BEFORE UPDATE ON public.fournisseurs FOR EACH ROW EXECUTE FUNCTION public.maj_modifie_le();


--
-- Name: journal_audit journal_audit_horodatage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER journal_audit_horodatage BEFORE INSERT ON public.journal_audit FOR EACH ROW EXECUTE FUNCTION public.journal_audit_horodater();


--
-- Name: journal_audit journal_audit_pas_de_modification; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER journal_audit_pas_de_modification BEFORE DELETE OR UPDATE ON public.journal_audit FOR EACH ROW EXECUTE FUNCTION public.journal_audit_ajout_seul();


--
-- Name: journal_audit journal_audit_pas_de_vidage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER journal_audit_pas_de_vidage BEFORE TRUNCATE ON public.journal_audit FOR EACH STATEMENT EXECUTE FUNCTION public.journal_audit_ajout_seul();


--
-- Name: rapprochements rapprochements_maj_modifie_le; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rapprochements_maj_modifie_le BEFORE UPDATE ON public.rapprochements FOR EACH ROW EXECUTE FUNCTION public.maj_modifie_le();


--
-- Name: resultats_controles resultats_controles_pas_de_modification; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER resultats_controles_pas_de_modification BEFORE DELETE OR UPDATE ON public.resultats_controles FOR EACH ROW EXECUTE FUNCTION public.refuser_modification();


--
-- Name: resultats_controles resultats_controles_pas_de_vidage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER resultats_controles_pas_de_vidage BEFORE TRUNCATE ON public.resultats_controles FOR EACH STATEMENT EXECUTE FUNCTION public.refuser_modification();


--
-- Name: actions_en_attente actions_en_attente_notification_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.actions_en_attente
    ADD CONSTRAINT actions_en_attente_notification_id_fkey FOREIGN KEY (notification_id) REFERENCES public.notifications(id);


--
-- Name: actions_en_attente actions_en_attente_utilisateur_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.actions_en_attente
    ADD CONSTRAINT actions_en_attente_utilisateur_id_fkey FOREIGN KEY (utilisateur_id) REFERENCES public.utilisateurs(id);


--
-- Name: adresses_canal adresses_canal_utilisateur_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.adresses_canal
    ADD CONSTRAINT adresses_canal_utilisateur_id_fkey FOREIGN KEY (utilisateur_id) REFERENCES public.utilisateurs(id);


--
-- Name: codes_inscription codes_inscription_utilisateur_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.codes_inscription
    ADD CONSTRAINT codes_inscription_utilisateur_id_fkey FOREIGN KEY (utilisateur_id) REFERENCES public.utilisateurs(id);


--
-- Name: decisions_humaines decisions_humaines_facture_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions_humaines
    ADD CONSTRAINT decisions_humaines_facture_id_fkey FOREIGN KEY (facture_id) REFERENCES public.factures(id);


--
-- Name: decisions_humaines decisions_humaines_utilisateur_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions_humaines
    ADD CONSTRAINT decisions_humaines_utilisateur_id_fkey FOREIGN KEY (utilisateur_id) REFERENCES public.utilisateurs(id);


--
-- Name: decisions_referentiel decisions_referentiel_demande_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions_referentiel
    ADD CONSTRAINT decisions_referentiel_demande_id_fkey FOREIGN KEY (demande_id) REFERENCES public.demandes_referentiel(id);


--
-- Name: decisions_referentiel decisions_referentiel_methode_verification_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions_referentiel
    ADD CONSTRAINT decisions_referentiel_methode_verification_fkey FOREIGN KEY (methode_verification) REFERENCES public.methodes_verification(code);


--
-- Name: decisions_referentiel decisions_referentiel_utilisateur_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions_referentiel
    ADD CONSTRAINT decisions_referentiel_utilisateur_id_fkey FOREIGN KEY (utilisateur_id) REFERENCES public.utilisateurs(id);


--
-- Name: demandes_referentiel demandes_referentiel_demande_par_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.demandes_referentiel
    ADD CONSTRAINT demandes_referentiel_demande_par_fkey FOREIGN KEY (demande_par) REFERENCES public.utilisateurs(id);


--
-- Name: demandes_referentiel demandes_referentiel_facture_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.demandes_referentiel
    ADD CONSTRAINT demandes_referentiel_facture_id_fkey FOREIGN KEY (facture_id) REFERENCES public.factures(id);


--
-- Name: demandes_referentiel demandes_referentiel_fournisseur_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.demandes_referentiel
    ADD CONSTRAINT demandes_referentiel_fournisseur_id_fkey FOREIGN KEY (fournisseur_id) REFERENCES public.fournisseurs(id);


--
-- Name: extractions extractions_facture_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.extractions
    ADD CONSTRAINT extractions_facture_id_fkey FOREIGN KEY (facture_id) REFERENCES public.factures(id);


--
-- Name: extractions extractions_reutilise_de_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.extractions
    ADD CONSTRAINT extractions_reutilise_de_fkey FOREIGN KEY (reutilise_de) REFERENCES public.extractions(id);


--
-- Name: factures factures_facture_origine_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.factures
    ADD CONSTRAINT factures_facture_origine_id_fkey FOREIGN KEY (facture_origine_id) REFERENCES public.factures(id);


--
-- Name: factures factures_fournisseur_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.factures
    ADD CONSTRAINT factures_fournisseur_id_fkey FOREIGN KEY (fournisseur_id) REFERENCES public.fournisseurs(id);


--
-- Name: fournisseur_ribs fournisseur_ribs_fournisseur_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fournisseur_ribs
    ADD CONSTRAINT fournisseur_ribs_fournisseur_id_fkey FOREIGN KEY (fournisseur_id) REFERENCES public.fournisseurs(id);


--
-- Name: lignes_facture lignes_facture_facture_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lignes_facture
    ADD CONSTRAINT lignes_facture_facture_id_fkey FOREIGN KEY (facture_id) REFERENCES public.factures(id) ON DELETE CASCADE;


--
-- Name: lignes_releve lignes_releve_releve_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lignes_releve
    ADD CONSTRAINT lignes_releve_releve_id_fkey FOREIGN KEY (releve_id) REFERENCES public.releves_bancaires(id) ON DELETE CASCADE;


--
-- Name: notifications notifications_demande_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_demande_id_fkey FOREIGN KEY (demande_id) REFERENCES public.demandes_referentiel(id);


--
-- Name: notifications notifications_facture_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_facture_id_fkey FOREIGN KEY (facture_id) REFERENCES public.factures(id);


--
-- Name: notifications notifications_utilisateur_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_utilisateur_id_fkey FOREIGN KEY (utilisateur_id) REFERENCES public.utilisateurs(id);


--
-- Name: rapprochements rapprochements_facture_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rapprochements
    ADD CONSTRAINT rapprochements_facture_id_fkey FOREIGN KEY (facture_id) REFERENCES public.factures(id);


--
-- Name: rapprochements rapprochements_ligne_releve_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rapprochements
    ADD CONSTRAINT rapprochements_ligne_releve_id_fkey FOREIGN KEY (ligne_releve_id) REFERENCES public.lignes_releve(id);


--
-- Name: resultats_controles resultats_controles_facture_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resultats_controles
    ADD CONSTRAINT resultats_controles_facture_id_fkey FOREIGN KEY (facture_id) REFERENCES public.factures(id);


--
-- Name: resultats_controles resultats_controles_regle_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resultats_controles
    ADD CONSTRAINT resultats_controles_regle_fk FOREIGN KEY (regle) REFERENCES public.regles_controle(regle);


--
-- PostgreSQL database dump complete
--

\unrestrict dbmate


--
-- Dbmate schema migrations
--

INSERT INTO public.schema_migrations (version) VALUES
    ('20261005120000'),
    ('20261005120100'),
    ('20261005120200'),
    ('20261005120300'),
    ('20261005120400'),
    ('20261005120500'),
    ('20261005120600'),
    ('20261005120700'),
    ('20261005120800'),
    ('20261005120900'),
    ('20261005121000'),
    ('20261006090000'),
    ('20261006100000'),
    ('20261006110000'),
    ('20261006110100'),
    ('20261006120000'),
    ('20261006130000'),
    ('20261008090000'),
    ('20261008100000'),
    ('20261008110000');
