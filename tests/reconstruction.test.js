// Reconstruction de l'état de démonstration (D-078) : le lot de test n'est
// jamais lu, et l'export des extractions ne concerne que le lot de
// développement, à la version figée de la chaîne.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { estDansLotTest, lireFichier, documentsDev } from '../scripts/lecture-protegee.js';

const lots = JSON.parse(readFileSync('data/synthetic/lots.json', 'utf8'));
const idsTest = new Set(lots.test.map((d) => d.id));
const idsDev = new Set(lots.dev.map((d) => d.id));
const exportDev = JSON.parse(readFileSync('demo/extractions-dev.json', 'utf8'));

test('lecture protégée : tout chemin du lot de test est refusé, sous toutes ses formes', () => {
  for (const chemin of ['data/synthetic/test', 'data/synthetic/test/documents/D013.pdf', './data/synthetic/test/verite/D013.json',
    'data/synthetic/dev/../test/documents/D013.pdf', `${process.cwd()}/data/synthetic/test/x`]) {
    assert.equal(estDansLotTest(chemin), true, chemin);
    assert.throws(() => lireFichier(chemin), /lecture refusée : .* appartient au lot de test/, chemin);
  }
  assert.equal(estDansLotTest('data/synthetic/testeur.txt'), false, 'un nom qui commence par « test » n\'est pas le lot');
  assert.equal(estDansLotTest('data/synthetic/dev/documents/D001.jpg'), false);
});

test('documents rejoués : exactement le lot de développement de lots.json, aucun document du lot de test', () => {
  const ids = documentsDev().map((d) => d.id);
  assert.deepEqual(new Set(ids), idsDev);
  assert.ok(ids.every((id) => !idsTest.has(id)));
  assert.ok(documentsDev().every((d) => d.fichier.startsWith('data/synthetic/dev/')));
});

test('export des extractions : lot de développement seulement, version figée, empreintes conformes aux fichiers', () => {
  const ids = exportDev.documents.map((d) => d.id);
  assert.deepEqual(new Set(ids), idsDev, 'chaque document du lot de développement, et rien d\'autre');
  assert.equal(ids.filter((id) => idsTest.has(id)).length, 0, 'aucun identifiant du lot de test');
  assert.equal(exportDev.version_chaine, 'D-053');
  for (const d of exportDev.documents) {
    const octets = lireFichier(`data/synthetic/dev/documents/${d.fichier}`);
    assert.equal(createHash('sha256').update(octets).digest('hex'), d.fichier_sha256, d.id);
    if (d.meme_fichier_que) {
      assert.equal(exportDev.documents.find((x) => x.id === d.meme_fichier_que).fichier_sha256, d.fichier_sha256, d.id);
    } else {
      assert.deepEqual([d.extraction.resultat, d.extraction.version_chaine], ['valide', 'D-053'], d.id);
      assert.ok(d.extraction.donnees && typeof d.extraction.donnees === 'object', d.id);
    }
  }
});

test('reconstruction et export : aucune lecture directe de fichier (tout passe par la lecture protégée), aucun appel au LLM', () => {
  for (const f of ['scripts/reconstruire-base.js', 'scripts/exporter-extractions-dev.js']) {
    const source = readFileSync(f, 'utf8');
    assert.doesNotMatch(source, /readFileSync|createReadStream|readdirSync/, `${f} : lecture hors du lecteur protégé`);
    assert.doesNotMatch(source, /gemini|generativelanguage|GEMINI_API_KEY|promptExtraction/i, `${f} : aucun appel au modèle`);
  }
});

test('le compte de l\'entreprise rejoué est celui du workflow du relevé', async () => {
  const { COMPTE_ENTREPRISE } = await import('../scripts/reconstruire-base.js');
  const wf = JSON.parse(readFileSync('workflows/releve-rapprochement.json', 'utf8'));
  const code = wf.nodes.find((n) => n.name === 'Préparer l\'import').parameters.jsCode;
  assert.ok(code.includes(JSON.stringify(COMPTE_ENTREPRISE)), 'même banque, même RIB, même devise');
});

test('seul « Mizan – Erreurs » peut rester publié pendant une reconstruction ou une évaluation (D-086)', async () => {
  const { publiesBloquants, PUBLIE_AUTORISE } = await import('../scripts/reconstruire-base.js');
  assert.equal(PUBLIE_AUTORISE, 'Mizan – Erreurs');
  assert.deepEqual(publiesBloquants(['Mizan – Erreurs']), []);
  assert.deepEqual(publiesBloquants(['Mizan – Erreurs', 'Mizan – Réponses Telegram', 'Mizan – Erreurs (copie)']),
    ['Mizan – Réponses Telegram', 'Mizan – Erreurs (copie)']);
});
