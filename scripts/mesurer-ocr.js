// Mesure la qualité de l'OCR sur les scans du lot de DÉVELOPPEMENT uniquement
// (le lot de test est réservé à l'étape 8, D-026) : pour chaque scan, on
// cherche dans le texte reconnu les valeurs clés de la vérité terrain.
// Usage : node scripts/mesurer-ocr.js [psm...]   (le service ocr doit tourner)
import { spawnSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';

const dossier = 'data/synthetic/dev';
const scans = readdirSync(`${dossier}/verite`)
  .map((f) => JSON.parse(readFileSync(`${dossier}/verite/${f}`, 'utf8')))
  .filter((v) => v.format === 'image');

// Comparaison tolérante à la mise en forme : on ne garde que lettres et chiffres.
const compacter = (t) => String(t).toUpperCase().normalize('NFD').replace(/[^A-Z0-9]/g, '');
const chiffresMontant = (m, devise) => (devise === 'EUR' ? m.toFixed(2) : m.toFixed(3)).replace('.', '');
const dateCompacte = (iso) => iso.replaceAll('-', '');

function valeursCles(v) {
  const e = v.extraction;
  return {
    numero: compacter(e.numero),
    matricule: compacter(e.fournisseur.matricule_fiscal),
    rib: compacter(e.fournisseur.rib),
    ttc: chiffresMontant(e.montant_ttc, e.devise),
    date: dateCompacte(e.date_facture),
  };
}

function ocr(chemin, psm) {
  const r = spawnSync('docker', ['compose', 'exec', '-T', '-e', `OCR_PSM=${psm}`, 'ocr', 'python3', 'serveur.py', '--stdin', 'image/jpeg'],
    { input: readFileSync(chemin), encoding: 'utf8', maxBuffer: 10 * 1024 * 1024 });
  if (r.status !== 0) throw new Error(r.stdout || r.stderr);
  return JSON.parse(r.stdout);
}

const reglages = process.argv.slice(2).length ? process.argv.slice(2) : ['3', '4', '6'];
for (const psm of reglages) {
  const trouves = { numero: 0, matricule: 0, rib: 0, ttc: 0, date: 0 };
  let duree = 0;
  for (const v of scans) {
    const resultat = ocr(`${dossier}/documents/${v.fichier}`, psm);
    duree += resultat.duree_ms;
    const texte = compacter(resultat.texte);
    const texteDates = texte; // les dates longues (« 3 juin 2026 ») ne sont pas comptées
    for (const [cle, valeur] of Object.entries(valeursCles(v))) {
      const cible = cle === 'date' ? texteDates : texte;
      if (cible.includes(valeur) || (cle === 'date' && cible.includes(valeur.slice(6) + valeur.slice(4, 6) + valeur.slice(0, 4)))) {
        trouves[cle] += 1;
      }
    }
  }
  const n = scans.length;
  const detail = Object.entries(trouves).map(([cle, k]) => `${cle} ${k}/${n}`).join(' · ');
  console.log(`psm ${psm} : ${detail} · durée moyenne ${Math.round(duree / n)} ms`);
}
