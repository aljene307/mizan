-- migrate:up

-- Rapprochement manuel d'une ligne dont la proposition a été rejetée (D-068,
-- D1). La ligne est rapprochée d'une facture choisie par une personne
-- (validateur ou responsable), ou signalée « sans facture ». Les mêmes
-- garanties qu'au rapprochement automatique : facture approuvée (MZ041),
-- justification, motif d'écart (MZ043), contrôle « sortie sans ordre »
-- (déclencheur sur le règlement confirmé). Une proposition rejetée n'est
-- toujours pas reproposée automatiquement.

-- 1. Lignes à rapprocher à la main. ---------------------------------------------------
-- Sortie d'argent dont une proposition a été rejetée, sans proposition ouverte
-- ou confirmée, sans signalement, sans catégorie.
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

-- Montant encore à payer d'une facture approuvée : reste, moins un paiement
-- déjà proposé sur une autre ligne. NULL si la facture n'est pas approuvée.
CREATE FUNCTION montant_a_rapprocher(p_facture_id BIGINT) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT s.reste_a_payer - s.paiement_propose FROM situation_paiement s WHERE s.facture_id = p_facture_id;
$$;

-- 2. Facture désignée par son numéro (bouton « Autre facture »). ---------------------
-- Parmi les factures approuvées seulement ; numéro comparé sans espaces ni
-- casse. Aucune ou plusieurs : refus explicite (MZ045).
CREATE FUNCTION facture_par_numero(p_numero TEXT) RETURNS BIGINT
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_ids BIGINT[];
BEGIN
    SELECT array_agg(f.id) INTO v_ids FROM factures f
    WHERE f.type_document = 'facture' AND f.statut IN ('conforme', 'validee')
      AND upper(regexp_replace(f.numero, '\s', '', 'g')) = upper(regexp_replace(coalesce(p_numero, ''), '\s', '', 'g'));
    IF coalesce(array_length(v_ids, 1), 0) <> 1 THEN
        RAISE EXCEPTION 'facture « % » : % facture(s) approuvée(s) de ce numéro', p_numero, coalesce(array_length(v_ids, 1), 0)
            USING ERRCODE = 'MZ045';
    END IF;
    RETURN v_ids[1];
END;
$$;

-- 3. Rapprochement manuel. ---------------------------------------------------------------
-- Opération ≤ montant à payer : paiement exact ou partiel. Au-delà, dans la
-- tolérance : écart, motif « autre » (la justification l'explique). Plus :
-- refus (MZ046). La proposition est créée puis confirmée par une décision
-- ordinaire : mêmes déclencheurs, même journal, même contrôle d'ordre.
CREATE FUNCTION rapprocher_manuellement(p_ligne BIGINT, p_facture BIGINT, p_utilisateur BIGINT, p_justification TEXT, p_canal TEXT)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_ligne     lignes_a_rapprocher%ROWTYPE;
    v_facture   factures%ROWTYPE;
    v_a_payer   NUMERIC;
    v_tolerance NUMERIC;
    v_affecte   NUMERIC;
    v_ecart     NUMERIC := 0;
    v_cas       TEXT;
    v_prop      BIGINT;
    v_decision  BIGINT;
BEGIN
    PERFORM utilisateur_autorise(p_utilisateur, ARRAY['validateur', 'responsable']);
    PERFORM verifier_justification(p_justification);
    PERFORM 1 FROM lignes_releve WHERE id = p_ligne FOR UPDATE;
    SELECT * INTO v_ligne FROM lignes_a_rapprocher WHERE ligne_releve_id = p_ligne;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ligne % : plus à rapprocher (déjà traitée)', p_ligne USING ERRCODE = 'MZ042';
    END IF;
    SELECT * INTO v_facture FROM factures WHERE id = p_facture;
    v_a_payer := montant_a_rapprocher(p_facture);
    IF v_a_payer IS NULL OR v_a_payer <= 0 THEN
        RAISE EXCEPTION 'facture % : non approuvée ou plus rien à payer', coalesce(v_facture.numero, p_facture::text) USING ERRCODE = 'MZ041';
    END IF;
    v_tolerance := parametre_controle('rapprochement.tolerance_ecart', v_ligne.date_operation);
    IF v_ligne.debit <= v_a_payer THEN
        v_affecte := v_ligne.debit;
        v_cas := CASE WHEN v_ligne.debit = v_a_payer THEN 'exact' ELSE 'partiel' END;
    ELSIF v_ligne.debit - v_a_payer <= v_tolerance THEN
        v_affecte := v_a_payer;
        v_ecart := v_ligne.debit - v_a_payer;
        v_cas := 'ecart';
    ELSE
        RAISE EXCEPTION 'opération de % TND, reste dû % TND sur la facture % : au-delà de la tolérance',
            v_ligne.debit, v_a_payer, v_facture.numero USING ERRCODE = 'MZ046';
    END IF;

    INSERT INTO propositions_rapprochement (ligne_releve_id, cas, score, raisons, ecart, methode, statut)
    VALUES (p_ligne, v_cas, 0, jsonb_build_array('rapprochement manuel après rejet', 'facture choisie par l''utilisateur ' || p_utilisateur),
            v_ecart, 'manuel', 'propose')
    RETURNING id INTO v_prop;
    INSERT INTO rapprochements (facture_id, ligne_releve_id, montant_affecte, methode, score, statut, ecart, cree_par, proposition_id, role)
    VALUES (p_facture, p_ligne, v_affecte, 'manuel', 0, 'propose', v_ecart, 'utilisateur:' || p_utilisateur, v_prop, 'reglement');
    INSERT INTO decisions_rapprochement (proposition_id, decision, motif_ecart, utilisateur_id, justification, canal)
    VALUES (v_prop, 'confirmer', CASE WHEN v_ecart <> 0 THEN 'autre' END, p_utilisateur, p_justification, p_canal)
    RETURNING id INTO v_decision;
    RETURN v_decision;
END;
$$;

-- 4. « Aucune facture » : la ligne devient un signalement pour le responsable. ----------
CREATE FUNCTION signaler_ligne_sans_facture(p_ligne BIGINT, p_utilisateur BIGINT, p_justification TEXT, p_canal TEXT)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_id BIGINT;
BEGIN
    PERFORM utilisateur_autorise(p_utilisateur, ARRAY['validateur', 'responsable']);
    PERFORM verifier_justification(p_justification);
    PERFORM 1 FROM lignes_releve WHERE id = p_ligne FOR UPDATE;
    IF NOT EXISTS (SELECT 1 FROM lignes_a_rapprocher WHERE ligne_releve_id = p_ligne) THEN
        RAISE EXCEPTION 'ligne % : plus à rapprocher (déjà traitée)', p_ligne USING ERRCODE = 'MZ042';
    END IF;
    INSERT INTO signalements_paiement (type, ligne_releve_id, message, detail)
    VALUES ('sortie_sans_facture', p_ligne, 'aucune facture ne correspond, selon la personne qui a examiné la ligne',
            jsonb_build_object('signale_par', p_utilisateur, 'justification', p_justification))
    RETURNING id INTO v_id;
    INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_apres, commentaire)
    VALUES ('utilisateur:' || p_utilisateur, 'ligne_releve.sans_facture', 'lignes_releve', p_ligne::text, p_canal,
            jsonb_build_object('signalement_id', v_id), p_justification);
    RETURN v_id;
END;
$$;

-- 5. Restitution : les lignes à rapprocher apparaissent dans « à traiter ». -------------
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
SELECT 'ligne_a_rapprocher', a.ligne_releve_id, a.libelle, NULL, a.debit, 'proposition rejetée', a.date_operation::timestamptz
FROM public.lignes_a_rapprocher a;

-- 6. Droits. -------------------------------------------------------------------------------
-- Ces fonctions ne sont appelées que par le canal (appliquer_action).
GRANT SELECT ON lignes_a_rapprocher TO mizan_app;
REVOKE EXECUTE ON FUNCTION rapprocher_manuellement(BIGINT, BIGINT, BIGINT, TEXT, TEXT),
    signaler_ligne_sans_facture(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;

-- migrate:down

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
WHERE NOT EXISTS (SELECT 1 FROM public.decisions_referentiel r WHERE r.demande_id = d.id);
DROP FUNCTION signaler_ligne_sans_facture(BIGINT, BIGINT, TEXT, TEXT);
DROP FUNCTION rapprocher_manuellement(BIGINT, BIGINT, BIGINT, TEXT, TEXT);
DROP FUNCTION facture_par_numero(TEXT);
DROP FUNCTION montant_a_rapprocher(BIGINT);
DROP VIEW lignes_a_rapprocher;
