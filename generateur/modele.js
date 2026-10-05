// Construction du jeu de données synthétiques, sans aucune écriture de fichier.
// Fonction pure : même configuration + même graine = même résultat.
// Décisions : docs/decisions.md D-023 à D-030.

import { creerAlea } from './alea.js';
import { ajouterJours, minDate, maxDate, nomMois } from './dates.js';
import {
  BANQUE_FICTIVE, ENTREPRISE, FOURNISSEURS_BASE, FOURNISSEURS_INCONNUS_BASE, catalogue,
} from './referentiel.js';
import { cleRib } from '../src/rib.js';
import { diviserArrondi, montantLigneHt, montantTva, versDinars } from '../src/montants.js';
import { valeurEnVigueur } from '../src/configFiscale.js';

export const PARAMETRES = Object.freeze({
  graine: 20260101,
  dateMin: '2026-01-05',
  dateMax: '2026-09-25',
  debutReleve: '2026-01-01',
  finReleve: '2026-09-30',
  // Seuil de validation provisoire (D-028), en millimes TTC.
  seuilValidationTtc: 20_000_000,
  plafondNormalTtc: 15_000_000,
  plancherEleveTtc: 40_000_000,
  soldeInitial: 120_000_000,
});

export const CODES_PIEGES = Object.freeze([
  'doublon_exact', 'doublon_rescanne', 'erreur_tva', 'ttc_incoherent', 'rib_modifie',
  'matricule_invalide', 'montant_eleve', 'fournisseur_inconnu', 'devise_etrangere',
]);

// Pièges portés par le document lui-même (les doublons sont des documents dérivés).
const PIEGES_DIRECTS = ['erreur_tva', 'ttc_incoherent', 'rib_modifie', 'matricule_invalide',
  'montant_eleve', 'fournisseur_inconnu', 'devise_etrangere'];

// Factures qui ne sont pas payées dans le relevé : elles seraient bloquées.
const PIEGES_NON_PAYES = new Set(['erreur_tva', 'ttc_incoherent', 'rib_modifie',
  'matricule_invalide', 'fournisseur_inconnu', 'devise_etrangere']);

const LETTRES_CLE = 'ABCDEFGHJKLMNPQRSTVWXYZ'; // sans I, O, U (D-027)
const NB_NORMAUX_DEV = 29;
const NB_NORMAUX_TEST = 5;
const NB_IMAGES_DEV = 10;
const NB_IMAGES_TEST = 3;

/**
 * @param {{config: object[], graine?: number}} options
 */
export function construireJeu({ config, graine = PARAMETRES.graine }) {
  const alea = creerAlea(graine);
  const utilises = new Set();

  const nouveauMatricule = () => {
    let m;
    do { m = `99${alea.chiffres(5)}${alea.choix(LETTRES_CLE)}`; } while (utilises.has(m));
    utilises.add(m);
    return m;
  };
  const nouveauRib = () => {
    let rib;
    do {
      const base = `${BANQUE_FICTIVE.code}${alea.chiffres(3)}${alea.chiffres(13)}`;
      rib = base + cleRib(base);
    } while (utilises.has(rib));
    utilises.add(rib);
    return rib;
  };
  const completerTiers = (base) => ({
    ...base,
    matricule_fiscal: nouveauMatricule(),
    rib: nouveauRib(),
    banque: BANQUE_FICTIVE.nom,
    email: `contact@${base.raison_sociale.normalize('NFD').replace(/[^A-Za-z]/g, '').toLowerCase().slice(0, 18)}.example`,
  });

  const entreprise = completerTiers(ENTREPRISE);
  const fournisseurs = FOURNISSEURS_BASE.map(completerTiers);
  const inconnus = FOURNISSEURS_INCONNUS_BASE.map(completerTiers);
  const parCode = new Map([...fournisseurs, ...inconnus].map((f) => [f.code, f]));
  const tirerFournisseur = () => alea.pondere(fournisseurs.map((f) => [f, f.poids]));

  // --- Plan des documents d'origine ------------------------------------------
  const plan = [];
  ['dev', 'test'].forEach((lot, instance) => {
    for (const code of PIEGES_DIRECTS) plan.push({ lot, role: 'piege', piege: code, instance });
    plan.push({ lot, role: 'normal', derive: 'doublon_exact' });
    plan.push({ lot, role: 'normal', derive: 'doublon_rescanne' });
    plan.push({ lot, role: 'normal', avecAvoir: true });
  });
  for (let i = 0; i < NB_NORMAUX_DEV; i += 1) plan.push({ lot: 'dev', role: 'normal' });
  for (let i = 0; i < NB_NORMAUX_TEST; i += 1) plan.push({ lot: 'test', role: 'normal' });

  const documents = [];
  plan.forEach((entree, index) => {
    const groupe = `G${String(index + 1).padStart(2, '0')}`;
    const facture = creerFacture(entree, groupe);
    documents.push(facture);
    if (entree.avecAvoir) documents.push(creerAvoir(facture, groupe));
  });

  // --- Numérotation, par fournisseur et dans l'ordre chronologique ----------
  numeroter(documents);

  // --- Documents dérivés (doublons) -----------------------------------------
  for (const original of [...documents]) {
    if (original.derive === 'doublon_exact' || original.derive === 'doublon_rescanne') {
      const copie = {
        ...structuredClone(sansReferences(original)),
        fournisseur: original.fournisseur,
        role: 'derive',
        facture_origine: null,
        derive_de: original,
        mode_derive: original.derive === 'doublon_exact' ? 'copie' : 'scan',
        format: original.derive === 'doublon_exact' ? original.format : 'image',
        derive: null,
        pieges: [{ code: original.derive, detail: { original: original } }],
      };
      documents.push(copie);
    }
  }

  // --- Formats : images (scans) ----------------------------------------------
  for (const [lot, nb] of [['dev', NB_IMAGES_DEV], ['test', NB_IMAGES_TEST]]) {
    const candidats = documents.filter((d) => d.lot === lot && !d.derive_de && d.derive !== 'doublon_rescanne');
    for (const d of alea.melanger(candidats).slice(0, nb)) d.format = 'image';
  }
  // Les copies exactes héritent du format final de leur original.
  for (const d of documents) if (d.mode_derive === 'copie') d.format = d.derive_de.format;

  // --- Identifiants, dans un ordre mélangé ----------------------------------
  alea.melanger(documents).forEach((d, i) => { d.id = `D${String(i + 1).padStart(3, '0')}`; });
  documents.sort((a, b) => a.id.localeCompare(b.id));

  const releve = genererReleve(documents);

  return { parametres: PARAMETRES, graine, entreprise, fournisseurs, fournisseursInconnus: inconnus, documents, releve };

  // ===========================================================================

  function creerFacture(entree, groupe) {
    const piege = entree.role === 'piege' ? entree.piege : null;
    let fournisseur;
    if (piege === 'fournisseur_inconnu') fournisseur = inconnus[entree.instance];
    else if (piege === 'devise_etrangere') fournisseur = parCode.get('F02');
    else if (piege === 'montant_eleve') fournisseur = parCode.get('F10');
    else fournisseur = tirerFournisseur();

    const dateMax = entree.avecAvoir ? '2026-07-10' : PARAMETRES.dateMax;
    const date = ajouterJours(PARAMETRES.dateMin, alea.entier(0, ecart(PARAMETRES.dateMin, dateMax)));
    const devise = piege === 'devise_etrangere' ? 'EUR' : 'TND';
    const cible = piege === 'montant_eleve' ? 'eleve' : 'normal';

    const doc = {
      groupe,
      lot: entree.lot,
      role: entree.role,
      derive: entree.derive ?? null,
      derive_de: null,
      mode_derive: null,
      format: 'pdf',
      fournisseur,
      fournisseur_connu: !inconnus.includes(fournisseur),
      type_document: 'facture',
      numero: null,
      date_facture: date,
      date_echeance: ajouterJours(date, fournisseur.delai),
      devise,
      facture_origine: null,
      pieges: [],
    };
    remplirMontants(doc, cible);
    if (piege) appliquerPiege(doc, piege, entree.instance);
    return doc;
  }

  function creerAvoir(facture, groupe) {
    const ligne = alea.choix(facture.lignes);
    const quantite = Math.max(1000, Math.round(ligne.quantiteMilliemes / 4000) * 1000);
    const date = ajouterJours(facture.date_facture, alea.entier(5, 20));
    const avoir = {
      ...facture,
      groupe,
      role: 'avoir',
      derive: null,
      type_document: 'avoir',
      numero: null,
      date_facture: date,
      date_echeance: null,
      facture_origine: facture,
      pieges: [],
      lignes: [{
        ...ligne,
        designation: `Retour : ${ligne.designation}`,
        quantiteMilliemes: Math.min(quantite, ligne.quantiteMilliemes),
      }],
    };
    calculer(avoir, null);
    return avoir;
  }

  function remplirMontants(doc, cible) {
    const timbre = doc.devise === 'TND' ? montantEnMillimes(valeurEnVigueur(config, 'timbre.facture', doc.date_facture)) : null;
    for (let essai = 0; essai < 200; essai += 1) {
      doc.lignes = tirerLignes(doc, cible);
      calculer(doc, timbre);
      const ttc = doc.calcule.ttc;
      if (cible === 'normal' && ttc < PARAMETRES.plafondNormalTtc) return;
      if (cible === 'eleve' && ttc > PARAMETRES.plancherEleveTtc) return;
    }
    throw new Error(`impossible de générer une facture ${cible} pour ${doc.fournisseur.code}`);
  }

  function tirerLignes(doc, cible) {
    const articles = alea.melanger(catalogue(doc.fournisseur.secteur));
    const nb = cible === 'eleve'
      ? alea.entier(2, 3)
      : alea.pondere([[1, 3], [2, 4], [3, 4], [4, 3], [5, 2], [6, 1], [8, 1]]);
    const diviseur = doc.devise === 'EUR' ? 3.4 : 1; // prix indicatifs convertis en EUR
    return articles.slice(0, Math.min(nb, articles.length)).map((a) => {
      // Quantités entières en EUR : tous les montants restent au centime.
      const pas = a.decimales === 1 && doc.devise === 'TND' ? 2 : 1;
      const quantite = cible === 'eleve'
        ? a.qMax
        : alea.entier(a.qMin * pas, a.qMax * pas) / pas;
      const prix = (a.prixMin + alea.flottant() * (a.prixMax - a.prixMin)) / diviseur;
      return {
        designation: a.designation,
        unite: a.unite,
        quantiteMilliemes: Math.round(quantite * 1000),
        prixUnitaire: Math.max(10, Math.round(prix * 100) * 10), // multiple de 10 millimes
        cleTaux: a.cleTaux,
        taux: valeurEnVigueur(config, a.cleTaux, doc.date_facture),
      };
    });
  }

  function calculer(doc, timbre) {
    for (const l of doc.lignes) l.ht = montantLigneHt(l.quantiteMilliemes, l.prixUnitaire);
    const bases = new Map();
    for (const l of doc.lignes) bases.set(l.taux, (bases.get(l.taux) ?? 0) + l.ht);
    const tvaParTaux = [...bases.entries()]
      .sort((a, b) => b[0] - a[0])
      .map(([taux, base]) => ({ taux, base, tva: doc.devise === 'TND' ? montantTva(base, taux) : tvaAuCentime(base, taux) }));
    const ht = doc.lignes.reduce((s, l) => s + l.ht, 0);
    const tva = tvaParTaux.reduce((s, t) => s + t.tva, 0);
    const timbreFinal = doc.type_document === 'avoir' ? null : timbre;
    doc.calcule = { ht, tva, timbre: timbreFinal, ttc: ht + tva + (timbreFinal ?? 0), tvaParTaux };
    doc.imprime = {
      matricule_fiscal: `${doc.fournisseur.matricule_fiscal}/A/M/000`,
      rib: doc.fournisseur.rib,
      tvaParTaux: tvaParTaux.map((t) => ({ ...t })),
      tva,
      ttc: doc.calcule.ttc,
    };
  }

  function appliquerPiege(doc, code, instance) {
    const c = doc.calcule;
    const p = doc.imprime;
    let detail;
    switch (code) {
      case 'erreur_tva': {
        const montant = alea.entier(5, 60) * 1000;
        const negatif = alea.booleen(0.5) && c.tvaParTaux[0].tva > montant;
        const delta = negatif ? -montant : montant;
        p.tvaParTaux[0].tva += delta;
        p.tva += delta;
        p.ttc += delta; // le TTC reste cohérent avec la TVA imprimée : seule la TVA est fausse
        detail = { tva_calculee: versDinars(c.tva), tva_imprimee: versDinars(p.tva) };
        break;
      }
      case 'ttc_incoherent': {
        const montant = alea.entier(1, 100) * 1000 + alea.entier(0, 999);
        const delta = alea.booleen(0.5) && c.ttc > 2 * montant ? -montant : montant;
        p.ttc += delta;
        detail = { ttc_calcule: versDinars(c.ttc), ttc_imprime: versDinars(p.ttc) };
        break;
      }
      case 'rib_modifie':
        p.rib = nouveauRib();
        detail = { rib_reference: doc.fournisseur.rib, rib_imprime: p.rib };
        break;
      case 'matricule_invalide': {
        const m = doc.fournisseur.matricule_fiscal;
        p.matricule_fiscal = instance === 0
          ? `${m.slice(0, 6)}${m.slice(7)}/A/M/000` // un chiffre manquant
          : `${m.slice(0, 7)}/A/M/000`; // lettre clé manquante
        detail = { matricule_reference: m, matricule_imprime: p.matricule_fiscal };
        break;
      }
      case 'montant_eleve':
        detail = { ttc: versDinars(c.ttc), seuil_provisoire: versDinars(PARAMETRES.seuilValidationTtc) };
        break;
      case 'fournisseur_inconnu':
        detail = { raison_sociale: doc.fournisseur.raison_sociale };
        break;
      case 'devise_etrangere':
        detail = { devise: doc.devise };
        break;
      default:
        throw new Error(`piège inconnu : ${code}`);
    }
    doc.pieges.push({ code, detail });
  }

  function numeroter(docs) {
    const parFournisseur = new Map();
    for (const d of docs) {
      const cle = `${d.fournisseur.code}|${d.type_document}`;
      if (!parFournisseur.has(cle)) parFournisseur.set(cle, []);
      parFournisseur.get(cle).push(d);
    }
    for (const [cle, liste] of [...parFournisseur.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
      const [code, type] = cle.split('|');
      const modeleNumero = type === 'avoir' ? 'AV-{AAAA}-{N3}' : parCode.get(code).numero;
      let compteur = type === 'avoir' ? alea.entier(1, 20) : alea.entier(12, 380);
      liste.sort((a, b) => a.date_facture.localeCompare(b.date_facture));
      for (const d of liste) {
        d.numero = formaterNumero(modeleNumero, d.date_facture, compteur);
        compteur += alea.entier(1, 9); // les numéros d'autres clients s'intercalent
      }
    }
  }

  // --- Relevé bancaire ------------------------------------------------------
  function genererReleve(docs) {
    const operations = [];
    let sequence = 0;
    const ajouter = (op) => {
      const enregistree = { ...op, sequence: sequence++ };
      operations.push(enregistree);
      return enregistree;
    };
    const fin = PARAMETRES.finReleve;

    const avoirDe = new Map(docs.filter((d) => d.type_document === 'avoir').map((a) => [a.facture_origine, a]));
    const factures = docs.filter((d) => d.type_document === 'facture' && !d.derive_de);
    const payables = factures.filter((d) => d.devise === 'TND' && d.fournisseur_connu
      && !d.pieges.some((p) => PIEGES_NON_PAYES.has(p.code)) && d.date_echeance <= '2026-09-20');
    const forcees = payables.filter((d) => avoirDe.has(d));
    if (forcees.length !== avoirDe.size) throw new Error('facture avec avoir non payable');

    const ordinaires = alea.melanger(payables.filter((d) => !avoirDe.has(d) && d.pieges.length === 0));
    // Paiement en deux fois : une échéance assez ancienne pour que les deux
    // versements tombent dans la période du relevé.
    const indexPartielle = ordinaires.findIndex((d) => d.date_echeance <= '2026-08-15');
    const partielle = ordinaires.splice(indexPartielle, 1)[0];
    const ecartDoc = ordinaires.shift();
    // Virement groupé : deux factures du même fournisseur.
    let groupe = null;
    for (let i = 0; i < ordinaires.length && !groupe; i += 1) {
      const j = ordinaires.findIndex((d, k) => k > i && d.fournisseur === ordinaires[i].fournisseur);
      if (j > 0) groupe = [ordinaires[i], ordinaires[j]];
    }
    if (!groupe) throw new Error('aucune paire pour un virement groupé');
    const speciales = new Set([partielle, ecartDoc, ...groupe, ...forcees]);
    const autres = payables.filter((d) => !speciales.has(d));
    const enRetard = new Set(alea.melanger(autres).slice(0, Math.round(autres.length * 0.12)));

    const abrege = (f) => f.raison_sociale.normalize('NFD').replace(/[̀-ͯ]/g, '')
      .toUpperCase().replace(/[^A-Z0-9 -]/g, '').slice(0, 22).trim();
    const datePaiement = (d) => minDate(fin, maxDate(ajouterJours(d.date_facture, 1),
      ajouterJours(d.date_echeance, alea.entier(-3, 12))));
    const libelleVirement = (d) => alea.pondere([
      [`VIR EMIS ${abrege(d.fournisseur)} FACT ${d.numero}`, 4],
      [`VIREMENT FAVEUR ${abrege(d.fournisseur)}`, 2],
      [`VIR ${abrege(d.fournisseur)} REF ${d.numero}`, 2],
    ]);
    const commission = (date) => {
      if (alea.booleen(0.5)) ajouter({ date, libelle: 'COMMISSION SUR VIREMENT', debit: 1_200, credit: 0 });
    };

    const appariements = [];
    const payer = (docsPayes, montant, date, type, { libelle, avoirs = [], ecart = 0 } = {}) => {
      const cheque = type === 'exact' && alea.booleen(0.15);
      const op = ajouter(cheque
        ? { date: minDate(fin, ajouterJours(date, alea.entier(2, 6))), libelle: `CHEQUE N ${alea.chiffres(7)}`, debit: montant, credit: 0 }
        : { date, libelle: libelle ?? libelleVirement(docsPayes[0].doc), debit: montant, credit: 0 });
      if (!cheque) commission(op.date);
      appariements.push({ operation: op, type, mode: cheque ? 'cheque' : 'virement', docsPayes, avoirs, ecart });
      return op;
    };

    for (const d of autres) {
      if (enRetard.has(d)) continue;
      payer([{ doc: d, montant: d.imprime.ttc }], d.imprime.ttc, datePaiement(d), 'exact');
    }
    // Paiement en deux fois.
    {
      const d = partielle;
      const premier = Math.round((d.imprime.ttc * 0.4) / 1000) * 1000;
      const date1 = datePaiement(d);
      const date2 = minDate(fin, ajouterJours(date1, alea.entier(10, 24)));
      payer([{ doc: d, montant: premier }], premier, date1, 'partiel', { libelle: `VIR EMIS ${abrege(d.fournisseur)} ACOMPTE FACT ${d.numero}` });
      payer([{ doc: d, montant: d.imprime.ttc - premier }], d.imprime.ttc - premier, date2, 'partiel', { libelle: `VIR EMIS ${abrege(d.fournisseur)} SOLDE FACT ${d.numero}` });
    }
    // Paiement avec un petit écart (2,000 TND de moins).
    {
      const d = ecartDoc;
      const montant = d.imprime.ttc - 2_000;
      payer([{ doc: d, montant }], montant, datePaiement(d), 'ecart', { ecart: -2_000 });
    }
    // Virement groupé.
    {
      const [a, b] = groupe;
      const date = maxDate(datePaiement(a), datePaiement(b));
      payer([{ doc: a, montant: a.imprime.ttc }, { doc: b, montant: b.imprime.ttc }], a.imprime.ttc + b.imprime.ttc, date, 'groupe',
        { libelle: `VIR EMIS ${abrege(a.fournisseur)} FACT ${a.numero} ${b.numero}` });
    }
    // Factures payées nettes de leur avoir.
    for (const d of forcees) {
      const av = avoirDe.get(d);
      const date = maxDate(ajouterJours(av.date_facture, 2), datePaiement(d));
      const montant = d.imprime.ttc - av.imprime.ttc;
      payer([{ doc: d, montant: d.imprime.ttc }], montant, minDate(fin, date), 'net_avoir', {
        libelle: `VIR EMIS ${abrege(d.fournisseur)} FACT ${d.numero} DED AV ${av.numero}`,
        avoirs: [{ doc: av, montant: av.imprime.ttc }],
      });
    }

    // Opérations sans rapport avec les factures.
    const clients = ['CLIENT ALPHA DISTRIBUTION', 'CLIENT EPICERIE FINE NOUR', 'CLIENT HOTEL DEMO SOUSSE', 'CLIENT GROSSISTE CAP BON'];
    for (let mois = 1; mois <= 9; mois += 1) {
      const m = String(mois).padStart(2, '0');
      ajouter({ date: `2026-${m}-05`, libelle: 'PRLV LOYER LOCAUX', debit: 3_500_000, credit: 0 });
      ajouter({ date: `2026-${m}-28`, libelle: `VIREMENT SALAIRES ${nomMois(`2026-${m}-01`).toUpperCase()}`, debit: alea.entier(24_000, 30_000) * 1000, credit: 0 });
      ajouter({ date: ajouterJours(mois === 9 ? '2026-10-01' : `2026-${String(mois + 1).padStart(2, '0')}-01`, -1), libelle: 'FRAIS TENUE DE COMPTE', debit: 12_500, credit: 0 });
      for (let k = 0; k < 3; k += 1) {
        ajouter({ date: `2026-${m}-${String(alea.entier(2, 27)).padStart(2, '0')}`, libelle: `VIR RECU ${alea.choix(clients)}`, debit: 0, credit: alea.entier(8_000, 35_000) * 1000 + alea.entier(0, 999) });
      }
    }

    operations.sort((a, b) => a.date.localeCompare(b.date) || a.sequence - b.sequence);
    let solde = PARAMETRES.soldeInitial;
    operations.forEach((op, i) => {
      op.numero_ligne = i + 1;
      op.date_valeur = op.libelle.startsWith('CHEQUE') ? op.date : minDate(fin, ajouterJours(op.date, alea.entier(0, 2)));
      op.reference = `OP${op.date.replaceAll('-', '')}${String(i + 1).padStart(4, '0')}`;
      solde += op.credit - op.debit;
      op.solde = solde;
    });

    const payees = new Set(appariements.flatMap((a) => a.docsPayes.map((p) => p.doc)));
    const impayes = factures.filter((d) => !payees.has(d)).map((d) => {
      const bloquant = d.pieges.find((p) => PIEGES_NON_PAYES.has(p.code));
      let raison;
      if (bloquant) raison = bloquant.code;
      else if (d.date_echeance > fin) raison = 'non_echue';
      else if (d.date_echeance > '2026-09-20') raison = 'echeance_fin_de_periode';
      else raison = 'retard';
      return { doc: d, raison };
    });

    return {
      compte: { banque: BANQUE_FICTIVE.nom, rib: entreprise.rib, devise: 'TND' },
      debut: PARAMETRES.debutReleve,
      fin,
      soldeInitial: PARAMETRES.soldeInitial,
      soldeFinal: solde,
      operations,
      appariements,
      impayes,
    };
  }
}

// --- Fonctions utilitaires ----------------------------------------------------

function ecart(a, b) {
  return Math.round((new Date(`${b}T00:00:00Z`) - new Date(`${a}T00:00:00Z`)) / 86400000);
}

function montantEnMillimes(valeur) {
  return Math.round(valeur * 1000);
}

// TVA arrondie au centime (devise à 2 décimales), résultat en millièmes d'unité.
function tvaAuCentime(base, taux) {
  return Number(diviserArrondi(BigInt(base) * BigInt(Math.round(taux * 10000)), 10_000_000n)) * 10;
}

function formaterNumero(modele, date, compteur) {
  return modele
    .replace('{AAAA}', date.slice(0, 4))
    .replace('{AA}', date.slice(2, 4))
    .replace(/\{N(\d)\}/, (_, n) => String(compteur).padStart(Number(n), '0'));
}

// Copie d'un document sans ses références vers d'autres objets (pour structuredClone).
function sansReferences(doc) {
  const { fournisseur, facture_origine: origine, derive_de: deriveDe, pieges, ...reste } = doc;
  return reste;
}

/**
 * Montants d'un document au format de la vérité terrain (TND ou EUR, nombres décimaux).
 * @param {object} doc
 */
export function versExtraction(doc) {
  return {
    type_document: doc.type_document,
    numero: doc.numero,
    date_facture: doc.date_facture,
    date_echeance: doc.date_echeance,
    devise: doc.devise,
    fournisseur: {
      raison_sociale: doc.fournisseur.raison_sociale,
      matricule_fiscal: doc.imprime.matricule_fiscal,
      adresse: doc.fournisseur.adresse,
      rib: doc.imprime.rib,
    },
    client: {
      raison_sociale: ENTREPRISE.raison_sociale,
      matricule_fiscal: null, // complété par versVerite (dépend de l'entreprise générée)
    },
    lignes: doc.lignes.map((l) => ({
      designation: l.designation,
      quantite: l.quantiteMilliemes / 1000,
      prix_unitaire_ht: versDinars(l.prixUnitaire),
      taux_tva: l.taux,
      montant_ht: versDinars(l.ht),
    })),
    montant_ht: versDinars(doc.calcule.ht),
    montant_tva: versDinars(doc.imprime.tva),
    droit_timbre: doc.calcule.timbre === null ? null : versDinars(doc.calcule.timbre),
    montant_ttc: versDinars(doc.imprime.ttc),
    facture_origine_numero: doc.facture_origine ? doc.facture_origine.numero : null,
  };
}

/**
 * Vérité terrain d'un document (sans l'empreinte du fichier, ajoutée après rendu).
 * @param {object} doc
 * @param {object} entreprise
 */
export function versVerite(doc, entreprise) {
  const extraction = versExtraction(doc);
  extraction.client.matricule_fiscal = `${entreprise.matricule_fiscal}/A/M/000`;
  return {
    id: doc.id,
    lot: doc.lot,
    groupe: doc.groupe,
    fichier: `${doc.id}.${doc.format === 'pdf' ? 'pdf' : 'jpg'}`,
    format: doc.format,
    sha256: null,
    derive_de: doc.derive_de ? doc.derive_de.id : null,
    fournisseur_code: doc.fournisseur_connu ? doc.fournisseur.code : null,
    mise_en_page: doc.fournisseur.modele,
    extraction,
    anomalies_attendues: doc.pieges.map((p) => ({
      code: p.code,
      detail: p.detail.original ? { original: p.detail.original.id } : p.detail,
    })),
  };
}
