// Mesure du rapprochement bancaire (D-065, E1) sur le lot de DÉVELOPPEMENT :
// lit le relevé synthétique, les factures telles que les fournit
// contexte_rapprochement() (état actuel de la base), applique l'appariement de
// src/, et compare à data/synthetic/releve/appariements-attendus.json.
// N'écrit rien en base. Lecture seule (mizan_app).
// Classements à part (demandes de Mohamed) :
// - « hors périmètre » : lignes qui règlent des factures du lot de test
//   (identifiants seulement, via lots.json ; leur vérité n'est pas ouverte, D-026) ;
// - « état de la base » : factures que la vérité terrain dit payées, mais qui ne
//   sont pas approuvées dans la base aujourd'hui (D001, D006, D018).
// Usage : npm run evaluer-rapprochement
// Écrit eval/resultats/rapprochement-dev.md et .json.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import pg from 'pg';
import { lireReleveCsv } from '../src/rapprochement/releve.js';
import { rapprocher, APPROUVES } from '../src/rapprochement/appariement.js';
import { enMillimes } from '../src/montants.js';

const FICHIER = 'data/synthetic/releve/releve-2026-01-01_2026-09-30.csv';
const attendu = JSON.parse(readFileSync('data/synthetic/releve/appariements-attendus.json', 'utf8'));
const lots = JSON.parse(readFileSync('data/synthetic/lots.json', 'utf8'));
const dev = new Set(lots.dev.map((d) => d.id));
const test = new Set(lots.test.map((d) => d.id));
const verites = lots.dev.map((d) => JSON.parse(readFileSync(`data/synthetic/dev/verite/${d.id}.json`, 'utf8')));
// Doublons (copie et original) : une même facture.
const classe = (doc) => verites.find((v) => v.id === doc)?.derive_de ?? doc;

if (existsSync('.env')) process.loadEnvFile('.env');
const client = new pg.Client({ host: 'localhost', port: 5432, user: 'mizan_app', password: process.env.MIZAN_APP_PASSWORD, database: process.env.MIZAN_DB ?? 'mizan' });
await client.connect();
// Relevé 0 (inexistant) : le contexte fournit seulement factures, catégories, paramètres.
const base = (await client.query('SELECT contexte_rapprochement(0) AS c')).rows[0].c;
// Lien facture → document par le NOM du fichier : un doublon exact a la même
// empreinte que son original (D035 et D056), le nom les distingue.
const noms = new Map((await client.query('SELECT id, fichier_nom FROM factures')).rows.map((x) => [Number(x.id), x.fichier_nom.replace(/\.\w+$/, '')]));
await client.end();

// Factures du lot de développement seulement (copies d'essai exclues, D-054).
const factures = base.factures.filter((f) => dev.has(noms.get(Number(f.id))));
const docDe = new Map(factures.map((f) => [f.id, noms.get(Number(f.id))]));
const statutDoc = new Map(factures.map((f) => [docDe.get(f.id), f.statut]));
const releve = lireReleveCsv(readFileSync(FICHIER, 'utf8'));
const lignes = releve.lignes.map((l) => ({ ...l, id: l.numero_ligne }));
const ctx = { lignes, factures, rejetees: [], categories: base.categories, parametres: base.parametres };
const r = rapprocher(ctx, { enMillimes });

const propositionDe = new Map(r.propositions.map((p) => [p.ligne_releve_id, p]));
const signalementsDe = new Map();
for (const s of r.signalements) signalementsDe.set(s.ligne_releve_id, [...(signalementsDe.get(s.ligne_releve_id) ?? []), s]);
const categorieDe = new Map(r.categories.map((c) => [c.ligne_releve_id, c.categorie]));
const docs = (p, role) => p.affectations.filter((a) => a.role === role).map((a) => classe(docDe.get(a.facture_id))).sort();

// --- Lignes attendues avec facture ------------------------------------------------------
const lignesAttendues = [];
for (const a of attendu.appariements) {
  const docsAttendus = a.factures.map((f) => f.document_id);
  const avoirsAttendus = (a.avoirs ?? []).map((f) => f.document_id);
  const p = propositionDe.get(a.numero_ligne);
  const s = signalementsDe.get(a.numero_ligne) ?? [];
  const resultat = p ? `proposition ${p.cas}${p.auto ? ' (auto)' : ''}` : (s.length ? s.map((x) => x.type).join(', ') : 'rien');
  const entree = { ligne: a.numero_ligne, type: a.type, mode: a.mode, docs: docsAttendus, avoirs: avoirsAttendus, resultat };
  if (docsAttendus.every((d) => test.has(d))) { lignesAttendues.push({ ...entree, classement: 'hors_perimetre', juste: s.some((x) => x.type === 'sortie_sans_facture') }); continue; }
  const nonApprouves = docsAttendus.filter((d) => !APPROUVES.has(statutDoc.get(d))
    && !verites.some((v) => (v.derive_de === d || classe(d) === v.id) && APPROUVES.has(statutDoc.get(v.id))));
  if (nonApprouves.length) {
    lignesAttendues.push({ ...entree, classement: 'etat_base', statuts: nonApprouves.map((d) => `${d} : ${statutDoc.get(d)}`),
      juste: !p && s.some((x) => x.type === 'payee_non_approuvee') });
    continue;
  }
  const juste = Boolean(p) && JSON.stringify(docs(p, 'reglement')) === JSON.stringify(docsAttendus.map(classe).sort())
    && JSON.stringify(docs(p, 'imputation_avoir')) === JSON.stringify(avoirsAttendus.map(classe).sort());
  lignesAttendues.push({ ...entree, classement: 'verite', juste, auto: p?.auto ?? false, cas: p?.cas ?? null,
    obtenu: p ? docs(p, 'reglement').concat(docs(p, 'imputation_avoir').map((d) => `avoir ${d}`)) : [] });
}

// --- Lignes sans facture, factures impayées -----------------------------------------------
const sansFacture = attendu.lignes_sans_facture.map((n) => ({
  ligne: n, libelle: lignes[n - 1].libelle, categorie: categorieDe.get(n) ?? null,
  proposition: propositionDe.has(n), signalements: (signalementsDe.get(n) ?? []).map((s) => s.type),
}));
const impayees = new Set(attendu.factures_impayees.map((f) => f.document_id).filter((d) => dev.has(d)));
const propositionsSurImpayees = r.propositions.filter((p) => p.affectations.some((a) => impayees.has(docDe.get(a.facture_id))));

// --- Rapport ---------------------------------------------------------------------------------
const verite = lignesAttendues.filter((l) => l.classement === 'verite');
const autos = verite.filter((l) => l.auto);
const l = [];
l.push('# Rapprochement bancaire : mesure sur le lot de développement', '');
l.push(`Relevé \`${FICHIER}\` (${lignes.length} opérations). Factures : état actuel de la base, telles que les fournit \`contexte_rapprochement\` `
  + `(${factures.length} factures du lot de développement ; copies d'essai exclues). Aucun écrit en base. Nombres bruts.`, '');
l.push(`Paramètres : tolérance d'écart ${base.parametres['rapprochement.tolerance_ecart']} TND, fenêtre ${base.parametres['rapprochement.fenetre_jours']} jours.`, '');

l.push('## 1. Lignes qui règlent des factures (vérité terrain)', '');
const parType = {};
for (const x of verite) { const t = (parType[x.type] ??= { attendus: 0, justes: 0, auto: 0 }); t.attendus += 1; t.justes += x.juste; t.auto += x.auto && x.juste; }
l.push('| Cas attendu | Lignes | Bonnes factures proposées | Dont confirmées automatiquement |', '|---|---|---|---|');
for (const [t, v] of Object.entries(parType)) l.push(`| ${t} | ${v.attendus} | ${v.justes} | ${v.auto} |`);
l.push(`| **Total** | **${verite.length}** | **${verite.filter((x) => x.juste).length}** | **${autos.filter((x) => x.juste).length}** |`, '');
l.push(`Confirmations automatiques **fausses** : **${autos.filter((x) => !x.juste).length}** (sur ${autos.length}).`, '');
const fausses = verite.filter((x) => !x.juste);
if (fausses.length) {
  l.push('Écarts :', '');
  for (const x of fausses) l.push(`- ligne ${x.ligne} (${x.type}, ${x.mode}) : attendu ${x.docs.join(' + ')}${x.avoirs.length ? ` (avoir ${x.avoirs.join(', ')})` : ''} ; obtenu ${x.resultat}${x.obtenu?.length ? ` → ${x.obtenu.join(' + ')}` : ''}`);
  l.push('');
}
l.push('| Ligne | Cas attendu | Mode | Résultat |', '|---|---|---|---|');
for (const x of verite) l.push(`| ${x.ligne} | ${x.type} | ${x.mode} | ${x.resultat}${x.juste ? '' : ' ✗'} |`);
l.push('');

l.push('## 2. Classés à part', '');
const etat = lignesAttendues.filter((x) => x.classement === 'etat_base');
l.push(`**État de la base** (payées selon la vérité terrain, non approuvées aujourd'hui) : ${etat.length} ligne(s) ; signalement « payée sans être approuvée » levé : ${etat.filter((x) => x.juste).length}.`, '');
for (const x of etat) l.push(`- ligne ${x.ligne} : ${x.statuts.join(', ')} → ${x.resultat}`);
const hors = lignesAttendues.filter((x) => x.classement === 'hors_perimetre');
l.push('', `**Hors périmètre** (factures du lot de test, absentes de la base) : ${hors.length} ligne(s) ; signalées « sortie sans facture » : ${hors.filter((x) => x.juste).length}. Évaluées à l'étape 8.`, '');

l.push('## 3. Lignes sans facture (loyer, salaires, frais, encaissements…)', '');
const rangees = sansFacture.filter((x) => x.categorie);
const faussesAlertes = sansFacture.filter((x) => x.signalements.length || x.proposition);
l.push(`${sansFacture.length} lignes ; rangées dans une catégorie : ${rangees.length} ; **fausses alertes ou propositions** : **${faussesAlertes.length}**.`, '');
for (const x of faussesAlertes) l.push(`- ligne ${x.ligne} « ${x.libelle} » : ${x.proposition ? 'proposition' : ''} ${x.signalements.join(', ')}`);
const parCategorie = {};
for (const x of rangees) parCategorie[x.categorie] = (parCategorie[x.categorie] ?? 0) + 1;
l.push(`Par catégorie : ${Object.entries(parCategorie).map(([c, nb]) => `${c} ${nb}`).join(', ')}.`, '');

l.push('## 4. Factures impayées (vérité terrain)', '');
l.push(`${impayees.size} factures du lot de développement ne sont pas payées dans le relevé ; propositions qui leur affectent un paiement à tort : **${propositionsSurImpayees.length}**.`, '');

l.push('## 5. Volume de notifications pour cet import', '');
const aConfirmer = r.propositions.filter((p) => !p.auto).length;
l.push(`1 synthèse ; ${aConfirmer} proposition(s) à confirmer ; ${r.signalements.length} signalement(s) ; soit **${1 + aConfirmer + r.signalements.length} messages** par destinataire responsable `
  + `(${1 + aConfirmer} pour un validateur, qui ne reçoit pas les signalements). Confirmées automatiquement, sans message : ${r.propositions.filter((p) => p.auto).length}.`, '');

l.push('## 6. Limites', '');
l.push('- Un seul relevé synthétique, généré avec des libellés réguliers : un vrai relevé aura des libellés plus variés.');
l.push('- Aucune retenue à la source n\'est simulée (D-065, C1) : l\'écart de 2 TND (D015) est un écart générique.');
l.push('- Le relevé ne montre pas le RIB du bénéficiaire : D-058 sera contrôlé par les ordres de paiement (étape 7).');
l.push('- Une proposition rejetée n\'est pas reproposée ; sa ligne reste à rapprocher à la main (tableau de bord, étape 7).');

mkdirSync('eval/resultats', { recursive: true });
const texte = `${l.join('\n')}\n`;
writeFileSync('eval/resultats/rapprochement-dev.md', texte);
writeFileSync('eval/resultats/rapprochement-dev.json', `${JSON.stringify({ lignesAttendues, sansFacture, propositions: r.propositions, signalements: r.signalements }, null, 2)}\n`);
console.log(texte);
