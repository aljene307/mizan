"""Tests de la passerelle Telegram (D-064), contre un faux serveur Telegram.

Lancés dans l'image de la passerelle par tests/integration/passerelle.test.js :
    python3 -m unittest -v test_passerelle
Vérifient en particulier que le jeton n'apparaît jamais dans les réponses ni
dans les journaux, y compris quand Telegram ou le réseau échouent.
"""

import io
import json
import logging
import os
import sys
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

JETON = "123456789:AAFauxJetonDeTestPourLaPasserelle00"
# Fonction d'ouverture du client de test, gardée avant toute substitution.
OUVRIR = urllib.request.urlopen


class FauxTelegram(BaseHTTPRequestHandler):
    """Répond selon la méthode ; garde les requêtes reçues."""

    recues = []

    def log_message(self, *args):
        pass

    def do_POST(self):  # noqa: N802
        corps = json.loads(self.rfile.read(int(self.headers["Content-Length"])).decode())
        FauxTelegram.recues.append((self.path, corps))
        methode = self.path.rsplit("/", 1)[-1]
        if methode == "answerCallbackQuery":
            # Pire cas : une erreur qui recopie le jeton (et l'URL) dans sa description.
            self.envoyer(401, {"ok": False, "error_code": 401, "description": f"Unauthorized {self.path} {JETON}"})
        elif methode == "editMessageReplyMarkup":
            time.sleep(3)
            self.envoyer(200, {"ok": True, "result": True})
        else:
            self.envoyer(200, {"ok": True, "result": {"message_id": 42, "echo": self.path}})

    def envoyer(self, code, contenu):
        donnees = json.dumps(contenu).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(donnees)))
        self.end_headers()
        self.wfile.write(donnees)


def demarrer(gestionnaire, classe=ThreadingHTTPServer):
    serveur = classe(("127.0.0.1", 0), gestionnaire)
    threading.Thread(target=serveur.serve_forever, daemon=True).start()
    return serveur


class TestPasserelle(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.faux = demarrer(FauxTelegram)
        os.environ["TELEGRAM_BOT_TOKEN"] = JETON
        os.environ["TELEGRAM_API"] = f"http://127.0.0.1:{cls.faux.server_port}"
        import serveur  # après la configuration de l'environnement

        cls.serveur_module = serveur
        serveur.API = os.environ["TELEGRAM_API"]
        serveur.DELAI_S = 1
        cls.journal = io.StringIO()
        gestion = logging.StreamHandler(cls.journal)
        serveur.journal.addHandler(gestion)
        serveur.journal.setLevel(logging.INFO)
        cls.passerelle = demarrer(serveur.Gestionnaire, serveur.Serveur)
        cls.base = f"http://127.0.0.1:{cls.passerelle.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.passerelle.shutdown()
        cls.faux.shutdown()

    def appeler(self, chemin, corps=None, brut=None):
        donnees = brut if brut is not None else (json.dumps(corps).encode() if corps is not None else None)
        requete = urllib.request.Request(self.base + chemin, data=donnees, method="POST" if donnees is not None else "GET",
                                         headers={"Content-Type": "application/json"})
        try:
            with OUVRIR(requete, timeout=10) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()

    def sans_jeton(self, texte):
        self.assertNotIn(JETON, texte)
        self.assertNotIn(JETON.split(":")[1], texte)

    def test_envoi_relaye_avec_le_jeton_vers_telegram_mais_jamais_rendu(self):
        code, texte = self.appeler("/telegram/sendMessage", {"chat_id": 1, "text": "Bonjour"})
        self.assertEqual(code, 200)
        reponse = json.loads(texte)
        self.assertTrue(reponse["ok"])
        self.assertEqual(reponse["result"]["message_id"], 42)
        chemin, corps = FauxTelegram.recues[-1]
        self.assertEqual(chemin, f"/bot{JETON}/sendMessage", "le jeton est bien utilisé vers Telegram")
        self.assertEqual(corps, {"chat_id": 1, "text": "Bonjour"})
        self.sans_jeton(texte)
        self.assertIn("/bot***/sendMessage", texte, "l'écho de l'URL est masqué")

    def test_methode_hors_liste_refusee_sans_appel(self):
        avant = len(FauxTelegram.recues)
        for methode in ("deleteWebhook", "setWebhook", "getMe", "", "sendMessage/../setWebhook"):
            code, _ = self.appeler(f"/telegram/{methode}", {})
            self.assertEqual(code, 403, methode)
        self.assertEqual(len(FauxTelegram.recues), avant, "rien n'est transmis à Telegram")

    def test_interrogation_longue_plafonnee_et_types_de_mises_a_jour(self):
        self.appeler("/telegram/getUpdates", {"offset": 7, "timeout": 600})
        _, corps = FauxTelegram.recues[-1]
        self.assertEqual(corps["timeout"], 50)
        self.assertEqual(corps["allowed_updates"], ["message", "callback_query"])
        self.assertEqual(corps["offset"], 7)

    def test_erreur_de_telegram_qui_recopie_le_jeton_masquee(self):
        code, texte = self.appeler("/telegram/answerCallbackQuery", {"callback_query_id": "x"})
        self.assertEqual(code, 200)
        reponse = json.loads(texte)
        self.assertFalse(reponse["ok"])
        self.assertEqual(reponse["error_code"], 401)
        self.sans_jeton(texte)

    def test_delai_depasse_masque(self):
        code, texte = self.appeler("/telegram/editMessageReplyMarkup", {"chat_id": 1, "message_id": 2})
        self.assertEqual(code, 504)
        self.sans_jeton(texte)

    def test_erreur_reseau_masquee(self):
        ancien = self.serveur_module.API
        self.serveur_module.API = "http://127.0.0.1:9"  # port fermé : connexion refusée
        try:
            code, texte = self.appeler("/telegram/sendMessage", {"chat_id": 1, "text": "x"})
        finally:
            self.serveur_module.API = ancien
        self.assertEqual(code, 502)
        self.assertIn("erreur réseau", texte)
        self.sans_jeton(texte)

    def test_corps_invalide_ou_trop_gros(self):
        self.assertEqual(self.appeler("/telegram/sendMessage", brut=b"pas du json")[0], 400)
        self.assertEqual(self.appeler("/telegram/sendMessage", brut=b"[1, 2]")[0], 400)
        self.assertEqual(self.appeler("/telegram/sendMessage", brut=b"x" * (64 * 1024 + 1))[0], 413)

    def test_sante_ne_revele_pas_le_jeton(self):
        code, texte = self.appeler("/sante")
        self.assertEqual(code, 200)
        self.assertTrue(json.loads(texte)["jeton_configure"])
        self.sans_jeton(texte)

    def test_jeton_fictif_ou_absent_refuse(self):
        ancien = os.environ["TELEGRAM_BOT_TOKEN"]
        os.environ["TELEGRAM_BOT_TOKEN"] = "change-me"
        try:
            code, _ = self.appeler("/telegram/sendMessage", {"chat_id": 1, "text": "x"})
        finally:
            os.environ["TELEGRAM_BOT_TOKEN"] = ancien
        self.assertEqual(code, 503)

    def appeler_en_capturant_stderr(self, *args, **kwargs):
        """Appel en capturant AUSSI la sortie d'erreur (traces Python du serveur)."""
        sortie = io.StringIO()
        ancienne = sys.stderr
        sys.stderr = sortie
        try:
            resultat = self.appeler(*args, **kwargs)
        finally:
            sys.stderr = ancienne
        return resultat, sortie.getvalue()

    def test_incident_jeton_avec_espace_refuse_sans_fuite(self):
        # Incident du 2026-10-08 : jeton collé avec une espace dans .env ;
        # l'URL invalide levait une exception non rattrapée, dont la trace
        # (avec le jeton) partait dans les journaux, et la connexion était coupée.
        ancien = os.environ["TELEGRAM_BOT_TOKEN"]
        avec_espace = "123456789:AAFauxJeton DeTestAvecUneEspaceDedans00"
        os.environ["TELEGRAM_BOT_TOKEN"] = avec_espace
        try:
            (code, texte), traces = self.appeler_en_capturant_stderr("/telegram/getUpdates", {"timeout": 0})
            _, sante = self.appeler("/sante")
        finally:
            os.environ["TELEGRAM_BOT_TOKEN"] = ancien
        self.assertEqual(code, 503, "réponse propre, pas de connexion coupée")
        self.assertIn("mal formé", texte)
        self.assertFalse(json.loads(sante)["jeton_bien_forme"])
        for morceau in avec_espace.split(" ") + avec_espace.split(":"):
            for sortie in (texte, traces, self.journal.getvalue(), sante):
                self.assertNotIn(morceau, sortie)

    def test_erreur_imprevue_rattrapee_et_masquee(self):
        # Toute exception imprévue : réponse 502 propre, aucune trace, jeton masqué.
        serveur = self.serveur_module

        def planter(*args, **kwargs):
            raise ValueError(f"panne imprévue sur /bot{JETON}/sendMessage")

        ancien = serveur.urllib.request.urlopen
        serveur.urllib.request.urlopen = planter
        try:
            (code, texte), traces = self.appeler_en_capturant_stderr("/telegram/sendMessage", {"chat_id": 1, "text": "x"})
        finally:
            serveur.urllib.request.urlopen = ancien
        self.assertEqual(code, 502)
        self.assertIn("erreur imprévue", texte)
        self.assertNotIn("Traceback", traces)
        for sortie in (texte, traces, self.journal.getvalue()):
            self.sans_jeton(sortie)

    def test_journaux_sans_jeton(self):
        # Après tous les autres tests (ordre alphabétique) : succès, erreurs, délais.
        self.appeler("/telegram/answerCallbackQuery", {"callback_query_id": "x"})
        journal = self.journal.getvalue()
        self.assertIn("answerCallbackQuery", journal)
        self.sans_jeton(journal)


if __name__ == "__main__":
    unittest.main()
