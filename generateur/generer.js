// Génère le jeu de données synthétiques dans data/synthetic/.
// Usage : npm run generer        (PostgreSQL doit tourner : config_fiscale y est lue)
// Décisions : docs/decisions.md D-023 à D-030.
import { createHash } from 'node:crypto';
import { mkdirSync, rmSync, writeFileSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { lireConfigFiscale } from './config.js';
import { construireJeu, versVerite, PARAMETRES } from './modele.js';
import { demarrerRendu, htmlDocument } from './rendu.js';
import { formaterDate } from './dates.js';
import { formaterMontant, versDinars } from '../src/montants.js';
import { valider } from '../src/schemas/valider.js';

const RACINE = join('data', 'synthetic');
const FICHIER_RELEVE = 'releve-2026-01-01_2026-09-30.csv';

const ecrireJson = (chemin, donnees) => writeFileSync(chemin, `${JSON.stringify(donnees, null, 2)}\n`);
const sha256 = (tampon) => createHash('sha256').update(tampon).digest('hex');

async function principal() {
  const config = await lireConfigFiscale();
  const jeu = construireJeu({ config });

  // Nettoyage des sorties précédentes (uniquement ce que le générateur produit).
  for (const nom of ['dev', 'test', 'releve', 'referentiel', 'lots.json', 'config-fiscale.json']) {
    rmSync(join(RACINE, nom), { recursive: true, force: true });
  }
  for (const lot of ['dev', 'test']) {
    mkdirSync(join(RACINE, lot, 'documents'), { recursive: true });
    mkdirSync(join(RACINE, lot, 'verite'), { recursive: true });
  }
  mkdirSync(join(RACINE, 'releve'), { recursive: true });
  mkdirSync(join(RACINE, 'referentiel'), { recursive: true });

  ecrireJson(join(RACINE, 'config-fiscale.json'), config);
  ecrireReferentiel(jeu);

  // Rendu : les originaux d'abord, les doublons ensuite.
  const rendu = await demarrerRendu();
  const fichiers = new Map();
  try {
    const ordre = [...jeu.documents.filter((d) => !d.derive_de), ...jeu.documents.filter((d) => d.derive_de)];
    for (const doc of ordre) {
      const verite = versVerite(doc, jeu.entreprise);
      let contenu;
      if (doc.mode_derive === 'copie') {
        contenu = fichiers.get(doc.derive_de.id);
      } else if (doc.format === 'image') {
        contenu = await rendu.scan(htmlDocument(doc, jeu.entreprise), `${jeu.graine}-${doc.id}`);
      } else {
        contenu = await rendu.pdf(htmlDocument(doc, jeu.entreprise));
      }
      fichiers.set(doc.id, contenu);
      writeFileSync(join(RACINE, doc.lot, 'documents', verite.fichier), contenu);

      verite.sha256 = sha256(contenu);
      const erreurs = valider('verite', verite);
      if (erreurs.length) throw new Error(`${doc.id} : vérité terrain invalide\n${erreurs.join('\n')}`);
      ecrireJson(join(RACINE, doc.lot, 'verite', `${doc.id}.json`), verite);
      process.stdout.write('.');
    }
  } finally {
    await rendu.fermer();
  }
  process.stdout.write('\n');

  ecrireLots(jeu);
  ecrireReleve(jeu);
  resumer(jeu);
}

function ecrireReferentiel(jeu) {
  const tiers = (t) => ({
    code: t.code,
    raison_sociale: t.raison_sociale,
    matricule_fiscal: t.matricule_fiscal,
    adresse: t.adresse,
    email: t.email,
    rib: t.rib,
    banque: t.banque,
  });
  ecrireJson(join(RACINE, 'referentiel', 'entreprise.json'), tiers(jeu.entreprise));
  // Seuls les fournisseurs connus : les fournisseurs « inconnus » n'y figurent pas.
  ecrireJson(join(RACINE, 'referentiel', 'fournisseurs.json'), jeu.fournisseurs.map(tiers));
}

function ecrireLots(jeu) {
  const resume = (d) => ({
    id: d.id,
    groupe: d.groupe,
    fichier: `${d.lot}/documents/${d.id}.${d.format === 'pdf' ? 'pdf' : 'jpg'}`,
    type_document: d.type_document,
    format: d.format,
    anomalies: d.pieges.map((p) => p.code),
    robustesse: d.robustesse.map((r) => r.code),
  });
  ecrireJson(join(RACINE, 'lots.json'), {
    graine: jeu.graine,
    regle: 'Le lot « test » est réservé à l\'évaluation (étape 8) : il ne sert jamais à régler le prompt ni le schéma (docs/decisions.md D-026).',
    dev: jeu.documents.filter((d) => d.lot === 'dev').map(resume),
    test: jeu.documents.filter((d) => d.lot === 'test').map(resume),
  });
}

function ecrireReleve(jeu) {
  const r = jeu.releve;
  const montant = (m) => (m === 0 ? '' : formaterMontant(m, { milliers: '', decimale: ',' }));
  const lignes = ['date_operation;date_valeur;libelle;reference;debit;credit;solde'];
  for (const op of r.operations) {
    lignes.push([
      formaterDate(op.date, 'jj/mm/aaaa'), formaterDate(op.date_valeur, 'jj/mm/aaaa'), op.libelle, op.reference,
      montant(op.debit), montant(op.credit), formaterMontant(op.solde, { milliers: '', decimale: ',' }),
    ].join(';'));
  }
  writeFileSync(join(RACINE, 'releve', FICHIER_RELEVE), `${lignes.join('\n')}\n`);

  const avecFacture = new Set(r.appariements.map((a) => a.operation));
  ecrireJson(join(RACINE, 'releve', 'appariements-attendus.json'), {
    fichier: FICHIER_RELEVE,
    format: { separateur: ';', decimale: ',', dates: 'JJ/MM/AAAA', encodage: 'UTF-8' },
    compte: r.compte,
    periode: { debut: r.debut, fin: r.fin },
    solde_initial: versDinars(r.soldeInitial),
    solde_final: versDinars(r.soldeFinal),
    appariements: r.appariements
      .sort((a, b) => a.operation.numero_ligne - b.operation.numero_ligne)
      .map((a) => ({
        numero_ligne: a.operation.numero_ligne,
        type: a.type,
        mode: a.mode,
        montant_operation: versDinars(a.operation.debit),
        factures: a.docsPayes.map((p) => ({ document_id: p.doc.id, numero: p.doc.numero, montant_affecte: versDinars(p.montant) })),
        avoirs: a.avoirs.map((p) => ({ document_id: p.doc.id, numero: p.doc.numero, montant_impute: versDinars(p.montant) })),
        ecart: versDinars(a.ecart),
      })),
    factures_impayees: r.impayes
      .sort((a, b) => a.doc.id.localeCompare(b.doc.id))
      .map((i) => ({ document_id: i.doc.id, numero: i.doc.numero, montant_ttc: versDinars(i.doc.imprime.ttc), devise: i.doc.devise, raison: i.raison })),
    lignes_sans_facture: r.operations.filter((op) => !avecFacture.has(op)).map((op) => op.numero_ligne),
  });
}

function resumer(jeu) {
  const d = jeu.documents;
  const n = (f) => d.filter(f).length;
  const lots = JSON.parse(readFileSync(join(RACINE, 'lots.json'), 'utf8'));
  console.log(`Documents : ${d.length} (dev ${lots.dev.length}, test ${lots.test.length}) — PDF ${n((x) => x.format === 'pdf')}, images ${n((x) => x.format === 'image')}, avoirs ${n((x) => x.type_document === 'avoir')}`);
  console.log(`Pièges : ${n((x) => x.pieges.length > 0)} documents piégés`);
  console.log(`Relevé : ${jeu.releve.operations.length} opérations, ${jeu.releve.appariements.length} appariements, ${jeu.releve.impayes.length} factures impayées`);
  console.log(`Seuil de validation provisoire : ${versDinars(PARAMETRES.seuilValidationTtc)} TND (D-028)`);
}

principal().catch((erreur) => {
  console.error(erreur);
  process.exit(1);
});
