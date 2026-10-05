// Logique des nœuds Code du sous-workflow « Extraction LLM » (contrat D-039).
// Les fonctions des autres modules sont reçues en paramètre (« deps ») : ce
// fichier n'importe rien et peut être recopié dans un nœud Code (D-041).

const MAX_TENTATIVES_LLM = 3;

/**
 * Vérifie l'entrée du contrat et prépare l'appel.
 * @param {{texte: string, version_prompt: string}} entree
 * @param {object} deps { versionPrompt, empreintes, instructions, construireMessageDocument,
 *   schemaFournisseur, parametres, construireRequete, url }
 */
function preparerAppel(entree, deps) {
  if (typeof entree?.texte !== 'string' || entree.texte.trim() === '') {
    throw new Error('contrat du sous-workflow : « texte » manquant ou vide');
  }
  if (entree.version_prompt !== deps.versionPrompt) {
    throw new Error(`contrat du sous-workflow : version de prompt « ${entree.version_prompt} » inconnue (disponible : ${deps.versionPrompt})`);
  }
  const empreinte = deps.empreintes[deps.versionPrompt];
  if (!empreinte) throw new Error(`empreinte du prompt ${deps.versionPrompt} absente du registre`);
  return {
    url: deps.url,
    requete: deps.construireRequete(deps.instructions, deps.construireMessageDocument(entree.texte), deps.schemaFournisseur, deps.parametres),
    version_prompt: deps.versionPrompt,
    empreinte_prompt: empreinte,
    parametres_generation: { ...deps.parametres },
    cumul_ms: 0,
  };
}

/**
 * Interprète une réponse HTTP et décide s'il faut réessayer ; construit le
 * résultat du contrat quand c'est la dernière tentative.
 * @param {object} essai sortie de preparerAppel, complétée de debut_essai (ms)
 * @param {object} reponseHttp sortie du nœud HTTP ({statusCode, body} ou {error})
 * @param {number} tentative numéro de la tentative (1, 2, 3)
 * @param {number} maintenant horodatage (ms)
 * @param {object} deps { lireReponse, attente, fournisseur }
 */
function traiterReponse(essai, reponseHttp, tentative, maintenant, deps) {
  const statut = reponseHttp?.statusCode ?? null;
  const corps = reponseHttp?.body ?? null;
  const lu = deps.lireReponse(statut, corps);
  const cumul = essai.cumul_ms + Math.max(0, maintenant - essai.debut_essai);
  const reessayer = lu.reessayer && tentative < MAX_TENTATIVES_LLM;
  const { debut_essai: _, ...suite } = essai;
  return {
    ...suite,
    cumul_ms: cumul,
    reessayer,
    attente_ms: reessayer ? deps.attente(tentative, lu.delai_ms) : 0,
    contrat: {
      code_resultat: lu.code,
      donnees: lu.code === 'ok' ? lu.donnees : null,
      jetons_entree: lu.jetons_entree,
      jetons_sortie: lu.jetons_sortie,
      jetons_reflexion: lu.jetons_reflexion,
      duree_ms: cumul,
      fournisseur_llm: deps.fournisseur,
      modele: lu.modele ?? essai.parametres_generation.modele,
      version_prompt: essai.version_prompt,
      empreinte_prompt: essai.empreinte_prompt,
      parametres_generation: essai.parametres_generation,
      tentatives: tentative,
      message_erreur: lu.message,
    },
  };
}

export { MAX_TENTATIVES_LLM, preparerAppel, traiterReponse };
