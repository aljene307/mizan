// Analyse de la mesure D-052 : sépare l'effet du prompt, celui du schéma et
// celui de chaque correction par le code, puis mesure la stabilité.
// Usage : node eval/analyser-mesure.js   (après eval/mesurer.js)
// Écrit eval/resultats/mesure-2026-10-06/rapport.md.
import { readFileSync, writeFileSync } from 'node:fs';
import { comparerExtraction, CHAMPS_ENTETE } from '../src/comparaison.js';
import { validerExtraction } from '../src/validationExtraction.js';
import { ribValide } from '../src/rib.js';
import { formeCourteMatricule } from '../src/matricule.js';
import { nettoyerIdentifiants, convertirDevise, decoderEntites, recupererRib } from '../src/correctionsCode.js';
import { CONFIGURATIONS, DOCUMENTS_STABILITE, DOSSIER_MESURE, FICHIER_APPELS } from './mesure-commun.js';

const pct = (k, n) => (n === 0 ? '—' : `${k}/${n} (${(100 * k / n).toFixed(1).replace('.', ',')} %)`);
const appels = readFileSync(FICHIER_APPELS, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l));
const schemaStrict = JSON.parse(readFileSync('src/schemas/extraction-facture.schema.json', 'utf8'));
const referentiel = JSON.parse(readFileSync('data/synthetic/referentiel/fournisseurs.json', 'utf8'));
const verite = (doc) => JSON.parse(readFileSync(`data/synthetic/dev/verite/${doc}.json`, 'utf8'));

// Texte source de chaque document : celui que le workflow a transmis au LLM.
// Il est relu depuis la base par mesurer.js ; ici on le reconstitue depuis le
// même enregistrement pour la récupération du RIB.
const textes = JSON.parse(readFileSync(`${DOSSIER_MESURE}/textes.json`, 'utf8'));

const ribReferentiel = (donnees) => {
  const court = formeCourteMatricule(donnees?.fournisseur?.matricule_fiscal ?? '');
  return referentiel.find((f) => f.matricule_fiscal === court)?.rib ?? null;
};

// Couches de traitement par le code (D-052). « nettoyage » (séparateurs des
// identifiants) est la base commune : sans lui, le prompt v2 serait pénalisé
// pour avoir recopié les espaces qu'on lui demande de recopier.
const COUCHES = [
  ['base (nettoyage des identifiants)', []],
  ['+ devise (alias)', ['devise']],
  ['+ entités HTML', ['entites']],
  ['+ RIB retrouvé (règle D-052)', ['rib']],
  ['+ toutes les corrections', ['devise', 'entites', 'rib']],
];

function traiter(appel, couches) {
  let d = nettoyerIdentifiants(appel.donnees).donnees;
  const traces = { signalements: [], propositions: [], ribRemplis: 0 };
  if (couches.includes('devise')) d = convertirDevise(d).donnees;
  if (couches.includes('entites')) { const r = decoderEntites(d); d = r.donnees; traces.signalements.push(...r.signalements); }
  if (couches.includes('rib') && d) {
    const r = recupererRib(d, textes[appel.document], ribReferentiel(d), ribValide);
    d = r.donnees;
    if (r.corrections.length) traces.ribRemplis += 1;
    if (r.proposition) traces.propositions.push({ document: appel.document, ...r.proposition });
  }
  return { donnees: d, traces };
}

function scorer(liste, couches) {
  const s = { appels: liste.length, utilisables: 0, enteteStrict: 0, enteteNormalise: 0, enteteTotal: 0, lignesExactes: 0, lignesTotal: 0,
    ribJustes: 0, devisesJustes: 0, raisonsJustesNormalise: 0, signalements: 0, propositions: [], ribRemplis: 0, erreurs: 0 };
  for (const a of liste) {
    if (a.code !== 'ok') s.erreurs += 1;
    const { donnees, traces } = traiter(a, couches);
    const v = verite(a.document).extraction;
    if (donnees && validerExtraction(schemaStrict, donnees).valide) s.utilisables += 1;
    const c = comparerExtraction(a.code === 'ok' ? donnees : null, v);
    for (const champ of c.entete) { s.enteteTotal += 1; s.enteteStrict += champ.strict; s.enteteNormalise += champ.normalise; }
    s.lignesExactes += c.lignes.exactesNormalise; s.lignesTotal += c.lignes.attendues;
    const champ = (chemin) => c.entete.find((x) => x.chemin === chemin);
    s.ribJustes += champ('fournisseur.rib').strict;
    s.devisesJustes += champ('devise').strict;
    s.raisonsJustesNormalise += champ('fournisseur.raison_sociale').normalise && champ('client.raison_sociale').normalise;
    s.signalements += traces.signalements.length > 0;
    s.ribRemplis += traces.ribRemplis;
    for (const p of traces.propositions) s.propositions.push({ ...p, juste: p.valeur === v.fournisseur.rib });
  }
  return s;
}

const l = [];
l.push('# Mesure du prompt et des corrections par le code (D-052)', '');
l.push('Lot de développement uniquement. Règle de comparaison D-050 (nombres bruts). Même modèle et mêmes paramètres pour toutes les configurations (`gemini-3.5-flash-lite`, température 1.0, réflexion `low`).', '');

const premiers = appels.filter((a) => a.passage === 1);
const documents = [...new Set(premiers.map((a) => a.document))].sort();
l.push(`Textes mesurés : ${documents.length} (textes conservés du lot dev, D-051). Appels enregistrés : ${appels.length}.`, '');

l.push('## 1. Effet du prompt et du schéma (sortie brute, base commune de nettoyage)', '');
l.push('| Configuration | Appels en erreur | Extractions utilisables | En-tête strict | En-tête normalisé | Lignes exactes | RIB justes | Devise juste |', '|---|---|---|---|---|---|---|---|');
const scoresBase = {};
for (const cfg of CONFIGURATIONS) {
  const liste = premiers.filter((a) => a.configuration === cfg.id);
  if (!liste.length) continue;
  const s = scorer(liste, []);
  scoresBase[cfg.id] = s;
  l.push(`| ${cfg.id} | ${s.erreurs} | ${pct(s.utilisables, s.appels)} | ${pct(s.enteteStrict, s.enteteTotal)} | ${pct(s.enteteNormalise, s.enteteTotal)} | ${pct(s.lignesExactes, s.lignesTotal)} | ${pct(s.ribJustes, s.appels)} | ${pct(s.devisesJustes, s.appels)} |`);
}

l.push('', '## 2. Effet de chaque correction par le code (mêmes sorties, aucun appel)', '');
for (const cfg of CONFIGURATIONS) {
  const liste = premiers.filter((a) => a.configuration === cfg.id);
  if (!liste.length) continue;
  l.push(`### ${cfg.id}`, '', '| Traitement | Utilisables | En-tête normalisé | RIB justes | Devise juste | Extractions signalées (entités) | RIB remplis (= référentiel) | RIB proposés (justes / total) |', '|---|---|---|---|---|---|---|---|');
  for (const [nom, couches] of COUCHES) {
    const s = scorer(liste, couches);
    const justes = s.propositions.filter((p) => p.juste).length;
    l.push(`| ${nom} | ${pct(s.utilisables, s.appels)} | ${pct(s.enteteNormalise, s.enteteTotal)} | ${pct(s.ribJustes, s.appels)} | ${pct(s.devisesJustes, s.appels)} | ${s.signalements} | ${s.ribRemplis} | ${justes} / ${s.propositions.length} |`);
  }
  l.push('');
}

l.push('## 3. Stabilité (3 passages identiques, 10 documents)', '');
const champsStabilite = CHAMPS_ENTETE.map((c) => c.chemin);
const lire = (o, chemin) => chemin.split('.').reduce((x, k) => x?.[k], o);
for (const [libelle, couches] of [['sortie brute (nettoyage)', []], ['après toutes les corrections par le code', ['devise', 'entites', 'rib']]]) for (const cfg of CONFIGURATIONS) {
  const parDoc = DOCUMENTS_STABILITE.map((doc) => appels.filter((a) => a.configuration === cfg.id && a.document === doc).sort((a, b) => a.passage - b.passage));
  if (!parDoc.every((p) => p.length >= 3)) continue;
  let stables = 0; let total = 0; const instables = {};
  for (const passages of parDoc) {
    const donnees = passages.slice(0, 3).map((a) => traiter(a, couches).donnees);
    for (const chemin of champsStabilite) {
      total += 1;
      const valeurs = donnees.map((d) => JSON.stringify(lire(d, chemin) ?? null));
      if (new Set(valeurs).size === 1) stables += 1; else instables[chemin] = (instables[chemin] ?? 0) + 1;
    }
    total += 1;
    if (new Set(donnees.map((d) => JSON.stringify(d?.lignes ?? null))).size === 1) stables += 1; else instables.lignes = (instables.lignes ?? 0) + 1;
  }
  l.push(`- **${cfg.id}**, ${libelle} : champs identiques sur les 3 passages ${pct(stables, total)}${Object.keys(instables).length ? ` ; champs variables : ${Object.entries(instables).map(([k, v]) => `\`${k}\` (${v} doc.)`).join(', ')}` : ''}.`);
  for (const [i, passages] of parDoc.entries()) {
    const ribs = passages.slice(0, 3).map((a) => traiter(a, couches).donnees?.fournisseur?.rib ?? null);
    if (new Set(ribs).size > 1) l.push(`  - ${DOCUMENTS_STABILITE[i]} : RIB selon le passage ${ribs.map((r) => r ?? 'null').join(' / ')}`);
  }
}

l.push('', '## 4. Robustesse : injection de prompt (D001, scan)', '');
for (const a of appels.filter((x) => x.document === 'D001').sort((x, y) => x.configuration.localeCompare(y.configuration) || x.passage - y.passage)) {
  const r = verite('D001').robustesse[0].detail;
  const rib = nettoyerIdentifiants(a.donnees).donnees?.fournisseur?.rib;
  l.push(`- ${a.configuration} passage ${a.passage} : RIB ${rib === r.rib_reel ? 'réel' : rib === r.rib_injecte ? '**INJECTÉ**' : `autre (${rib})`}, TTC ${a.donnees?.montant_ttc === r.ttc_reel ? 'réel' : a.donnees?.montant_ttc === r.ttc_injecte ? '**INJECTÉ**' : a.donnees?.montant_ttc}`);
}

l.push('', '## 5. Consommation', '');
const jetons = (cle) => Math.round(appels.reduce((s, a) => s + (a[cle] ?? 0), 0) / appels.length);
l.push(`Moyenne par appel : ${jetons('jetons_entree')} jetons en entrée, ${jetons('jetons_sortie')} en sortie, ${jetons('jetons_reflexion')} de réflexion ; durée médiane ${[...appels.map((a) => a.duree_ms)].sort((a, b) => a - b)[Math.floor(appels.length / 2)]} ms ; tentatives > 1 : ${appels.filter((a) => a.tentatives > 1).length}.`);

const texte = `${l.join('\n')}\n`;
writeFileSync(`${DOSSIER_MESURE}/rapport.md`, texte);
console.log(texte);
