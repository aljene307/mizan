// Workflow « Questions (langage naturel) » (D-068, B2) : structure, et
// exécution du code GÉNÉRÉ des nœuds Code (copies de src/), de la question
// reçue jusqu'à la conclusion.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const wf = JSON.parse(readFileSync('workflows/questions.json', 'utf8'));
const noeud = (nom) => wf.nodes.find((n) => n.name === nom);

async function executer(nom, { entrees, sorties = {} }) {
  const elements = entrees.map((json, i) => ({ json, pairedItem: { item: i } }));
  const contexte = vm.createContext({
    $input: { first: () => elements[0], all: () => elements },
    $: (cible) => ({ all: () => sorties[cible].map((json) => ({ json })) }),
    $execution: { id: 'exec-test' }, Date, Intl,
  });
  const r = await vm.runInContext(`(async () => {\n${noeud(nom).parameters.jsCode}\n})()`, contexte);
  return JSON.parse(JSON.stringify(r)).map((x) => x.json);
}
const reponseGemini = (objet) => ({ statusCode: 200, body: {
  candidates: [{ finishReason: 'STOP', content: { parts: [{ text: JSON.stringify(objet) }] } }], usageMetadata: {} } });

test('structure : données lues avec la credential « lecture », file prise et conclue avec mizan_app', () => {
  const lecture = noeud('Lire les données (mizan_lecture)');
  assert.equal(lecture.credentials.postgres.name, 'PostgreSQL Mizan (lecture)');
  assert.equal(lecture.parameters.query, '={{ $json.sql }}');
  assert.equal(lecture.parameters.options.queryBatching, 'independently');
  for (const nom of ['Questions à traiter', 'Conclure la question']) {
    assert.equal(noeud(nom).credentials.postgres.name, 'PostgreSQL Mizan (mizan_app)', nom);
  }
  const lecteurs = wf.nodes.filter((n) => n.credentials?.postgres?.name === 'PostgreSQL Mizan (lecture)').map((n) => n.name);
  assert.deepEqual(lecteurs, ['Lire les données (mizan_lecture)'], 'seule la requête du catalogue lit avec mizan_lecture');
  assert.equal(noeud('Interpréter (Gemini)').parameters.options.batching.batch.batchSize, 1);
  assert.equal(wf.settings.saveDataSuccessExecution, 'none', 'pas de trace des exécutions réussies (questions, réponses)');
});

test('préparation : le modèle reçoit le catalogue et la question balisée, aucune donnée', async () => {
  const [p] = await executer('Préparer l\'interprétation', { entrees: [{ question_id: 7, texte: 'Combien je dois à Trans-Cap ?', adresse: '555', canal: 'telegram', role: 'responsable' }] });
  assert.equal(p.question_id, 7);
  assert.match(p.url, /generativelanguage\.googleapis\.com\/v1beta\/models\/.+:generateContent$/);
  const message = p.requete.contents[0].parts[0].text;
  assert.match(message, /^Date du jour : \d{4}-\d{2}-\d{2}\n<question>\nCombien je dois à Trans-Cap \?\n<\/question>$/);
  assert.ok(p.requete.generationConfig.responseJsonSchema.properties.question.enum.includes('hors_catalogue'));
});

test('de la sortie du modèle à la réponse : requête fixe, valeurs liées, réponse rédigée par le code, conclusion', async () => {
  const preparees = [{ question_id: 7, adresse: '555' }, { question_id: 8, adresse: '555' }, { question_id: 9, adresse: '555' }];
  const lues = await executer('Lire l\'interprétation', {
    entrees: [
      reponseGemini({ question: 'du_a_un_fournisseur', parametres: { fournisseur: 'Trans-Cap' } }),
      reponseGemini({ question: 'supprimer_tout', parametres: {} }),
      { statusCode: 429, body: { error: { message: 'quota' } } },
    ],
    sorties: { 'Préparer l\'interprétation': preparees },
  });
  assert.deepEqual(lues.map((l) => [l.question_id, l.interpretation.code, l.valeurs]),
    [[7, 'ok', ['%Trans-Cap%']], [8, 'hors_catalogue', []], [9, 'erreur_interpretation', []]]);
  assert.match(lues[0].sql, /FROM echeancier WHERE fournisseur ILIKE \$1/);

  const redigees = await executer('Rédiger la réponse', {
    entrees: [{ lignes: [{ fournisseur: 'Trans-Cap Logistique', devise: 'TND', factures: 1, a_payer: 6092.478, au_releve: 0, en_retard: 0 }] },
      { lignes: [] }, { lignes: [] }],
    sorties: { 'Lire l\'interprétation': lues },
  });
  assert.equal(redigees[0].corps.chat_id, '555');
  assert.match(redigees[0].corps.text, /Trans-Cap Logistique : .+ TND à payer sur 1 facture/);
  assert.match(redigees[1].corps.text, /Je ne sais pas répondre/);
  assert.deepEqual(redigees.map((r) => [r.conclusion.question_id, r.conclusion.code_reponse, r.conclusion.question_catalogue]),
    [[7, 'ok', 'du_a_un_fournisseur'], [8, 'hors_catalogue', null], [9, 'erreur_interpretation', null]]);
  assert.deepEqual(redigees[0].conclusion.parametres, { fournisseur: 'Trans-Cap' });

  const conclusions = await executer('Résultat de l\'envoi', {
    entrees: [{ statusCode: 200, body: { ok: true } }, { statusCode: 200, body: { ok: true } }, { statusCode: 400, body: { ok: false, description: 'chat not found' } }],
    sorties: { 'Rédiger la réponse': redigees },
  });
  assert.deepEqual(conclusions.map((c) => [c.question_id, c.envoyee]), [[7, true], [8, true], [9, false]]);
  assert.equal(conclusions[2].erreur, 'chat not found');
});
