// Mesure des contrôles déterministes (D-055, précision 2) sur la VÉRITÉ
// TERRAIN du lot de développement : la logique seule, sans extraction.
// Usage : node eval/evaluer-controles.js
// Lit dans la base « mizan » (rôle mizan_app, lecture seule) la configuration
// fiscale, les paramètres de contrôle et le catalogue des règles ; le reste
// vient de data/synthetic. Écrit eval/resultats/controles-verite-dev.md et .json.
// Le lot de test est réservé à l'étape 8 (D-026) et n'est pas lu ici.
import { mkdirSync, writeFileSync } from 'node:fs';
import { controlerFacture, statutSelonGravite } from '../src/controles/regles.js';
import { deps, DATE_REFERENCE, alerte, lireConfiguration, verites, contexte, ATTENDU, REGLES_DOUBLON } from './controles-commun.js';


// --- Mesure ---------------------------------------------------------------------------------
const conf = await lireConfiguration();
const documents = verites.map((v) => {
  const r = controlerFacture(contexte(v, conf), deps);
  const pieges = v.anomalies_attendues.map((a) => a.code);
  const derive = v.derive_de ?? null;
  const original = verites.find((o) => o.derive_de === v.id)?.id ?? null;
  return {
    id: v.id, format: v.format, type_document: v.extraction.type_document, pieges, derive_de: derive, doublon_de: original,
    robustesse: v.robustesse.map((x) => x.code), statut: statutSelonGravite(r.resultats), fournisseur_id: r.fournisseur_id,
    alertes: r.resultats.filter(alerte).map((x) => ({ regle: x.regle, gravite: x.gravite, message: x.message })),
    infos: r.resultats.filter((x) => x.resultat === 'anomalie' && x.gravite === 'info').map((x) => ({ regle: x.regle, message: x.message })),
    nonApplicables: r.resultats.filter((x) => x.resultat === 'non_applicable').length,
    // Écarts d'arrondi tolérés (D-055, B2) : montrés, pour qu'ils ne masquent rien.
    toleres: {
      lignes: r.resultats.find((x) => x.regle === 'coherence_lignes')?.detail?.toleres?.length ?? 0,
      tva_millimes: r.resultats.find((x) => x.regle === 'coherence_tva' && x.resultat === 'ok')?.detail?.ecart_millimes ?? 0,
      tva_detectee_millimes: r.resultats.find((x) => x.regle === 'coherence_tva' && x.resultat === 'anomalie')?.detail?.ecart_millimes ?? null,
    },
    resultats: r.resultats.length,
  };
});
const parId = new Map(documents.map((d) => [d.id, d]));
const regleEnAlerte = (d, regle) => d.alertes.some((a) => a.regle === regle);

// Pièges, par type. Doublons : la paire est l'unité ; elle est détectée si
// exactement une des deux factures est marquée par la règle prévue.
const pieges = {};
for (const [code, attendu] of Object.entries(ATTENDU)) {
  const p = { attendus: 0, prevue: 0, autre: 0, manques: [], documents: [] };
  for (const d of documents.filter((x) => x.pieges.includes(code))) {
    p.attendus += 1;
    p.documents.push(d.id);
    const membres = d.derive_de ? [d, parId.get(d.derive_de)] : [d];
    const marques = membres.filter((m) => regleEnAlerte(m, attendu.regle));
    if (d.derive_de ? marques.length === 1 : marques.length > 0) p.prevue += 1;
    else if (d.alertes.length) { p.autre += 1; p.manques.push(`${d.id} (autres règles : ${d.alertes.map((a) => a.regle).join(', ')})`); }
    else p.manques.push(d.id);
  }
  pieges[code] = p;
}

// Statut final attendu. Paire de doublons : la facture reçue en second est bloquée.
const statutAttendu = (d) => {
  if (d.derive_de || d.doublon_de) {
    const autreId = d.derive_de ?? d.doublon_de;
    const recueEnSecond = Number(d.id.slice(1)) > Number(autreId.slice(1));
    return recueEnSecond ? 'bloquee' : 'conforme';
  }
  if (!d.pieges.length) return 'conforme';
  return d.pieges.map((c) => ATTENDU[c].statut).sort((a, b) => ['bloquee', 'anomalie', 'a_valider'].indexOf(a) - ['bloquee', 'anomalie', 'a_valider'].indexOf(b))[0];
};
for (const d of documents) d.statut_attendu = statutAttendu(d);

// Fausses alertes : factures sans piège ; les alertes de doublon d'un membre
// de paire sont la détection du piège, pas une fausse alerte.
const normales = documents.filter((d) => !d.pieges.length);
const faussesAlertes = normales.map((d) => ({
  id: d.id, robustesse: d.robustesse,
  alertes: d.alertes.filter((a) => !(d.doublon_de && REGLES_DOUBLON.has(a.regle))),
})).filter((d) => d.alertes.length);
const parRegle = {};
for (const d of faussesAlertes) for (const a of d.alertes) parRegle[a.regle] = (parRegle[a.regle] ?? 0) + 1;

// --- Rapport ----------------------------------------------------------------------------------
const l = [];
l.push('# Contrôles déterministes : mesure sur la vérité terrain (lot de développement)', '');
l.push(`Logique seule : les règles s'appliquent aux valeurs **imprimées** (vérité terrain), sans OCR ni LLM. `
  + `${documents.length} documents, ${conf.regles.length} règles exécutées sur chacun (${documents.every((d) => d.resultats === conf.regles.length) ? 'vérifié' : '**ÉCART**'}). `
  + `Date de référence : ${DATE_REFERENCE}. Configuration fiscale, paramètres de contrôle et catalogue lus en base. Nombres bruts.`, '');
l.push(`Paramètres : seuil de validation ${conf.parametres.seuil_validation_ttc} TND ; tolérances : TTC ${conf.parametres['tolerance.ttc_millimes']} millime, `
  + `TVA ${conf.parametres['tolerance.tva_millimes_par_ligne']} millime par ligne, ligne ${conf.parametres['tolerance.ligne_millimes']} millime.`, '');

l.push('## 1. Pièges détectés, par type', '');
l.push('| Piège | Règle prévue | Attendus | Détectés par la règle prévue | Par une autre règle seulement | Non détectés |', '|---|---|---|---|---|---|');
for (const [code, p] of Object.entries(pieges)) {
  l.push(`| ${code} | ${ATTENDU[code].regle} | ${p.attendus} | ${p.prevue} | ${p.autre} | ${p.attendus - p.prevue - p.autre} |`);
}
const totalAttendus = Object.values(pieges).reduce((s, p) => s + p.attendus, 0);
const totalPrevue = Object.values(pieges).reduce((s, p) => s + p.prevue, 0);
l.push(`| **Total** | | **${totalAttendus}** | **${totalPrevue}** | | |`, '');
const manques = Object.values(pieges).flatMap((p) => p.manques);
if (manques.length) l.push(`Non détectés par la règle prévue : ${manques.join(' ; ')}.`, '');
l.push('Doublons : la paire est l\'unité ; elle compte comme détectée si exactement une des deux factures est marquée : celle **reçue en second** (ordre de dépôt, par nom de fichier). Pour la paire D035/D056, c\'est donc D056 qui est bloquée, bien que D035 soit la copie générée.', '');

l.push('## 2. Fausses alertes sur les factures sans piège', '');
l.push(`Factures sans piège : ${normales.length}. Avec au moins une alerte (avertissement, bloquant ou validation) : **${faussesAlertes.length}**.`, '');
if (Object.keys(parRegle).length) {
  l.push('| Règle | Factures concernées |', '|---|---|');
  for (const [r, n] of Object.entries(parRegle).sort()) l.push(`| ${r} | ${n} |`);
  l.push('');
  for (const d of faussesAlertes) l.push(`- ${d.id}${d.robustesse.length ? ` (${d.robustesse.join(', ')})` : ''} : ${d.alertes.map((a) => `${a.regle} — ${a.message}`).join(' ; ')}`);
  l.push('');
}

l.push('## 3. Statut final', '');
const concordants = documents.filter((d) => d.statut === d.statut_attendu);
l.push(`Statut obtenu = statut attendu : **${concordants.length} / ${documents.length}**.`, '');
const parStatut = {};
for (const d of documents) parStatut[d.statut] = (parStatut[d.statut] ?? 0) + 1;
l.push(`Répartition : ${Object.entries(parStatut).sort().map(([s, n]) => `${s} ${n}`).join(', ')}.`, '');
const discordants = documents.filter((d) => d.statut !== d.statut_attendu);
if (discordants.length) {
  l.push('| Document | Attendu | Obtenu | Alertes |', '|---|---|---|---|');
  for (const d of discordants) l.push(`| ${d.id} | ${d.statut_attendu} | ${d.statut} | ${d.alertes.map((a) => a.regle).join(', ') || '—'} |`);
  l.push('');
}

l.push('## 4. Détail des factures piégées et des doublons', '');
l.push('| Document | Piège | Statut | Alertes (règle : gravité) |', '|---|---|---|---|');
for (const d of documents.filter((x) => x.pieges.length || x.doublon_de)) {
  l.push(`| ${d.id} | ${d.pieges.join(', ') || `original de ${d.doublon_de}`} | ${d.statut} | ${d.alertes.map((a) => `${a.regle} : ${a.gravite}`).join(' ; ') || '—'} |`);
}
l.push('');

l.push('## 5. Tolérances d\'arrondi utilisées', '');
const lignesToleres = documents.filter((d) => d.toleres.lignes > 0);
const tvaToleree = documents.filter((d) => d.toleres.tva_millimes > 0);
const liste = (docs, f) => (docs.length ? ` (${docs.map(f).join(', ')})` : '');
l.push(`- Lignes (quantité × prix) : ${lignesToleres.reduce((s, d) => s + d.toleres.lignes, 0)} ligne(s) tolérée(s) sur ${lignesToleres.length} document(s)${liste(lignesToleres, (d) => d.id)}.`);
l.push(`- TVA : écart toléré sur ${tvaToleree.length} document(s)${liste(tvaToleree, (d) => `${d.id} : ${d.toleres.tva_millimes} millime(s)`)}.`);
l.push(`- Écart de TVA du piège, détecté : ${documents.filter((d) => d.toleres.tva_detectee_millimes !== null).map((d) => `${d.id} : ${d.toleres.tva_detectee_millimes} millimes`).join(', ') || '—'}.`, '');

l.push('## 6. Résultats « info » (non comptés comme alertes)', '');
const infos = documents.flatMap((d) => d.infos.map((i) => `${d.id} : ${i.regle} — ${i.message}`));
l.push(infos.length ? infos.map((x) => `- ${x}`).join('\n') : 'Aucun.', '');
l.push('', '## 7. Limites de cette mesure', '');
l.push('- Les règles qui dépendent de l\'extraction (identifiants absents du texte, plusieurs RIB, signalements) sont **non applicables** ici : elles seront mesurées sur l\'extraction réelle, après le workflow.');
l.push('- Les documents synthétiques sont réguliers ; une facture réelle peut arrondir autrement (voir les tolérances, D-055 B2).');
l.push('- Les pièges d\'injection (D001, D006) n\'ont aucun effet sur les valeurs imprimées : ils comptent ici comme des factures sans piège.');

mkdirSync('eval/resultats', { recursive: true });
const texte = `${l.join('\n')}\n`;
writeFileSync('eval/resultats/controles-verite-dev.md', texte);
writeFileSync('eval/resultats/controles-verite-dev.json', `${JSON.stringify({ date_reference: DATE_REFERENCE, parametres: conf.parametres, pieges, fausses_alertes: faussesAlertes, documents }, null, 2)}\n`);
console.log(texte);
