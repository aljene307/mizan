-- migrate:up

-- Défauts du 2026-10-10 (démonstration de l'annulation) :
-- 1. Le chèque 9886778 ne pouvait pas être rapproché à la main de
--    MC2026-00089 : une contrainte d'unicité (facture, ligne) comptait aussi
--    le lien REJETÉ le 2026-10-09, gardé dans l'historique. L'unicité ne
--    porte plus que sur les liens actifs (proposé, confirmé) ; rien n'est
--    effacé.
-- 2. Le message technique de la base arrivait tel quel à l'utilisateur. Une
--    erreur interne (hors codes MZ) est désormais tracée au journal d'audit ;
--    l'utilisateur reçoit un message lisible avec la référence de l'incident.

ALTER TABLE rapprochements DROP CONSTRAINT rapprochements_paire_uk;
CREATE UNIQUE INDEX rapprochements_paire_active_uk ON rapprochements (facture_id, ligne_releve_id)
    WHERE statut NOT IN ('rejete', 'annule');

CREATE OR REPLACE FUNCTION recevoir_evenement(p JSONB) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
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
            ELSIF v_notif.objet = 'rapprochement'
                  AND (SELECT statut FROM propositions_rapprochement WHERE id = v_notif.proposition_id) <> 'propose' THEN
                v_res := jsonb_build_object('code', 'notification_perimee');
            ELSIF v_notif.objet = 'signalement'
                  AND (SELECT statut FROM signalements_paiement WHERE id = v_notif.signalement_id) <> 'ouvert' THEN
                v_res := jsonb_build_object('code', 'notification_perimee');
            ELSIF v_notif.objet = 'lot_paiement'
                  AND (SELECT statut FROM lots_paiement WHERE id = v_notif.lot_id) <> 'propose' THEN
                v_res := jsonb_build_object('code', 'notification_perimee');
            ELSIF v_notif.objet = 'ligne_a_rapprocher'
                  AND (NOT EXISTS (SELECT 1 FROM lignes_a_rapprocher WHERE ligne_releve_id = v_notif.ligne_releve_id)
                       OR v_notif.cree_le < ligne_a_rapprocher_depuis(v_notif.ligne_releve_id)) THEN
                v_res := jsonb_build_object('code', 'notification_perimee');
            ELSIF v_notif.objet = 'demande_annulation'
                  AND EXISTS (SELECT 1 FROM decisions_annulation x WHERE x.demande_id = v_notif.demande_annulation_id) THEN
                v_res := jsonb_build_object('code', 'notification_perimee');
            ELSIF v_notif.objet = 'choix_annulation'
                  AND (SELECT statut FROM propositions_rapprochement WHERE id = (v_action -> 'params' ->> 'proposition_id')::BIGINT)
                      IS DISTINCT FROM 'confirme' THEN
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

    ELSIF v_type = 'commande' AND p ->> 'commande' = 'annuler' THEN
        -- Annulation d'un rapprochement (D-077) : responsable seulement ; la
        -- liste des rapprochements confirmés de la facture arrive par notification.
        IF v_util.role <> 'responsable' THEN
            v_res := jsonb_build_object('code', 'commande_refusee', 'motif', 'role');
        ELSE
            SELECT count(DISTINCT x.id) INTO v_id FROM propositions_rapprochement x
            JOIN rapprochements r ON r.proposition_id = x.id JOIN factures fx ON fx.id = r.facture_id
            WHERE x.statut = 'confirme'
              AND upper(regexp_replace(fx.numero, '\s', '', 'g')) = upper(regexp_replace(coalesce(p ->> 'argument', ''), '\s', '', 'g'));
            IF v_id = 0 THEN
                v_res := jsonb_build_object('code', 'annulation_introuvable', 'numero', p ->> 'argument');
            ELSE
                INSERT INTO recherches_annulation (utilisateur_id, canal, numero) VALUES (v_util.id, v_canal, btrim(p ->> 'argument'));
                v_res := jsonb_build_object('code', 'recherche_annulation_enregistree', 'numero', p ->> 'argument', 'rapprochements', v_id);
            END IF;
        END IF;

    ELSIF v_type = 'question' THEN
        -- Question en langage naturel (D-068, B2) : mise en file, traitée par
        -- le workflow « Questions ». Longueur et nombre par heure limités.
        IF length(btrim(coalesce(p ->> 'texte', ''))) = 0
           OR length(p ->> 'texte') > parametre_controle('questions.longueur_max') THEN
            v_res := jsonb_build_object('code', 'question_refusee', 'motif', 'longueur',
                                        'longueur_max', parametre_controle('questions.longueur_max'));
        ELSIF (SELECT count(*) FROM questions q WHERE q.utilisateur_id = v_util.id AND q.recue_le > now() - interval '1 hour')
              >= parametre_controle('questions.max_par_heure') THEN
            v_res := jsonb_build_object('code', 'question_refusee', 'motif', 'quota',
                                        'max_par_heure', parametre_controle('questions.max_par_heure'));
        ELSE
            INSERT INTO questions (utilisateur_id, canal, adresse, texte, reference)
            VALUES (v_util.id, v_canal, v_adresse, btrim(p ->> 'texte'), p ->> 'reference')
            RETURNING id INTO v_id;
            v_res := jsonb_build_object('code', 'question_recue', 'question_id', v_id);
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
                -- Refus de la base : rien n'est appliqué. Un refus prévu (code
                -- MZ : rôle, justification, quatre yeux…) est expliqué ; une
                -- erreur interne n'est JAMAIS renvoyée telle quelle (défaut du
                -- 2026-10-10) : détail au journal, référence à l'usager.
                IF SQLSTATE LIKE 'MZ%' THEN
                    v_res := jsonb_build_object('code', 'decision_refusee', 'action', v_action,
                                                'erreur', SQLSTATE, 'motif', SQLERRM);
                ELSE
                    INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_apres)
                    VALUES ('utilisateur:' || v_util.id, 'canal.erreur_interne', 'notifications', v_notif.id::text, v_canal,
                            jsonb_build_object('sqlstate', SQLSTATE, 'message', SQLERRM, 'action', v_action))
                    RETURNING id INTO v_id;
                    v_res := jsonb_build_object('code', 'decision_refusee', 'action', v_action,
                                                'erreur', 'interne', 'reference', v_id);
                END IF;
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
$$;

-- migrate:down

CREATE OR REPLACE FUNCTION recevoir_evenement(p JSONB) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
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
            ELSIF v_notif.objet = 'rapprochement'
                  AND (SELECT statut FROM propositions_rapprochement WHERE id = v_notif.proposition_id) <> 'propose' THEN
                v_res := jsonb_build_object('code', 'notification_perimee');
            ELSIF v_notif.objet = 'signalement'
                  AND (SELECT statut FROM signalements_paiement WHERE id = v_notif.signalement_id) <> 'ouvert' THEN
                v_res := jsonb_build_object('code', 'notification_perimee');
            ELSIF v_notif.objet = 'lot_paiement'
                  AND (SELECT statut FROM lots_paiement WHERE id = v_notif.lot_id) <> 'propose' THEN
                v_res := jsonb_build_object('code', 'notification_perimee');
            ELSIF v_notif.objet = 'ligne_a_rapprocher'
                  AND (NOT EXISTS (SELECT 1 FROM lignes_a_rapprocher WHERE ligne_releve_id = v_notif.ligne_releve_id)
                       OR v_notif.cree_le < ligne_a_rapprocher_depuis(v_notif.ligne_releve_id)) THEN
                v_res := jsonb_build_object('code', 'notification_perimee');
            ELSIF v_notif.objet = 'demande_annulation'
                  AND EXISTS (SELECT 1 FROM decisions_annulation x WHERE x.demande_id = v_notif.demande_annulation_id) THEN
                v_res := jsonb_build_object('code', 'notification_perimee');
            ELSIF v_notif.objet = 'choix_annulation'
                  AND (SELECT statut FROM propositions_rapprochement WHERE id = (v_action -> 'params' ->> 'proposition_id')::BIGINT)
                      IS DISTINCT FROM 'confirme' THEN
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

    ELSIF v_type = 'commande' AND p ->> 'commande' = 'annuler' THEN
        -- Annulation d'un rapprochement (D-077) : responsable seulement ; la
        -- liste des rapprochements confirmés de la facture arrive par notification.
        IF v_util.role <> 'responsable' THEN
            v_res := jsonb_build_object('code', 'commande_refusee', 'motif', 'role');
        ELSE
            SELECT count(DISTINCT x.id) INTO v_id FROM propositions_rapprochement x
            JOIN rapprochements r ON r.proposition_id = x.id JOIN factures fx ON fx.id = r.facture_id
            WHERE x.statut = 'confirme'
              AND upper(regexp_replace(fx.numero, '\s', '', 'g')) = upper(regexp_replace(coalesce(p ->> 'argument', ''), '\s', '', 'g'));
            IF v_id = 0 THEN
                v_res := jsonb_build_object('code', 'annulation_introuvable', 'numero', p ->> 'argument');
            ELSE
                INSERT INTO recherches_annulation (utilisateur_id, canal, numero) VALUES (v_util.id, v_canal, btrim(p ->> 'argument'));
                v_res := jsonb_build_object('code', 'recherche_annulation_enregistree', 'numero', p ->> 'argument', 'rapprochements', v_id);
            END IF;
        END IF;

    ELSIF v_type = 'question' THEN
        -- Question en langage naturel (D-068, B2) : mise en file, traitée par
        -- le workflow « Questions ». Longueur et nombre par heure limités.
        IF length(btrim(coalesce(p ->> 'texte', ''))) = 0
           OR length(p ->> 'texte') > parametre_controle('questions.longueur_max') THEN
            v_res := jsonb_build_object('code', 'question_refusee', 'motif', 'longueur',
                                        'longueur_max', parametre_controle('questions.longueur_max'));
        ELSIF (SELECT count(*) FROM questions q WHERE q.utilisateur_id = v_util.id AND q.recue_le > now() - interval '1 hour')
              >= parametre_controle('questions.max_par_heure') THEN
            v_res := jsonb_build_object('code', 'question_refusee', 'motif', 'quota',
                                        'max_par_heure', parametre_controle('questions.max_par_heure'));
        ELSE
            INSERT INTO questions (utilisateur_id, canal, adresse, texte, reference)
            VALUES (v_util.id, v_canal, v_adresse, btrim(p ->> 'texte'), p ->> 'reference')
            RETURNING id INTO v_id;
            v_res := jsonb_build_object('code', 'question_recue', 'question_id', v_id);
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
$$;

-- Échoue si l'historique contient déjà une paire rejetée puis de nouveau active.
DROP INDEX rapprochements_paire_active_uk;
ALTER TABLE rapprochements ADD CONSTRAINT rapprochements_paire_uk UNIQUE (facture_id, ligne_releve_id);
