// Test par mutation des contrôles (demande de Mohamed, 2026-10-06), sans LLM :
// sur chacune des factures SANS PIÈGE du lot de développement (vérité
// terrain), introduit par programme chaque type d'erreur et vérifie que la
// règle prévue la détecte ; aux limites des tolérances, vérifie qu'un écart
// égal à la tolérance est accepté (aucune alerte nouvelle) et qu'un millime
// de plus est détecté.
// Usage : npm run test:mutations   (PostgreSQL doit tourner : configuration lue en base)
// Écrit eval/resultats/controles-mutations-dev.md et .json ; code de sortie 1
// si une mutation n'a pas le résultat attendu.
import { mkdirSync, writeFileSync } from 'node:fs';
import { controlerFacture } from '../src/controles/regles.js';
import { cleRib } from '../src/rib.js';
import { deps, alerte, lireConfiguration, verites, contexte, referentiel, DATE_REFERENCE } from './controles-commun.js';

const conf = await lireConfiguration();
const p = conf.parametres;
const plus = (montant, millimes) => (deps.enMillimes(montant) + millimes) / 1000;
const jourSuivant = (date, n) => new Date(Date.parse(`${date}T00:00:00Z`) + n * 86400000).toISOString().slice(0, 10);
const unite = (ctx) => (ctx.facture.devise === 'TND' ? 1 : 10);
const toleranceTva = (ctx) => ctx.lignes.length * Number(p['tolerance.tva_millimes_par_ligne']) * unite(ctx);
const toleranceLigne = (ctx) => Number(p['tolerance.ligne_millimes']) * unite(ctx);
const toleranceTtc = () => Number(p['tolerance.ttc_millimes']);

// TVA modifiée, TTC ajusté : seule la TVA est fausse (comme le piège erreur_tva).
const tva = (k) => (ctx) => { ctx.facture.montant_tva = plus(ctx.facture.montant_tva, k(ctx)); ctx.facture.montant_ttc = plus(ctx.facture.montant_ttc, k(ctx)); };
// Montant de la première ligne modifié, HT et TTC ajustés : seul « quantité × prix » est faux.
const ligne = (k) => (ctx) => {
  const d = k(ctx);
  ctx.lignes[0].montant_ht = plus(ctx.lignes[0].montant_ht, d);
  ctx.facture.montant_ht = plus(ctx.facture.montant_ht, d);
  ctx.facture.montant_ttc = plus(ctx.facture.montant_ttc, d);
};
// Matricule : forme courte modifiée, suffixe conservé.
const matricule = (modifier) => (ctx) => {
  const [court, ...suffixe] = ctx.facture.matricule_fiscal_lu.split('/');
  ctx.facture.matricule_fiscal_lu = [modifier(court), ...suffixe].join('/');
};

const MUTATIONS = [
  { type: 'TVA', cas: 'écart égal à la tolérance (1 millime par ligne)', attendu: 'accepte', regle: 'coherence_tva', appliquer: tva(toleranceTva) },
  { type: 'TVA', cas: 'tolérance + 1 millime', attendu: 'detecte', regle: 'coherence_tva', appliquer: tva((c) => toleranceTva(c) + 1) },
  { type: 'TVA', cas: 'TVA + 1,000 TND', attendu: 'detecte', regle: 'coherence_tva', appliquer: tva(() => 1000) },
  { type: 'TTC', cas: `écart égal à la tolérance (${toleranceTtc()} millime)`, attendu: 'accepte', regle: 'coherence_ttc',
    appliquer: (c) => { c.facture.montant_ttc = plus(c.facture.montant_ttc, toleranceTtc()); } },
  { type: 'TTC', cas: 'tolérance + 1 millime', attendu: 'detecte', regle: 'coherence_ttc',
    appliquer: (c) => { c.facture.montant_ttc = plus(c.facture.montant_ttc, toleranceTtc() + 1); } },
  { type: 'TTC', cas: 'TTC − 1,000 TND', attendu: 'detecte', regle: 'coherence_ttc',
    appliquer: (c) => { c.facture.montant_ttc = plus(c.facture.montant_ttc, -1000); } },
  { type: 'Ligne', cas: 'écart égal à la tolérance (1 millime), HT et TTC ajustés', attendu: 'accepte', regle: 'coherence_lignes', appliquer: ligne(toleranceLigne) },
  { type: 'Ligne', cas: 'tolérance + 1 millime, HT et TTC ajustés', attendu: 'detecte', regle: 'coherence_lignes', appliquer: ligne((c) => toleranceLigne(c) + 1) },
  { type: 'Ligne', cas: 'montant de ligne + 1,000 TND, HT non ajusté', attendu: 'detecte', regle: 'coherence_lignes',
    appliquer: (c) => { c.lignes[0].montant_ht = plus(c.lignes[0].montant_ht, 1000); } },
  { type: 'RIB', cas: 'autre RIB valide, inconnu du référentiel', attendu: 'detecte', regle: 'changement_rib',
    appliquer: (c) => { const base = `99${String(c.facture.id).padStart(16, '7')}`; c.facture.rib_facture = base + cleRib(base); } },
  { type: 'RIB', cas: 'RIB valide d\'un autre fournisseur du référentiel', attendu: 'detecte', regle: 'changement_rib',
    appliquer: (c) => { c.facture.rib_facture = referentiel.find((f) => f.ribs[0].rib !== c.facture.rib_facture).ribs[0].rib; } },
  { type: 'Matricule', cas: 'un chiffre supprimé', attendu: 'detecte', regle: 'matricule_format',
    appliquer: matricule((m) => m.slice(0, 3) + m.slice(4)) },
  { type: 'Matricule', cas: 'lettre clé supprimée', attendu: 'detecte', regle: 'matricule_format',
    appliquer: matricule((m) => m.slice(0, 7)) },
  { type: 'Matricule', cas: 'un chiffre remplacé (format valide, matricule inconnu)', attendu: 'detecte', regle: 'fournisseur_inconnu',
    appliquer: matricule((m) => m.slice(0, 3) + String((Number(m[3]) + 1) % 10) + m.slice(4)) },
  { type: 'Date', cas: 'échéance la veille de la date de facture', attendu: 'detecte', regle: 'dates',
    appliquer: (c) => { c.facture.date_echeance = jourSuivant(c.facture.date_facture, -1); } },
  { type: 'Date', cas: 'échéance le jour de la facture (limite)', attendu: 'accepte', regle: 'dates',
    appliquer: (c) => { c.facture.date_echeance = c.facture.date_facture; } },
  { type: 'Date', cas: 'date de facture au lendemain de la date de référence', attendu: 'detecte', regle: 'dates',
    appliquer: (c) => { c.facture.date_facture = jourSuivant(DATE_REFERENCE, 1); c.facture.date_echeance = jourSuivant(DATE_REFERENCE, 31); } },
  { type: 'Date', cas: 'date de facture égale à la date de référence (limite)', attendu: 'accepte', regle: 'dates',
    appliquer: (c) => { c.facture.date_facture = DATE_REFERENCE; c.facture.date_echeance = jourSuivant(DATE_REFERENCE, 30); } },
];

const normales = verites.filter((v) => !v.anomalies_attendues.length);
const cles = (r) => r.resultats.filter(alerte).map((x) => x.regle).sort();
const lignesRapport = [];
const echecs = [];
for (const m of MUTATIONS) {
  const res = { ...m, conformes: 0, total: 0, echecs: [], autresRegles: {} };
  for (const v of normales) {
    const base = contexte(v, conf);
    const avant = cles(controlerFacture(base, deps));
    const ctx = structuredClone(base);
    m.appliquer(ctx);
    const apres = cles(controlerFacture(ctx, deps));
    const nouvelles = apres.filter((r) => !avant.includes(r));
    const okMutation = m.attendu === 'detecte' ? nouvelles.includes(m.regle) : nouvelles.length === 0;
    res.total += 1;
    if (okMutation) res.conformes += 1;
    else res.echecs.push(`${v.id} (nouvelles alertes : ${nouvelles.join(', ') || 'aucune'})`);
    for (const r of nouvelles.filter((x) => x !== m.regle)) res.autresRegles[r] = (res.autresRegles[r] ?? 0) + 1;
  }
  lignesRapport.push(res);
  echecs.push(...res.echecs.map((e) => `${m.type} / ${m.cas} : ${e}`));
}

const l = [];
l.push('# Contrôles : test par mutation sur la vérité terrain (lot de développement)', '');
l.push(`Sans LLM. Chaque mutation est appliquée, une à une, aux ${normales.length} factures sans piège ; on compare les alertes `
  + 'à celles de la même facture non modifiée. **Détecté** : la règle prévue lève une alerte nouvelle. **Accepté** : aucune alerte nouvelle, quelle que soit la règle.', '');
l.push(`Tolérances (table parametres_controle) : TTC ${toleranceTtc()} millime ; TVA ${p['tolerance.tva_millimes_par_ligne']} millime par ligne au taux ; `
  + `ligne ${p['tolerance.ligne_millimes']} millime. Date de référence : ${DATE_REFERENCE}. Nombres bruts.`, '');
l.push('| Erreur | Cas | Attendu | Conformes | Autres règles déclenchées (factures) |', '|---|---|---|---|---|');
for (const r of lignesRapport) {
  const autres = Object.entries(r.autresRegles).map(([k, n]) => `${k} (${n})`).join(', ') || '—';
  l.push(`| ${r.type} | ${r.cas} | ${r.attendu === 'detecte' ? `détecté par ${r.regle}` : 'accepté'} | ${r.conformes} / ${r.total} | ${autres} |`);
}
const total = lignesRapport.reduce((s, r) => s + r.total, 0);
const conformes = lignesRapport.reduce((s, r) => s + r.conformes, 0);
l.push('', `**Total : ${conformes} / ${total} mutations conformes à l'attendu.**`, '');
if (echecs.length) l.push('## Écarts', '', ...echecs.map((e) => `- ${e}`), '');
l.push('« Autres règles déclenchées » : alertes nouvelles levées en plus de la règle prévue (par exemple, un RIB d\'un autre fournisseur révèle aussi une incohérence d\'identité). Elles ne comptent pas comme des échecs pour une mutation « détecté ».');

mkdirSync('eval/resultats', { recursive: true });
const texte = `${l.join('\n')}\n`;
writeFileSync('eval/resultats/controles-mutations-dev.md', texte);
writeFileSync('eval/resultats/controles-mutations-dev.json', `${JSON.stringify(lignesRapport.map(({ appliquer, ...r }) => r), null, 2)}\n`);
console.log(texte);
if (echecs.length) process.exit(1);
