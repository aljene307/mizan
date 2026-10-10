// Contrôle des credentials rattachés dans n8n (incident du 2026-10-09) :
// l'attendu vient des fichiers du dépôt ; tout écart est signalé.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { credentialsAttendus, ecartsCredentials, ecartsReglages } from '../scripts/verifier-credentials-n8n.js';

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

// --- Réglages (D-086) ---------------------------------------------------------------------------
const reglagesDepot = (nom) => workflows.find((w) => w.name === nom).settings;
const n8nConforme = () => [
  { id: 'E', name: 'Mizan – Erreurs', active: true, settings: { executionOrder: 'v1' } },
  ...['Mizan – Réponses Telegram', 'Mizan – Notifications Telegram', 'Mizan – Questions (langage naturel)']
    .map((name, i) => ({ id: `P${i}`, name, active: true, settings: { ...reglagesDepot(name), errorWorkflow: 'E' } })),
  { id: 'R', name: 'Mizan – Réception et extraction', active: false, settings: { executionOrder: 'v1' } },
];

test('réglages conformes : workflows publiés reliés à « Mizan – Erreurs », réglages d\'exécution du dépôt', () => {
  assert.deepEqual(ecartsReglages(workflows, n8nConforme()), []);
});

test('réglages perdus à l\'import (constat du 2026-10-10) : signalés', () => {
  const deployes = n8nConforme().map((d) => (d.name === 'Mizan – Réponses Telegram' ? { ...d, settings: { executionOrder: 'v1', binaryMode: 'separate' } } : d));
  assert.deepEqual(ecartsReglages(workflows, deployes).map((e) => [e.reglage, e.obtenu]),
    [['errorWorkflow', 'aucun'], ['saveDataSuccessExecution', 'all'], ['executionTimeout', -1]]);
});

test('le workflow d\'erreurs ne doit désigner aucun workflow d\'erreur, pas même lui-même', () => {
  const deployes = n8nConforme().map((d) => (d.name === 'Mizan – Erreurs' ? { ...d, settings: { errorWorkflow: 'E' } } : d));
  assert.deepEqual(ecartsReglages(workflows, deployes).map((e) => [e.workflow, e.reglage, e.obtenu]),
    [['Mizan – Erreurs', 'errorWorkflow', 'E']]);
});

test('workflow d\'erreurs absent ou en double ; workflow non publié ou hors dépôt : traités comme il faut', () => {
  const sans = n8nConforme().filter((d) => d.name !== 'Mizan – Erreurs');
  assert.ok(ecartsReglages(workflows, sans).some((e) => e.reglage === 'présence'));
  const double = [...n8nConforme(), { id: 'E2', name: 'Mizan – Erreurs', active: false, settings: {} }];
  assert.ok(ecartsReglages(workflows, double).some((e) => e.reglage === 'présence' && e.obtenu === '2'));
  assert.deepEqual(ecartsReglages(workflows, [...n8nConforme(), { id: 'X', name: 'Essai hors dépôt', active: true, settings: {} }]), []);
  // « Default » choisi dans n8n pour les erreurs : la valeur par défaut (enregistrer) est celle du dépôt.
  const defaut = n8nConforme().map((d) => (d.id === 'P0' ? { ...d, settings: { ...d.settings, saveDataErrorExecution: 'DEFAULT' } } : d));
  assert.deepEqual(ecartsReglages(workflows, defaut), []);
});

test('« Mizan – Erreurs » non publié : signalé (n8n n\'exécute que la version publiée d\'un workflow d\'erreur)', () => {
  const deployes = n8nConforme().map((d) => (d.name === 'Mizan – Erreurs' ? { ...d, active: false } : d));
  assert.deepEqual(ecartsReglages(workflows, deployes).map((e) => [e.workflow, e.reglage, e.obtenu]),
    [['Mizan – Erreurs', 'publication', 'non publié']]);
});
