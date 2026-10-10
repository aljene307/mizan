// Construit les workflows n8n (fichiers JSON à importer) :
//   workflows/extraction-llm.json        sous-workflow « Extraction LLM » (D-039)
//   workflows/reception-extraction.json  workflow principal (D-035 à D-040, D-047)
//   workflows/controles.json             contrôles déterministes (D-055)
//   workflows/notifications-telegram.json  envoi des notifications (D-062, D-064)
//   workflows/reponses-telegram.json     réception des réponses (D-062, D-064)
//   workflows/releve-rapprochement.json  import et rapprochement du relevé (D-065)
//   workflows/ordres-paiement.json       proposition d'un lot d'ordres de paiement (D-068)
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

// =============================================================================
// Canal Telegram (D-062, D-064) : deux workflows, seuls à connaître Telegram.
// Ils n'appellent jamais Telegram directement, mais la passerelle interne
// (seule détentrice du jeton). Exécutions réussies non enregistrées
// (une exécution par minute) ; erreurs gardées ; délai maximal 120 s.
// =============================================================================
const PASSERELLE = 'http://passerelle-telegram:8885/telegram';
const REGLAGES_CANAL = {
  executionOrder: 'v1', saveDataSuccessExecution: 'none', saveDataErrorExecution: 'all', executionTimeout: 120,
};
// Une requête par élément : l'échec de l'un n'emporte pas les autres.
const postgresParElement = (nom, position, query, remplacement, extra = {}) => {
  const n = postgres(nom, position, query, remplacement, extra);
  n.parameters.options.queryBatching = 'independently';
  return n;
};
// options.batching : espacement entre deux requêtes (sans lui, le nœud les lance toutes en même temps).
const passerelle = (nom, position, methode, corps, delaiMs, espacementMs = 0) => noeud(nom, 'n8n-nodes-base.httpRequest', 4.5, position, {
  method: 'POST',
  url: methode.startsWith('=') ? methode : `${PASSERELLE}/${methode}`,
  sendBody: true,
  specifyBody: 'json',
  jsonBody: `={{ JSON.stringify(${corps}) }}`,
  options: {
    response: { response: { fullResponse: true, neverError: true } }, timeout: delaiMs,
    ...(espacementMs ? { batching: { batch: { batchSize: 1, batchInterval: espacementMs } } } : {}),
  },
});

// --- Envoi des notifications ---------------------------------------------------
const N_PREPARER_NOTIF = 'Préparer les notifications';
const N_A_ENVOYER = 'Notification à envoyer ?';
const notifications = {
  name: 'Mizan – Notifications Telegram',
  nodes: [
    noeud('Toutes les minutes', 'n8n-nodes-base.scheduleTrigger', 1.2, [0, 0], {
      rule: { interval: [{ field: 'minutes', minutesInterval: 1 }] },
    }),
    postgres('Notifications à préparer', [220, 0], 'SELECT donnees_notifications(\'telegram\') AS donnees;', null, { executeOnce: true }),
    code(N_PREPARER_NOTIF, [440, 0], ['src/decisions/notifications.js', 'src/montants.js', 'src/rapprochement/appariement.js'],
      `// Contenu et actions, sans rien connaître du canal (D-062, D-065, D-068).
const deps = { formaterMontant, enMillimes, fournisseurDansLibelle };
const preparer = {
  facture: (d) => notificationFacture({ candidat: d.candidat, facture: d.facture, fournisseur: d.fournisseur, resultats: d.resultats, regles: d.regles }, deps),
  demande: (d) => notificationDemande({ candidat: d.candidat, demande: d.demande, fournisseur: d.fournisseur, facture: d.facture, methodes: d.methodes }),
  rapprochement: (d) => notificationRapprochement({ candidat: d.candidat, proposition: d.proposition }, deps),
  signalement: (d) => notificationSignalement({ candidat: d.candidat, signalement: d.signalement, facture: d.facture }, deps),
  synthese: (d) => notificationSynthese({ candidat: d.candidat, synthese: d.synthese }),
  lot_paiement: (d) => notificationLot({ candidat: d.candidat, lot: d.lot }, deps),
  ligne_a_rapprocher: (d) => notificationLigneARapprocher({ candidat: d.candidat, ligne_a_rapprocher: d.ligne_a_rapprocher }, deps),
  choix_annulation: (d) => notificationChoixAnnulation({ candidat: d.candidat, choix_annulation: d.choix_annulation }, deps),
  demande_annulation: (d) => notificationDemandeAnnulation({ candidat: d.candidat, demande_annulation: d.demande_annulation }, deps),
};
return $input.all().map((i) => {
  const d = i.json.donnees;
  return { json: { notification: preparer[d.candidat.objet](d), adresse: d.candidat.adresse } };
});`),
    // La base vérifie le destinataire et l'état notifié, et renvoie le jeton une seule fois.
    postgresParElement('Créer la notification', [660, 0], 'SELECT * FROM creer_notification($1::jsonb);',
      '[ $json.notification ]', { onError: 'continueRegularOutput' }),
    code('Message Telegram', [880, 0], ['src/canaux/telegram.js'],
      `// Un élément par notification préparée, dans le même ordre.
const preparees = $('${N_PREPARER_NOTIF}').all();
return $input.all().map((i, k) => {
  const p = preparees[i.pairedItem?.item ?? k].json;
  if (!i.json.jeton) return { json: { ignorer: true, motif: String(i.json.error?.message ?? i.json.error ?? 'notification non créée') } };
  return { json: {
    notification_id: i.json.notification_id,
    corps: { chat_id: p.adresse, ...messageNotification(p.notification.contenu, p.notification.actions, i.json.jeton) },
  } };
});`),
    si(N_A_ENVOYER, [1100, 0], '$json.ignorer !== true'),
    // Une notification par seconde : rythme conseillé par Telegram dans une même conversation.
    passerelle('Envoyer (passerelle)', [1320, -80], 'sendMessage', '$json.corps', 40000, 1000),
    code('Résultat de l\'envoi', [1540, -80], [],
      `const envois = $('${N_A_ENVOYER}').all();
return $input.all().map((i, k) => {
  const corps = i.json.body ?? {};
  const ok = i.json.statusCode === 200 && corps.ok === true;
  return { json: {
    id: envois[i.pairedItem?.item ?? k].json.notification_id,
    reference: ok ? String(corps.result.message_id) : null,
    erreur: ok ? null : String(corps.description ?? \`HTTP \${i.json.statusCode}\`).slice(0, 500),
  } };
});`),
    postgresParElement('Marquer la notification', [1760, -80],
      'SELECT marquer_notification((p ->> \'id\')::bigint, p ->> \'reference\', p ->> \'erreur\') FROM (SELECT $1::jsonb AS p) x;',
      '[ $json ]'),
  ],
  settings: REGLAGES_CANAL,
  pinData: {},
};
notifications.connections = connexions([
  ['Toutes les minutes', 0, 'Notifications à préparer'],
  ['Notifications à préparer', 0, N_PREPARER_NOTIF],
  [N_PREPARER_NOTIF, 0, 'Créer la notification'],
  ['Créer la notification', 0, 'Message Telegram'],
  ['Message Telegram', 0, N_A_ENVOYER],
  [N_A_ENVOYER, 0, 'Envoyer (passerelle)'],
  ['Envoyer (passerelle)', 0, 'Résultat de l\'envoi'],
  ['Résultat de l\'envoi', 0, 'Marquer la notification'],
]);

// --- Réception des réponses ------------------------------------------------------
// Une interrogation longue par exécution, sous bail : jamais deux à la fois.
// Toutes les branches finissent sur « Rendre le bail » (exécuté une fois).
const N_BAIL = 'Prendre le bail';
const N_LIRE = 'Lire les mises à jour';
const N_A_TRAITER = 'Mise à jour à traiter ?';
const N_RENDRE = 'Rendre le bail';
const N_UNE_A_LA_FOIS = 'Une réponse à la fois';
const ATTENTE_TELEGRAM_S = 50;
const reponses = {
  name: 'Mizan – Réponses Telegram',
  nodes: [
    noeud('Toutes les minutes', 'n8n-nodes-base.scheduleTrigger', 1.2, [0, 0], {
      rule: { interval: [{ field: 'minutes', minutesInterval: 1 }] },
    }),
    // Aucune ligne si une autre exécution détient le bail : l'exécution s'arrête là.
    postgres(N_BAIL, [220, 0], 'SELECT * FROM prendre_bail_canal(\'telegram\');', null, { executeOnce: true }),
    passerelle('Interroger Telegram (attente longue)', [440, 0], 'getUpdates',
      `{ offset: Number($json.curseur), timeout: ${ATTENTE_TELEGRAM_S} }`, (ATTENTE_TELEGRAM_S + 20) * 1000),
    code(N_LIRE, [660, 0], ['src/canaux/telegram.js'],
      `// Échec de l'interrogation : erreur visible ; le bail expire seul (curseur inchangé).
const bail = $('${N_BAIL}').first().json;
const r = $input.first().json;
if (r.statusCode !== 200 || r.body?.ok !== true) {
  throw new Error(\`interrogation de Telegram en échec : \${r.body?.description ?? 'HTTP ' + r.statusCode}\`);
}
const misesAJour = r.body.result ?? [];
const commun = { bail_jeton: bail.bail_jeton, curseur: curseurSuivant(misesAJour, bail.curseur) };
if (!misesAJour.length) return [{ json: { ...commun, vide: true } }];
return misesAJour.map((u) => ({ json: { ...commun, ...evenementTelegram(u) } }));`),
    si(N_A_TRAITER, [880, 0], '$json.vide !== true'),
    // Toute l'autorisation est en base (D-062) : destinataire, état notifié, délai, rôle.
    postgresParElement('Recevoir l\'événement', [1100, -80], 'SELECT recevoir_evenement($1::jsonb) AS resultat;', '[ $json.evenement ]'),
    code('Préparer les réponses', [1320, -80], ['src/decisions/notifications.js', 'src/canaux/telegram.js'],
      `const lues = $('${N_A_TRAITER}').all();
const envois = [];
$input.all().forEach((i, k) => {
  const { repondre } = lues[i.pairedItem?.item ?? k].json;
  const reponse = messageReponse(i.json.resultat);
  if (repondre.callback_query_id) {
    envois.push({ methode: 'answerCallbackQuery', corps: { callback_query_id: repondre.callback_query_id, text: alerteBouton(reponse) } });
  }
  // Jamais de réponse dans un groupe : conversation privée seulement.
  if (reponse && repondre.prive && repondre.chat_id !== null) {
    envois.push({ methode: 'sendMessage', corps: { chat_id: repondre.chat_id, ...messageReponseTelegram(reponse) } });
  }
});
return envois.length ? envois.map((e) => ({ json: e })) : [{ json: { rien: true } }];`),
    si('Réponse à envoyer ?', [1540, -80], '$json.rien !== true'),
    // Une réponse à la fois, en attendant la fin de la précédente : l'ordre d'arrivée
    // est garanti (le nœud HTTP seul lancerait toutes les requêtes en même temps).
    noeud(N_UNE_A_LA_FOIS, 'n8n-nodes-base.splitInBatches', 3, [1760, -160], { batchSize: 1, options: {} }),
    passerelle('Répondre (passerelle)', [1980, -240], `={{ '${PASSERELLE}/' + $json.methode }}`, '$json.corps', 40000),
    postgres(N_RENDRE, [2200, 0], 'SELECT rendre_bail_canal(\'telegram\', $1::uuid, $2::bigint) AS rendu;',
      `[ $('${N_LIRE}').first().json.bail_jeton, $('${N_LIRE}').first().json.curseur ]`, { executeOnce: true }),
  ],
  settings: REGLAGES_CANAL,
  pinData: {},
};
reponses.connections = connexions([
  ['Toutes les minutes', 0, N_BAIL],
  [N_BAIL, 0, 'Interroger Telegram (attente longue)'],
  ['Interroger Telegram (attente longue)', 0, N_LIRE],
  [N_LIRE, 0, N_A_TRAITER],
  [N_A_TRAITER, 0, 'Recevoir l\'événement'],
  [N_A_TRAITER, 1, N_RENDRE],
  ['Recevoir l\'événement', 0, 'Préparer les réponses'],
  ['Préparer les réponses', 0, 'Réponse à envoyer ?'],
  ['Réponse à envoyer ?', 0, N_UNE_A_LA_FOIS],
  ['Réponse à envoyer ?', 1, N_RENDRE],
  // Sortie 1 (« loop ») : un élément à envoyer ; sortie 0 (« done ») : tout est envoyé.
  [N_UNE_A_LA_FOIS, 1, 'Répondre (passerelle)'],
  ['Répondre (passerelle)', 0, N_UNE_A_LA_FOIS],
  [N_UNE_A_LA_FOIS, 0, N_RENDRE],
]);

// =============================================================================
// Import et rapprochement du relevé (D-065) : un CSV déposé dans
// data/entrant/releves/ est lu, contrôlé (soldes), enregistré une seule fois,
// puis ses lignes non traitées sont appariées. Rien n'est enregistré s'il n'y
// a rien de nouveau (sinon une synthèse serait renvoyée à chaque passage).
// =============================================================================
const N_RELEVES = 'Lister les relevés déposés';
const N_TEXTE_RELEVE = 'Lire le texte du relevé';
const N_RELEVE_ENREGISTRE = 'Enregistrer le relevé';
// Compte de l'entreprise (fictif) : le CSV de la banque ne le contient pas.
const COMPTE_ENTREPRISE = { banque: 'Banque Démo 99', rib_compte: '99330228027133819365', devise: 'TND' };
const releve = {
  name: 'Mizan – Import et rapprochement du relevé',
  nodes: [
    noeud('Toutes les 15 minutes', 'n8n-nodes-base.scheduleTrigger', 1.2, [0, 0], {
      rule: { interval: [{ field: 'minutes', minutesInterval: 15 }] },
    }),
    noeud(N_RELEVES, 'n8n-nodes-base.readWriteFile', 1, [220, 0], {
      operation: 'read', fileSelector: '/data/entrant/releves/*.{csv,CSV}', options: {},
    }, { alwaysOutputData: true }),
    si('Relevé déposé ?', [440, 0], '$json.fileName !== undefined'),
    noeud(N_TEXTE_RELEVE, 'n8n-nodes-base.extractFromFile', 1.1, [660, -80], {
      operation: 'text', binaryPropertyName: 'data', destinationKey: 'texte',
      options: { keepSource: 'json', encoding: 'utf8', stripBOM: true },
    }),
    code('Préparer l\'import', [880, -80], ['src/rapprochement/releve.js'],
      `// Lecture du CSV (virgule décimale, dates JJ/MM/AAAA) ; les soldes sont revérifiés en base.
const compte = ${JSON.stringify(COMPTE_ENTREPRISE)};
return $input.all().map((i) => {
  const r = lireReleveCsv(i.json.texte);
  return { json: { texte: i.json.texte, payload: {
    ...compte, date_debut: r.date_debut, date_fin: r.date_fin, solde_initial: r.solde_initial, solde_final: r.solde_final,
    fichier_nom: i.json.fileName, execution_n8n_id: $execution.id, lignes: r.lignes,
  } } };
});`),
    // Empreinte du contenu calculée par la base : un relevé n'est importé qu'une fois.
    postgresParElement(N_RELEVE_ENREGISTRE, [1100, -80],
      'SELECT * FROM enregistrer_releve($1::jsonb || jsonb_build_object(\'fichier_sha256\', encode(sha256(convert_to($2, \'UTF8\')), \'hex\')));',
      '[ $json.payload, $json.texte ]'),
    postgresParElement('Contexte du rapprochement', [1320, -80], 'SELECT contexte_rapprochement($1::bigint) AS contexte;', '[ $json.releve_id ]'),
    code('Apparier', [1540, -80], ['src/rapprochement/appariement.js', 'src/montants.js'],
      `// Règles déterministes (D-065) ; confirmation automatique seulement pour le cas sûr.
const enregistres = $('${N_RELEVE_ENREGISTRE}').all();
return $input.all().map((i, k) => {
  const ctx = i.json.contexte;
  const r = rapprocher(ctx, { enMillimes });
  return { json: {
    a_enregistrer: r.categories.length + r.propositions.length + r.signalements.length > 0,
    payload: { releve_id: enregistres[i.pairedItem?.item ?? k].json.releve_id, execution_n8n_id: $execution.id, ...r },
  } };
});`),
    si('Quelque chose à enregistrer ?', [1760, -80], '$json.a_enregistrer === true'),
    postgresParElement('Enregistrer le rapprochement', [1980, -160], 'SELECT enregistrer_rapprochements($1::jsonb) AS bilan;', '[ $json.payload ]'),
  ],
  settings: { executionOrder: 'v1' },
  pinData: {},
};
releve.connections = connexions([
  ['Toutes les 15 minutes', 0, N_RELEVES],
  [N_RELEVES, 0, 'Relevé déposé ?'],
  ['Relevé déposé ?', 0, N_TEXTE_RELEVE],
  [N_TEXTE_RELEVE, 0, 'Préparer l\'import'],
  ['Préparer l\'import', 0, N_RELEVE_ENREGISTRE],
  [N_RELEVE_ENREGISTRE, 0, 'Contexte du rapprochement'],
  ['Contexte du rapprochement', 0, 'Apparier'],
  ['Apparier', 0, 'Quelque chose à enregistrer ?'],
  ['Quelque chose à enregistrer ?', 0, 'Enregistrer le rapprochement'],
]);

// =============================================================================
// Ordres de paiement (D-068) : chaque lundi à 8 h (ou à la main), la base
// propose un lot d'ordres pour les échéances proches, sur le RIB du
// référentiel (D-058). La notification au responsable part par le workflow
// « Notifications Telegram » ; l'approbation passe par le canal.
// =============================================================================
const ordres = {
  name: 'Mizan – Ordres de paiement',
  nodes: [
    noeud('Chaque lundi à 8 h', 'n8n-nodes-base.scheduleTrigger', 1.2, [0, -80], {
      rule: { interval: [{ field: 'weeks', weeksInterval: 1, triggerAtDay: [1], triggerAtHour: 8, triggerAtMinute: 0 }] },
    }),
    noeud('Lancement manuel', 'n8n-nodes-base.manualTrigger', 1, [0, 80], {}),
    // Un lot déjà en attente est renvoyé tel quel ; aucun lot sans facture à payer.
    postgres('Proposer un lot', [220, 0], 'SELECT proposer_lot_paiement($1::jsonb) AS bilan;',
      '[ { execution_n8n_id: $execution.id } ]', { executeOnce: true }),
  ],
  settings: { executionOrder: 'v1' },
  pinData: {},
};
ordres.connections = connexions([
  ['Chaque lundi à 8 h', 0, 'Proposer un lot'],
  ['Lancement manuel', 0, 'Proposer un lot'],
]);

// =============================================================================
// Questions en langage naturel (D-068, B2). File remplie par « Réponses
// Telegram » (/q …). Le modèle choisit seulement une question du catalogue ;
// la requête du catalogue est lue avec le rôle mizan_lecture ; le code
// rédige la réponse ; la question est conclue (trace en base).
// =============================================================================
const CRED_POSTGRES_LECTURE = { postgres: { id: '', name: 'PostgreSQL Mizan (lecture)' } };
const N_QUESTIONS = 'Questions à traiter';
const N_PREPARER_Q = 'Préparer l\'interprétation';
const N_LIRE_Q = 'Lire l\'interprétation';
const N_DONNEES_Q = 'Lire les données (mizan_lecture)';
const N_REDIGER_Q = 'Rédiger la réponse';
const PAUSE_ENTRE_APPELS_MS = 4000; // quota par minute de l'offre gratuite (D-036)
const questions = {
  name: 'Mizan – Questions (langage naturel)',
  nodes: [
    noeud('Toutes les minutes', 'n8n-nodes-base.scheduleTrigger', 1.2, [0, 0], {
      rule: { interval: [{ field: 'minutes', minutesInterval: 1 }] },
    }),
    // Aucune ligne : l'exécution s'arrête là.
    postgres(N_QUESTIONS, [220, 0], 'SELECT * FROM prendre_questions(5);', null, { executeOnce: true }),
    code(N_PREPARER_Q, [440, 0], ['src/questions/catalogue.js', 'src/gemini.js'],
      `// Le modèle reçoit le catalogue et la question balisée, jamais de données.
const aujourdhui = new Intl.DateTimeFormat('en-CA', { timeZone: 'Africa/Tunis' }).format(new Date());
const instructions = instructionsInterpretation();
const schema = schemaInterpretation();
return $input.all().map((i) => ({ json: {
  question_id: i.json.question_id, adresse: i.json.adresse, url: urlGemini(),
  requete: construireRequeteGemini(instructions, messageQuestion(i.json.texte, aujourdhui), schema),
} }));`),
    noeud('Interpréter (Gemini)', 'n8n-nodes-base.httpRequest', 4.5, [660, 0], {
      method: 'POST',
      url: '={{ $json.url }}',
      authentication: 'predefinedCredentialType',
      nodeCredentialType: 'googlePalmApi',
      sendBody: true,
      specifyBody: 'json',
      jsonBody: '={{ JSON.stringify($json.requete) }}',
      options: {
        response: { response: { fullResponse: true, neverError: true } }, timeout: 60000,
        batching: { batch: { batchSize: 1, batchInterval: PAUSE_ENTRE_APPELS_MS } },
      },
    }, { credentials: CRED_GEMINI, onError: 'continueRegularOutput' }),
    code(N_LIRE_Q, [880, 0], ['src/questions/catalogue.js', 'src/gemini.js'],
      `// Sortie du modèle validée par le code ; requête fixe du catalogue (ou requête vide).
const preparees = $("${N_PREPARER_Q}").all();
return $input.all().map((i, k) => {
  const p = preparees[i.pairedItem?.item ?? k].json;
  const lu = lireReponseGemini(i.json.statusCode ?? null, i.json.body ?? null);
  const interpretation = lu.code === 'ok' ? interpreter(lu.donnees) : { code: 'erreur_interpretation', message: lu.message };
  return { json: { question_id: p.question_id, adresse: p.adresse, interpretation, ...requeteQuestion(interpretation) } };
});`),
    postgresParElement(N_DONNEES_Q, [1100, 0], '={{ $json.sql }}', '$json.valeurs',
      { credentials: CRED_POSTGRES_LECTURE, onError: 'continueRegularOutput' }),
    code(N_REDIGER_Q, [1320, 0], ['src/questions/catalogue.js', 'src/montants.js', 'src/canaux/telegram.js'],
      `// Le code rédige la réponse à partir des lignes lues (une ligne « lignes » par question).
const lues = $("${N_LIRE_Q}").all();
const deps = { formaterMontant, enMillimes };
return $input.all().map((i, k) => {
  const q = lues[i.pairedItem?.item ?? k].json;
  const lignes = Array.isArray(i.json.lignes) ? i.json.lignes : null;
  const reponse = redigerReponse(q.interpretation, lignes, deps);
  const erreurLecture = lignes ? null : String(i.json.error?.message ?? i.json.error ?? 'lecture impossible').slice(0, 500);
  return { json: {
    corps: { chat_id: q.adresse, ...messageReponseTelegram({ lignes: reponse.lignes }) },
    conclusion: {
      question_id: q.question_id, question_catalogue: q.interpretation.id ?? null,
      parametres: q.interpretation.parametres ?? null, code_reponse: reponse.code_reponse,
      erreur: q.interpretation.message ?? erreurLecture,
      execution_n8n_id: $execution.id,
    },
  } };
});`),
    passerelle('Répondre (passerelle)', [1540, 0], 'sendMessage', '$json.corps', 40000, 1000),
    code('Résultat de l\'envoi', [1760, 0], [],
      `const redigees = $("${N_REDIGER_Q}").all();
return $input.all().map((i, k) => {
  const c = redigees[i.pairedItem?.item ?? k].json.conclusion;
  const ok = i.json.statusCode === 200 && i.json.body?.ok === true;
  return { json: { ...c, envoyee: ok, erreur: ok ? c.erreur : String(i.json.body?.description ?? \`HTTP \${i.json.statusCode}\`).slice(0, 500) } };
});`),
    postgresParElement('Conclure la question', [1980, 0], 'SELECT conclure_question($1::jsonb) AS statut;', '[ $json ]'),
  ],
  settings: REGLAGES_CANAL,
  pinData: {},
};
questions.connections = connexions([
  ['Toutes les minutes', 0, N_QUESTIONS],
  [N_QUESTIONS, 0, N_PREPARER_Q],
  [N_PREPARER_Q, 0, 'Interpréter (Gemini)'],
  ['Interpréter (Gemini)', 0, N_LIRE_Q],
  [N_LIRE_Q, 0, N_DONNEES_Q],
  [N_DONNEES_Q, 0, N_REDIGER_Q],
  [N_REDIGER_Q, 0, 'Répondre (passerelle)'],
  ['Répondre (passerelle)', 0, 'Résultat de l\'envoi'],
  ['Résultat de l\'envoi', 0, 'Conclure la question'],
]);

ecrire('workflows/releve-rapprochement.json', releve);
ecrire('workflows/ordres-paiement.json', ordres);
ecrire('workflows/questions.json', questions);
ecrire('workflows/notifications-telegram.json', notifications);
ecrire('workflows/reponses-telegram.json', reponses);
ecrire('workflows/extraction-llm.json', sousWorkflow);
ecrire('workflows/reception-extraction.json', principal);
ecrire('workflows/controles.json', controles);
