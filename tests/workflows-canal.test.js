// Workflows du canal Telegram (D-062, D-064) : structure, réglages, et
// exécution du code GÉNÉRÉ de leurs nœuds Code (tel que n8n l'exécutera),
// sur un aller-retour simulé : données de la base → message → bouton → réponse.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const lire = (chemin) => JSON.parse(readFileSync(chemin, 'utf8'));
const envoi = lire('workflows/notifications-telegram.json');
const reception = lire('workflows/reponses-telegram.json');
const noeud = (wf, nom) => wf.nodes.find((n) => n.name === nom);
const JETON = 'abcdefabcdefabcdefabcdefabcdef12';

/** Exécute le code d'un nœud Code avec plusieurs éléments en entrée et des sorties d'autres nœuds. */
async function executer(wf, nom, { entrees, sorties = {} }) {
  const elements = entrees.map((json, i) => ({ json, pairedItem: { item: i } }));
  const contexte = vm.createContext({
    $input: { first: () => elements[0], all: () => elements },
    $: (cible) => ({
      all: () => sorties[cible].map((json) => ({ json })),
      first: () => ({ json: sorties[cible][0] }),
      last: () => ({ json: sorties[cible].at(-1) }),
    }),
    $execution: { id: 'exec-test' },
    $runIndex: 0,
    Date,
  });
  const resultat = await vm.runInContext(`(async () => {\n${noeud(wf, nom).parameters.jsCode}\n})()`, contexte);
  return JSON.parse(JSON.stringify(resultat)).map((x) => x.json);
}

for (const [nom, wf] of [['notifications', envoi], ['réponses', reception]]) {
  test(`${nom} : réglages d'exécution (réussites non enregistrées, erreurs gardées, délai 120 s)`, () => {
    assert.deepEqual(wf.settings, {
      executionOrder: 'v1', saveDataSuccessExecution: 'none', saveDataErrorExecution: 'all', executionTimeout: 120,
    });
  });

  test(`${nom} : Telegram n'est appelé que par la passerelle interne, sans jeton ni credential Telegram`, () => {
    const texte = JSON.stringify(wf);
    assert.doesNotMatch(texte, /api\.telegram\.org/);
    assert.doesNotMatch(texte, /\d{6,}:[A-Za-z0-9_-]{30,}/, 'aucun jeton de bot');
    assert.doesNotMatch(texte, /telegramApi/);
    for (const n of wf.nodes.filter((x) => x.type === 'n8n-nodes-base.httpRequest')) {
      assert.match(n.parameters.url, /^=?\{?\{?.*http:\/\/passerelle-telegram:8885\/telegram/, n.name);
      assert.equal(n.parameters.options.response.response.neverError, true, n.name);
    }
  });
}

test('réponses : bail pris une fois, interrogation longue de 50 s, délai HTTP supérieur', () => {
  assert.equal(noeud(reception, 'Prendre le bail').executeOnce, true);
  const interroger = noeud(reception, 'Interroger Telegram (attente longue)');
  assert.match(interroger.parameters.jsonBody, /timeout: 50/);
  assert.ok(interroger.parameters.options.timeout > 50000);
  assert.ok(reception.settings.executionTimeout * 1000 > interroger.parameters.options.timeout);
});

test('réponses : toutes les branches finissent sur « Rendre le bail », exécuté une seule fois', () => {
  const vers = (source, sortie) => reception.connections[source].main[sortie].map((l) => l.node);
  assert.deepEqual(vers('Mise à jour à traiter ?', 1), ['Rendre le bail'], 'aucune mise à jour');
  assert.deepEqual(vers('Réponse à envoyer ?', 1), ['Rendre le bail'], 'rien à répondre');
  assert.deepEqual(vers('Une réponse à la fois', 0), ['Rendre le bail'], 'réponses toutes envoyées (sortie « done »)');
  assert.equal(noeud(reception, 'Rendre le bail').executeOnce, true);
  assert.equal(noeud(reception, 'Recevoir l\'événement').parameters.options.queryBatching, 'independently');
});

test('réponses : envoyées une à une, dans l\'ordre d\'arrivée (boucle), pas en parallèle', () => {
  // Incident du 2026-10-08 : « Accès réservé » affiché après « Inscription réussie » ; le nœud
  // HTTP Request lance les requêtes de tous les éléments sans attendre la précédente.
  const boucle = noeud(reception, 'Une réponse à la fois');
  assert.equal(boucle.type, 'n8n-nodes-base.splitInBatches');
  assert.equal(boucle.typeVersion, 3);
  assert.equal(boucle.parameters.batchSize, 1);
  const vers = (source, sortie) => reception.connections[source].main[sortie].map((l) => l.node);
  assert.deepEqual(vers('Réponse à envoyer ?', 0), ['Une réponse à la fois']);
  assert.deepEqual(vers('Une réponse à la fois', 1), ['Répondre (passerelle)'], 'sortie « loop » : une réponse');
  assert.deepEqual(vers('Répondre (passerelle)', 0), ['Une réponse à la fois'], 'retour dans la boucle après la réponse');
});

test('notifications : une par seconde au plus (rythme conseillé par Telegram)', () => {
  assert.deepEqual(noeud(envoi, 'Envoyer (passerelle)').parameters.options.batching, { batch: { batchSize: 1, batchInterval: 1000 } });
});

// --- Aller-retour simulé ------------------------------------------------------------
const donneesFacture = {
  candidat: { canal: 'telegram', objet: 'facture', utilisateur_id: 3, role: 'validateur', passage_controle: 9, adresse: '555000111' },
  facture: { id: 7, statut: 'a_valider', type_document: 'facture', numero: 'FA-2026-0007', devise: 'TND', montant_ttc: 35701.5,
    date_facture: '2026-03-01', date_echeance: '2026-03-31', raison_sociale_lue: 'Fournisseur', rib_facture: null },
  fournisseur: { raison_sociale: 'Fournisseur <SARL>', matricule_fiscal: '9912377K', rib_actif: '99001000000000000165' },
  resultats: [{ regle: 'seuil_validation', resultat: 'anomalie', gravite: 'validation', message: 'TTC au-dessus du seuil', detail: {} }],
  regles: [{ regle: 'seuil_validation', derogeable: true }],
  demande: null,
  methodes: [],
};

test('envoi : données de la base → notification → message avec boutons → résultat de l\'envoi', async () => {
  const preparees = await executer(envoi, 'Préparer les notifications', { entrees: [{ donnees: donneesFacture }] });
  assert.equal(preparees[0].notification.statut_facture, 'a_valider');
  assert.deepEqual(preparees[0].notification.actions.map((a) => a.code), ['valider', 'rejeter']);

  // Sortie de « Créer la notification » : un élément réussi, un refusé par la base.
  const creees = [{ notification_id: 41, jeton: JETON }, { error: 'la facture n\'est plus au statut notifié' }];
  const messages = await executer(envoi, 'Message Telegram', {
    entrees: creees, sorties: { 'Préparer les notifications': [preparees[0], preparees[0]] },
  });
  assert.equal(messages[0].notification_id, 41);
  assert.equal(messages[0].corps.chat_id, '555000111');
  assert.equal(messages[0].corps.parse_mode, 'HTML');
  assert.match(messages[0].corps.text, /Fournisseur &lt;SARL&gt;/);
  assert.deepEqual(messages[0].corps.reply_markup.inline_keyboard.map(([b]) => b.callback_data), [`${JETON}:0`, `${JETON}:1`]);
  assert.deepEqual([messages[1].ignorer, messages[1].motif], [true, 'la facture n\'est plus au statut notifié']);

  const resultats = await executer(envoi, 'Résultat de l\'envoi', {
    entrees: [{ statusCode: 200, body: { ok: true, result: { message_id: 812 } } }, { statusCode: 200, body: { ok: false, description: 'Forbidden: bot was blocked by the user' } }],
    sorties: { 'Notification à envoyer ?': [{ notification_id: 41 }, { notification_id: 42 }] },
  });
  assert.deepEqual(resultats, [
    { id: 41, reference: '812', erreur: null },
    { id: 42, reference: null, erreur: 'Forbidden: bot was blocked by the user' },
  ]);
});

test('réception : mises à jour → événements ; curseur avancé ; aucune mise à jour → fin sans événement', async () => {
  const bail = { bail_jeton: '7d0c6f1e-0000-4000-8000-000000000001', curseur: '100' };
  const miseAJour = {
    update_id: 105,
    callback_query: { id: 'cb-1', from: { id: 555000111, is_bot: false, first_name: 'M' },
      message: { message_id: 812, chat: { id: 555000111, type: 'private' }, date: 1, text: 'x' }, chat_instance: '1', data: `${JETON}:0` },
  };
  const lus = await executer(reception, 'Lire les mises à jour', {
    entrees: [{ statusCode: 200, body: { ok: true, result: [miseAJour] } }], sorties: { 'Prendre le bail': [bail] },
  });
  assert.equal(lus.length, 1);
  assert.equal(lus[0].curseur, 106);
  assert.deepEqual(lus[0].evenement, { canal: 'telegram', reference: '105', adresse: '555000111', type: 'action', jeton: JETON, indice: '0' });

  const vide = await executer(reception, 'Lire les mises à jour', {
    entrees: [{ statusCode: 200, body: { ok: true, result: [] } }], sorties: { 'Prendre le bail': [bail] },
  });
  assert.deepEqual(vide, [{ bail_jeton: bail.bail_jeton, curseur: 100, vide: true }]);

  await assert.rejects(executer(reception, 'Lire les mises à jour', {
    entrees: [{ statusCode: 200, body: { ok: false, description: 'Conflict: terminated by other getUpdates request' } }], sorties: { 'Prendre le bail': [bail] },
  }), /interrogation de Telegram en échec : Conflict/);
});

test('réception : résultats de la base → réponse au bouton et message ; rien pour un événement déjà traité', async () => {
  const lues = [
    { repondre: { chat_id: 555000111, callback_query_id: 'cb-1', prive: true } },
    { repondre: { chat_id: 555000111, callback_query_id: null, prive: true } },
    { repondre: { chat_id: -100, callback_query_id: null, prive: false } },
  ];
  const envois = await executer(reception, 'Préparer les réponses', {
    entrees: [
      { resultat: { code: 'justification_demandee', action: { libelle: 'Valider' }, contenu: { titre: 'Facture FA-2026-0007' }, delai_minutes: 10 } },
      { resultat: { code: 'deja_traite' } },
      { resultat: { code: 'non_compris' } },
    ],
    sorties: { 'Mise à jour à traiter ?': lues },
  });
  assert.deepEqual(envois.map((e) => e.methode), ['answerCallbackQuery', 'sendMessage'], 'rien pour « déjà traité », rien dans un groupe');
  assert.equal(envois[0].corps.text, 'Justification demandée');
  assert.equal(envois[1].corps.reply_markup.force_reply, true);
  const rien = await executer(reception, 'Préparer les réponses', {
    entrees: [{ resultat: { code: 'deja_traite' } }], sorties: { 'Mise à jour à traiter ?': [lues[1]] },
  });
  assert.deepEqual(rien, [{ rien: true }], 'un élément témoin pour atteindre « Rendre le bail »');
});
