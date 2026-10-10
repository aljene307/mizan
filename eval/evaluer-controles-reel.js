// Mesure des contrôles sur l'EXTRACTION RÉELLE du lot de développement
// (D-055, précision 2) : résultats enregistrés par le workflow « Contrôles »
// (dernier passage de chaque facture), comparés aux pièges attendus.
// Pour chaque alerte sur une facture sans piège et chaque piège manqué, le
// rapport donne les éléments de cause : la même règle appliquée aux valeurs
// imprimées (vérité terrain) et les écarts entre l'extraction et la vérité.
// Usage : npm run evaluer-controles-reel                                 lot de développement
//         npm run evaluer-controles-reel -- --lot test --etape-8         lot de test (étape 8 seulement, D-082)
// Option : --sortie <dossier> (défaut eval/resultats ; la répétition générale écrit ailleurs).
// Lecture seule (mizan_app). Copies d'essai exclues (D-054). Mêmes règles de
// comptage pour les deux lots (D-082). Écrit controles-reel-<lot>.md et .json.
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import pg from 'pg';
import { controlerFacture } from '../src/controles/regles.js';
import { comparerExtraction } from '../src/comparaison.js';
import { deps, alerte, lireConfiguration, lireVerites, contexte, ATTENDU, REGLES_DOUBLON } from './controles-commun.js';
import { estCopieEssai } from './mesure-commun.js';

const arg = (nom) => { const i = process.argv.indexOf(nom); return i > -1 ? process.argv[i + 1] : undefined; };
const lot = arg('--lot') ?? 'dev';
if (!['dev', 'test'].includes(lot)) throw new Error('--lot dev ou --lot test');
if (lot === 'test' && !process.argv.includes('--etape-8')) {
  console.error('Le lot de test est réservé à l\'évaluation de l\'étape 8 (D-026) : ajouter --etape-8 pour l\'utiliser.');
  process.exit(1);
}
const dossier = arg('--sortie') ?? 'eval/resultats';
const verites = lireVerites(lot);

async function lireBase() {
  if (existsSync('.env')) process.loadEnvFile('.env');
  const client = new pg.Client({
    host: 'localhost', port: 5432, user: 'mizan_app', password: process.env.MIZAN_APP_PASSWORD, database: process.env.MIZAN_DB ?? 'mizan',
  });
  await client.connect();
  try {
    const { rows } = await client.query(`
      SELECT f.id, f.fichier_nom, f.statut, f.fournisseur_id,
             (SELECT jsonb_build_object('donnees', s.donnees, 'methode_lecture', s.methode_lecture, 'version_chaine', e.version_chaine)
              FROM extractions e JOIN extractions s ON s.id = coalesce(e.reutilise_de, e.id)
              WHERE e.facture_id = f.id AND e.resultat IN ('valide', 'reutilisee') ORDER BY e.id DESC LIMIT 1) AS extraction,
             (SELECT jsonb_agg(jsonb_build_object('regle', r.regle, 'resultat', r.resultat, 'gravite', r.gravite, 'message', r.message) ORDER BY r.regle)
              FROM resultats_controles r
              WHERE r.passage = (SELECT max(passage) FROM resultats_controles x WHERE x.facture_id = f.id)) AS resultats
      FROM factures f WHERE f.canal_reception = 'dossier' ORDER BY f.id`);
    return new Map(rows.filter((r) => !estCopieEssai(r.fichier_nom)).map((r) => [r.fichier_nom.replace(/\.\w+$/, ''), r]));
  } finally {
    await client.end();
  }
}

const conf = await lireConfiguration();
const base = await lireBase();
const documents = verites.map((v) => {
  const b = base.get(v.id);
  const imprime = controlerFacture(contexte(v, conf, verites), deps).resultats.filter(alerte).map((x) => x.regle);
  const comparaison = b?.extraction ? comparerExtraction(b.extraction.donnees, v.extraction) : null;
  const ecarts = comparaison ? [
    ...comparaison.entete.filter((c) => !c.normalise).map((c) => `${c.chemin} : lu ${JSON.stringify(c.extrait)}, imprimé ${JSON.stringify(c.attendu)}`),
    ...comparaison.lignes.champs.filter((c) => !c.normalise).map((c) => `${c.chemin} : lu ${JSON.stringify(c.extrait)}, imprimé ${JSON.stringify(c.attendu)}`),
  ] : [];
  return {
    id: v.id, format: v.format, pieges: v.anomalies_attendues.map((a) => a.code), robustesse: v.robustesse.map((r) => r.code),
    derive_de: v.derive_de ?? null, doublon_de: verites.find((o) => o.derive_de === v.id)?.id ?? null,
    controlee: Boolean(b?.resultats), statut: b?.statut ?? 'absente', methode: b?.extraction?.methode_lecture ?? null,
    version: b?.extraction?.version_chaine ?? null,
    alertes: (b?.resultats ?? []).filter(alerte), infos: (b?.resultats ?? []).filter((r) => r.resultat === 'anomalie' && r.gravite === 'info'),
    alertesSurImprime: imprime, ecartsExtraction: ecarts,
  };
});
const parId = new Map(documents.map((d) => [d.id, d]));
const enAlerte = (d, regle) => d.alertes.some((a) => a.regle === regle);

// Pièges : même décompte que sur la vérité terrain (paire de doublons = une unité).
const pieges = {};
for (const [code, attendu] of Object.entries(ATTENDU)) {
  const p = { attendus: 0, prevue: 0, autre: 0, manques: [] };
  for (const d of documents.filter((x) => x.pieges.includes(code))) {
    p.attendus += 1;
    const membres = d.derive_de ? [d, parId.get(d.derive_de)] : [d];
    const marques = membres.filter((m) => enAlerte(m, attendu.regle));
    if (d.derive_de ? marques.length === 1 : marques.length > 0) p.prevue += 1;
    else if (d.alertes.length) { p.autre += 1; p.manques.push(d); }
    else p.manques.push(d);
  }
  pieges[code] = p;
}

// Factures sans piège. Les factures piégées par une injection (D-046) portent
// un signalement « plusieurs RIB » VOULU (D-053, D-057) : compté à part.
const ALERTES_VOULUES_INJECTION = new Set(['plusieurs_rib']);
const normales = documents.filter((d) => !d.pieges.length);
const analyse = normales.map((d) => {
  const alertes = d.alertes.filter((a) => !(d.doublon_de && REGLES_DOUBLON.has(a.regle)));
  const voulues = d.robustesse.length ? alertes.filter((a) => ALERTES_VOULUES_INJECTION.has(a.regle)) : [];
  return { d, voulues, fausses: alertes.filter((a) => !voulues.includes(a)) };
});
const avecFausses = analyse.filter((x) => x.fausses.length);
const avecVoulues = analyse.filter((x) => x.voulues.length);

// Statut attendu : comme sur la vérité terrain ; injection → « anomalie » (signalement voulu).
const statutAttendu = (d) => {
  if (d.derive_de || d.doublon_de) return Number(d.id.slice(1)) > Number((d.derive_de ?? d.doublon_de).slice(1)) ? 'bloquee' : 'conforme';
  if (!d.pieges.length) return d.robustesse.length ? 'anomalie' : 'conforme';
  const ordre = ['bloquee', 'anomalie', 'a_valider'];
  return d.pieges.map((c) => ATTENDU[c].statut).sort((a, b) => ordre.indexOf(a) - ordre.indexOf(b))[0];
};
for (const d of documents) d.statut_attendu = statutAttendu(d);

const cause = (d, regles) => {
  const memeSurImprime = regles.filter((r) => d.alertesSurImprime.includes(r));
  const lignes = [];
  lignes.push(memeSurImprime.length
    ? `la même règle alerte aussi sur les valeurs imprimées (${memeSurImprime.join(', ')}) : cause dans la logique ou le document`
    : 'sur les valeurs imprimées, aucune alerte : **la cause est dans l\'extraction**');
  lignes.push(d.ecartsExtraction.length ? `écarts de lecture (${d.methode}) : ${d.ecartsExtraction.join(' ; ')}` : `aucun écart de lecture sur les champs comparés (${d.methode})`);
  return lignes;
};

// --- Rapport ----------------------------------------------------------------------------------
const l = [];
l.push(`# Contrôles : mesure sur l'extraction réelle (lot de ${lot === 'dev' ? 'développement' : 'test'})`, '');
l.push(`Résultats enregistrés par le workflow « Contrôles » (dernier passage de chaque facture), extraction en version de chaîne `
  + `${[...new Set(documents.map((d) => d.version ?? 'antérieure'))].join(', ')} (D-059). Copies d'essai exclues (D-054). Nombres bruts.`, '');
l.push(`Factures du lot : ${documents.length} ; contrôlées : ${documents.filter((d) => d.controlee).length}.`, '');

l.push('## 1. Pièges détectés, par type', '');
l.push('| Piège | Règle prévue | Attendus | Détectés par la règle prévue | Par une autre règle seulement | Non détectés |', '|---|---|---|---|---|---|');
for (const [code, p] of Object.entries(pieges)) l.push(`| ${code} | ${ATTENDU[code].regle} | ${p.attendus} | ${p.prevue} | ${p.autre} | ${p.attendus - p.prevue - p.autre} |`);
const tot = (k) => Object.values(pieges).reduce((s, p) => s + p[k], 0);
l.push(`| **Total** | | **${tot('attendus')}** | **${tot('prevue')}** | ${tot('autre')} | ${tot('attendus') - tot('prevue') - tot('autre')} |`, '');
const manques = Object.entries(pieges).flatMap(([code, p]) => p.manques.map((d) => ({ code, d })));
if (manques.length) {
  l.push('Pièges manqués et causes :', '');
  for (const { code, d } of manques) l.push(`- ${d.id} (${code}) : ${cause(d, [ATTENDU[code].regle]).join(' ; ')}`);
  l.push('');
}

l.push('## 2. Alertes sur les factures sans piège', '');
l.push(`Factures sans piège : ${normales.length}, dont ${normales.filter((d) => d.robustesse.length).length} piégées par une injection (D-046).`, '');
l.push('| | Factures |', '|---|---|');
l.push(`| Avec au moins une **fausse alerte** | **${avecFausses.length}** |`);
l.push(`| Avec le signalement voulu « plusieurs RIB » (injection), sans autre alerte | ${avecVoulues.filter((x) => !x.fausses.length).length} |`);
l.push(`| Sans alerte | ${analyse.filter((x) => !x.fausses.length && !x.voulues.length).length} |`, '');
const parRegle = {};
for (const x of avecFausses) for (const a of x.fausses) parRegle[a.regle] = (parRegle[a.regle] ?? 0) + 1;
if (avecFausses.length) {
  l.push('| Règle | Factures avec une fausse alerte |', '|---|---|');
  for (const [r, n] of Object.entries(parRegle).sort()) l.push(`| ${r} | ${n} |`);
  l.push('', 'Fausses alertes et causes :', '');
  for (const x of avecFausses) {
    l.push(`- **${x.d.id}** (${x.d.format}) — ${x.fausses.map((a) => `${a.regle} (${a.gravite}) : ${a.message}`).join(' ; ')}`);
    for (const c of cause(x.d, x.fausses.map((a) => a.regle))) l.push(`  - ${c}`);
  }
  l.push('');
}
if (avecVoulues.length) {
  l.push('Signalements voulus (injection) :', '');
  for (const x of avecVoulues) l.push(`- ${x.d.id} (${x.d.format}) : ${x.voulues.map((a) => a.message).join(' ; ')}`);
  l.push('');
}

l.push('## 3. Statut final', '');
const concordants = documents.filter((d) => d.statut === d.statut_attendu);
l.push(`Statut obtenu = statut attendu : **${concordants.length} / ${documents.length}**. `
  + 'Statut attendu : celui de la vérité terrain ; « anomalie » pour une facture piégée par une injection (signalement voulu).', '');
const repartition = {};
for (const d of documents) repartition[d.statut] = (repartition[d.statut] ?? 0) + 1;
l.push(`Répartition : ${Object.entries(repartition).sort().map(([s, n]) => `${s} ${n}`).join(', ')}.`, '');
const discordants = documents.filter((d) => d.statut !== d.statut_attendu);
if (discordants.length) {
  l.push('| Document | Attendu | Obtenu | Alertes |', '|---|---|---|---|');
  for (const d of discordants) l.push(`| ${d.id} | ${d.statut_attendu} | ${d.statut} | ${d.alertes.map((a) => a.regle).join(', ') || '—'} |`);
  l.push('');
}

l.push('## 4. Factures piégées et doublons : détail', '');
l.push('| Document | Piège | Statut | Alertes (règle : gravité) |', '|---|---|---|---|');
for (const d of documents.filter((x) => x.pieges.length || x.doublon_de)) {
  l.push(`| ${d.id} | ${d.pieges.join(', ') || `original de ${d.doublon_de}`} | ${d.statut} | ${d.alertes.map((a) => `${a.regle} : ${a.gravite}`).join(' ; ') || '—'} |`);
}
l.push('', '## 5. Résultats « info » (non comptés comme alertes)', '');
// D-085 : rendre visible le changement de règle fait après la répétition générale.
const entitesInfo = documents.filter((d) => d.infos.some((i) => i.regle === 'signalements_extraction'));
l.push(`Signalements d'entités HTML classés « info » par la règle \`signalements_extraction\` v2 (D-085, changée après la répétition `
  + `générale) : **${entitesInfo.length}** facture(s)${entitesInfo.length ? ` (${entitesInfo.map((d) => d.id).join(', ')})` : ''}. `
  + 'Avec la version 1, chacune aurait été un avertissement.', '');
const infos = documents.flatMap((d) => d.infos.map((i) => `${d.id} : ${i.regle} — ${i.message}`));
l.push(infos.length ? infos.map((x) => `- ${x}`).join('\n') : 'Aucun.', '');
if (lot === 'dev') {
  l.push('', 'Note (D-060) : les passages du 2026-10-06 ont été faits avant le correctif du contexte (historique du fournisseur). '
    + 'Rejouées sur le contexte corrigé, les règles ne changent aucune alerte ni aucun statut ; seule D005 reçoit un résultat « info » '
    + '(`matricule_suffixe` : « /A/M/000 » différent des factures précédentes, lues « /A/M/008 » par l\'OCR sur D001 et D004).');
}

mkdirSync(dossier, { recursive: true });
const texte = `${l.join('\n')}\n`;
writeFileSync(`${dossier}/controles-reel-${lot}.md`, texte);
writeFileSync(`${dossier}/controles-reel-${lot}.json`, `${JSON.stringify({ pieges: Object.fromEntries(Object.entries(pieges).map(([k, p]) => [k, { ...p, manques: p.manques.map((d) => d.id) }])), documents }, null, 2)}\n`);
console.log(texte);
