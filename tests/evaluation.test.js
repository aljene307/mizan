// Outils de l'évaluation finale (D-082) : comparaison des workflows chargés
// dans n8n avec le dépôt, ordre de réception, verrou du lot de test.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { differences, ecartsNoeuds } from '../scripts/verifier-avant-evaluation.js';
import { ordreConforme } from '../scripts/etat-evaluation.js';

test('comparaison avec n8n : valeurs par défaut omises tolérées, toute autre différence signalée', () => {
  const depot = [{ name: 'Pause', type: 'n8n-nodes-base.wait', parameters: { resume: 'timeInterval', amount: 7, unit: 'seconds' } },
    { name: 'Code', type: 'n8n-nodes-base.code', parameters: { jsCode: 'return 1;' } }];
  assert.deepEqual(ecartsNoeuds(depot, [{ name: 'Pause', parameters: { amount: 7 } }, { name: 'Code', parameters: { jsCode: 'return 1;' } }]), []);
  assert.deepEqual(ecartsNoeuds(depot, [{ name: 'Pause', parameters: { amount: 8 } }, { name: 'Code', parameters: { jsCode: 'return 2;' } }]),
    ['Pause : paramètres différents (.amount)', 'Code : paramètres différents (.jsCode)']);
  assert.deepEqual(ecartsNoeuds(depot, [{ name: 'Pause', parameters: { amount: 7, extra: true } }]),
    ['Pause : paramètres différents (.extra (absent du dépôt))', 'Code : absent de n8n']);
  assert.deepEqual(differences({ a: [1, 2] }, { a: [1, 2, 3] }), ['.a (longueur)']);
});

test('appel de sous-workflow : l\'identifiant propre à l\'installation n\'est pas comparé (il est vérifié à part)', () => {
  const depot = [{ name: 'Sous', type: 'n8n-nodes-base.executeWorkflow', parameters: { workflowId: { value: '' }, mode: 'each' } }];
  assert.deepEqual(ecartsNoeuds(depot, [{ name: 'Sous', parameters: { workflowId: { value: 'abc', cachedResultName: 'x' }, workflowInputs: {}, mode: 'each' } }]), []);
  assert.equal(ecartsNoeuds(depot, [{ name: 'Sous', parameters: { workflowId: { value: 'abc' }, mode: 'once' } }]).length, 1);
});

test('ordre de réception : identifiants croissants dans l\'ordre des noms (protocole D-082)', () => {
  assert.equal(ordreConforme([{ id: 1, fichier_nom: 'D013.pdf' }, { id: 2, fichier_nom: 'D016.jpg' }, { id: 3, fichier_nom: 'D043.pdf' }]), null);
  assert.match(ordreConforme([{ id: 1, fichier_nom: 'D043.pdf' }, { id: 2, fichier_nom: 'D013.pdf' }]), /D043\.pdf reçu à la place de D013\.pdf/);
});

test('scripts de mesure : le lot de test est refusé sans --etape-8 (et sa vérité terrain n\'est pas lue)', () => {
  for (const s of ['eval/evaluer.js', 'eval/evaluer-controles-reel.js', 'eval/evaluer-rapprochement.js']) {
    const r = spawnSync(process.execPath, [s, '--lot', 'test'], { encoding: 'utf8', env: { ...process.env, MIZAN_DB: 'base_inexistante' } });
    assert.equal(r.status, 1, s);
    assert.match(r.stderr, /réservé à l'évaluation de l'étape 8/, s);
  }
});
