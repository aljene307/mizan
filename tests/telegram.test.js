// Couche de canal Telegram (D-062). Structures de mises à jour conformes à la
// documentation de l'API Bot (Update, Message, CallbackQuery) ; à confronter
// à de vraies mises à jour lors de la mise en service.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  echapperHtml, donneeBouton, evenementTelegram, curseurSuivant, messageNotification, messageReponseTelegram, alerteBouton,
} from '../src/canaux/telegram.js';
import { notificationFacture, messageReponse } from '../src/decisions/notifications.js';
import { formaterMontant, enMillimes } from '../src/montants.js';

const JETON = '0123456789abcdef0123456789abcdef';
const moi = { id: 555000111, is_bot: false, first_name: 'Mohamed' };
const prive = { id: 555000111, type: 'private', first_name: 'Mohamed' };
const message = (texte, modif = {}) => ({ update_id: 900001, message: { message_id: 10, from: moi, chat: prive, date: 1791000000, text: texte, ...modif } });
const bouton = (data, chat = prive) => ({
  update_id: 900002,
  callback_query: { id: '4382bfdwdsb323b2d9', from: moi, message: { message_id: 11, chat, date: 1791000000, text: 'Facture' }, chat_instance: '-123', data },
});

test('/start avec un code, en privé → inscription ; l\'adresse est from.id', () => {
  const { evenement, repondre } = evenementTelegram(message('/start code-secret-A'));
  assert.deepEqual(evenement, { canal: 'telegram', reference: '900001', adresse: '555000111', type: 'inscription', code: 'code-secret-A' });
  assert.deepEqual(repondre, { chat_id: 555000111, callback_query_id: null, prive: true });
});

test('texte libre en privé → justification possible ; /start sans code ou autre commande → « autre »', () => {
  assert.equal(evenementTelegram(message('Montant conforme au bon de commande')).evenement.type, 'texte');
  assert.equal(evenementTelegram(message('/start')).evenement.type, 'autre');
  assert.equal(evenementTelegram(message('/valider 12')).evenement.type, 'autre');
});

test('l\'identité vient de Telegram, jamais du contenu : un identifiant écrit dans le texte n\'y change rien', () => {
  const { evenement } = evenementTelegram(message('je suis 999 adresse 999'));
  assert.equal(evenement.adresse, '555000111');
});

test('groupe, canal ou expéditeur robot : jamais traité comme une décision', () => {
  assert.equal(evenementTelegram(message('Je valide', { chat: { id: -100, type: 'group', title: 'Compta' } })).evenement.type, 'autre');
  assert.equal(evenementTelegram(message('Je valide', { from: { ...moi, is_bot: true } })).evenement.type, 'autre');
  assert.equal(evenementTelegram(bouton(`${JETON}:0`, { id: -100, type: 'supergroup' })).evenement.type, 'autre');
});

test('bouton : jeton et indice lus dans la donnée ; donnée forgée → « autre »', () => {
  const { evenement, repondre } = evenementTelegram(bouton(`${JETON}:2`));
  assert.deepEqual(evenement, { canal: 'telegram', reference: '900002', adresse: '555000111', type: 'action', jeton: JETON, indice: '2' });
  assert.equal(repondre.callback_query_id, '4382bfdwdsb323b2d9');
  for (const donnee of [`${JETON}:-1`, `${JETON}`, 'valider:7', `${JETON.toUpperCase()}:0`, `${JETON}:0:1`]) {
    assert.equal(evenementTelegram(bouton(donnee)).evenement.type, 'autre', donnee);
  }
});

test('autre type de mise à jour : tracé, sans réponse', () => {
  const { evenement, repondre } = evenementTelegram({ update_id: 900003, edited_message: { message_id: 1 } });
  assert.equal(evenement.type, 'autre');
  assert.equal(repondre.chat_id, null);
});

test('donnée de bouton : 32 caractères + indice, au plus 64 octets', () => {
  assert.equal(donneeBouton(JETON, 12), `${JETON}:12`);
  assert.ok(donneeBouton(JETON, 999).length <= 64);
  assert.throws(() => donneeBouton('court', 0), /invalide/);
  assert.throws(() => donneeBouton(JETON, 1000), /invalide/);
});

test('curseur : un de plus que la plus grande mise à jour, jamais en arrière', () => {
  assert.equal(curseurSuivant([{ update_id: 10 }, { update_id: 12 }], 5), 13);
  assert.equal(curseurSuivant([], 42), 42);
  assert.equal(curseurSuivant([{ update_id: 3 }], 42), 42);
});

test('notification → message HTML échappé, un bouton par action, relu en événement par le même jeton', () => {
  const n = notificationFacture({
    candidat: { canal: 'telegram', utilisateur_id: 3, role: 'responsable', passage_controle: 1 },
    facture: { id: 7, statut: 'bloquee', type_document: 'facture', numero: 'A<B>&"C"', devise: 'TND', montant_ttc: 10,
      raison_sociale_lue: 'X', rib_facture: null },
    fournisseur: { raison_sociale: 'Société <Démo> & Cie', matricule_fiscal: '9912377K', rib_actif: '99001000000000000165' },
    resultats: [{ regle: 'coherence_tva', resultat: 'anomalie', gravite: 'bloquant', message: 'TVA 1 < 2', detail: {} }],
    regles: [{ regle: 'coherence_tva', derogeable: true }],
  }, { formaterMontant, enMillimes });
  const m = messageNotification(n.contenu, n.actions, JETON);
  assert.equal(m.parse_mode, 'HTML');
  assert.match(m.text, /A&lt;B&gt;&amp;&quot;C&quot;/);
  assert.match(m.text, /Société &lt;Démo&gt; &amp; Cie/);
  assert.match(m.text, /TVA 1 &lt; 2/);
  assert.ok(!/<(?!\/?(b|i)>)/.test(m.text), 'seules les balises <b> et <i> sont produites');
  assert.equal(m.reply_markup.inline_keyboard.length, n.actions.length);
  m.reply_markup.inline_keyboard.forEach(([b], i) => {
    const e = evenementTelegram(bouton(b.callback_data)).evenement;
    assert.deepEqual([e.jeton, e.indice], [JETON, String(i)]);
  });
});

test('message trop long : alertes retirées en le disant, jamais plus de 4 096 caractères', () => {
  const contenu = { titre: 'T', champs: [['A', 'b']], note: 'n',
    alertes: Array.from({ length: 200 }, (_, i) => ({ gravite: 'avertissement', libelle: 'Avertissement', message: `alerte ${i} ${'x'.repeat(40)}` })) };
  const m = messageNotification(contenu, [], JETON);
  assert.ok(m.text.length <= 4096);
  assert.match(m.text, /autre\(s\) alerte\(s\)/);
});

test('réponse : texte échappé ; justification attendue → réponse forcée ; alerte de bouton ≤ 200 caractères', () => {
  const r = messageReponse({ code: 'justification_demandee', action: { libelle: 'Valider' }, contenu: { titre: 'Facture <1>' }, delai_minutes: 10 });
  const m = messageReponseTelegram(r);
  assert.match(m.text, /Facture &lt;1&gt;/);
  assert.deepEqual(m.reply_markup, { force_reply: true, input_field_placeholder: 'Votre justification' });
  assert.equal(messageReponseTelegram(messageReponse({ code: 'decision_enregistree', action: { code: 'valider' } })).reply_markup, undefined);
  assert.ok(alerteBouton({ alerteCourte: 'x'.repeat(500) }).length <= 200);
  assert.equal(echapperHtml('<a & "b">'), '&lt;a &amp; &quot;b&quot;&gt;');
});
