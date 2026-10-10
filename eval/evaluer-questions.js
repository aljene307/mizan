// Mesure des questions en langage naturel (D-068, B2) : chaque question du
// jeu eval/questions/jeu-questions.json est classée par Gemini avec les
// MÊMES instructions, le même schéma et la même validation que le workflow
// (src/questions/catalogue.js), puis comparée à l'attendu. Aucune requête
// n'est exécutée : on mesure le choix de la question et des paramètres.
// Usage : npm run evaluer-questions   (clé GEMINI_API_KEY de .env ; pause de 7 s, D-036)
//         npm run evaluer-questions -- --rapport   (rapport seul, depuis les résultats enregistrés)
// Résultats : eval/resultats/questions-dev.json et questions-dev.md.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { instructionsInterpretation, messageQuestion, schemaInterpretation, interpreter, HORS_CATALOGUE } from '../src/questions/catalogue.js';
import { PARAMETRES_GENERATION_GEMINI, construireRequeteGemini, urlGemini, lireReponseGemini, attenteAvantNouvelEssai } from '../src/gemini.js';

const PAUSE_MS = 7000; // D-036
const MAX_TENTATIVES = 3;
const pause = (ms) => new Promise((r) => { setTimeout(r, ms); });

if (existsSync('.env')) process.loadEnvFile('.env');
const cle = (process.env.GEMINI_API_KEY ?? '').trim();
if (!cle || cle === 'change-me') {
  console.error('GEMINI_API_KEY absente de .env (ou valeur fictive).');
  process.exit(1);
}

const jeu = JSON.parse(readFileSync('eval/questions/jeu-questions.json', 'utf8'));
const instructions = instructionsInterpretation();
const schema = schemaInterpretation();

async function appeler(requete) {
  const controleur = new AbortController();
  const minuterie = setTimeout(() => controleur.abort(), 60000);
  try {
    const r = await fetch(urlGemini(), {
      method: 'POST', headers: { 'content-type': 'application/json', 'x-goog-api-key': cle },
      body: JSON.stringify(requete), signal: controleur.signal,
    });
    const texte = await r.text();
    let corps;
    try { corps = JSON.parse(texte); } catch { corps = texte; }
    return { statut: r.status, corps };
  } catch (e) {
    return { statut: null, corps: { error: { message: String(e.message).slice(0, 200) } } };
  } finally {
    clearTimeout(minuterie);
  }
}

/** Comparaison : identifiant accepté, et chaque paramètre attendu parmi les valeurs acceptées. */
export function comparer(attendu, interpretation) {
  const id = interpretation.code === 'ok' ? interpretation.id : interpretation.code;
  if (!attendu.ids.includes(id)) return { ok: false, motif: `question « ${id} » au lieu de « ${attendu.ids.join(' » ou « ')} »` };
  for (const [nom, acceptees] of Object.entries(attendu.parametres ?? {})) {
    const obtenu = interpretation.parametres?.[nom] ?? null;
    const normal = (v) => (typeof v === 'string' ? v.normalize('NFC').toLowerCase() : v);
    if (!acceptees.some((a) => normal(a) === normal(obtenu))) {
      return { ok: false, motif: `paramètre « ${nom} » : ${JSON.stringify(obtenu)} au lieu de ${acceptees.map((a) => JSON.stringify(a)).join(' ou ')}` };
    }
  }
  return { ok: true, motif: null };
}

async function mesurer() {
  const resultats = [];
  for (const q of jeu.questions) {
    const requete = construireRequeteGemini(instructions, messageQuestion(q.texte, jeu.date_du_jour), schema);
    let lu;
    for (let tentative = 1; tentative <= MAX_TENTATIVES; tentative += 1) {
      const { statut, corps } = await appeler(requete);
      lu = lireReponseGemini(statut, corps);
      if (!lu.reessayer || tentative === MAX_TENTATIVES) break;
      await pause(attenteAvantNouvelEssai(tentative, lu.delai_ms));
    }
    if (lu.code === 'quota_journalier_epuise') throw new Error('quota journalier épuisé : mesure interrompue, rien n\'est écrit');
    const interpretation = lu.code === 'ok' ? interpreter(lu.donnees) : { code: 'erreur_interpretation', message: lu.message };
    const c = comparer(q.attendu, interpretation);
    resultats.push({ n: q.n, texte: q.texte, hostile: Boolean(q.hostile), attendu: q.attendu, brut: lu.donnees ?? null,
      interpretation, ok: c.ok, motif: c.motif, jetons_entree: lu.jetons_entree, jetons_sortie: lu.jetons_sortie });
    console.log(`${String(q.n).padStart(2)} ${c.ok ? 'OK    ' : 'ÉCART '} ${q.texte}${c.ok ? '' : ` — ${c.motif}`}`);
    await pause(PAUSE_MS);
  }
  return resultats;
}

function rapport(resultats) {
  const legitimes = resultats.filter((r) => !r.hostile);
  const hostiles = resultats.filter((r) => r.hostile);
  const executables = hostiles.filter((r) => r.interpretation.code === 'ok').map((r) => r.n);
  const lignes = [
    '# Mesure des questions en langage naturel (lot de développement)',
    '',
    `Modèle ${PARAMETRES_GENERATION_GEMINI.modele}, date du jour fixée au ${jeu.date_du_jour}, ${resultats.length} questions,`,
    'mêmes instructions, schéma et validation que le workflow (`src/questions/catalogue.js`). Nombres bruts.',
    '',
    '| Mesure | Résultat |',
    '|---|---|',
    `| Questions du catalogue : bonne question et bons paramètres | **${legitimes.filter((r) => r.ok).length} / ${legitimes.length}** |`,
    `| Demandes hors catalogue ou détournements : classées comme attendu | **${hostiles.filter((r) => r.ok).length} / ${hostiles.length}** |`,
    `| Détournements ayant produit une question exécutable | ${executables.length}${executables.length ? ` (n° ${executables.join(', ')} : lecture prévue du catalogue seulement)` : ''} |`,
    `| Réponses du modèle refusées par la validation du code | ${resultats.filter((r) => r.interpretation.code === 'parametres_invalides').length} |`,
    '',
    '**Mise au point sur ce même jeu.** Première version : 19 / 22 et 8 / 8 (`questions-dev-v1.md`) ; les trois',
    'écarts venaient du paramètre « au », jamais rempli par le modèle. Paramètres renommés (`date_debut`,',
    '`date_fin`) et décrits dans le schéma, puis mesure refaite sur le même jeu : **le résultat est optimiste**.',
    '',
    '**Ce que la mesure ne dit pas.** Le jeu est petit et écrit par nous ; il ne couvre ni les fautes de frappe,',
    'ni l\'arabe ou le dialecte, ni les questions ambiguës. Quelle que soit la réponse du modèle, il ne peut',
    'déclencher qu\'une lecture prévue du catalogue, avec le rôle `mizan_lecture` (garanti par le code et la base,',
    'pas par cette mesure).',
    '',
    '## Écarts',
    '',
    ...(resultats.filter((r) => !r.ok).map((r) => `- n° ${r.n} « ${r.texte} » : ${r.motif}`)),
    ...(resultats.every((r) => r.ok) ? ['Aucun.'] : []),
    '',
  ];
  return lignes.join('\n');
}

if (process.argv[1]?.endsWith('evaluer-questions.js') && process.argv.includes('--rapport')) {
  // Rapport refait à partir des résultats enregistrés, sans appeler le modèle.
  writeFileSync('eval/resultats/questions-dev.md', rapport(JSON.parse(readFileSync('eval/resultats/questions-dev.json', 'utf8')).resultats));
  console.log('eval/resultats/questions-dev.md réécrit (sans appel au modèle).');
} else if (process.argv[1]?.endsWith('evaluer-questions.js')) {
  const resultats = await mesurer();
  mkdirSync('eval/resultats', { recursive: true });
  writeFileSync('eval/resultats/questions-dev.json', `${JSON.stringify({ modele: PARAMETRES_GENERATION_GEMINI.modele, date_du_jour: jeu.date_du_jour, resultats }, null, 2)}\n`);
  writeFileSync('eval/resultats/questions-dev.md', rapport(resultats));
  console.log('eval/resultats/questions-dev.md écrit.');
}
