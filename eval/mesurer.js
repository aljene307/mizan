// Mesure (D-052) : appelle Gemini sur les textes conservés du lot de
// DÉVELOPPEMENT (D-051), pour chaque configuration, et enregistre chaque
// appel dans eval/resultats/mesure-2026-10-06/appels.jsonl.
// Usage :
//   node eval/mesurer.js --phase precision                 4 configurations × textes dev, passage 1
//   node eval/mesurer.js --phase stabilite --configs v1-libre,v2-liste   passages 2 et 3, 10 documents
// Garanties : lot de test refusé (D-026) ; pause de 7 s après chaque appel
// (D-036) ; clé lue dans .env, transmise dans l'en-tête x-goog-api-key, jamais
// écrite ; reprise possible (les appels déjà enregistrés sont sautés) ;
// arrêt propre si le quota journalier est épuisé.
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import pg from 'pg';
import { PROMPTS, construireMessageDocument } from '../src/promptExtraction.js';
import { PARAMETRES_GENERATION_GEMINI, construireRequeteGemini, urlGemini, lireReponseGemini, attenteAvantNouvelEssai } from '../src/gemini.js';
import { CONFIGURATIONS, DOCUMENTS_STABILITE, DOSSIER_MESURE, FICHIER_APPELS, cleAppel, estCopieEssai, schemaPourConfiguration } from './mesure-commun.js';

const PAUSE_MS = 7000; // D-036
const MAX_TENTATIVES = 3;
const DELAI_APPEL_MS = 90000;
const pause = (ms) => new Promise((r) => { setTimeout(r, ms); });
const arg = (nom) => { const i = process.argv.indexOf(nom); return i > -1 ? process.argv[i + 1] : undefined; };

if (existsSync('.env')) process.loadEnvFile('.env');
const cle = (process.env.GEMINI_API_KEY ?? '').trim();
if (!cle || cle === 'change-me') {
  console.error('GEMINI_API_KEY absente de .env (ou valeur fictive).');
  process.exit(1);
}

const phase = arg('--phase');
if (!['precision', 'stabilite'].includes(phase)) throw new Error('--phase precision ou --phase stabilite');
const configsDemandees = (arg('--configs') ?? CONFIGURATIONS.map((c) => c.id).join(',')).split(',');
const configurations = CONFIGURATIONS.filter((c) => configsDemandees.includes(c.id));
if (configurations.length !== configsDemandees.length) throw new Error(`configuration inconnue dans ${configsDemandees}`);

const lots = JSON.parse(readFileSync('data/synthetic/lots.json', 'utf8'));
const fichiersDev = new Set(lots.dev.map((d) => d.fichier.split('/').pop()));
const schemaStrict = JSON.parse(readFileSync('src/schemas/extraction-facture.schema.json', 'utf8'));

async function lireTextes() {
  const client = new pg.Client({
    host: 'localhost', port: 5432, user: 'mizan_app', password: process.env.MIZAN_APP_PASSWORD, database: process.env.MIZAN_DB ?? 'mizan',
  });
  await client.connect();
  try {
    const { rows } = await client.query(`
      SELECT DISTINCT ON (f.id) f.fichier_nom, e.texte_source
      FROM factures f JOIN extractions e ON e.facture_id = f.id
      WHERE e.texte_source IS NOT NULL
      ORDER BY f.id, e.id DESC`);
    // Lot de développement uniquement (D-026), sans les copies d'essai (D-054).
    return rows.filter((r) => fichiersDev.has(r.fichier_nom) && !estCopieEssai(r.fichier_nom))
      .map((r) => ({ document: r.fichier_nom.replace(/\.\w+$/, ''), texte: r.texte_source }))
      .sort((a, b) => a.document.localeCompare(b.document));
  } finally {
    await client.end();
  }
}

async function appeler(requete) {
  const controleur = new AbortController();
  const minuterie = setTimeout(() => controleur.abort(), DELAI_APPEL_MS);
  try {
    const reponse = await fetch(urlGemini(), {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-goog-api-key': cle },
      body: JSON.stringify(requete),
      signal: controleur.signal,
    });
    const texte = await reponse.text();
    let corps;
    try { corps = JSON.parse(texte); } catch { corps = texte; }
    return { statut: reponse.status, corps };
  } catch (erreur) {
    return { statut: null, corps: { error: { message: String(erreur.message).slice(0, 200) } } };
  } finally {
    clearTimeout(minuterie);
  }
}

const textes = await lireTextes();
// Textes mesurés, conservés avec les résultats : l'analyse est rejouable sans la base.
mkdirSync(DOSSIER_MESURE, { recursive: true });
writeFileSync(`${DOSSIER_MESURE}/textes.json`, `${JSON.stringify(Object.fromEntries(textes.map((t) => [t.document, t.texte])), null, 2)}\n`);
const deja = new Set(existsSync(FICHIER_APPELS)
  ? readFileSync(FICHIER_APPELS, 'utf8').trim().split('\n').filter(Boolean).map((l) => cleAppel(JSON.parse(l)))
  : []);
mkdirSync(DOSSIER_MESURE, { recursive: true });

const plan = [];
for (const configuration of configurations) {
  const documents = phase === 'precision' ? textes : textes.filter((t) => DOCUMENTS_STABILITE.includes(t.document));
  const passages = phase === 'precision' ? [1] : [2, 3];
  for (const passage of passages) for (const t of documents) plan.push({ configuration, passage, ...t });
}
const aFaire = plan.filter((p) => !deja.has(cleAppel({ configuration: p.configuration.id, document: p.document, passage: p.passage })));
console.log(`${textes.length} textes dev ; phase ${phase} ; ${plan.length} appels prévus, ${plan.length - aFaire.length} déjà faits, ${aFaire.length} à faire.`);

let n = 0;
for (const p of aFaire) {
  const requete = construireRequeteGemini(
    PROMPTS[p.configuration.prompt], construireMessageDocument(p.texte), schemaPourConfiguration(schemaStrict, p.configuration),
  );
  let lu;
  let tentative = 0;
  const debut = Date.now();
  for (;;) {
    tentative += 1;
    const { statut, corps } = await appeler(requete);
    lu = lireReponseGemini(statut, corps);
    if (!lu.reessayer || tentative >= MAX_TENTATIVES) break;
    await pause(attenteAvantNouvelEssai(tentative, lu.delai_ms));
  }
  appendFileSync(FICHIER_APPELS, `${JSON.stringify({
    configuration: p.configuration.id, prompt: p.configuration.prompt, devise_schema: p.configuration.devise,
    document: p.document, passage: p.passage, code: lu.code, donnees: lu.donnees, message: lu.message,
    jetons_entree: lu.jetons_entree, jetons_sortie: lu.jetons_sortie, jetons_reflexion: lu.jetons_reflexion,
    modele: lu.modele, tentatives: tentative, duree_ms: Date.now() - debut,
    parametres_generation: { ...PARAMETRES_GENERATION_GEMINI }, horodatage: new Date().toISOString(),
  })}\n`);
  n += 1;
  console.log(`[${n}/${aFaire.length}] ${p.configuration.id} ${p.document} passage ${p.passage} : ${lu.code}${lu.message ? ` (${lu.message.slice(0, 80)})` : ''}`);
  if (lu.code === 'quota_journalier_epuise') {
    console.log('Quota journalier épuisé : arrêt propre. Relancer la même commande demain pour reprendre.');
    process.exit(2);
  }
  await pause(PAUSE_MS);
}
console.log('Terminé.');
