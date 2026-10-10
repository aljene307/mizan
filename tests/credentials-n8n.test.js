// Contrôle des credentials rattachés dans n8n (incident du 2026-10-09) :
// l'attendu vient des fichiers du dépôt ; tout écart est signalé.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { credentialsAttendus, ecartsCredentials } from '../scripts/verifier-credentials-n8n.js';

const workflows = readdirSync('workflows').filter((f) => f.endsWith('.json')).map((f) => JSON.parse(readFileSync(`workflows/${f}`, 'utf8')));
const attendus = credentialsAttendus(workflows);
const noms = new Map([['app', 'PostgreSQL Mizan (mizan_app)'], ['lect', 'PostgreSQL Mizan (lecture)'], ['gem', 'Gemini Mizan']]);
// Déploiement conforme d'un workflow : chaque nœud avec le credential prévu.
const conforme = (nomWorkflow, version) => [...attendus.get(nomWorkflow)].flatMap(([noeud, types]) => Object.entries(types)
  .map(([type, nom]) => ({ workflow: nomWorkflow, version, noeud, type, credential_id: [...noms].find(([, n]) => n === nom)[0] })));

test('dans le dépôt, seule la lecture des données des questions utilise le credential de lecture', () => {
  const lecteurs = [...attendus].flatMap(([wf, parNoeud]) => [...parNoeud]
    .filter(([, t]) => t.postgres === 'PostgreSQL Mizan (lecture)').map(([n]) => `${wf} / ${n}`));
  assert.deepEqual(lecteurs, ['Mizan – Questions (langage naturel) / Lire les données (mizan_lecture)']);
});

test('déploiement conforme : aucun écart', () => {
  const deployes = [...conforme('Mizan – Réponses Telegram', 'publiée'), ...conforme('Mizan – Questions (langage naturel)', 'brouillon')];
  assert.deepEqual(ecartsCredentials(attendus, deployes, noms), []);
});

test('incident du 2026-10-09 rejoué : credential de lecture sur « Prendre le bail » → signalé', () => {
  const deployes = conforme('Mizan – Réponses Telegram', 'publiée')
    .map((d) => (d.noeud === 'Prendre le bail' ? { ...d, credential_id: 'lect' } : d));
  const ecarts = ecartsCredentials(attendus, deployes, noms);
  assert.deepEqual(ecarts.map((e) => [e.noeud, e.obtenu, e.attendu]),
    [['Prendre le bail', 'PostgreSQL Mizan (lecture)', 'PostgreSQL Mizan (mizan_app)']]);
});

test('credential manquant, ou supprimé dans n8n, ou workflow d\'essai : signalé ou ignoré comme il faut', () => {
  const sansBail = conforme('Mizan – Réponses Telegram', 'brouillon').filter((d) => d.noeud !== 'Prendre le bail');
  assert.deepEqual(ecartsCredentials(attendus, sansBail, noms).map((e) => [e.noeud, e.obtenu]), [['Prendre le bail', null]]);
  const supprime = conforme('Mizan – Réponses Telegram', 'brouillon').map((d) => ({ ...d, credential_id: 'disparu' }));
  assert.ok(ecartsCredentials(attendus, supprime, noms).every((e) => e.obtenu === 'inconnu (disparu)'));
  assert.deepEqual(ecartsCredentials(attendus, [{ workflow: 'Essai hors dépôt', version: 'brouillon', noeud: 'X', type: 'postgres', credential_id: 'lect' }], noms), []);
});
