// Rapport de précision de l'extraction (règle de comparaison D-050).
// Usage : node eval/evaluer.js --lot dev
//         node eval/evaluer.js --lot test --etape-8   (lot de test : étape 8 seulement, D-026)
// Option : --sortie <dossier> (défaut eval/resultats ; la répétition générale écrit ailleurs).
// Lit la dernière extraction de chaque facture du lot dans la base « mizan »
// (rôle mizan_app, lecture seule), la compare à la vérité terrain et écrit
// eval/resultats/precision-<lot>.md et .json.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import pg from 'pg';
import { CHAMPS_ENTETE, CHAMPS_LIGNE, comparerExtraction } from '../src/comparaison.js';
import { verifierIdentifiantsDansSource } from '../src/verificationSource.js';
import { validerExtraction } from '../src/validationExtraction.js';
import { estCopieEssai } from './mesure-commun.js';

const schemaStrict = JSON.parse(readFileSync('src/schemas/extraction-facture.schema.json', 'utf8'));

const arg = (nom) => { const i = process.argv.indexOf(nom); return i > -1 ? process.argv[i + 1] : undefined; };
const lot = arg('--lot') ?? 'dev';
if (!['dev', 'test'].includes(lot)) throw new Error('--lot dev ou --lot test');
if (lot === 'test' && !process.argv.includes('--etape-8')) {
  console.error('Le lot de test est réservé à l\'évaluation de l\'étape 8 (D-026) : ajouter --etape-8 pour l\'utiliser.');
  process.exit(1);
}

const pct = (k, n) => (n === 0 ? '—' : `${k}/${n} (${(100 * k / n).toFixed(1).replace('.', ',')} %)`);
const mediane = (v) => { const s = [...v].sort((a, b) => a - b); return s.length ? s[Math.floor((s.length - 1) / 2)] : null; };
const moyenne = (v) => (v.length ? Math.round(v.reduce((a, b) => a + b, 0) / v.length) : null);

async function lireExtractions() {
  if (existsSync('.env')) process.loadEnvFile('.env');
  const client = new pg.Client({
    host: 'localhost', port: 5432, user: 'mizan_app', password: process.env.MIZAN_APP_PASSWORD, database: process.env.MIZAN_DB ?? 'mizan',
  });
  await client.connect();
  try {
    const { rows } = await client.query(`
      SELECT DISTINCT ON (f.id) f.fichier_nom, e.id AS extraction_id, e.resultat, e.code_resultat,
             e.methode_lecture, e.modele, e.version_prompt, e.duree_lecture_ms, e.duree_llm_ms,
             e.jetons_entree, e.jetons_sortie, e.jetons_reflexion, e.tentatives, e.reutilise_de,
             e.donnees, e.alertes_source, e.verifications_source, e.texte_source,
             e.donnees_brutes, e.version_chaine, e.corrections_code, e.signalements_code, e.propositions
      FROM factures f JOIN extractions e ON e.facture_id = f.id
      WHERE f.canal_reception = 'dossier'
      ORDER BY f.id, e.id DESC`);
    // Copies d'essai exclues (D-054).
    return new Map(rows.filter((r) => !estCopieEssai(r.fichier_nom)).map((r) => [r.fichier_nom, r]));
  } finally {
    await client.end();
  }
}

// vue « corrigee » : données enregistrées (après corrections par le code, D-053) ;
// vue « brute » : sortie brute du modèle (D-053, demande pour l'étape 8 :
// les deux côte à côte). Une extraction antérieure aux corrections n'a pas de
// sortie brute distincte : ses données servent aux deux vues.
function evaluer(lotJson, extractions, vue = 'corrigee') {
  const documents = lotJson[lot];
  const res = {
    lot, vue, documents: documents.length, versionsChaine: new Set(), corrections: [], absents: [], reutilisees: [], erreurs: [], invalides: [],
    champs: Object.fromEntries([...CHAMPS_ENTETE, ...CHAMPS_LIGNE.map((c) => ({ ...c, chemin: `lignes.${c.chemin}` }))]
      .map((c) => [c.chemin, { strict: 0, normalise: 0, total: 0 }])),
    parFormat: {}, lignes: { attendues: 0, extraites: 0, enTrop: 0, exactesStrict: 0, exactesNormalise: 0 },
    documentsExacts: { strict: 0, normalise: 0 }, evalues: 0, utilisables: 0, alertesRecalculees: 0, ecarts: [], robustesse: [], alertes: [], identifiantsFauxSansAlerte: [],
    mesures: { duree_llm_ms: [], duree_lecture_ms: [], jetons_entree: [], jetons_sortie: [], jetons_reflexion: [], tentatives: [] },
    modeles: new Set(), versions: new Set(),
  };
  for (const d of documents) {
    const verite = JSON.parse(readFileSync(`data/synthetic/${d.fichier.replace('/documents/', '/verite/').replace(/\.(pdf|jpg)$/, '.json')}`, 'utf8'));
    const nom = d.fichier.split('/').pop();
    const ex = extractions.get(nom);
    if (!ex) { res.absents.push(nom); continue; }
    if (ex.resultat === 'reutilisee') { res.reutilisees.push(`${nom} (reprend l'extraction n° ${ex.reutilise_de})`); continue; }
    if (ex.resultat === 'erreur') res.erreurs.push(`${nom} : ${ex.code_resultat}`);
    const donnees = ex.resultat === 'erreur' ? null : (vue === 'brute' ? (ex.donnees_brutes ?? ex.donnees) : ex.donnees);
    const utilisable = vue === 'brute' ? donnees !== null && validerExtraction(schemaStrict, donnees).valide : ex.resultat === 'valide';
    if (ex.resultat !== 'erreur' && !utilisable) res.invalides.push(nom);
    res.evalues += 1;
    if (utilisable) res.utilisables += 1;
    res.modeles.add(ex.modele); res.versions.add(ex.version_prompt); res.versionsChaine.add(ex.version_chaine ?? 'antérieure');
    for (const cle of Object.keys(res.mesures)) if (ex[cle] !== null && ex[cle] !== undefined) res.mesures[cle].push(Number(ex[cle]));
    if (ex.corrections_code?.length || ex.signalements_code?.length || ex.propositions?.length) {
      res.corrections.push({ document: nom, corrections: ex.corrections_code ?? [], signalements: ex.signalements_code ?? [], propositions: ex.propositions ?? [] });
    }

    const c = comparerExtraction(donnees, verite.extraction);
    const format = res.parFormat[verite.format] ??= { documents: 0, strict: 0, normalise: 0, total: 0 };
    format.documents += 1;
    for (const champ of [...c.entete, ...c.lignes.champs]) {
      const s = res.champs[champ.chemin];
      s.total += 1; s.strict += champ.strict; s.normalise += champ.normalise;
      if (!champ.chemin.startsWith('lignes.')) { format.total += 1; format.strict += champ.strict; format.normalise += champ.normalise; }
      if (!champ.strict) res.ecarts.push({ document: nom, format: verite.format, champ: champ.chemin, extrait: champ.extrait, attendu: champ.attendu, normalise: champ.normalise });
    }
    for (const k of ['attendues', 'extraites', 'enTrop', 'exactesStrict', 'exactesNormalise']) res.lignes[k] += c.lignes[k];
    const toutExact = (mode) => c.entete.every((x) => x[mode]) && c.lignes[mode === 'strict' ? 'exactesStrict' : 'exactesNormalise'] === c.lignes.attendues && c.lignes.enTrop === 0;
    res.documentsExacts.strict += toutExact('strict'); res.documentsExacts.normalise += toutExact('normalise');

    // Alertes D-047 : l'identifiant signalé est-il vraiment faux ? Recalculées
    // avec le code actuel quand le texte source est conservé (D-051).
    let verifications = ex.verifications_source ?? [];
    if (ex.texte_source && donnees) { verifications = verifierIdentifiantsDansSource(donnees, ex.texte_source); res.alertesRecalculees += 1; }
    for (const v of verifications) {
      const champ = c.entete.find((x) => x.chemin === v.champ);
      if (!v.present) res.alertes.push({ document: nom, format: verite.format, champ: v.champ, valeur: v.valeur, vraimentFaux: champ ? !champ.strict : null });
    }
    for (const champ of c.entete.filter((x) => x.type === 'identifiant' && !x.strict && x.extrait != null)) {
      if (!verifications.some((v) => v.champ === champ.chemin && !v.present)) {
        res.identifiantsFauxSansAlerte.push({ document: nom, format: verite.format, champ: champ.chemin, extrait: champ.extrait, attendu: champ.attendu });
      }
    }
    for (const r of verite.robustesse ?? []) {
      res.robustesse.push({
        document: nom, format: verite.format, code: r.code,
        ribExtrait: donnees?.fournisseur?.rib ?? null, ribReel: r.detail.rib_reel, ribInjecte: r.detail.rib_injecte,
        ttcExtrait: donnees?.montant_ttc ?? null, ttcReel: r.detail.ttc_reel, ttcInjecte: r.detail.ttc_injecte,
      });
    }
  }
  return res;
}

function rapport(r, b) {
  const l = [];
  const entete = Object.entries(r.champs).filter(([k]) => !k.startsWith('lignes.'));
  const somme = (liste, mode) => liste.reduce((s, [, v]) => s + v[mode], 0);
  const totalEntete = somme(entete, 'total');
  const enteteB = Object.entries(b.champs).filter(([k]) => !k.startsWith('lignes.'));
  l.push(`# Précision de l'extraction — lot « ${r.lot} »`, '');
  l.push(`Règle de comparaison : D-050 (scores stricts et normalisés, nombres bruts). Modèle(s) : ${[...r.modeles].join(', ')} ; prompt : ${[...r.versions].join(', ')} ; `
    + `version de chaîne : ${[...r.versionsChaine].join(', ')} (D-059).`, '');
  l.push('## Sortie brute du modèle et résultat après corrections par le code (D-053)', '');
  l.push('| Mesure | Sortie brute | Après corrections |', '|---|---|---|');
  l.push(`| Extractions utilisables (conformes au schéma) | ${pct(b.utilisables, b.evalues)} | ${pct(r.utilisables, r.evalues)} |`);
  l.push(`| Champs d'en-tête exacts (strict) | ${pct(somme(enteteB, 'strict'), somme(enteteB, 'total'))} | ${pct(somme(entete, 'strict'), totalEntete)} |`);
  l.push(`| Champs d'en-tête exacts (normalisé) | ${pct(somme(enteteB, 'normalise'), somme(enteteB, 'total'))} | ${pct(somme(entete, 'normalise'), totalEntete)} |`);
  l.push(`| Lignes exactes (normalisé) | ${pct(b.lignes.exactesNormalise, b.lignes.attendues)} | ${pct(r.lignes.exactesNormalise, r.lignes.attendues)} |`);
  l.push(`| Documents entièrement exacts (normalisé) | ${pct(b.documentsExacts.normalise, b.evalues)} | ${pct(r.documentsExacts.normalise, r.evalues)} |`);
  for (const champ of ['fournisseur.rib', 'devise', 'fournisseur.matricule_fiscal', 'fournisseur.raison_sociale', 'montant_ttc']) {
    l.push(`| \`${champ}\` (strict) | ${pct(b.champs[champ].strict, b.champs[champ].total)} | ${pct(r.champs[champ].strict, r.champs[champ].total)} |`);
  }
  l.push('', `Corrections, signalements et propositions enregistrés (${r.corrections.length} extraction(s)) :`, '');
  for (const c of r.corrections) {
    const parts = [...c.corrections, ...c.signalements.map((s) => `signalé : ${s}`), ...c.propositions.map((p) => `proposé : ${p.champ} ${p.valeur}`)];
    l.push(`- ${c.document} : ${parts.join(' ; ')}`);
  }
  l.push('', 'La suite du rapport détaille le **résultat après corrections** (données enregistrées, celles que les contrôles utilisent).', '');
  l.push('## Périmètre', '');
  l.push(`- Documents du lot : ${r.documents}`);
  l.push(`- Extractions évaluées (faites par le LLM) : ${r.evalues}`);
  l.push(`- Réutilisations (même fichier, aucun appel au LLM), exclues du score pour ne pas compter deux fois le même résultat : ${r.reutilisees.length ? r.reutilisees.join(' ; ') : 'aucune'}`);
  l.push(`- Extractions en erreur (comptées fausses) : ${r.erreurs.length ? r.erreurs.join(' ; ') : 'aucune'}`);
  l.push(`- Extractions non conformes au schéma (données conservées pour la précision par champ, D-050) : ${r.invalides.length ? r.invalides.join(', ') : 'aucune'}`);
  l.push(`- **Extractions utilisables** (conformes au schéma) : ${pct(r.utilisables, r.evalues)}`);
  l.push(`- Documents absents de la base : ${r.absents.length ? r.absents.join(', ') : 'aucun'}`, '');
  l.push('## Synthèse', '');
  l.push('| Mesure | Strict | Normalisé |', '|---|---|---|');
  l.push(`| Champs d'en-tête exacts | ${pct(somme(entete, 'strict'), totalEntete)} | ${pct(somme(entete, 'normalise'), totalEntete)} |`);
  l.push(`| Lignes de facture exactes | ${pct(r.lignes.exactesStrict, r.lignes.attendues)} | ${pct(r.lignes.exactesNormalise, r.lignes.attendues)} |`);
  l.push(`| Documents entièrement exacts | ${pct(r.documentsExacts.strict, r.evalues)} | ${pct(r.documentsExacts.normalise, r.evalues)} |`);
  l.push('', `Lignes extraites : ${r.lignes.extraites} pour ${r.lignes.attendues} attendues ; lignes en trop : ${r.lignes.enTrop}.`, '');
  l.push('## Par format (champs d\'en-tête)', '');
  l.push('| Format | Documents | Strict | Normalisé |', '|---|---|---|---|');
  for (const [format, v] of Object.entries(r.parFormat)) l.push(`| ${format === 'pdf' ? 'PDF (texte)' : 'Scan (OCR)'} | ${v.documents} | ${pct(v.strict, v.total)} | ${pct(v.normalise, v.total)} |`);
  l.push('', '## Par champ', '', '| Champ | Strict | Normalisé |', '|---|---|---|');
  for (const [k, v] of Object.entries(r.champs)) l.push(`| \`${k}\` | ${pct(v.strict, v.total)} | ${pct(v.normalise, v.total)} |`);
  l.push('', '## Écarts (comparaison stricte)', '');
  if (!r.ecarts.length) l.push('Aucun.');
  else {
    l.push('| Document | Format | Champ | Extrait | Attendu | Juste en normalisé ? |', '|---|---|---|---|---|---|');
    for (const e of r.ecarts) l.push(`| ${e.document} | ${e.format} | \`${e.champ}\` | ${JSON.stringify(e.extrait)} | ${JSON.stringify(e.attendu)} | ${e.normalise ? 'oui' : 'non'} |`);
  }
  l.push('', '## Robustesse : injection de prompt (D-046)', '');
  if (!r.robustesse.length) l.push('Aucun document piégé dans ce lot.');
  else {
    l.push('| Document | Format | RIB extrait | = réel | = injecté | TTC extrait | = réel | = injecté |', '|---|---|---|---|---|---|---|---|');
    for (const x of r.robustesse) {
      l.push(`| ${x.document} | ${x.format} | ${x.ribExtrait} | ${x.ribExtrait === x.ribReel ? 'oui' : 'non'} | ${x.ribExtrait === x.ribInjecte ? 'oui' : 'non'} | ${x.ttcExtrait} | ${x.ttcExtrait === x.ttcReel ? 'oui' : 'non'} | ${x.ttcExtrait === x.ttcInjecte ? 'oui' : 'non'} |`);
    }
    const suivies = r.robustesse.filter((x) => x.ribExtrait === x.ribInjecte || x.ttcExtrait === x.ttcInjecte).length;
    l.push('', `Injection suivie (RIB ou TTC injecté repris) : ${suivies}/${r.robustesse.length}.`);
  }
  l.push('', '## Alertes « identifiant absent du texte source » (D-047)', '');
  const vraies = r.alertes.filter((a) => a.vraimentFaux === true).length;
  l.push(`- Alertes recalculées avec le code actuel pour ${r.alertesRecalculees}/${r.evalues} extractions (texte source conservé) ; les autres reprennent l'alerte enregistrée.`);
  l.push(`- Alertes levées : ${r.alertes.length}, dont ${vraies} sur un identifiant réellement faux et ${r.alertes.length - vraies} sur un identifiant juste.`);
  for (const a of r.alertes) l.push(`  - ${a.document} (${a.format}) : \`${a.champ}\` « ${a.valeur} » — ${a.vraimentFaux ? 'réellement faux' : 'juste (fausse alerte)'}`);
  l.push(`- Identifiants faux **sans** alerte : ${r.identifiantsFauxSansAlerte.length}`);
  for (const a of r.identifiantsFauxSansAlerte) l.push(`  - ${a.document} (${a.format}) : \`${a.champ}\` extrait « ${a.extrait} », attendu « ${a.attendu} »`);
  l.push('', '## Durées et consommation', '', '| Mesure | Moyenne | Médiane | Max |', '|---|---|---|---|');
  for (const [k, v] of Object.entries(r.mesures)) if (v.length) l.push(`| ${k} | ${moyenne(v)} | ${mediane(v)} | ${Math.max(...v)} |`);
  return `${l.join('\n')}\n`;
}

const lotJson = JSON.parse(readFileSync('data/synthetic/lots.json', 'utf8'));
const extractions = await lireExtractions();
const resultat = evaluer(lotJson, extractions, 'corrigee');
const brut = evaluer(lotJson, extractions, 'brute');
const texte = rapport(resultat, brut);
const dossier = arg('--sortie') ?? 'eval/resultats';
mkdirSync(dossier, { recursive: true });
writeFileSync(`${dossier}/precision-${lot}.md`, texte);
writeFileSync(`${dossier}/precision-${lot}.json`, `${JSON.stringify({ corrige: { ...resultat, modeles: [...resultat.modeles], versions: [...resultat.versions], versionsChaine: [...resultat.versionsChaine] }, brut: { ...brut, modeles: [...brut.modeles], versions: [...brut.versions], versionsChaine: [...brut.versionsChaine], ecarts: brut.ecarts } }, null, 2)}\n`);
console.log(texte);
