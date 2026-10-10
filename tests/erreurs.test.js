// Erreurs des workflows (D-086) : masquage des secrets, résumé de la donnée
// de l'Error Trigger, message court ; workflow « Mizan – Erreurs » : il ne
// peut pas se déclencher lui-même, et le message Telegram ne contient jamais
// le message technique.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { MASQUE, LONGUEUR_MESSAGE, masquerSecrets, resumerErreur, heureLocale, messageErreur } from '../src/erreurs.js';

const JETON = '123456789:AAFabcdefghijklmnopqrstuvwxyz0123456';
const CLE = 'AIzaSyA1234567890abcdefghijklmnopqrstu';
const wf = JSON.parse(readFileSync('workflows/erreurs.json', 'utf8'));
const noeud = (nom) => wf.nodes.find((n) => n.name === nom);

test('masquage : jeton de bot, clé Google, mot de passe d\'URL, secret en paramètre (mêmes formes qu\'en base)', () => {
  assert.equal(masquerSecrets(`https://api.telegram.org/bot${JETON}/getUpdates`), 'https://api.telegram.org/bot***/getUpdates');
  assert.equal(masquerSecrets(`clé ${CLE} ok`), 'clé *** ok');
  assert.equal(masquerSecrets('postgres://mizan_app:motdepasse123@postgres:5432/mizan'), 'postgres://mizan_app:***@postgres:5432/mizan');
  assert.equal(masquerSecrets('https://x.example/v1?alt=json&key=secret123&b=2'), 'https://x.example/v1?alt=json&key=***&b=2');
  assert.equal(masquerSecrets('erreur à 12:30, facture 2026-10-10 : délai dépassé'), 'erreur à 12:30, facture 2026-10-10 : délai dépassé');
  assert.equal(masquerSecrets(null), '');
  assert.equal(MASQUE, '***');
});

test('résumé d\'une erreur d\'exécution : workflow, nœud, exécution, message masqué', () => {
  const r = resumerErreur({
    execution: { id: 4321, mode: 'trigger', lastNodeExecuted: 'Lire les mises à jour', error: { message: `HTTP 401 bot${JETON}` } },
    workflow: { id: 'K0hq', name: 'Mizan – Réponses Telegram' },
  });
  assert.deepEqual(r, {
    workflow_id: 'K0hq', workflow_nom: 'Mizan – Réponses Telegram', noeud: 'Lire les mises à jour',
    execution_n8n_id: '4321', mode: 'trigger', message: 'HTTP 401 bot***',
  });
});

test('résumé d\'une erreur au démarrage d\'un déclencheur, et d\'une donnée vide', () => {
  const r = resumerErreur({ trigger: { mode: 'trigger', error: { message: 'cron invalide' } }, workflow: { id: 7, name: 'Mizan – Questions (langage naturel)' } });
  assert.equal(r.message, 'cron invalide');
  assert.equal(r.workflow_id, '7');
  assert.equal(r.noeud, null);
  assert.deepEqual(resumerErreur(undefined), {
    workflow_id: null, workflow_nom: 'workflow inconnu', noeud: null, execution_n8n_id: null, mode: null, message: 'erreur sans message',
  });
});

test('masquage AVANT troncature : un jeton à la limite des 500 caractères ne fuit pas en partie', () => {
  const r = resumerErreur({ execution: { error: { message: `${'x'.repeat(LONGUEUR_MESSAGE - 20)} ${JETON}` } }, workflow: { name: 'W' } });
  assert.ok(r.message.length <= LONGUEUR_MESSAGE);
  assert.ok(!r.message.includes('AAFabcdef'));
  assert.ok(r.message.endsWith(MASQUE));
});

test('message court : numéro, workflow, nœud, heure de Tunis ; jamais le message technique', () => {
  const resume = resumerErreur({ execution: { lastNodeExecuted: 'Prendre le bail', error: { message: 'relation « secret_interne » inexistante' } }, workflow: { name: 'Mizan – Réponses Telegram' } });
  const texte = messageErreur({ erreur_id: 12, survenue_le: '2026-10-10T20:04:30Z', intervalle_minutes: 60 }, resume);
  assert.equal(texte, [
    'Mizan : erreur n° 12', 'Workflow : Mizan – Réponses Telegram', 'Nœud : Prendre le bail', 'Heure : 2026-10-10 21:04',
    'Détail enregistré en base (erreurs_workflow). Les erreurs suivantes de ce workflow ne sont pas renvoyées pendant 60 minutes.',
  ].join('\n'));
  assert.ok(!texte.includes('secret_interne'));
  assert.equal(heureLocale('2026-01-15T23:30:00Z'), '2026-01-16 00:30');
});

// --- Workflow « Mizan – Erreurs » -----------------------------------------------------------------

test('le workflow d\'erreurs ne peut pas se déclencher lui-même : aucun « Error workflow » dans ses réglages', () => {
  assert.equal(wf.name, 'Mizan – Erreurs');
  assert.ok(!('errorWorkflow' in wf.settings));
  assert.deepEqual(wf.nodes.filter((n) => n.type === 'n8n-nodes-base.errorTrigger').map((n) => n.name), ['Erreur reçue']);
});

test('aucun nœud du workflow d\'erreurs ne fait échouer l\'exécution', () => {
  for (const n of wf.nodes.filter((x) => x.type !== 'n8n-nodes-base.errorTrigger')) {
    assert.equal(n.onError, 'continueRegularOutput', n.name);
  }
  const envoi = noeud('Envoyer (passerelle)');
  assert.equal(envoi.parameters.url, 'http://passerelle-telegram:8885/telegram/sendMessage');
  assert.equal(envoi.parameters.options.response.response.neverError, true);
  assert.ok(!JSON.stringify(wf).includes('api.telegram.org'));
});

test('aucun autre workflow du dépôt ne fixe un « Error workflow » dans son fichier (réglage fait dans n8n)', () => {
  for (const f of ['controles', 'erreurs', 'extraction-llm', 'notifications-telegram', 'ordres-paiement', 'questions',
    'reception-extraction', 'releve-rapprochement', 'reponses-telegram', 'test-erreur', 'test-gemini']) {
    const w = JSON.parse(readFileSync(`workflows/${f}.json`, 'utf8'));
    assert.ok(!('errorWorkflow' in (w.settings ?? {})), f);
  }
});

async function executer(nom, { entrees, sorties = {} }) {
  const elements = entrees.map((json, i) => ({ json, pairedItem: { item: i } }));
  const contexte = vm.createContext({
    $input: { first: () => elements[0], all: () => elements },
    $: (cible) => ({ first: () => ({ json: sorties[cible][0] }), all: () => sorties[cible].map((json) => ({ json })) }),
  });
  const resultat = await vm.runInContext(`(async () => {\n${noeud(nom).parameters.jsCode}\n})()`, contexte);
  return JSON.parse(JSON.stringify(resultat)).map((x) => x.json);
}

test('nœud « Résumer l\'erreur » : résumé masqué, prêt pour signaler_erreur_workflow()', async () => {
  const [r] = await executer('Résumer l\'erreur', {
    entrees: [{ execution: { id: 9, mode: 'trigger', lastNodeExecuted: 'Interroger Telegram (attente longue)', error: { message: `échec bot${JETON}` } },
      workflow: { id: 'abc', name: 'Mizan – Réponses Telegram' } }],
  });
  assert.equal(r.message, 'échec bot***');
  assert.equal(r.noeud, 'Interroger Telegram (attente longue)');
});

test('nœud « Messages aux responsables » : un message court par destinataire, rien si pas de message à envoyer', async () => {
  const resume = { workflow_nom: 'Mizan – Questions (langage naturel)', noeud: 'Interpréter (Gemini)', message: 'quota dépassé, clé ***' };
  const sorties = { 'Résumer l\'erreur': [resume] };
  const r = { erreur_id: 3, notifier: true, survenue_le: '2026-10-10T08:00:00Z', intervalle_minutes: 60, destinataires: ['941', '945'] };
  const envois = await executer('Messages aux responsables', { entrees: [{ r }], sorties });
  assert.deepEqual(envois.map((e) => e.corps.chat_id), ['941', '945']);
  assert.ok(envois.every((e) => e.corps.text.startsWith('Mizan : erreur n° 3\nWorkflow : Mizan – Questions (langage naturel)\nNœud : Interpréter (Gemini)\nHeure : 2026-10-10 09:00')));
  assert.ok(envois.every((e) => !e.corps.text.includes('quota') && Object.keys(e.corps).join() === 'chat_id,text'));
  assert.deepEqual(await executer('Messages aux responsables', { entrees: [{ r: { ...r, notifier: false, destinataires: [] } }], sorties }), []);
  // Enregistrement en échec (base indisponible) : rien à envoyer, l'exécution se termine sans erreur.
  assert.deepEqual(await executer('Messages aux responsables', { entrees: [{ error: 'connexion refusée' }], sorties }), []);
});

test('workflow de test d\'erreur : échoue sans lire ni écrire', () => {
  const t = JSON.parse(readFileSync('workflows/test-erreur.json', 'utf8'));
  assert.deepEqual(t.nodes.map((n) => n.type), ['n8n-nodes-base.scheduleTrigger', 'n8n-nodes-base.code']);
  assert.ok(!JSON.stringify(t).includes('credentials'));
  assert.match(t.nodes[1].parameters.jsCode, /^throw new Error\('Erreur de test volontaire/m);
});
