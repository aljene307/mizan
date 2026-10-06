// Construit les trois workflows n8n (fichiers JSON à importer) :
//   workflows/extraction-llm.json        sous-workflow « Extraction LLM » (D-039)
//   workflows/reception-extraction.json  workflow principal (D-035 à D-040, D-047)
//   workflows/controles.json             contrôles déterministes (D-055)
// Le code des nœuds Code est recopié depuis src/ (D-041). Paramètres des nœuds
// relevés dans n8n 2.41.7. Usage : node scripts/construire-workflows.js
import { readFileSync, writeFileSync } from 'node:fs';
import { synchroniserWorkflow } from './synchroniser-noeuds.js';
import { VERSION_CHAINE_EXTRACTION } from '../src/extractionWorkflow.js';

const CRED_POSTGRES = { postgres: { id: '', name: 'PostgreSQL Mizan (mizan_app)' } };
const CRED_GEMINI = { googlePalmApi: { id: '', name: 'Gemini Mizan' } };
const PAUSE_APRES_LLM_S = 7; // D-036

let compteur = 0;
const id = (prefixe) => {
  compteur += 1;
  return `${prefixe}-0000-4000-8000-${String(compteur).padStart(12, '0')}`;
};
const noeud = (nom, type, typeVersion, position, parameters, extra = {}) => ({
  parameters, id: id('5e1f0000'), name: nom, type, typeVersion, position, ...extra,
});
const regions = (...sources) => sources.map((s) => `// <<< ${s}\n// >>>\n`).join('');
const code = (nom, position, sources, glue, extra = {}) => noeud(nom, 'n8n-nodes-base.code', 2, position,
  { jsCode: `${regions(...sources)}\n${glue.trim()}\n` }, extra);
const si = (nom, position, expression) => noeud(nom, 'n8n-nodes-base.if', 2.2, position, {
  conditions: {
    options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
    conditions: [{ id: id('c0de0000'), leftValue: `={{ ${expression} }}`, rightValue: '', operator: { type: 'boolean', operation: 'true', singleValue: true } }],
    combinator: 'and',
  },
  options: {},
});
const postgres = (nom, position, query, remplacement, extra = {}) => noeud(nom, 'n8n-nodes-base.postgres', 2.6, position, {
  operation: 'executeQuery',
  query,
  options: remplacement ? { queryReplacement: `={{ ${remplacement} }}` } : {},
}, { credentials: CRED_POSTGRES, ...extra });
const lien = (cible) => ({ node: cible, type: 'main', index: 0 });

function connexions(liste) {
  // liste : [source, indexSortie, cible]
  const resultat = {};
  for (const [source, sortie, cible] of liste) {
    resultat[source] ??= { main: [] };
    while (resultat[source].main.length <= sortie) resultat[source].main.push([]);
    resultat[source].main[sortie].push(lien(cible));
  }
  return resultat;
}

const lire = (chemin) => readFileSync(chemin, 'utf8');
function ecrire(chemin, workflow) {
  const { workflow: synchronise } = synchroniserWorkflow(workflow, lire);
  writeFileSync(chemin, `${JSON.stringify(synchronise, null, 2)}\n`);
  console.log(`${chemin} : ${workflow.nodes.length} nœuds`);
}

// =============================================================================
// Sous-workflow « Extraction LLM » (Gemini)
// =============================================================================
const N_TENTATIVE = 'Horodater la tentative';
const sousWorkflow = {
  name: 'Mizan – Extraction LLM (Gemini)',
  nodes: [
    noeud('Appel par le workflow principal', 'n8n-nodes-base.executeWorkflowTrigger', 1.1, [0, 0], { inputSource: 'passthrough' }),
    code('Préparer l\'appel', [220, 0],
      ['src/promptExtraction.js', 'src/schemaFournisseur.js', 'src/gemini.js', 'src/sousWorkflowLlm.js',
        'src/schemas/extraction-facture.schema.json as SCHEMA_EXTRACTION', 'src/prompts-versions.json as VERSIONS_PROMPT'],
      `// Contrat d'entrée (D-039) : { texte, version_prompt }.
const appel = preparerAppel($input.first().json, {
  versionPrompt: VERSION_PROMPT,
  empreintes: VERSIONS_PROMPT,
  instructions: INSTRUCTIONS_SYSTEME,
  construireMessageDocument,
  schemaFournisseur: simplifierSchema(SCHEMA_EXTRACTION, MOTS_CLES_GEMINI),
  parametres: PARAMETRES_GENERATION_GEMINI,
  construireRequete: construireRequeteGemini,
  url: urlGemini(),
});
return [{ json: appel }];`),
    code(N_TENTATIVE, [440, 0], [],
      `// Point de départ de chaque tentative : on garde le contexte et on note l'heure.
const e = $input.first().json;
return [{ json: {
  url: e.url, requete: e.requete, version_prompt: e.version_prompt, empreinte_prompt: e.empreinte_prompt,
  parametres_generation: e.parametres_generation, cumul_ms: e.cumul_ms, debut_essai: Date.now(),
} }];`),
    noeud('Appel Gemini', 'n8n-nodes-base.httpRequest', 4.5, [660, 0], {
      method: 'POST',
      url: '={{ $json.url }}',
      authentication: 'predefinedCredentialType',
      nodeCredentialType: 'googlePalmApi',
      sendBody: true,
      specifyBody: 'json',
      jsonBody: '={{ JSON.stringify($json.requete) }}',
      options: { response: { response: { fullResponse: true, neverError: true } }, timeout: 90000 },
    }, { credentials: CRED_GEMINI, onError: 'continueRegularOutput' }),
    code('Lire la réponse', [880, 0], ['src/gemini.js', 'src/sousWorkflowLlm.js'],
      `// Une exécution par tentative : $runIndex vaut 0, 1, 2…
const essai = $('${N_TENTATIVE}').last().json;
const resultat = traiterReponse(essai, $input.first().json, $runIndex + 1, Date.now(), {
  lireReponse: lireReponseGemini, attente: attenteAvantNouvelEssai, fournisseur: 'google',
});
return [{ json: resultat }];`),
    si('Réessayer ?', [1100, 0], '$json.reessayer === true'),
    noeud('Attendre avant la tentative suivante', 'n8n-nodes-base.wait', 1.1, [1320, -140], {
      resume: 'timeInterval', amount: '={{ $json.attente_ms / 1000 }}', unit: 'seconds',
    }, { webhookId: id('3a170000') }),
    code('Résultat (contrat)', [1320, 120], [],
      `// Contrat de sortie (D-039) : code_resultat, donnees, jetons, durée, modèle, prompt…
return [{ json: $input.first().json.contrat }];`),
  ],
  settings: { executionOrder: 'v1' },
  pinData: {},
};
sousWorkflow.connections = connexions([
  ['Appel par le workflow principal', 0, 'Préparer l\'appel'],
  ['Préparer l\'appel', 0, N_TENTATIVE],
  [N_TENTATIVE, 0, 'Appel Gemini'],
  ['Appel Gemini', 0, 'Lire la réponse'],
  ['Lire la réponse', 0, 'Réessayer ?'],
  ['Réessayer ?', 0, 'Attendre avant la tentative suivante'],
  ['Réessayer ?', 1, 'Résultat (contrat)'],
  ['Attendre avant la tentative suivante', 0, N_TENTATIVE],
]);

// =============================================================================
// Workflow principal « Réception et extraction »
// =============================================================================
const N_RESERVER = 'Réserver une facture';
const N_TEXTE = 'Texte à extraire';
const N_A_ENREGISTRER = 'Enregistrement à faire';
const N_LLM = 'Extraction LLM (sous-workflow)';
const N_REFERENTIEL = 'RIB du référentiel';
const RESERVATION = `$('${N_RESERVER}').last().json`;
const MOTIF_FICHIERS = '/data/entrant/*.{pdf,PDF,jpg,JPG,jpeg,JPEG,png,PNG}';
const REQUETE_ENREGISTRER = 'SELECT enregistrer_extraction($1::jsonb) AS extraction_id;';

const principal = {
  name: 'Mizan – Réception et extraction',
  nodes: [
    // --- Phase 1 : réception de tous les nouveaux fichiers (D-038) ----------
    noeud('Toutes les minutes', 'n8n-nodes-base.scheduleTrigger', 1.2, [0, 0], {
      rule: { interval: [{ field: 'minutes', minutesInterval: 1 }] },
    }),
    noeud('Lister les fichiers reçus', 'n8n-nodes-base.readWriteFile', 1, [220, 0], {
      operation: 'read', fileSelector: MOTIF_FICHIERS, options: {},
    }, { alwaysOutputData: true }),
    si('Fichier reçu ?', [440, 0], '$json.fileName !== undefined'),
    noeud('Empreinte SHA-256', 'n8n-nodes-base.crypto', 2, [660, -120], {
      action: 'hash', type: 'SHA256', binaryData: true, binaryPropertyName: 'data', dataPropertyName: 'sha256', encoding: 'hex',
    }),
    postgres('Enregistrer la réception', [880, -120],
      'SELECT * FROM enregistrer_reception($1, $2, $3, $4, $5, $6);',
      '[ \'dossier\', $json.fileName, String($json.fileExtension || \'\').toLowerCase() === \'pdf\' ? \'pdf\' : \'image\', $json.fileName, $json.sha256, $execution.id ]'),
    code('Fin de la réception', [1100, 0], [],
      `// Point de passage unique entre la réception et l'extraction.
const nouvelles = $input.all().filter((i) => i.json.nouvelle === true).length;
return [{ json: { nouvelles_factures: nouvelles } }];`),

    // --- Phase 2 : extraction, une facture réservée à la fois -----------------
    postgres(N_RESERVER, [1320, 0], 'SELECT * FROM reserver_facture_a_extraire();', null, { executeOnce: true }),
    // Réutilisation limitée à une extraction de la même version de chaîne (D-059).
    postgres('Extraction déjà faite ?', [1540, 0], 'SELECT * FROM extraction_valide_existante($1, $2);',
      `[ $json.fichier_sha256, '${VERSION_CHAINE_EXTRACTION}' ]`, { alwaysOutputData: true }),
    si('Réutiliser l\'extraction ?', [1760, 0], '!!$json.extraction_id'),
    code('Préparer la réutilisation', [1980, -260], ['src/extractionWorkflow.js'],
      `// Même fichier déjà extrait : aucun appel au LLM (D-035, point 2).
return [{ json: payloadReutilisation(${RESERVATION}, $input.first().json, $execution.id) }];`),
    noeud('Lire le fichier réservé', 'n8n-nodes-base.readWriteFile', 1, [1980, 100], {
      operation: 'read', fileSelector: `={{ '/data/entrant/' + ${RESERVATION}.fichier_nom }}`, options: {},
    }, { alwaysOutputData: true, onError: 'continueErrorOutput' }),
    si('Fichier trouvé ?', [2200, 100], '$json.fileName !== undefined'),
    si('PDF ?', [2420, 40], `${RESERVATION}.format_source === 'pdf'`),
    noeud('Lire le texte du PDF', 'n8n-nodes-base.extractFromFile', 1, [2640, -60], {
      operation: 'pdf', binaryPropertyName: 'data', options: {},
    }, { onError: 'continueErrorOutput' }),
    code('Évaluer le texte du PDF', [2860, -60], ['src/extractionWorkflow.js'],
      `// Un PDF scanné n'a pas (ou presque pas) de texte : il passera par l'OCR.
return $input.all().map((i) => ({ json: { ...i.json, texte_suffisant: texteSuffisant(i.json.text) } }));`),
    si('Texte PDF exploitable ?', [3080, -60], '$json.texte_suffisant === true'),
    noeud('Relire le fichier pour l\'OCR', 'n8n-nodes-base.readWriteFile', 1, [3300, 60], {
      operation: 'read', fileSelector: `={{ '/data/entrant/' + ${RESERVATION}.fichier_nom }}`, options: {},
    }, { onError: 'continueErrorOutput' }),
    noeud('OCR (Tesseract)', 'n8n-nodes-base.httpRequest', 4.5, [3520, 160], {
      method: 'POST',
      url: 'http://ocr:8884/ocr',
      sendHeaders: true,
      specifyHeaders: 'keypair',
      headerParameters: { parameters: [{ name: 'Content-Type', value: '={{ $binary.data.mimeType }}' }] },
      sendBody: true,
      contentType: 'binaryData',
      inputDataFieldName: 'data',
      options: { response: { response: { fullResponse: true } }, timeout: 120000 },
    }, { onError: 'continueErrorOutput' }),
    code(N_TEXTE, [3740, 0], ['src/extractionWorkflow.js', 'src/promptExtraction.js'],
      `// Texte du PDF ou de l'OCR, et version du prompt EN SERVICE (VERSION_PROMPT, D-052).
return [{ json: texteAExtraire($input.first().json, VERSION_PROMPT) }];`),
    noeud('Extraction LLM (sous-workflow)', 'n8n-nodes-base.executeWorkflow', 1.2, [3960, 0], {
      source: 'database',
      workflowId: { __rl: true, value: '', mode: 'list' },
      mode: 'once',
      options: { waitForSubWorkflow: true },
    }, { onError: 'continueErrorOutput' }),
    // Une seule ligne, toujours (objet vide si aucun RIB actif). En cas de panne,
    // l'exécution continue sans référentiel : aucun RIB ne sera rempli (D-053).
    postgres(N_REFERENTIEL, [4180, -60], 'SELECT ribs_referentiel() AS ribs;', null,
      { executeOnce: true, onError: 'continueRegularOutput' }),
    code('Valider et vérifier', [4400, -60],
      ['src/extractionWorkflow.js', 'src/correctionsCode.js', 'src/rib.js', 'src/matricule.js',
        'src/validationExtraction.js', 'src/verificationSource.js',
        'src/schemas/extraction-facture.schema.json as SCHEMA_EXTRACTION'],
      `// Corrections par le code (D-053), schéma strict, puis identifiants présents
// dans le texte source (D-047). La sortie brute du modèle est conservée.
const referentiel = $input.first().json.ribs;
const resultat = payloadExtraction({
  reservation: ${RESERVATION},
  lecture: $('${N_TEXTE}').last().json,
  contrat: $('${N_LLM}').last().json,
  ribsReferentiel: referentiel && typeof referentiel === 'object' ? referentiel : null,
  schema: SCHEMA_EXTRACTION,
  executionId: $execution.id,
}, { corrigerExtraction, ribValide, formeCourteMatricule, validerExtraction, verifierIdentifiantsDansSource, alertesSource });
return [{ json: resultat }];`),
    si('Quota journalier épuisé ?', [4620, -60], '$json.arret_quota === true'),
    postgres('Libérer la facture et arrêter', [4840, -200],
      `WITH liberation AS (SELECT liberer_facture($1::bigint) AS liberee)
INSERT INTO journal_audit (acteur, action, entite, entite_id, donnees_apres, execution_n8n_id)
SELECT 'n8n:extraction', 'extraction.quota_journalier_epuise', 'factures', $2,
       jsonb_build_object('liberee', liberation.liberee, 'message', $3::text), $4
FROM liberation RETURNING id;`,
      `[ ${RESERVATION}.facture_id, String(${RESERVATION}.facture_id), $json.message, $execution.id ]`),
    code('Échec du sous-workflow', [4180, 140], ['src/extractionWorkflow.js'],
      `return [{ json: payloadEchec(${RESERVATION}, 'erreur_fournisseur', messageErreur($input.first().json), $execution.id, true, $('${N_TEXTE}').last().json.texte) }];`),
    code('Échec de lecture', [3740, 360], ['src/extractionWorkflow.js'],
      `// Fichier introuvable ou illisible, PDF illisible, OCR indisponible.
const item = $input.first().json;
const message = item.fileName === undefined && !item.error ? 'fichier introuvable dans /data/entrant' : messageErreur(item);
return [{ json: payloadEchec(${RESERVATION}, 'erreur_lecture', message, $execution.id, false) }];`),
    code(N_A_ENREGISTRER, [5060, 0], [],
      '// Point de passage unique avant l\'écriture en base.\nreturn $input.all();'),
    postgres('Enregistrer l\'extraction', [5280, 0], REQUETE_ENREGISTRER, '[ $json.payload ]', { onError: 'continueErrorOutput' }),
    code('Échec d\'écriture', [5500, 200], ['src/extractionWorkflow.js'],
      `const appelLlm = $('${N_A_ENREGISTRER}').last().json.appel_llm === true;
return [{ json: payloadEchec(${RESERVATION}, 'erreur_ecriture', messageErreur($input.first().json), $execution.id, appelLlm) }];`),
    postgres('Enregistrer l\'échec d\'écriture', [5720, 200], REQUETE_ENREGISTRER, '[ $json.payload ]', { onError: 'continueRegularOutput' }),
    si('Pause après un appel au LLM ?', [5940, 0], `$('${N_A_ENREGISTRER}').last().json.appel_llm === true`),
    noeud(`Pause de ${PAUSE_APRES_LLM_S} secondes`, 'n8n-nodes-base.wait', 1.1, [6160, -100], {
      resume: 'timeInterval', amount: PAUSE_APRES_LLM_S, unit: 'seconds',
    }, { webhookId: id('3a170000') }),
  ],
  settings: { executionOrder: 'v1' },
  pinData: {},
};
principal.connections = connexions([
  ['Toutes les minutes', 0, 'Lister les fichiers reçus'],
  ['Lister les fichiers reçus', 0, 'Fichier reçu ?'],
  ['Fichier reçu ?', 0, 'Empreinte SHA-256'],
  ['Fichier reçu ?', 1, 'Fin de la réception'],
  ['Empreinte SHA-256', 0, 'Enregistrer la réception'],
  ['Enregistrer la réception', 0, 'Fin de la réception'],
  ['Fin de la réception', 0, N_RESERVER],
  [N_RESERVER, 0, 'Extraction déjà faite ?'],
  ['Extraction déjà faite ?', 0, 'Réutiliser l\'extraction ?'],
  ['Réutiliser l\'extraction ?', 0, 'Préparer la réutilisation'],
  ['Réutiliser l\'extraction ?', 1, 'Lire le fichier réservé'],
  ['Préparer la réutilisation', 0, N_A_ENREGISTRER],
  ['Lire le fichier réservé', 0, 'Fichier trouvé ?'],
  ['Lire le fichier réservé', 1, 'Échec de lecture'],
  ['Fichier trouvé ?', 0, 'PDF ?'],
  ['Fichier trouvé ?', 1, 'Échec de lecture'],
  ['PDF ?', 0, 'Lire le texte du PDF'],
  ['PDF ?', 1, 'OCR (Tesseract)'],
  ['Lire le texte du PDF', 0, 'Évaluer le texte du PDF'],
  ['Lire le texte du PDF', 1, 'Échec de lecture'],
  ['Évaluer le texte du PDF', 0, 'Texte PDF exploitable ?'],
  ['Texte PDF exploitable ?', 0, N_TEXTE],
  ['Texte PDF exploitable ?', 1, 'Relire le fichier pour l\'OCR'],
  ['Relire le fichier pour l\'OCR', 0, 'OCR (Tesseract)'],
  ['Relire le fichier pour l\'OCR', 1, 'Échec de lecture'],
  ['OCR (Tesseract)', 0, N_TEXTE],
  ['OCR (Tesseract)', 1, 'Échec de lecture'],
  [N_TEXTE, 0, 'Extraction LLM (sous-workflow)'],
  [N_LLM, 0, N_REFERENTIEL],
  [N_REFERENTIEL, 0, 'Valider et vérifier'],
  ['Extraction LLM (sous-workflow)', 1, 'Échec du sous-workflow'],
  ['Valider et vérifier', 0, 'Quota journalier épuisé ?'],
  ['Quota journalier épuisé ?', 0, 'Libérer la facture et arrêter'],
  ['Quota journalier épuisé ?', 1, N_A_ENREGISTRER],
  ['Échec du sous-workflow', 0, N_A_ENREGISTRER],
  ['Échec de lecture', 0, N_A_ENREGISTRER],
  [N_A_ENREGISTRER, 0, 'Enregistrer l\'extraction'],
  ['Enregistrer l\'extraction', 0, 'Pause après un appel au LLM ?'],
  ['Enregistrer l\'extraction', 1, 'Échec d\'écriture'],
  ['Échec d\'écriture', 0, 'Enregistrer l\'échec d\'écriture'],
  ['Enregistrer l\'échec d\'écriture', 0, 'Pause après un appel au LLM ?'],
  ['Pause après un appel au LLM ?', 0, `Pause de ${PAUSE_APRES_LLM_S} secondes`],
  ['Pause après un appel au LLM ?', 1, N_RESERVER],
  [`Pause de ${PAUSE_APRES_LLM_S} secondes`, 0, N_RESERVER],
]);

// =============================================================================
// Workflow « Contrôles » (D-055, A1) : une facture extraite à la fois, toutes
// les règles, puis enregistrement du passage (statut calculé par la base).
// Une erreur arrête l'exécution, visible dans n8n : la facture reste
// « en_controle » et sera reprise après 15 minutes (règles déterministes :
// réessayer aussitôt donnerait la même erreur).
// =============================================================================
const N_RESERVER_CONTROLE = 'Réserver une facture à contrôler';
const controles = {
  name: 'Mizan – Contrôles',
  nodes: [
    noeud('Toutes les minutes', 'n8n-nodes-base.scheduleTrigger', 1.2, [0, 0], {
      rule: { interval: [{ field: 'minutes', minutesInterval: 1 }] },
    }),
    postgres(N_RESERVER_CONTROLE, [220, 0], 'SELECT * FROM reserver_facture_a_controler();', null, { executeOnce: true }),
    postgres('Contexte des contrôles', [440, 0], 'SELECT contexte_controles($1::bigint) AS contexte;', '[ $json.facture_id ]'),
    code('Exécuter toutes les règles', [660, 0],
      ['src/controles/regles.js', 'src/montants.js', 'src/matricule.js', 'src/rib.js'],
      `// Toutes les règles du catalogue, sans s'arrêter à la première anomalie (D-055).
const r = controlerFacture($input.first().json.contexte, {
  enMillimes, diviserArrondi, montantTva, formeCourteMatricule, normaliserMatricule, ribValide,
});
return [{ json: { payload: {
  facture_id: $('${N_RESERVER_CONTROLE}').last().json.facture_id,
  fournisseur_id: r.fournisseur_id,
  execution_n8n_id: $execution.id,
  resultats: r.resultats,
} } }];`),
    postgres('Enregistrer le passage', [880, 0], 'SELECT enregistrer_controles($1::jsonb) AS passage;', '[ $json.payload ]'),
  ],
  settings: { executionOrder: 'v1' },
  pinData: {},
};
controles.connections = connexions([
  ['Toutes les minutes', 0, N_RESERVER_CONTROLE],
  [N_RESERVER_CONTROLE, 0, 'Contexte des contrôles'],
  ['Contexte des contrôles', 0, 'Exécuter toutes les règles'],
  ['Exécuter toutes les règles', 0, 'Enregistrer le passage'],
  // Boucle : facture suivante, jusqu'à ce que la réservation ne renvoie plus rien.
  ['Enregistrer le passage', 0, N_RESERVER_CONTROLE],
]);

ecrire('workflows/extraction-llm.json', sousWorkflow);
ecrire('workflows/reception-extraction.json', principal);
ecrire('workflows/controles.json', controles);
