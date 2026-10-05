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
-- Name: normaliser_numero_facture(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.normaliser_numero_facture(numero text) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    RETURN upper(regexp_replace(numero, '[[:space:]]'::text, ''::text, 'g'::text));


SET default_tablespace = '';

SET default_table_access_method = heap;

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
    CONSTRAINT factures_approuvee_identifiee_ck CHECK (((statut <> ALL (ARRAY['conforme'::text, 'validee'::text])) OR ((fournisseur_id IS NOT NULL) AND (numero IS NOT NULL) AND (btrim(numero) <> ''::text)))),
    CONSTRAINT factures_canal_ck CHECK ((canal_reception = ANY (ARRAY['dossier'::text, 'email'::text, 'telegram'::text]))),
    CONSTRAINT factures_devise_ck CHECK ((devise ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT factures_format_ck CHECK ((format_source = ANY (ARRAY['pdf'::text, 'image'::text, 'xml'::text]))),
    CONSTRAINT factures_methode_ck CHECK ((methode_extraction = ANY (ARRAY['ocr_llm'::text, 'xml'::text, 'manuelle'::text]))),
    CONSTRAINT factures_montants_positifs_ck CHECK (((COALESCE(montant_ht, (0)::numeric) >= (0)::numeric) AND (COALESCE(montant_tva, (0)::numeric) >= (0)::numeric) AND (COALESCE(droit_timbre, (0)::numeric) >= (0)::numeric) AND (COALESCE(montant_ttc, (0)::numeric) >= (0)::numeric))),
    CONSTRAINT factures_origine_avoir_ck CHECK (((facture_origine_id IS NULL) OR (type_document = 'avoir'::text))),
    CONSTRAINT factures_sha256_ck CHECK ((fichier_sha256 ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT factures_statut_ck CHECK ((statut = ANY (ARRAY['recue'::text, 'extraite'::text, 'erreur_extraction'::text, 'conforme'::text, 'anomalie'::text, 'bloquee'::text, 'validee'::text, 'rejetee'::text]))),
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
    CONSTRAINT resultats_controles_gravite_ck CHECK ((gravite = ANY (ARRAY['info'::text, 'avertissement'::text, 'bloquant'::text]))),
    CONSTRAINT resultats_controles_resultat_ck CHECK ((resultat = ANY (ARRAY['ok'::text, 'anomalie'::text, 'erreur'::text])))
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
-- Name: rapprochements_ligne_releve_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rapprochements_ligne_releve_ix ON public.rapprochements USING btree (ligne_releve_id);


--
-- Name: resultats_controles_facture_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resultats_controles_facture_ix ON public.resultats_controles USING btree (facture_id, execute_le DESC);


--
-- Name: resultats_controles_regle_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resultats_controles_regle_ix ON public.resultats_controles USING btree (regle, resultat);


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
    ('20261005120800');
