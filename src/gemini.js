// Appel à Gemini (API REST generateContent) : construction de la requête et
// lecture de la réponse selon le contrat du sous-workflow LLM (D-039).
// Recopié dans les nœuds Code du sous-workflow (D-041) : aucun import.

// Paramètres de génération fixés explicitement (D-048) et enregistrés avec
// chaque extraction. Google recommande de garder la température à 1.0 pour
// les modèles Gemini 3 ; la réflexion ne peut pas être désactivée, seulement
// réglée (thinkingLevel).
const PARAMETRES_GENERATION_GEMINI = Object.freeze({
  modele: 'gemini-3.5-flash-lite',
  temperature: 1.0,
  thinkingLevel: 'low',
  maxOutputTokens: 8192,
  candidateCount: 1,
  responseMimeType: 'application/json',
});

/**
 * Corps de la requête generateContent.
 * @param {string} instructions instructions système (prompt)
 * @param {string} messageDocument message contenant le document balisé
 * @param {object} schemaFournisseur schéma simplifié (responseJsonSchema)
 */
function construireRequeteGemini(instructions, messageDocument, schemaFournisseur, parametres = PARAMETRES_GENERATION_GEMINI) {
  return {
    systemInstruction: { parts: [{ text: instructions }] },
    contents: [{ role: 'user', parts: [{ text: messageDocument }] }],
    generationConfig: {
      temperature: parametres.temperature,
      maxOutputTokens: parametres.maxOutputTokens,
      candidateCount: parametres.candidateCount,
      thinkingConfig: { thinkingLevel: parametres.thinkingLevel },
      responseMimeType: parametres.responseMimeType,
      responseJsonSchema: schemaFournisseur,
    },
  };
}

/** URL de l'appel (la clé est ajoutée par le credential n8n). */
function urlGemini(parametres = PARAMETRES_GENERATION_GEMINI) {
  return `https://generativelanguage.googleapis.com/v1beta/models/${parametres.modele}:generateContent`;
}

// Délai demandé par Google (google.rpc.RetryInfo, ex. « 37s »), en ms.
function delaiDemande(corps) {
  const details = corps?.error?.details ?? [];
  for (const d of details) {
    const m = /^(\d+(?:\.\d+)?)s$/.exec(String(d?.retryDelay ?? ''));
    if (m) return Math.ceil(Number(m[1]) * 1000);
  }
  return null;
}

/**
 * Classe une réponse 429. Formats documentés : codes « quota_exceeded »
 * (quota journalier) et « rate_limit_exceeded » / « too_many_requests ».
 * Pour generateContent, le détail n'est pas documenté : on cherche aussi
 * « per day » / « PerDay » / « daily » dans les identifiants de quota et le
 * message. À vérifier sur la première vraie réponse 429 (D-040).
 * @returns {'quota_journalier_epuise'|'quota_minute'}
 */
function classerErreur429(corps) {
  const texte = JSON.stringify(corps ?? {});
  if (/quota_exceeded|PerDay|per[ _-]?day|daily/i.test(texte)) return 'quota_journalier_epuise';
  return 'quota_minute';
}

/**
 * Lit la réponse HTTP de Gemini et la traduit selon le contrat du
 * sous-workflow. Ne lève jamais d'exception.
 * @param {number|null} statut code HTTP (null si pas de réponse : réseau, délai)
 * @param {object|string|null} corps corps de la réponse
 * @returns {{code: string, donnees: object|null, message: string|null, reessayer: boolean,
 *   delai_ms: number|null, jetons_entree: number|null, jetons_sortie: number|null,
 *   jetons_reflexion: number|null, modele: string|null}}
 */
function lireReponseGemini(statut, corps) {
  const base = {
    code: 'erreur_fournisseur', donnees: null, message: null, reessayer: false, delai_ms: null,
    jetons_entree: null, jetons_sortie: null, jetons_reflexion: null, modele: null,
  };
  let objet = corps;
  if (typeof corps === 'string') {
    try { objet = JSON.parse(corps); } catch { objet = { texte: corps }; }
  }

  if (statut === null || statut === undefined) {
    return { ...base, message: 'aucune réponse (réseau ou délai dépassé)', reessayer: true };
  }
  if (statut === 429) {
    const classe = classerErreur429(objet);
    return {
      ...base,
      code: classe === 'quota_journalier_epuise' ? 'quota_journalier_epuise' : 'quota_minute_epuise',
      message: objet?.error?.message ?? 'quota dépassé',
      reessayer: classe === 'quota_minute',
      delai_ms: delaiDemande(objet),
    };
  }
  if (statut !== 200) {
    return {
      ...base,
      message: `HTTP ${statut} : ${objet?.error?.message ?? 'erreur du fournisseur'}`,
      reessayer: statut === 408 || statut >= 500,
    };
  }

  const usage = objet?.usageMetadata ?? {};
  const mesures = {
    jetons_entree: usage.promptTokenCount ?? null,
    jetons_sortie: usage.candidatesTokenCount ?? null,
    jetons_reflexion: usage.thoughtsTokenCount ?? 0,
    modele: objet?.modelVersion ?? null,
  };
  const candidat = objet?.candidates?.[0];
  if (!candidat) {
    const blocage = objet?.promptFeedback?.blockReason;
    return { ...base, ...mesures, code: 'reponse_illisible', message: `aucune réponse du modèle${blocage ? ` (bloquée : ${blocage})` : ''}` };
  }
  if (candidat.finishReason !== 'STOP') {
    return { ...base, ...mesures, code: 'reponse_illisible', message: `génération interrompue : ${candidat.finishReason}` };
  }
  const texte = (candidat.content?.parts ?? [])
    .filter((p) => p.thought !== true && typeof p.text === 'string')
    .map((p) => p.text)
    .join('');
  try {
    const donnees = JSON.parse(texte);
    return { ...base, ...mesures, code: 'ok', donnees };
  } catch {
    return { ...base, ...mesures, code: 'reponse_illisible', message: 'la réponse n\'est pas un JSON lisible' };
  }
}

/**
 * Attente avant une nouvelle tentative : le délai demandé par Google s'il
 * existe, sinon un délai exponentiel (10 s, 20 s, 40 s…), plafonné à 60 s.
 * @param {number} tentative numéro de la tentative qui vient d'échouer (1, 2…)
 * @param {number|null} delaiDemandeMs
 */
function attenteAvantNouvelEssai(tentative, delaiDemandeMs) {
  const exponentiel = Math.min(60000, 10000 * 2 ** (tentative - 1));
  return Math.min(60000, Math.max(exponentiel, delaiDemandeMs ?? 0));
}

export {
  PARAMETRES_GENERATION_GEMINI, construireRequeteGemini, urlGemini, classerErreur429,
  lireReponseGemini, attenteAvantNouvelEssai,
};
