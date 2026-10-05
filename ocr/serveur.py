"""Service OCR de Mizan : Tesseract derrière une petite API HTTP (D-032).

POST /ocr    corps = le fichier (image ou PDF), en-tête Content-Type
             -> {"texte", "pages", "duree_ms", "moteur", "langue", "psm"}
GET  /sante  -> {"statut": "ok", "moteur", "langue"}

Mode ligne de commande (tests) : python3 serveur.py --stdin <type MIME> < fichier
Bibliothèque standard uniquement. Aucun port n'est publié sur la machine :
n8n appelle http://ocr:8884 sur le réseau Docker interne.
"""

import glob
import json
import os
import subprocess
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LANGUE = os.environ.get("OCR_LANGUE", "fra")
PSM = os.environ.get("OCR_PSM", "3")
DELAI_S = int(os.environ.get("OCR_DELAI_S", "90"))
TAILLE_MAX = 20 * 1024 * 1024
PORT = 8884
TYPES = {
    "application/pdf": "pdf",
    "image/jpeg": "image",
    "image/png": "image",
    "image/tiff": "image",
}


class ErreurOcr(Exception):
    def __init__(self, code_http, message):
        super().__init__(message)
        self.code_http = code_http


def version_moteur():
    sortie = subprocess.run(["tesseract", "--version"], capture_output=True, text=True, check=False)
    premiere_ligne = (sortie.stdout or sortie.stderr).splitlines()
    return premiere_ligne[0].strip() if premiere_ligne else "tesseract"


MOTEUR = version_moteur()


def lancer(commande):
    try:
        return subprocess.run(commande, capture_output=True, text=True, timeout=DELAI_S, check=True).stdout
    except subprocess.TimeoutExpired as erreur:
        raise ErreurOcr(504, f"délai dépassé ({DELAI_S} s)") from erreur
    except subprocess.CalledProcessError as erreur:
        raise ErreurOcr(422, f"fichier illisible : {erreur.stderr.strip()[:300]}") from erreur


def ocr_image(chemin):
    return lancer(["tesseract", chemin, "stdout", "-l", LANGUE, "--psm", PSM])


def reconnaitre(contenu, type_mime):
    """Renvoie le texte reconnu et le nombre de pages."""
    genre = TYPES.get(type_mime.split(";")[0].strip().lower())
    if genre is None:
        raise ErreurOcr(415, f"type non pris en charge : {type_mime}")
    if not contenu:
        raise ErreurOcr(400, "fichier vide")
    with tempfile.TemporaryDirectory() as dossier:
        chemin = os.path.join(dossier, "entree.pdf" if genre == "pdf" else "entree")
        with open(chemin, "wb") as fichier:
            fichier.write(contenu)
        if genre == "image":
            return ocr_image(chemin), 1
        lancer(["pdftoppm", "-r", "300", "-png", chemin, os.path.join(dossier, "page")])
        pages = sorted(glob.glob(os.path.join(dossier, "page*.png")))
        if not pages:
            raise ErreurOcr(422, "PDF sans page")
        return "\n\f\n".join(ocr_image(page) for page in pages), len(pages)


def traiter(contenu, type_mime):
    debut = time.monotonic()
    texte, pages = reconnaitre(contenu, type_mime)
    return {
        "texte": texte,
        "pages": pages,
        "duree_ms": round((time.monotonic() - debut) * 1000),
        "moteur": MOTEUR,
        "langue": LANGUE,
        "psm": PSM,
    }


class Gestionnaire(BaseHTTPRequestHandler):
    def repondre(self, code, donnees):
        corps = json.dumps(donnees, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)

    def do_GET(self):
        if self.path == "/sante":
            self.repondre(200, {"statut": "ok", "moteur": MOTEUR, "langue": LANGUE})
        else:
            self.repondre(404, {"erreur": "inconnu"})

    def do_POST(self):
        if self.path != "/ocr":
            self.repondre(404, {"erreur": "inconnu"})
            return
        try:
            taille = int(self.headers.get("Content-Length", "0"))
            if taille > TAILLE_MAX:
                raise ErreurOcr(413, "fichier trop volumineux")
            contenu = self.rfile.read(taille)
            self.repondre(200, traiter(contenu, self.headers.get("Content-Type", "")))
        except ErreurOcr as erreur:
            self.repondre(erreur.code_http, {"erreur": str(erreur)})
        except Exception as erreur:  # noqa: BLE001 - toute autre panne devient une 500 lisible
            self.repondre(500, {"erreur": f"erreur interne : {erreur}"})

    def log_message(self, format, *args):  # noqa: A002 - signature imposée
        sys.stderr.write(f"[ocr] {self.address_string()} {format % args}\n")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--stdin":
        try:
            print(json.dumps(traiter(sys.stdin.buffer.read(), sys.argv[2]), ensure_ascii=False))
        except ErreurOcr as erreur:
            print(json.dumps({"erreur": str(erreur), "code_http": erreur.code_http}, ensure_ascii=False))
            sys.exit(1)
    else:
        print(f"Service OCR ({MOTEUR}, langue {LANGUE}, psm {PSM}) sur le port {PORT}", flush=True)
        ThreadingHTTPServer(("0.0.0.0", PORT), Gestionnaire).serve_forever()
