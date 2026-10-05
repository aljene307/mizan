// Structure des workflows exportés, et exécution du code GÉNÉRÉ de leurs
// nœuds Code (tel que n8n l'exécutera), avec les vraies réponses de Gemini.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const lire = (chemin) => JSON.parse(readFileSync(chemin, 'utf8'));
const sous = lire('workflows/extraction-llm.json');
const principal = lire('workflows/reception-extraction.json');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const DECLENCHEURS = new Set(['n8n-nodes-base.scheduleTrigger', 'n8n-nodes-base.executeWorkflowTrigger', 'n8n-nodes-base.manualTrigger']);

for (const [nom, wf] of [['sous-workflow', sous], ['workflow principal', principal]]) {
  test(`${nom} : noms uniques, connexions valides, aucun nœud orphelin`, () => {
    const noms = wf.nodes.map((n) => n.name);
    assert.equal(new Set(noms).size, noms.length, 'noms de nœuds uniques');
    const cibles = new Set();
    for (const [source, { main }] of Object.entries(wf.connections)) {
      assert.ok(noms.includes(source), `source inconnue : ${source}`);
      for (const sortie of main) for (const l of sortie) {
        assert.ok(noms.includes(l.node), `cible inconnue : ${l.node}`);
        cibles.add(l.node);
      }
    }
    for (const n of wf.nodes) {
      if (!DECLENCHEURS.has(n.type)) assert.ok(cibles.has(n.name), `nœud jamais atteint : ${n.name}`);
      assert.match(n.id, UUID, `identifiant de ${n.name}`);
      if (n.webhookId) assert.match(n.webhookId, UUID, `webhookId de ${n.name}`);
    }
  });

  test(`${nom} : le code de chaque nœud Code est du JavaScript valide`, () => {
    const AsyncFunction = (async () => {}).constructor;
    for (const n of wf.nodes.filter((x) => x.type === 'n8n-nodes-base.code')) {
      assert.doesNotThrow(() => new AsyncFunction('$input', '$json', '$', '$execution', '$runIndex', n.parameters.jsCode), n.name);
    }
  });

  test(`${nom} : aucun secret, credentials référencés par leur nom`, () => {
    const texte = JSON.stringify(wf);
    assert.doesNotMatch(texte, /AIza[0-9A-Za-z_-]{20,}/, 'pas de clé Google');
    assert.doesNotMatch(texte, /password/i, 'pas de mot de passe');
    for (const n of wf.nodes.filter((x) => x.credentials)) {
      for (const c of Object.values(n.credentials)) assert.deepEqual(Object.keys(c).sort(), ['id', 'name']);
    }
  });
}

// --- Exécution du code généré, comme dans n8n -------------------------------------
const noeud = (wf, nom) => wf.nodes.find((n) => n.name === nom);
async function executer(wf, nom, { entree, sorties = {}, runIndex = 0 }) {
  const contexte = vm.createContext({
    $input: { first: () => ({ json: entree }), all: () => [{ json: entree }] },
    $: (cible) => ({ last: () => ({ json: sorties[cible] }), first: () => ({ json: sorties[cible] }) }),
    $execution: { id: 'exec-test' },
    $runIndex: runIndex,
    Date,
  });
  const [{ json }] = await vm.runInContext(`(async () => {\n${noeud(wf, nom).parameters.jsCode}\n})()`, contexte);
  return JSON.parse(JSON.stringify(json));
}

test('chaîne du sous-workflow : préparer, horodater, lire la réponse réelle, contrat', async () => {
  const appel = await executer(sous, 'Préparer l\'appel', { entree: { texte: 'FACTURE N° TEST-0001', version_prompt: 'v1' } });
  assert.equal(appel.version_prompt, 'v1');
  assert.equal(appel.requete.generationConfig.thinkingConfig.thinkingLevel, 'low');
  assert.ok(!JSON.stringify(appel.requete.generationConfig.responseJsonSchema).includes('"pattern"'));
  const tentative = await executer(sous, 'Horodater la tentative', { entree: appel });
  assert.equal(typeof tentative.debut_essai, 'number');
  const reponse = { statusCode: 200, body: lire('tests/fixtures/gemini-reponse-200-rib-errone.json') };
  const lu = await executer(sous, 'Lire la réponse', { entree: reponse, sorties: { 'Horodater la tentative': tentative } });
  assert.equal(lu.reessayer, false);
  const contrat = await executer(sous, 'Résultat (contrat)', { entree: lu });
  assert.equal(contrat.code_resultat, 'ok');
  assert.equal(contrat.tentatives, 1);
  assert.equal(contrat.donnees.fournisseur.rib, '990010000000000000165');

  // Suite dans le workflow principal : validation et contrôle des identifiants.
  const reservation = { facture_id: 7, fichier_sha256: 'b'.repeat(64), format_source: 'pdf' };
  const lecture = { texte: 'MF : 9900000K/A/M/000\nFACTURE N° TEST-0001\nRIB : 99 001 0000000000001 65', methode_lecture: 'texte_pdf', duree_lecture_ms: null };
  const sortie = await executer(principal, 'Valider et vérifier', {
    entree: contrat, sorties: { 'Réserver une facture': reservation, 'Texte à extraire': lecture },
  });
  assert.equal(sortie.payload.resultat, 'valide');
  assert.equal(sortie.payload.execution_n8n_id, 'exec-test');
  assert.deepEqual(sortie.payload.alertes_source, ['fournisseur.rib « 990010000000000000165 » absent du texte source']);
});

test('429 par minute dans le sous-workflow : nouvelle tentative avec attente', async () => {
  const appel = await executer(sous, 'Préparer l\'appel', { entree: { texte: 'x', version_prompt: 'v1' } });
  const tentative = await executer(sous, 'Horodater la tentative', { entree: appel });
  const quota = { statusCode: 429, body: { error: { code: 429, message: 'Quota', details: [{ retryDelay: '15s' }] } } };
  const lu = await executer(sous, 'Lire la réponse', { entree: quota, sorties: { 'Horodater la tentative': tentative }, runIndex: 0 });
  assert.deepEqual([lu.reessayer, lu.attente_ms], [true, 15000]);
  const dernier = await executer(sous, 'Lire la réponse', { entree: quota, sorties: { 'Horodater la tentative': tentative }, runIndex: 2 });
  assert.deepEqual([dernier.reessayer, dernier.contrat.code_resultat], [false, 'quota_minute_epuise']);
});

test('workflow principal : texte du PDF ou de l\'OCR, version de prompt la plus récente', async () => {
  const pdf = await executer(principal, 'Texte à extraire', { entree: { text: 'Facture' } });
  assert.deepEqual(pdf, { texte: 'Facture', methode_lecture: 'texte_pdf', duree_lecture_ms: null, version_prompt: 'v1' });
  const ocr = await executer(principal, 'Texte à extraire', { entree: { statusCode: 200, body: { texte: 'Scan', duree_ms: 600 } } });
  assert.equal(ocr.methode_lecture, 'ocr');
});

test('workflow principal : paramètres clés (réservation, pause, montage /data/entrant)', () => {
  const reserver = noeud(principal, 'Réserver une facture');
  assert.equal(reserver.executeOnce, true);
  assert.match(reserver.parameters.query, /reserver_facture_a_extraire\(\)/);
  assert.equal(noeud(principal, 'Pause de 7 secondes').parameters.amount, 7);
  assert.equal(noeud(principal, 'Extraction déjà faite ?').alwaysOutputData, true);
  assert.match(noeud(principal, 'Lister les fichiers reçus').parameters.fileSelector, /^\/data\/entrant\//);
  for (const nom of ['Lire le fichier réservé', 'OCR (Tesseract)', 'Extraction LLM (sous-workflow)', 'Enregistrer l\'extraction']) {
    assert.equal(noeud(principal, nom).onError, 'continueErrorOutput', `${nom} : sortie d'erreur`);
  }
});
