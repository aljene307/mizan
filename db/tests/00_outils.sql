-- Fonctions d'assertion, créées dans le schéma temporaire de la session
-- (disparaissent à la déconnexion). Inclus par les fichiers de test.

-- Exécute une requête qui doit réussir.
CREATE FUNCTION pg_temp.doit_reussir(requete text, libelle text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE requete;
    RAISE NOTICE 'OK     %', libelle;
EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'ECHEC  % : erreur inattendue % (%)', libelle, SQLSTATE, SQLERRM;
END;
$$;

-- Exécute une requête qui doit échouer avec le code d'erreur attendu.
-- Codes utiles : 23514 check, 23505 unicité, 23P01 exclusion,
-- 42501 droits insuffisants, MZ001 journal d'audit en ajout seul.
CREATE FUNCTION pg_temp.doit_echouer(requete text, code_attendu text, libelle text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE requete;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = code_attendu THEN
            RAISE NOTICE 'OK     % (refusé : %)', libelle, SQLSTATE;
            RETURN;
        END IF;
        RAISE EXCEPTION 'ECHEC  % : code % attendu, obtenu % (%)', libelle, code_attendu, SQLSTATE, SQLERRM;
    END;
    RAISE EXCEPTION 'ECHEC  % : la requête aurait dû être refusée', libelle;
END;
$$;

-- Vérifie qu'une requête renvoie la valeur attendue.
CREATE FUNCTION pg_temp.doit_valoir(requete text, attendu text, libelle text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    obtenu text;
BEGIN
    EXECUTE requete INTO obtenu;
    IF obtenu IS DISTINCT FROM attendu THEN
        RAISE EXCEPTION 'ECHEC  % : attendu %, obtenu %', libelle, attendu, obtenu;
    END IF;
    RAISE NOTICE 'OK     %', libelle;
END;
$$;
