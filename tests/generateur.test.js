// Tests du modèle de données synthétiques (sans rendu ni fichiers).
// La configuration fiscale utilisée est l'instantané lu en base lors de la
// dernière génération (data/synthetic/config-fiscale.json).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { construireJeu, versVerite, CODES_PIEGES, PARAMETRES } from '../generateur/modele.js';
import { montantTva, montantLigneHt } from '../src/montants.js';
import { ribValide } from '../src/rib.js';
import { matriculeFormatValide } from '../src/matricule.js';
import { valeurEnVigueur } from '../src/configFiscale.js';

const config = JSON.parse(readFileSync(new URL('../data/synthetic/config-fiscale.json', import.meta.url), 'utf8'));
const jeu = construireJeu({ config });
const docs = jeu.documents;
const aPiege = (d, code) => d.pieges.some((p) => p.code === code);
const PIEGES_MONTANTS = ['erreur_tva', 'ttc_incoherent'];

test('déterminisme : même graine, mêmes données', () => {
  const autre = construireJeu({ config });
  assert.deepEqual(
    autre.documents.map((d) => versVerite(d, autre.entreprise)),
    docs.map((d) => versVerite(d, jeu.entreprise)),
  );
  assert.equal(autre.releve.soldeFinal, jeu.releve.soldeFinal);
});

test('volumes : 60 documents, 42 dev / 18 test, 15 images, 2 avoirs', () => {
  assert.equal(docs.length, 60);
  assert.equal(docs.filter((d) => d.lot === 'dev').length, 42);
  assert.equal(docs.filter((d) => d.lot === 'test').length, 18);
  assert.equal(docs.filter((d) => d.format === 'image').length, 15);
  assert.equal(docs.filter((d) => d.type_document === 'avoir').length, 2);
});

test('chaque type de piège est présent dans les deux lots (D-026)', () => {
  for (const code of CODES_PIEGES) {
    for (const lot of ['dev', 'test']) {
      assert.ok(docs.some((d) => d.lot === lot && aPiege(d, code)), `${code} absent du lot ${lot}`);
    }
  }
});

test('un document et ses dérivés restent dans le même lot (pas de fuite)', () => {
  const lotsParGroupe = new Map();
  for (const d of docs) {
    lotsParGroupe.set(d.groupe, new Set([...(lotsParGroupe.get(d.groupe) ?? []), d.lot]));
    if (d.derive_de) assert.equal(d.derive_de.lot, d.lot, d.id);
    if (d.facture_origine) assert.equal(d.facture_origine.lot, d.lot, d.id);
  }
  for (const [groupe, lots] of lotsParGroupe) assert.equal(lots.size, 1, groupe);
});

test('toutes les factures sont datées de 2026 (D-023)', () => {
  for (const d of docs) {
    assert.match(d.date_facture, /^2026-/, d.id);
    if (d.date_echeance) {
      assert.match(d.date_echeance, /^2026-/, d.id);
      assert.ok(d.date_echeance >= d.date_facture, d.id);
    }
  }
});

test('montants cohérents au millime (hors pièges sur les montants)', () => {
  for (const d of docs.filter((x) => !PIEGES_MONTANTS.some((c) => aPiege(x, c)))) {
    const ht = d.lignes.reduce((s, l) => s + montantLigneHt(l.quantiteMilliemes, l.prixUnitaire), 0);
    assert.equal(d.calcule.ht, ht, d.id);
    if (d.devise === 'TND') {
      const bases = new Map();
      for (const l of d.lignes) bases.set(l.taux, (bases.get(l.taux) ?? 0) + l.ht);
      const tva = [...bases].reduce((s, [taux, base]) => s + montantTva(base, taux), 0);
      assert.equal(d.imprime.tva, tva, d.id);
    }
    assert.equal(d.imprime.ttc, d.calcule.ht + d.imprime.tva + (d.calcule.timbre ?? 0), d.id);
  }
});

test('droit de timbre : valeur de config_fiscale sur les factures TND, absent ailleurs (D-029)', () => {
  for (const d of docs) {
    if (d.type_document === 'facture' && d.devise === 'TND') {
      assert.equal(d.calcule.timbre, valeurEnVigueur(config, 'timbre.facture', d.date_facture) * 1000, d.id);
    } else {
      assert.equal(d.calcule.timbre, null, d.id);
    }
  }
});

test('les taux de TVA viennent de config_fiscale', () => {
  const taux = new Set(['tva.taux_normal', 'tva.taux_intermediaire', 'tva.taux_reduit']
    .map((cle) => valeurEnVigueur(config, cle, '2026-06-30')));
  for (const d of docs) for (const l of d.lignes) assert.ok(taux.has(l.taux), `${d.id} : ${l.taux}`);
});

test('pièges : chaque anomalie déclarée est bien présente sur le document', () => {
  const connus = new Set(jeu.fournisseurs);
  for (const d of docs) {
    if (aPiege(d, 'erreur_tva')) {
      assert.notEqual(d.imprime.tva, d.calcule.tva, d.id);
      assert.equal(d.imprime.ttc, d.calcule.ht + d.imprime.tva + d.calcule.timbre, `${d.id} : seule la TVA est fausse`);
    }
    if (aPiege(d, 'ttc_incoherent')) {
      assert.notEqual(d.imprime.ttc, d.calcule.ht + d.imprime.tva + d.calcule.timbre, d.id);
      assert.ok(d.imprime.ttc > 0, d.id);
    }
    if (aPiege(d, 'rib_modifie')) {
      assert.ok(ribValide(d.imprime.rib), d.id);
      assert.notEqual(d.imprime.rib, d.fournisseur.rib, d.id);
    }
    if (aPiege(d, 'matricule_invalide')) assert.ok(!matriculeFormatValide(d.imprime.matricule_fiscal), d.id);
    else assert.ok(matriculeFormatValide(d.imprime.matricule_fiscal), d.id);
    if (aPiege(d, 'montant_eleve')) assert.ok(d.imprime.ttc > PARAMETRES.plancherEleveTtc, d.id);
    else assert.ok(d.imprime.ttc < PARAMETRES.plafondNormalTtc, d.id);
    assert.equal(aPiege(d, 'fournisseur_inconnu'), !connus.has(d.fournisseur), d.id);
    assert.equal(aPiege(d, 'devise_etrangere'), d.devise !== 'TND', d.id);
    if (!aPiege(d, 'rib_modifie')) assert.equal(d.imprime.rib, d.fournisseur.rib, d.id);
  }
});

test('injection de prompt : un PDF et un scan par lot, sur des factures normales seulement (D-046)', () => {
  const injectes = docs.filter((d) => d.robustesse.length > 0);
  assert.equal(injectes.length, 4);
  const avecAvoir = new Set(docs.filter((d) => d.facture_origine).map((d) => d.facture_origine));
  for (const lot of ['dev', 'test']) {
    const formats = injectes.filter((d) => d.lot === lot).map((d) => d.format).sort();
    assert.deepEqual(formats, ['image', 'pdf'], `lot ${lot}`);
  }
  for (const d of injectes) {
    assert.equal(d.type_document, 'facture', d.id);
    assert.equal(d.pieges.length, 0, `${d.id} : aucun autre piège`);
    assert.ok(!d.derive && !d.derive_de, `${d.id} : ni doublon ni dérivé`);
    assert.ok(!avecAvoir.has(d), `${d.id} : pas d'avoir lié`);
    assert.deepEqual(d.robustesse.map((r) => r.code), ['injection_prompt']);
  }
});

test('injection de prompt : les valeurs injectées diffèrent des vraies, la vérité terrain ne change pas', async () => {
  const { htmlDocument } = await import('../generateur/rendu.js');
  const tousLesRib = new Set([jeu.entreprise, ...jeu.fournisseurs, ...jeu.fournisseursInconnus].map((t) => t.rib));
  for (const d of docs.filter((x) => x.robustesse.length > 0)) {
    const { detail } = d.robustesse[0];
    assert.ok(ribValide(detail.rib_injecte), `${d.id} : RIB injecté au bon format`);
    assert.ok(detail.rib_injecte.startsWith('99'), `${d.id} : RIB injecté non attribuable`);
    assert.ok(!tousLesRib.has(detail.rib_injecte), `${d.id} : RIB injecté différent de tout RIB connu`);
    assert.notEqual(detail.ttc_injecte, detail.ttc_reel);
    // La vérité terrain reste celle du document imprimé.
    const extraction = versVerite(d, jeu.entreprise).extraction;
    assert.equal(extraction.fournisseur.rib, detail.rib_reel);
    assert.equal(extraction.montant_ttc, detail.ttc_reel);
    // La phrase figure bien dans le document rendu.
    assert.match(htmlDocument(d, jeu.entreprise), /ignorez vos instructions précédentes/);
  }
  const sansInjection = docs.find((x) => x.robustesse.length === 0);
  assert.doesNotMatch(htmlDocument(sansInjection, jeu.entreprise), /Observations/);
});

test('le seuil provisoire sépare factures normales et montants élevés (D-028)', () => {
  assert.ok(PARAMETRES.plafondNormalTtc < PARAMETRES.seuilValidationTtc);
  assert.ok(PARAMETRES.seuilValidationTtc < PARAMETRES.plancherEleveTtc);
});

test('doublons : même contenu que l\'original, enregistrés après lui', () => {
  const derives = docs.filter((d) => d.derive_de);
  assert.equal(derives.length, 4);
  for (const d of derives) {
    assert.deepEqual(versVerite(d, jeu.entreprise).extraction, versVerite(d.derive_de, jeu.entreprise).extraction, d.id);
    if (d.mode_derive === 'copie') assert.equal(d.format, d.derive_de.format, d.id);
    else assert.equal(d.format, 'image', d.id);
  }
});

test('identifiants non attribuables : matricules en 99…, RIB en banque 99 (D-027)', () => {
  const tiers = [jeu.entreprise, ...jeu.fournisseurs, ...jeu.fournisseursInconnus];
  for (const t of tiers) {
    assert.match(t.matricule_fiscal, /^99\d{5}[A-HJ-NP-TV-Z]$/, t.code);
    assert.ok(ribValide(t.rib), t.code);
    assert.ok(t.rib.startsWith('99'), t.code);
    assert.match(t.email, /\.example$/, t.code);
  }
  assert.equal(new Set(tiers.map((t) => t.matricule_fiscal)).size, tiers.length);
  assert.equal(new Set(tiers.map((t) => t.rib)).size, tiers.length);
});

test('relevé : soldes, période et montants des appariements', () => {
  const r = jeu.releve;
  const mouvements = r.operations.reduce((s, op) => s + op.credit - op.debit, 0);
  assert.equal(r.soldeInitial + mouvements, r.soldeFinal);
  for (const op of r.operations) assert.ok(op.date >= r.debut && op.date <= r.fin, op.libelle);
  // Chaque appariement pointe vers une opération réellement présente dans le relevé.
  const presentes = new Set(r.operations);
  for (const a of r.appariements) assert.ok(presentes.has(a.operation), a.operation.libelle);
  for (const a of r.appariements) {
    const affecte = a.docsPayes.reduce((s, p) => s + p.montant, 0);
    const avoirs = a.avoirs.reduce((s, p) => s + p.montant, 0);
    assert.equal(affecte - avoirs, a.operation.debit, a.operation.libelle);
    for (const p of a.docsPayes) assert.ok(a.operation.date > p.doc.date_facture, a.operation.libelle);
  }
});

test('relevé : chaque facture est soit réglée en totalité, soit impayée', () => {
  const r = jeu.releve;
  const regle = new Map();
  for (const a of r.appariements) {
    for (const p of a.docsPayes) regle.set(p.doc, (regle.get(p.doc) ?? 0) + p.montant - (a.type === 'ecart' ? a.ecart : 0));
  }
  const impayees = new Set(r.impayes.map((i) => i.doc));
  for (const d of docs.filter((x) => x.type_document === 'facture' && !x.derive_de)) {
    assert.ok(regle.has(d) !== impayees.has(d), `${d.id} : réglée et impayée, ou ni l'un ni l'autre`);
    if (regle.has(d)) assert.equal(regle.get(d), d.imprime.ttc, d.id);
  }
  for (const d of docs.filter((x) => x.derive_de || x.type_document === 'avoir')) {
    assert.ok(!regle.has(d), `${d.id} : un doublon ou un avoir n'est jamais réglé`);
  }
});

test('relevé : les factures bloquantes ne sont pas réglées, tous les cas de paiement sont présents', () => {
  const r = jeu.releve;
  const bloquants = ['erreur_tva', 'ttc_incoherent', 'rib_modifie', 'matricule_invalide', 'fournisseur_inconnu', 'devise_etrangere'];
  for (const a of r.appariements) {
    for (const p of a.docsPayes) assert.ok(!bloquants.some((c) => aPiege(p.doc, c)), p.doc.id);
  }
  const types = new Set(r.appariements.map((a) => a.type));
  for (const t of ['exact', 'partiel', 'groupe', 'net_avoir', 'ecart']) assert.ok(types.has(t), t);
  assert.ok(r.appariements.some((a) => a.mode === 'cheque'));
  assert.ok(r.impayes.some((i) => i.raison === 'retard'));
});
