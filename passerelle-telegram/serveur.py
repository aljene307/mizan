"""Passerelle Telegram de Mizan (D-064).

Seul composant à détenir le jeton du bot (variable TELEGRAM_BOT_TOKEN, lue
dans .env et transmise à ce seul conteneur). n8n l'appelle sur le réseau
Docker dédié « canal-telegram » ; aucun port n'est publié.

POST /telegram/<méthode>  corps JSON -> réponse JSON de Telegram, jeton masqué
GET  /sante               -> {"statut", "jeton_configure", "methodes"}

Méthodes admises (liste fermée) : getUpdates, sendMessage,
answerCallbackQuery, editMessageReplyMarkup. Toute autre est refusée (403).
Le jeton n'apparaît jamais dans les réponses ni dans les journaux, y compris
en cas d'erreur de Telegram ou du réseau : tout texte sortant est masqué.
Bibliothèque standard uniquement.
"""

import json
import logging
import os
import re
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PASSERELLE_PORT", "8885"))
API = os.environ.get("TELEGRAM_API", "https://api.telegram.org").rstrip("/")
METHODES = ("getUpdates", "sendMessage", "answerCallbackQuery", "editMessageReplyMarkup")
TAILLE_MAX = 64 * 1024
ATTENTE_MAX_S = 50  # interrogation longue (getUpdates.timeout), plafonnée
DELAI_S = 30  # appels ordinaires
MISES_A_JOUR = ["message", "callback_query"]
MASQUE = "***"

journal = logging.getLogger("passerelle")


def jeton():
    """Jeton du bot, ou chaîne vide s'il n'est pas configuré."""
    valeur = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    return "" if valeur in ("", "change-me") else valeur


# Forme d'un jeton de bot : identifiant numérique, deux-points, secret.
FORME_JETON = re.compile(r"^\d+:[A-Za-z0-9_-]{30,}$")


def jeton_bien_forme():
    return bool(FORME_JETON.match(jeton()))


def masquer(texte):
    """Retire le jeton de tout texte sortant (réponse ou journal), ainsi que
    chacun de ses morceaux (un jeton mal collé peut être coupé par une
    espace ou un retour à la ligne)."""
    texte = str(texte)
    secret = jeton()
    if not secret:
        return texte
    morceaux = [secret] + [m for m in re.split(r"[\s:]+", secret) if len(m) >= 8]
    for morceau in sorted(set(morceaux), key=len, reverse=True):
        texte = texte.replace(morceau, MASQUE)
    return texte


def masquer_json(valeur):
    """Masque le jeton dans toutes les chaînes d'une valeur JSON."""
    if isinstance(valeur, str):
        return masquer(valeur)
    if isinstance(valeur, list):
        return [masquer_json(v) for v in valeur]
    if isinstance(valeur, dict):
        return {k: masquer_json(v) for k, v in valeur.items()}
    return valeur


def preparer(methode, corps):
    """Corps envoyé à Telegram et délai d'attente de la réponse."""
    corps = dict(corps)
    if methode == "getUpdates":
        attente = corps.get("timeout", 0)
        attente = attente if isinstance(attente, int) and attente >= 0 else 0
        corps["timeout"] = min(attente, ATTENTE_MAX_S)
        corps.setdefault("allowed_updates", MISES_A_JOUR)
        return corps, corps["timeout"] + 15
    return corps, DELAI_S


def appeler(methode, corps):
    """Appelle Telegram. Renvoie (code HTTP, réponse JSON déjà masquée)."""
    secret = jeton()
    if not secret:
        return 503, {"ok": False, "description": "jeton du bot non configuré (TELEGRAM_BOT_TOKEN)"}
    if not jeton_bien_forme():
        # Incident du 2026-10-08 : espace dans le jeton → URL invalide.
        return 503, {"ok": False, "description": "jeton du bot mal formé : vérifier TELEGRAM_BOT_TOKEN dans .env "
                                                 "(espace, guillemet ou caractère parasite ?)"}
    corps, delai = preparer(methode, corps)
    requete = urllib.request.Request(
        f"{API}/bot{secret}/{methode}",
        data=json.dumps(corps).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(requete, timeout=delai) as reponse:
            return 200, masquer_json(json.loads(reponse.read().decode("utf-8")))
    except urllib.error.HTTPError as erreur:
        # Telegram répond en JSON même en erreur (401, 400, 409, 429…).
        try:
            contenu = json.loads(erreur.read().decode("utf-8"))
        except (ValueError, OSError):
            contenu = {"ok": False, "error_code": erreur.code, "description": f"HTTP {erreur.code}"}
        return 200, masquer_json(contenu)
    except (TimeoutError, OSError) as erreur:
        # L'exception peut citer l'URL, donc le jeton : texte masqué.
        raison = getattr(erreur, "reason", erreur)
        if isinstance(raison, TimeoutError) or isinstance(erreur, TimeoutError):
            return 504, {"ok": False, "description": f"délai dépassé ({delai} s)"}
        return 502, {"ok": False, "description": masquer(f"erreur réseau : {raison}")}
    except Exception as erreur:  # noqa: BLE001 — toute autre erreur : réponse propre, type seul
        # Le message d'une exception imprévue peut contenir l'URL, donc le
        # jeton : seul son type est rendu et journalisé.
        return 502, {"ok": False, "description": f"erreur imprévue ({type(erreur).__name__})"}


class Gestionnaire(BaseHTTPRequestHandler):
    server_version = "passerelle-telegram"

    def log_message(self, format, *args):  # noqa: A002 (signature imposée)
        journal.info(masquer(format % args))

    def repondre(self, code, contenu):
        donnees = json.dumps(masquer_json(contenu), ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(donnees)))
        self.end_headers()
        self.wfile.write(donnees)

    def do_GET(self):  # noqa: N802
        if self.path != "/sante":
            self.repondre(404, {"ok": False, "description": "inconnu"})
            return
        self.repondre(200, {"statut": "ok", "jeton_configure": bool(jeton()), "jeton_bien_forme": jeton_bien_forme(),
                            "methodes": list(METHODES)})

    def do_POST(self):  # noqa: N802
        debut = time.monotonic()
        prefixe = "/telegram/"
        methode = self.path[len(prefixe):] if self.path.startswith(prefixe) else ""
        if methode not in METHODES:
            self.repondre(403, {"ok": False, "description": f"méthode non admise : {methode[:40]}"})
            return
        longueur = int(self.headers.get("Content-Length") or 0)
        if longueur > TAILLE_MAX:
            # Corps lu (jusqu'à 1 Mo) avant de refuser, pour une réponse propre.
            if longueur <= 1024 * 1024:
                self.rfile.read(longueur)
            self.repondre(413, {"ok": False, "description": "corps trop volumineux"})
            return
        try:
            corps = json.loads(self.rfile.read(longueur).decode("utf-8") or "{}")
            if not isinstance(corps, dict):
                raise ValueError("objet JSON attendu")
        except ValueError as erreur:
            self.repondre(400, {"ok": False, "description": f"JSON invalide : {erreur}"})
            return
        code, contenu = appeler(methode, corps)
        journal.info(masquer(f"{methode} -> HTTP {code}, ok={contenu.get('ok')}, {round((time.monotonic() - debut) * 1000)} ms"))
        self.repondre(code, contenu)


class Serveur(ThreadingHTTPServer):
    """Remplace le gestionnaire d'erreurs par défaut de Python, qui écrit la
    trace complète (avec ses variables, dont l'URL et le jeton) sur la
    sortie d'erreur : une ligne masquée, sans trace."""

    def handle_error(self, request, client_address):
        erreur = sys.exc_info()[1]
        journal.error(masquer(f"erreur non rattrapée ({type(erreur).__name__}) ; trace non journalisée"))


def main():
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(asctime)s %(message)s")
    journal.info("passerelle Telegram sur le port %s ; jeton configuré : %s ; bien formé : %s",
                 PORT, bool(jeton()), jeton_bien_forme())
    Serveur(("0.0.0.0", PORT), Gestionnaire).serve_forever()


if __name__ == "__main__":
    main()
