// Erreurs des workflows n8n (D-086) : résumé de la donnée de l'Error Trigger,
// masquage des secrets, message court pour les responsables. Le message
// Telegram reste générique (workflow, nœud, heure, numéro d'erreur) : le
// message technique, masqué et tronqué, ne va qu'en base (erreurs_workflow).
// Mêmes formes masquées que masquer_secrets() en base, avec le même masque
// que la passerelle Telegram (« *** ») ; n8n ne détient pas le jeton du bot,
// d'où un masquage par forme et non par valeur.
// Aucun import (recopié dans un nœud Code, D-041).

const MASQUE = '***';
const LONGUEUR_MESSAGE = 500; // caractères gardés en base
const FUSEAU = 'Africa/Tunis';
const FORMES_SECRETES = [
  [/[0-9]+:[A-Za-z0-9_-]{30,}/g, MASQUE], // jeton de bot Telegram (forme vérifiée par la passerelle)
  [/AIza[0-9A-Za-z_-]{20,}/g, MASQUE], // clé d'API Google
  [/(\/\/[^\s:/@]+:)[^\s@/]+@/g, `$1${MASQUE}@`], // mot de passe dans une URL
  [/([?&](?:key|token|password|api_key|apikey)=)[^&\s]+/gi, `$1${MASQUE}`], // secret en paramètre d'URL
];

/** Retire les secrets d'un texte (masquage avant toute troncature). */
function masquerSecrets(texte) {
  return FORMES_SECRETES.reduce((t, [forme, remplacement]) => t.replace(forme, remplacement), String(texte ?? ''));
}

/**
 * Résumé d'une erreur reçue par l'Error Trigger de n8n : erreur d'exécution
 * ({ execution, workflow }) ou erreur au démarrage d'un déclencheur
 * ({ trigger, workflow }). Le message est masqué puis tronqué.
 */
function resumerErreur(donnee) {
  const execution = donnee?.execution ?? {};
  const erreur = execution.error ?? donnee?.trigger?.error ?? {};
  const message = masquerSecrets(erreur.message ?? erreur.description ?? 'erreur sans message').slice(0, LONGUEUR_MESSAGE);
  return {
    workflow_id: donnee?.workflow?.id == null ? null : String(donnee.workflow.id),
    workflow_nom: String(donnee?.workflow?.name ?? 'workflow inconnu'),
    noeud: execution.lastNodeExecuted ?? erreur.node?.name ?? null,
    execution_n8n_id: execution.id == null ? null : String(execution.id),
    mode: execution.mode ?? donnee?.trigger?.mode ?? null,
    message,
  };
}

/** Heure lisible, à l'heure de Tunis : « 2026-10-10 21:04 ». */
function heureLocale(date) {
  const p = Object.fromEntries(new Intl.DateTimeFormat('fr-FR', {
    timeZone: FUSEAU, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(new Date(date)).map((x) => [x.type, x.value]));
  return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}`;
}

/** Message court et générique, en texte brut : jamais le message technique. */
function messageErreur({ erreur_id: erreurId, survenue_le: survenueLe, intervalle_minutes: minutes }, { workflow_nom: workflow, noeud }) {
  return [
    `Mizan : erreur n° ${erreurId}`,
    `Workflow : ${workflow}`,
    `Nœud : ${noeud ?? 'inconnu'}`,
    `Heure : ${heureLocale(survenueLe)}`,
    `Détail enregistré en base (erreurs_workflow). Les erreurs suivantes de ce workflow ne sont pas renvoyées pendant ${minutes} minutes.`,
  ].join('\n');
}

export { MASQUE, LONGUEUR_MESSAGE, masquerSecrets, resumerErreur, heureLocale, messageErreur };
