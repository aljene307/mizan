// Logique des nœuds Code du workflow « Réception et extraction » (D-035 à
// D-040, D-047). Les fonctions des autres modules sont reçues en paramètre
// (« deps ») : ce fichier n'importe rien et peut être recopié dans un nœud
// Code (D-041).

// En dessous de ce nombre de lettres et de chiffres, le texte d'un PDF est
// jugé inexploitable (PDF scanné sans couche de texte) : on passe par l'OCR.
const SEUIL_CARACTERES_PDF = 50;

/** Vrai si le texte contient assez de lettres et de chiffres. */
function texteSuffisant(texte) {
  return (String(texte ?? '').match(/[\p{L}\p{N}]/gu) ?? []).length >= SEUIL_CARACTERES_PDF;
}

/**
 * Texte à envoyer au LLM, depuis la sortie du nœud Extract From File (« text »)
 * ou du nœud HTTP vers l'OCR (« body.texte »).
 * @returns {{texte: string, methode_lecture: 'texte_pdf'|'ocr', duree_lecture_ms: number|null, version_prompt: string}}
 */
function texteAExtraire(entree, versionPrompt) {
  if (typeof entree?.body?.texte === 'string') {
    return { texte: entree.body.texte, methode_lecture: 'ocr', duree_lecture_ms: entree.body.duree_ms ?? null, version_prompt: versionPrompt };
  }
  if (typeof entree?.text === 'string') {
    return { texte: entree.text, methode_lecture: 'texte_pdf', duree_lecture_ms: null, version_prompt: versionPrompt };
  }
  throw new Error('aucun texte lu (ni texte de PDF, ni réponse de l\'OCR)');
}

/** Dernière version enregistrée dans le registre des prompts. */
function derniereVersionPrompt(registre) {
  const versions = Object.keys(registre);
  if (!versions.length) throw new Error('registre des prompts vide');
  return versions[versions.length - 1];
}

/**
 * Enregistrement d'une extraction faite par le LLM : validation du schéma
 * strict, puis contrôle des identifiants dans le texte source.
 * @returns {{arret_quota: boolean, appel_llm: boolean, message: string|null, payload: object|null}}
 */
function payloadExtraction({ reservation, lecture, contrat, schema, executionId }, deps) {
  if (contrat.code_resultat === 'quota_journalier_epuise') {
    return { arret_quota: true, appel_llm: true, message: contrat.message_erreur ?? 'quota journalier épuisé', payload: null };
  }
  const base = {
    facture_id: reservation.facture_id,
    code_resultat: contrat.code_resultat,
    methode_lecture: lecture.methode_lecture,
    duree_lecture_ms: lecture.duree_lecture_ms,
    fournisseur_llm: contrat.fournisseur_llm,
    modele: contrat.modele,
    version_prompt: contrat.version_prompt,
    empreinte_prompt: contrat.empreinte_prompt,
    parametres_generation: contrat.parametres_generation,
    duree_llm_ms: contrat.duree_ms,
    jetons_entree: contrat.jetons_entree,
    jetons_sortie: contrat.jetons_sortie,
    jetons_reflexion: contrat.jetons_reflexion,
    tentatives: contrat.tentatives,
    execution_n8n_id: executionId,
  };
  if (contrat.code_resultat !== 'ok') {
    return {
      arret_quota: false, appel_llm: true, message: contrat.message_erreur,
      payload: { ...base, resultat: 'erreur', donnees: null, erreurs: [contrat.message_erreur ?? contrat.code_resultat] },
    };
  }
  const validation = deps.validerExtraction(schema, contrat.donnees);
  const verifications = validation.valide ? deps.verifierIdentifiantsDansSource(contrat.donnees, lecture.texte) : [];
  return {
    arret_quota: false, appel_llm: true, message: null,
    payload: {
      ...base,
      resultat: validation.valide ? 'valide' : 'invalide',
      donnees: contrat.donnees,
      erreurs: validation.erreurs,
      verifications_source: verifications,
      alertes_source: deps.alertesSource(verifications),
    },
  };
}

/** Réutilisation d'une extraction valide du même fichier (aucun appel au LLM). */
function payloadReutilisation(reservation, existante, executionId) {
  return {
    arret_quota: false, appel_llm: false, message: null,
    payload: {
      facture_id: reservation.facture_id,
      resultat: 'reutilisee',
      code_resultat: 'reutilisation',
      reutilise_de: existante.extraction_id,
      methode_lecture: existante.methode_lecture,
      donnees: existante.donnees,
      execution_n8n_id: executionId,
    },
  };
}

/** Échec hors LLM (lecture du fichier, OCR) ou panne du sous-workflow. */
function payloadEchec(reservation, code, message, executionId, appelLlm) {
  return {
    arret_quota: false, appel_llm: appelLlm, message,
    payload: {
      facture_id: reservation.facture_id,
      resultat: 'erreur',
      code_resultat: code,
      donnees: null,
      erreurs: [message],
      execution_n8n_id: executionId,
    },
  };
}

/** Message lisible depuis un item de la sortie d'erreur d'un nœud n8n. */
function messageErreur(item) {
  const e = item?.error ?? item;
  return String(e?.message ?? e?.description ?? (typeof e === 'string' ? e : JSON.stringify(e ?? 'erreur inconnue'))).slice(0, 1000);
}

export {
  SEUIL_CARACTERES_PDF, texteSuffisant, texteAExtraire, derniereVersionPrompt,
  payloadExtraction, payloadReutilisation, payloadEchec, messageErreur,
};
