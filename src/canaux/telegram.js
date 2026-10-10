// Couche de canal Telegram (D-062) : traduit une mise à jour Telegram en
// événement indépendant du canal, et présente une notification ou une
// réponse en message Telegram. Seul module de src/ à connaître Telegram.
// Limites relevées dans la documentation de l'API Bot (2026-10-08) :
// callback_data 1 à 64 octets ; texte d'un message 1 à 4 096 caractères ;
// réponse à un bouton (answerCallbackQuery) 0 à 200 caractères ; en mode
// HTML, < > & et " hors balises s'écrivent &lt; &gt; &amp; &quot;.
// Aucun import (recopié dans un nœud Code, D-041).

const CANAL_TELEGRAM = 'telegram';
const LIMITE_DONNEE_BOUTON = 64; // octets
const LIMITE_TEXTE = 4096; // caractères
const LIMITE_ALERTE_BOUTON = 200; // caractères
const DONNEE_BOUTON = /^([0-9a-f]{32}):(\d{1,3})$/;
const COMMANDE_START = /^\/start(?:@\w+)?(?:\s+(\S+))?\s*$/;
// Question en langage naturel (D-068, B2) : « /q » suivi de la question.
const COMMANDE_QUESTION = /^\/q(?:@\w+)?\s+([\s\S]+)$/;
// Annulation d'un rapprochement (D-077) : « /annuler » suivi du numéro de facture.
const COMMANDE_ANNULER = /^\/annuler(?:@\w+)?\s+(\S[^\n]{0,59})$/;
const SYMBOLES_GRAVITE = Object.freeze({ bloquant: '⛔', avertissement: '⚠️', validation: '🔎' });

/** Échappe un texte pour le mode HTML de Telegram. */
function echapperHtml(texte) {
  return String(texte ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/** Donnée d'un bouton : jeton et indice de l'action, au plus 64 octets. */
function donneeBouton(jeton, indice) {
  const donnee = `${jeton}:${indice}`;
  if (!DONNEE_BOUTON.test(donnee)) throw new Error(`donnée de bouton invalide : ${donnee}`);
  // Caractères ASCII seulement (vérifié ci-dessus) : un caractère = un octet.
  if (donnee.length > LIMITE_DONNEE_BOUTON) throw new Error('donnée de bouton trop longue');
  return donnee;
}

/**
 * Traduit une mise à jour Telegram (Update) en événement pour
 * recevoir_evenement(). L'adresse est from.id, fourni par Telegram : elle
 * ne vient jamais du contenu du message ni du bouton.
 * @returns {{evenement: object, repondre: {chat_id: number|null, callback_query_id: string|null, prive: boolean}}}
 */
function evenementTelegram(miseAJour) {
  const base = { canal: CANAL_TELEGRAM, reference: String(miseAJour.update_id) };
  const cq = miseAJour.callback_query;
  if (cq) {
    const chat = cq.message?.chat ?? null;
    const prive = chat?.type === 'private';
    const m = DONNEE_BOUTON.exec(cq.data ?? '');
    const evenement = { ...base, adresse: String(cq.from.id), type: prive && m ? 'action' : 'autre' };
    if (prive && m) Object.assign(evenement, { jeton: m[1], indice: m[2] });
    return { evenement, repondre: { chat_id: chat?.id ?? null, callback_query_id: cq.id, prive } };
  }
  const msg = miseAJour.message;
  if (msg) {
    const prive = msg.chat?.type === 'private' && msg.from && !msg.from.is_bot;
    const evenement = { ...base, adresse: msg.from ? String(msg.from.id) : null, type: 'autre' };
    const texte = typeof msg.text === 'string' ? msg.text.trim() : '';
    if (prive && texte) {
      const start = COMMANDE_START.exec(texte);
      const question = COMMANDE_QUESTION.exec(texte);
      const annuler = COMMANDE_ANNULER.exec(texte);
      if (start?.[1]) Object.assign(evenement, { type: 'inscription', code: start[1] });
      else if (question) Object.assign(evenement, { type: 'question', texte: question[1].trim() });
      else if (annuler) Object.assign(evenement, { type: 'commande', commande: 'annuler', argument: annuler[1].trim() });
      else if (!texte.startsWith('/')) Object.assign(evenement, { type: 'texte', texte });
    }
    return { evenement, repondre: { chat_id: msg.chat?.id ?? null, callback_query_id: null, prive } };
  }
  // Autres types de mises à jour (non demandés) : tracés, sans réponse.
  return { evenement: { ...base, adresse: null, type: 'autre' }, repondre: { chat_id: null, callback_query_id: null, prive: false } };
}

/** Curseur suivant : un de plus que la plus grande mise à jour reçue. */
function curseurSuivant(misesAJour, curseur) {
  return misesAJour.reduce((max, u) => Math.max(max, u.update_id + 1), Number(curseur));
}

/**
 * Message Telegram d'une notification : texte HTML et un bouton par action.
 * @param {{titre: string, champs: string[][], alertes: object[], note: string}} contenu
 * @param {{libelle: string}[]} actions
 * @param {string} jeton jeton en clair, renvoyé une seule fois par creer_notification()
 */
function messageNotification(contenu, actions, jeton) {
  const entete = [`<b>${echapperHtml(contenu.titre)}</b>`, '',
    ...contenu.champs.map(([libelle, valeur]) => `${echapperHtml(libelle)} : ${echapperHtml(valeur)}`)];
  const pied = contenu.note ? ['', `<i>${echapperHtml(contenu.note)}</i>`] : [];
  const alertes = contenu.alertes.map((a) => `${SYMBOLES_GRAVITE[a.gravite] ?? '•'} <b>${echapperHtml(a.libelle)}</b> — ${echapperHtml(a.message)}`);
  // Respecte la limite de 4 096 caractères : on retire des alertes, en le disant.
  let gardees = alertes.length;
  const composer = (n) => [...entete, ...(n ? ['', ...alertes.slice(0, n)] : []),
    ...(n < alertes.length ? [`… et ${alertes.length - n} autre(s) alerte(s), à voir dans le tableau de bord.`] : []), ...pied].join('\n');
  while (gardees > 0 && composer(gardees).length > LIMITE_TEXTE) gardees -= 1;
  return {
    text: composer(gardees).slice(0, LIMITE_TEXTE),
    parse_mode: 'HTML',
    reply_markup: { inline_keyboard: actions.map((a, i) => [{ text: a.libelle, callback_data: donneeBouton(jeton, i) }]) },
  };
}

/**
 * Message Telegram d'une réponse ; demande une réponse au message quand une
 * justification est attendue (ForceReply).
 * @param {{lignes: string[], attendJustification: boolean}} reponse de messageReponse()
 */
function messageReponseTelegram(reponse) {
  const message = { text: reponse.lignes.map(echapperHtml).join('\n').slice(0, LIMITE_TEXTE), parse_mode: 'HTML' };
  if (reponse.attendJustification) message.reply_markup = { force_reply: true, input_field_placeholder: 'Votre justification' };
  return message;
}

/** Texte court affiché quand on touche un bouton (answerCallbackQuery). */
function alerteBouton(reponse) {
  return String(reponse?.alerteCourte ?? '').slice(0, LIMITE_ALERTE_BOUTON);
}

export {
  CANAL_TELEGRAM, echapperHtml, donneeBouton, evenementTelegram, curseurSuivant,
  messageNotification, messageReponseTelegram, alerteBouton,
};
