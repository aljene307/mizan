// Tests du service OCR (conteneur « ocr », sans port publié : les appels
// passent par docker compose exec). Lot de développement uniquement (D-026).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const executer = (args, entree) => spawnSync('docker', ['compose', 'exec', '-T', 'ocr', ...args],
  { input: entree, encoding: 'utf8', maxBuffer: 10 * 1024 * 1024 });
const ocrStdin = (chemin, type) => {
  const r = executer(['python3', 'serveur.py', '--stdin', type], readFileSync(chemin));
  return { code: r.status, json: JSON.parse(r.stdout) };
};
// Appel HTTP réel au serveur, depuis l'intérieur du conteneur.
const http = (script) => {
  const r = executer(['python3', '-c', script]);
  return JSON.parse(r.stdout);
};

test('le service répond sur /sante avec Tesseract et la langue française', () => {
  const sante = http("import urllib.request;print(urllib.request.urlopen('http://localhost:8884/sante').read().decode())");
  assert.equal(sante.statut, 'ok');
  assert.match(sante.moteur, /^tesseract 5\./);
  assert.equal(sante.langue, 'fra');
});

test('un scan du lot dev est lu : numéro et TTC retrouvés', () => {
  const verite = JSON.parse(readFileSync('data/synthetic/dev/verite/D001.json', 'utf8'));
  assert.equal(verite.format, 'image');
  const { code, json } = ocrStdin(`data/synthetic/dev/documents/${verite.fichier}`, 'image/jpeg');
  assert.equal(code, 0);
  assert.equal(json.pages, 1);
  assert.ok(json.duree_ms > 0);
  const texte = json.texte.replace(/\s/g, '');
  assert.ok(texte.includes(verite.extraction.numero.replace(/\s/g, '')), 'numéro retrouvé');
  assert.ok(texte.includes(verite.extraction.montant_ttc.toFixed(3)), 'TTC retrouvé');
});

test('un PDF est converti en image puis lu (cas des PDF scannés)', () => {
  const { code, json } = ocrStdin('data/synthetic/dev/documents/D007.pdf', 'application/pdf');
  assert.equal(code, 0);
  assert.equal(json.pages, 1);
  assert.match(json.texte, /BNM\/2026\/033/);
});

test('erreurs lisibles : type non pris en charge, fichier vide, fichier illisible', () => {
  assert.deepEqual(ocrStdin('package.json', 'text/plain').json.code_http, 415);
  assert.equal(executer(['python3', 'serveur.py', '--stdin', 'image/png'], Buffer.alloc(0)).status, 1);
  const illisible = ocrStdin('package.json', 'image/png');
  assert.equal(illisible.code, 1);
  assert.equal(illisible.json.code_http, 422);
});

test('l\'API HTTP renvoie 415 pour un type non pris en charge (et ne plante pas)', () => {
  const reponse = http(`
import urllib.request, urllib.error, json
requete = urllib.request.Request('http://localhost:8884/ocr', data=b'abc', headers={'Content-Type': 'text/plain'})
try:
    urllib.request.urlopen(requete)
except urllib.error.HTTPError as e:
    print(json.dumps({'code': e.code, 'corps': json.loads(e.read().decode())}))`);
  assert.equal(reponse.code, 415);
  assert.match(reponse.corps.erreur, /type non pris en charge/);
});
