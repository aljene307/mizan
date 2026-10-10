// Règles de contrôle (D-055) : une facture saine, puis chaque piège et les cas
// limites, règle par règle. Toutes les règles s'exécutent à chaque fois.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { controlerFacture, statutSelonGravite, REGLES, distanceEdition, enMillioniemes } from '../src/controles/regles.js';
import { enMillimes, diviserArrondi, montantTva } from '../src/montants.js';
import { formeCourteMatricule, normaliserMatricule } from '../src/matricule.js';
import { ribValide } from '../src/rib.js';
import { normaliserTexte } from '../src/comparaison.js';

const deps = { enMillimes, diviserArrondi, montantTva, formeCourteMatricule, normaliserMatricule, ribValide, normaliserTexte };

// Catalogue des règles, lu dans la migration (source de vérité en base).
const migration = readFileSync('db/migrations/20261006110000_controles_modele.sql', 'utf8');
const blocCatalogue = migration.slice(migration.indexOf('INSERT INTO regles_controle'), migration.indexOf('-- 4. Résultats'));
const CATALOGUE = [...blocCatalogue.matchAll(/\('([a-z_]+)', '(?:[^']|'')*', (TRUE|FALSE)\)/g)]
  .map(([, regle, derogeable]) => ({ regle, derogeable: derogeable === 'TRUE' }));

const RIB_ENNOUR = '99932238223510373255';
const RIB_MEDINA = '99463183057963294105';
const RIB_AUTRE = '99003000000000000269';
const RIB_ANCIEN = '99002000000000000120';

function contexte(modif = {}) {
  const ctx = {
    aujourd_hui: '2026-10-06',
    facture: {
      id: 10, type_document: 'facture', numero: 'FA-2026-0010', numero_normalise: 'FA-2026-0010',
      date_facture: '2026-03-01', date_echeance: '2026-03-31', devise: 'TND',
      montant_ht: 100, montant_tva: 19, droit_timbre: 1, montant_ttc: 120,
      matricule_fiscal_lu: '9979067J/A/M/000', raison_sociale_lue: 'Papeterie Ennour Bureautique',
      rib_facture: RIB_ENNOUR, fichier_sha256: 'a'.repeat(64), fournisseur_id: null, fournisseur_source: null,
    },
    lignes: [{ numero_ligne: 1, designation: 'Ramette', quantite: 4, prix_unitaire_ht: 25, taux_tva: 19, montant_ht: 100 }],
    extraction: { verifications_source: [], alertes_source: [], signalements_code: [], propositions: [], facture_origine_numero: null },
    referentiel: [
      { id: 1, raison_sociale: 'Papeterie Ennour Bureautique', matricule_fiscal: '9979067J', actif: true,
        ribs: [{ rib: RIB_ANCIEN, valide_du: '2025-01-01', valide_au: '2026-01-01' }, { rib: RIB_ENNOUR, valide_du: '2026-01-01', valide_au: null }] },
      { id: 2, raison_sociale: 'Médina Connect Télécom', matricule_fiscal: '9917566L', actif: true,
        ribs: [{ rib: RIB_MEDINA, valide_du: '2026-01-01', valide_au: null }] },
    ],
    autres_factures: [],
    config_fiscale: {
      'tva.taux_normal': { valeur: 19 }, 'tva.taux_intermediaire': { valeur: 13 }, 'tva.taux_reduit': { valeur: 7 },
      'timbre.facture': { valeur: 1, a_confirmer: true },
    },
    parametres: {
      seuil_validation_ttc: 20000, 'tolerance.ttc_millimes': 0, 'tolerance.tva_millimes_par_ligne': 1,
      'tolerance.ligne_millimes': 1, 'justification.longueur_min': 15,
    },
    regles: CATALOGUE,
  };
  return { ...ctx, ...modif, facture: { ...ctx.facture, ...(modif.facture ?? {}) } };
}

const controler = (modif) => {
  const r = controlerFacture(contexte(modif), deps);
  return { ...r, statut: statutSelonGravite(r.resultats), regle: (nom) => r.resultats.find((x) => x.regle === nom) };
};
const alertes = (r) => r.resultats.filter((x) => ['anomalie', 'erreur'].includes(x.resultat) && x.gravite !== 'info').map((x) => x.regle).sort();
const autre = (modif) => ({
  id: 5, statut: 'conforme', fournisseur_id: 1, matricule_fiscal_lu: '9979067J/A/M/000', type_document: 'facture',
  numero: 'FA-2026-0001', numero_normalise: 'FA-2026-0001', date_facture: '2026-02-01', montant_ttc: 50, fichier_sha256: 'b'.repeat(64),
  ...modif,
});

// --- Catalogue -----------------------------------------------------------------------

test('catalogue : 22 règles, chacune codée, dont 4 non dérogeables (D-056)', () => {
  assert.equal(CATALOGUE.length, 22);
  assert.deepEqual(CATALOGUE.map((r) => r.regle).sort(), Object.keys(REGLES).sort(), 'code et migration identiques');
  assert.deepEqual(CATALOGUE.filter((r) => !r.derogeable).map((r) => r.regle).sort(),
    ['changement_rib', 'doublon_fichier', 'doublon_numero', 'incoherence_identite']);
});

test('facture saine : toutes les règles exécutées, aucune alerte, fournisseur rattaché, « conforme »', () => {
  const r = controler();
  assert.equal(r.resultats.length, 22);
  assert.deepEqual(alertes(r), []);
  assert.equal(r.fournisseur_id, 1);
  assert.equal(r.statut, 'conforme');
  // Version par règle : signalements_extraction passe en 2 (D-085), les autres restent en 1.
  assert.ok(r.resultats.every((x) => x.version_regle === (x.regle === 'signalements_extraction' ? '2' : '1') && typeof x.message === 'string'));
});

test('toutes les règles s\'exécutent : plusieurs anomalies sont toutes rapportées', () => {
  const r = controler({ facture: { montant_tva: 30, montant_ttc: 500, devise: 'EUR', rib_facture: RIB_AUTRE } });
  assert.deepEqual(alertes(r), ['changement_rib', 'coherence_ttc', 'coherence_tva', 'devise']);
});

test('une règle qui échoue est une erreur bloquante, les autres s\'exécutent', () => {
  const r = controler({ facture: { montant_ttc: 'abc' } });
  assert.equal(r.regle('coherence_ttc').resultat, 'erreur');
  assert.equal(r.regle('coherence_ttc').gravite, 'bloquant');
  assert.equal(r.resultats.length, 22);
});

test('le catalogue fait foi : une règle inconnue du code arrête le contrôle', () => {
  assert.throws(() => controlerFacture(contexte({ regles: [...CATALOGUE, { regle: 'nouvelle' }] }), deps), /sans code : nouvelle/);
});

// --- Identification du fournisseur ----------------------------------------------------

test('matricule mal formé (piège D011) : bloqué, fournisseur probable proposé, jamais rattaché', () => {
  const r = controler({ facture: { matricule_fiscal_lu: '991756L/A/M/000', raison_sociale_lue: 'Médina Connect Télécom', rib_facture: RIB_MEDINA } });
  assert.equal(r.regle('matricule_format').gravite, 'bloquant');
  assert.equal(r.regle('fournisseur_inconnu').resultat, 'anomalie');
  const probable = r.regle('fournisseur_inconnu').detail.fournisseurs_probables;
  assert.deepEqual(probable.map((p) => [p.id, p.par]), [[2, ['rib', 'raison sociale', 'matricule à un caractère près']]]);
  assert.equal(r.regle('matricule_lecture_probable').gravite, 'avertissement');
  assert.equal(r.fournisseur_id, null, 'C1 : proposé seulement');
  assert.equal(r.statut, 'bloquee');
});

test('fournisseur inconnu (piège D008) : bloqué, aucun probable, pas de comparaison de RIB', () => {
  const r = controler({ facture: { matricule_fiscal_lu: '9900001A/A/M/000', raison_sociale_lue: 'Djerba Express', rib_facture: RIB_AUTRE } });
  assert.equal(r.regle('fournisseur_inconnu').gravite, 'bloquant');
  assert.deepEqual(r.regle('fournisseur_inconnu').detail.fournisseurs_probables, []);
  assert.equal(r.regle('changement_rib').resultat, 'non_applicable');
  assert.equal(r.regle('matricule_lecture_probable').resultat, 'ok', 'aucun matricule proche corroboré');
});

test('incohérence d\'identité : matricule du fournisseur 1, RIB du fournisseur 2 → bloquant, rien de rattaché', () => {
  const r = controler({ facture: { rib_facture: RIB_MEDINA } });
  assert.equal(r.regle('incoherence_identite').gravite, 'bloquant');
  assert.deepEqual(r.regle('incoherence_identite').detail.contradictions, [{ id: 2, par: 'rib' }]);
  assert.equal(r.fournisseur_id, null);
  const nom = controler({ facture: { raison_sociale_lue: 'MEDINA CONNECT TELECOM' } });
  assert.deepEqual(nom.regle('incoherence_identite').detail.contradictions, [{ id: 2, par: 'raison sociale' }],
    'raison sociale d\'un autre fournisseur (accents et casse ignorés)');
});

test('lecture probablement erronée d\'un matricule valide mais inconnu, corroborée par le RIB → avertissement', () => {
  const r = controler({ facture: { matricule_fiscal_lu: '9979061J/A/M/000' } });
  assert.equal(r.regle('matricule_format').resultat, 'ok');
  assert.equal(r.regle('matricule_lecture_probable').gravite, 'avertissement');
  assert.equal(r.regle('fournisseur_inconnu').detail.fournisseurs_probables[0].id, 1);
});

test('suffixe du matricule différent des factures précédentes (cas D001) : info seulement', () => {
  const r = controler({ facture: { matricule_fiscal_lu: '9979067J/A/M/008' }, autres_factures: [autre({})] });
  assert.equal(r.regle('matricule_suffixe').resultat, 'anomalie');
  assert.equal(r.regle('matricule_suffixe').gravite, 'info');
  assert.equal(r.statut, 'conforme', 'une info ne change pas le statut');
  assert.equal(r.fournisseur_id, 1, 'la forme courte, juste, identifie le fournisseur');
});

test('fournisseur confirmé par une décision : conservé, sans effacer le défaut du document', () => {
  const r = controler({ facture: { matricule_fiscal_lu: '991756L/A/M/000', rib_facture: RIB_MEDINA, raison_sociale_lue: 'Médina Connect Télécom',
    fournisseur_id: 2, fournisseur_source: 'decision' } });
  assert.equal(r.fournisseur_id, 2);
  assert.equal(r.regle('fournisseur_inconnu').resultat, 'ok');
  assert.equal(r.regle('changement_rib').resultat, 'ok');
  assert.equal(r.regle('matricule_format').gravite, 'bloquant', 'le matricule imprimé reste mal formé : dérogation nécessaire');
});

// --- RIB ----------------------------------------------------------------------------------

test('changement de RIB (piège D030) : RIB différent du RIB actif → bloquant', () => {
  const r = controler({ facture: { rib_facture: RIB_AUTRE } });
  assert.equal(r.regle('changement_rib').gravite, 'bloquant');
  assert.equal(r.regle('changement_rib').detail.rib_actif, RIB_ENNOUR);
  assert.equal(r.regle('incoherence_identite').resultat, 'ok', 'RIB inconnu : pas une contradiction');
});

test('ancien RIB clos du même fournisseur → bloquant, message distinct', () => {
  const r = controler({ facture: { rib_facture: RIB_ANCIEN } });
  assert.match(r.regle('changement_rib').message, /ancien RIB clos/);
});

test('règle de Mohamed (D-053) : proposition différente avec un RIB vide → alerte de changement de RIB', () => {
  const r = controler({ facture: { rib_facture: null },
    extraction: { ...contexte().extraction, propositions: [{ champ: 'fournisseur.rib', valeur: RIB_AUTRE }] } });
  assert.equal(r.regle('changement_rib').gravite, 'bloquant');
  assert.match(r.regle('changement_rib').message, /trouvé dans le texte/);
  const egale = controler({ facture: { rib_facture: null },
    extraction: { ...contexte().extraction, propositions: [{ champ: 'fournisseur.rib', valeur: RIB_ENNOUR }] } });
  assert.equal(egale.regle('changement_rib').resultat, 'ok');
  assert.equal(controler({ facture: { rib_facture: null } }).regle('changement_rib').resultat, 'ok', 'sans RIB : celui du référentiel');
});

test('clé RIB fausse → bloquant ; RIB absent → non applicable', () => {
  assert.equal(controler({ facture: { rib_facture: '99932238223510373256' } }).regle('rib_cle').gravite, 'bloquant');
  assert.equal(controler({ facture: { rib_facture: null } }).regle('rib_cle').resultat, 'non_applicable');
});

test('identifiants absents du texte (D-047) : RIB → bloquant, autre identifiant → avertissement', () => {
  const ext = (champ) => ({ ...contexte().extraction, verifications_source: [{ champ, valeur: 'x', present: false }] });
  assert.equal(controler({ extraction: ext('fournisseur.rib') }).regle('identifiants_absents_du_texte').gravite, 'bloquant');
  assert.equal(controler({ extraction: ext('numero') }).regle('identifiants_absents_du_texte').gravite, 'avertissement');
  assert.equal(controler({ extraction: null }).regle('identifiants_absents_du_texte').resultat, 'non_applicable');
});

test('signalements : plusieurs RIB → plusieurs_rib ; les autres → signalements_extraction', () => {
  const r = controler({ extraction: { ...contexte().extraction, signalements_code: [
    'fournisseur.rib : 2 RIB valides dans le texte source (a, b)', '/numero : entité HTML dans la réponse du modèle'] } });
  assert.equal(r.regle('plusieurs_rib').gravite, 'avertissement');
  assert.deepEqual(r.regle('signalements_extraction').detail.signalements, ['/numero : entité HTML dans la réponse du modèle']);
});

test('signalements d\'entités, règle v2 (D-085) : « info » seulement si bien formée, champ descriptif, raison sociale présente dans le texte', () => {
  const ent = (chemin, valeur) => `${chemin} : entité HTML dans la réponse du modèle (« ${valeur} »)`;
  const avec = (signalements, texte = 'FACTURE Papeterie Ennour Bureautique 9979067J') => controler({
    extraction: { ...contexte().extraction, signalements_code: signalements, texte_source: texte } }).regle('signalements_extraction');
  const descriptifs = [ent('/fournisseur/adresse', 'Avenue de l\'Environnement, 9000 B&#233;ja'),
    ent('/client/raison_sociale', 'Soci&eacute;t&eacute; D&eacute;mo Mizan SARL')];
  let r = avec(descriptifs);
  assert.deepEqual([r.resultat, r.gravite, r.version_regle], ['anomalie', 'info', '2'], 'bien formées, champs descriptifs');
  assert.equal(controler({ extraction: { ...contexte().extraction, signalements_code: descriptifs } }).statut, 'conforme', 'une « info » ne change pas le statut');
  r = avec([ent('/fournisseur/raison_sociale', 'Papeterie Ennour Bureauti&#113;ue')]);
  assert.equal(r.gravite, 'info', 'raison sociale décodée présente dans le texte source (comparaison normalisée)');
  r = avec([ent('/fournisseur/raison_sociale', 'Papeterie Ennour Bureauti&#113;ue')], 'FACTURE Papeterie Ennour Burotique');
  assert.equal(r.gravite, 'avertissement', 'raison sociale absente du texte source : avertissement');
  assert.equal(avec([ent('/fournisseur/raison_sociale', 'x&#113;')], null).gravite, 'avertissement', 'sans texte source : avertissement');
  r = avec([ent('/fournisseur/adresse', 'Avenue de l\'Environnement, 9000 B&#2333ja')]);
  assert.equal(r.gravite, 'avertissement', 'entité malformée (sans « ; ») : avertissement, même sur un champ descriptif');
  for (const chemin of ['/numero', '/fournisseur/matricule_fiscal', '/fournisseur/rib', '/lignes/0/designation']) {
    assert.equal(avec([ent(chemin, 'A&#66;C')]).gravite, 'avertissement', `${chemin} : avertissement`);
  }
  r = avec([...descriptifs, ent('/numero', 'F&#45;1')]);
  assert.deepEqual([r.gravite, r.detail.avertissements.length, r.detail.info.length], ['avertissement', 1, 2], 'un seul champ décisif suffit');
  assert.equal(avec(['/numero : entité HTML dans la réponse du modèle']).gravite, 'avertissement', 'signalement au format inattendu : avertissement');
});

// --- Doublons -------------------------------------------------------------------------------

test('doublon de fichier (piège D035) : même empreinte qu\'une facture reçue avant → bloquant', () => {
  const r = controler({ autres_factures: [autre({ fichier_sha256: 'a'.repeat(64), numero: 'X', numero_normalise: 'X' })] });
  assert.equal(r.regle('doublon_fichier').gravite, 'bloquant');
  const apres = controler({ autres_factures: [autre({ id: 11, fichier_sha256: 'a'.repeat(64) })] });
  assert.equal(apres.regle('doublon_fichier').resultat, 'ok', 'c\'est la facture reçue en second qui est marquée');
  const rejetee = controler({ autres_factures: [autre({ statut: 'rejetee', fichier_sha256: 'a'.repeat(64) })] });
  assert.equal(rejetee.regle('doublon_fichier').resultat, 'ok', 'une facture rejetée ne sert pas de référence');
});

test('doublon de numéro (piège D050) : même fournisseur, même type, numéro normalisé → bloquant', () => {
  const r = controler({ autres_factures: [autre({ fournisseur_id: null, numero: 'fa-2026-0010 ', numero_normalise: 'FA-2026-0010' })] });
  assert.equal(r.regle('doublon_numero').gravite, 'bloquant', 'fournisseur reconnu par le matricule lu de l\'autre facture');
  const autreFournisseur = controler({ autres_factures: [autre({ fournisseur_id: 2, numero_normalise: 'FA-2026-0010' })] });
  assert.equal(autreFournisseur.regle('doublon_numero').resultat, 'ok');
  const avoir = controler({ autres_factures: [autre({ type_document: 'avoir', numero_normalise: 'FA-2026-0010' })] });
  assert.equal(avoir.regle('doublon_numero').resultat, 'ok', 'un avoir et une facture peuvent partager un numéro');
});

test('doublon probable : même TTC et même date, numéro différent (mal lu) ou autre fournisseur → avertissement', () => {
  const numeroMalLu = controler({ autres_factures: [autre({ date_facture: '2026-03-01', montant_ttc: 120, numero_normalise: 'FA-2O26-0010' })] });
  assert.equal(numeroMalLu.regle('doublon_probable').gravite, 'avertissement');
  const autreFournisseur = controler({ autres_factures: [autre({ fournisseur_id: 2, date_facture: '2026-03-01', montant_ttc: 120, numero_normalise: 'FA-2026-0010' })] });
  assert.equal(autreFournisseur.regle('doublon_probable').gravite, 'avertissement');
  const vraiDoublon = controler({ autres_factures: [autre({ date_facture: '2026-03-01', montant_ttc: 120, numero_normalise: 'FA-2026-0010' })] });
  assert.equal(vraiDoublon.regle('doublon_probable').resultat, 'ok', 'déjà couvert par doublon_numero');
});

// --- Montants -------------------------------------------------------------------------------

test('lignes : quantité × prix, tolérance d\'un millime lue dans les paramètres', () => {
  // 3 × 0,333 = 0,999 pour 1,000 imprimé : un millime d'écart (prix unitaire arrondi).
  const tiers = { numero_ligne: 1, quantite: 3, prix_unitaire_ht: 0.333, taux_tva: 19, montant_ht: 1 };
  const r = controler({ lignes: [tiers], facture: { montant_ht: 1, montant_tva: 0.19, montant_ttc: 2.19 } });
  assert.equal(r.regle('coherence_lignes').resultat, 'ok');
  assert.equal(r.regle('coherence_lignes').detail.toleres.length, 1, 'écart toléré tracé');
  const ecart = controler({ lignes: [{ ...tiers, montant_ht: 1.002 }], facture: { montant_ht: 1.002, montant_tva: 0.19, montant_ttc: 2.192 } });
  assert.equal(ecart.regle('coherence_lignes').gravite, 'bloquant');
  const large = controler({ lignes: [{ ...tiers, montant_ht: 1.002 }], facture: { montant_ht: 1.002, montant_tva: 0.19, montant_ttc: 2.192 },
    parametres: { ...contexte().parametres, 'tolerance.ligne_millimes': 3 } });
  assert.equal(large.regle('coherence_lignes').resultat, 'ok', 'la tolérance vient de la table de configuration');
  const somme = controler({ facture: { montant_ht: 101, montant_ttc: 121 } });
  assert.match(JSON.stringify(somme.regle('coherence_lignes').detail.ecarts), /somme des lignes/);
});

test('TVA (piège D051) : écart au-delà de la tolérance → bloquant ; arrondi ligne à ligne toléré', () => {
  assert.equal(controler({ facture: { montant_tva: 68, montant_ttc: 169 } }).regle('coherence_tva').gravite, 'bloquant');
  // 3 lignes de 0,333 à 19 % : TVA par taux 0,190 ; ligne à ligne 3 × 0,063 = 0,189.
  const lignes = [1, 2, 3].map((n) => ({ numero_ligne: n, quantite: 1, prix_unitaire_ht: n === 3 ? 0.334 : 0.333, taux_tva: 19, montant_ht: n === 3 ? 0.334 : 0.333 }));
  const r = controler({ lignes, facture: { montant_ht: 1, montant_tva: 0.189, montant_ttc: 2.189 } });
  assert.equal(r.regle('coherence_tva').resultat, 'ok');
  assert.equal(r.regle('coherence_tva').detail.tolerance_millimes, 3, 'un millime par ligne à ce taux');
});

test('TVA : taux absent de la configuration → avertissement ; plusieurs taux recalculés séparément', () => {
  const inconnu = controler({ lignes: [{ ...contexte().lignes[0], taux_tva: 10 }], facture: { montant_tva: 10, montant_ttc: 111 } });
  assert.equal(inconnu.regle('coherence_tva').gravite, 'avertissement');
  const deux = controler({
    lignes: [{ numero_ligne: 1, quantite: 1, prix_unitaire_ht: 100, taux_tva: 19, montant_ht: 100 },
      { numero_ligne: 2, quantite: 1, prix_unitaire_ht: 50, taux_tva: 7, montant_ht: 50 }],
    facture: { montant_ht: 150, montant_tva: 22.5, montant_ttc: 173.5 } });
  assert.equal(deux.regle('coherence_tva').resultat, 'ok');
});

test('TTC (piège D010) : HT + TVA + timbre ≠ TTC → bloquant, au millime près', () => {
  assert.equal(controler({ facture: { montant_ttc: 120.001 } }).regle('coherence_ttc').gravite, 'bloquant');
  assert.equal(controler({ facture: { droit_timbre: null, montant_ttc: 119 } }).regle('coherence_ttc').resultat, 'ok');
});

test('droit de timbre : absent ou différent → avertissement ; avoir et devise étrangère → non applicable', () => {
  assert.equal(controler({ facture: { droit_timbre: null, montant_ttc: 119 } }).regle('droit_timbre').gravite, 'avertissement');
  assert.equal(controler({ facture: { type_document: 'avoir', droit_timbre: null, montant_ttc: 119 } }).regle('droit_timbre').resultat, 'non_applicable');
  assert.equal(controler({ facture: { devise: 'EUR', droit_timbre: null, montant_ttc: 119 } }).regle('droit_timbre').resultat, 'non_applicable');
});

// --- Devise, dates, avoirs, seuil ------------------------------------------------------------

test('devise étrangère (piège D045) : avertissement, TVA arrondie au centime, seuil non comparable', () => {
  const r = controler({ facture: { devise: 'EUR', droit_timbre: null, montant_tva: 19, montant_ttc: 119 } });
  assert.equal(r.regle('devise').gravite, 'avertissement');
  assert.equal(r.regle('seuil_validation').resultat, 'non_applicable');
  assert.equal(r.statut, 'anomalie');
  const centimes = controler({ facture: { devise: 'EUR', droit_timbre: null, montant_ht: 33.33, montant_tva: 6.33, montant_ttc: 39.66 },
    lignes: [{ numero_ligne: 1, quantite: 1, prix_unitaire_ht: 33.33, taux_tva: 19, montant_ht: 33.33 }] });
  assert.equal(centimes.regle('coherence_tva').resultat, 'ok', '6,3327 arrondi au centime : 6,33');
});

test('dates : facture dans le futur ou échéance avant la date → avertissement', () => {
  assert.equal(controler({ facture: { date_facture: '2026-12-01', date_echeance: '2026-12-31' } }).regle('dates').gravite, 'avertissement');
  assert.equal(controler({ facture: { date_echeance: '2026-02-01' } }).regle('dates').gravite, 'avertissement');
});

test('avoir : facture d\'origine trouvée chez le même fournisseur, sinon avertissement', () => {
  const avoir = { type_document: 'avoir', droit_timbre: null, montant_ttc: 119 };
  const ext = { ...contexte().extraction, facture_origine_numero: 'FA-2026-0001' };
  assert.equal(controler({ facture: avoir, extraction: ext, autres_factures: [autre({})] }).regle('avoir_origine').resultat, 'ok');
  assert.equal(controler({ facture: avoir, extraction: ext, autres_factures: [autre({ fournisseur_id: 2 })] }).regle('avoir_origine').gravite, 'avertissement');
  assert.equal(controler({ facture: avoir }).regle('avoir_origine').gravite, 'avertissement', 'origine non indiquée');
});

test('seuil (piège D028) : au-dessus → « validation », statut « a_valider » ; seuil lu dans les paramètres', () => {
  const lignes = [{ numero_ligne: 1, quantite: 1, prix_unitaire_ht: 30000, taux_tva: 19, montant_ht: 30000 }];
  const facture = { montant_ht: 30000, montant_tva: 5700, montant_ttc: 35701 };
  const r = controler({ lignes, facture });
  assert.equal(r.regle('seuil_validation').gravite, 'validation');
  assert.equal(r.statut, 'a_valider');
  const haut = controler({ lignes, facture, parametres: { ...contexte().parametres, seuil_validation_ttc: 50000 } });
  assert.equal(haut.statut, 'conforme');
});

test('statut : la gravité la plus forte l\'emporte (même calcul que enregistrer_controles)', () => {
  const r = (gravites) => statutSelonGravite(gravites.map((gravite) => ({ resultat: 'anomalie', gravite })));
  assert.equal(r(['validation', 'avertissement', 'bloquant']), 'bloquee');
  assert.equal(r(['validation', 'avertissement']), 'anomalie');
  assert.equal(r(['validation', 'info']), 'a_valider');
  assert.equal(r(['info']), 'conforme');
});

test('outils : distance d\'édition et décimaux sans flottant', () => {
  assert.equal(distanceEdition('991756L', '9917566L'), 1);
  assert.equal(distanceEdition('9979067J', '9979067J'), 0);
  assert.equal(enMillioniemes('0.333333'), 333333n);
  assert.throws(() => enMillioniemes('0.1234567'), /6 décimales/);
});
