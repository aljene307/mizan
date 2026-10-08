// Appariement des lignes d'un relevé avec les factures (D-065, B1) : règles
// déterministes, sans LLM. Entrée : le contexte de contexte_rapprochement() ;
// sortie : catégories, propositions, signalements, à enregistrer par
// enregistrer_rapprochements() (qui revérifie les garanties).
// Aucun import (recopié dans un nœud Code, D-041) : enMillimes reçu en paramètre.
//
// Confirmation automatique SEULEMENT si : cas exact, une seule facture,
// approuvée, sans écart, numéro de facture trouvé dans le libellé.

const APPROUVES = new Set(['conforme', 'validee']);

const sansAccents = (t) => String(t ?? '').normalize('NFD').replace(/\p{M}/gu, '').toUpperCase();
const normaliserNumero = (n) => (n === null || n === undefined ? null : String(n).toUpperCase().replace(/\s/g, ''));
const echapper = (t) => t.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&');

/** Le numéro figure-t-il dans le libellé, comme un mot entier ? */
function numeroDansLibelle(numero, libelle) {
  const n = normaliserNumero(numero);
  if (!n || n.length < 3) return false;
  return new RegExp(`(?<![A-Z0-9])${echapper(n)}(?![A-Z0-9])`).test(sansAccents(libelle));
}

/** Nom du bénéficiaire tel qu'une banque l'abrège : sans accents, majuscules, 22 caractères. */
function abreviation(raisonSociale) {
  return sansAccents(raisonSociale).replace(/[^A-Z0-9 -]/g, '').slice(0, 22).trim();
}

// Confusions classiques de lecture (OCR) : lettre ↔ chiffre de même forme.
const CONFUSIONS_LECTURE = Object.freeze({ O: '0', Q: '0', D: '0', I: '1', L: '1', S: '5', B: '8', Z: '2', G: '6' });
const formeCanonique = (t) => t.replace(/[OQDILSBZG]/g, (c) => CONFUSIONS_LECTURE[c]);

/**
 * Numéro du libellé proche du numéro lu sur la facture (erreur de lecture,
 * comme « 1S5260287 » lu pour « ISS260287 ») : identique une fois les
 * confusions de lecture (lettre ↔ chiffre) ramenées à une même forme.
 * Jetons d'au moins 6 caractères contenant un chiffre.
 */
function numeroProcheDansLibelle(numero, libelle) {
  const n = normaliserNumero(numero);
  if (!n || n.length < 6) return null;
  const jetons = sansAccents(libelle).split(/\s+/).filter((j) => j.length >= 6 && /\d/.test(j));
  // Seules les confusions lettre ↔ chiffre de même forme sont admises :
  // JAMAIS un chiffre pour un autre, car c'est ainsi que diffèrent deux
  // factures consécutives d'un même fournisseur (« 2026/131 » et « 2026/137 »),
  // ni un caractère en plus ou en moins (« 2026/13 » et « 2026/131 »).
  // Défaut trouvé par la mesure du 2026-10-08 (tolérance d'un caractère).
  return jetons.find((j) => j !== n && j.length === n.length && formeCanonique(j) === formeCanonique(n)) ?? null;
}

function fournisseurDansLibelle(raisonSociale, libelle) {
  const a = abreviation(raisonSociale);
  return a.length >= 6 && sansAccents(libelle).includes(a);
}

const ajouterJours = (iso, n) => new Date(Date.parse(`${iso}T00:00:00Z`) + n * 86400000).toISOString().slice(0, 10);

/**
 * @param {object} ctx contexte de contexte_rapprochement()
 * @param {{enMillimes: Function}} deps
 * @returns {{categories: object[], propositions: object[], signalements: object[]}}
 */
function rapprocher(ctx, deps) {
  const mm = (v) => deps.enMillimes(v ?? 0);
  const tolerance = mm(ctx.parametres['rapprochement.tolerance_ecart']);
  const fenetre = Number(ctx.parametres['rapprochement.fenetre_jours']);
  const categories = (ctx.categories ?? []).map((c) => ({ ...c, re: new RegExp(c.motif) }));
  const factures = (ctx.factures ?? []).filter((f) => f.montant_ttc !== null && f.devise === 'TND');
  const engage = new Map(); // montants déjà proposés dans ce passage, par facture
  const reste = (f) => mm(f.montant_ttc) - mm(f.deja_paye) - (engage.get(f.id) ?? 0);
  const engager = (f, montant) => engage.set(f.id, (engage.get(f.id) ?? 0) + montant);
  const rejetees = new Set((ctx.rejetees ?? []).map((r) => `${r.ligne_releve_id}:${[...(r.factures ?? [])].sort().join(',')}`));
  const dejaRejetee = (ligne, ids) => rejetees.has(`${ligne.id}:${[...ids].sort().join(',')}`);
  const resultat = { categories: [], propositions: [], signalements: [] };
  let plafondScore = 1; // abaissé pour une ligne dont le numéro n'est qu'approchant

  const proposer = (ligne, cas, affectations, { ecart = 0, raisons, score, numero }) => {
    const reglements = affectations.filter((a) => a.role !== 'imputation_avoir');
    if (dejaRejetee(ligne, affectations.map((a) => a.facture.id))) return false;
    const auto = cas === 'exact' && reglements.length === 1 && ecart === 0 && numero
      && APPROUVES.has(reglements[0].facture.statut) && !/^CHEQUE\b/.test(sansAccents(ligne.libelle));
    for (const a of reglements) engager(a.facture, a.montant);
    resultat.propositions.push({
      ligne_releve_id: ligne.id, cas, auto, score: Math.max(0, Math.min(plafondScore, Number(score.toFixed(4)))), raisons,
      ecart: ecart / 1000,
      affectations: affectations.map((a) => ({ facture_id: a.facture.id, montant: a.montant / 1000, role: a.role ?? 'reglement' })),
    });
    return true;
  };
  const signaler = (ligne, type, message, facture = null, detail = {}) => {
    resultat.signalements.push({ type, ligne_releve_id: ligne.id, facture_id: facture?.id ?? null, message, detail });
  };

  for (const ligne of ctx.lignes ?? []) {
    plafondScore = 1;
    const sens = mm(ligne.debit) > 0 ? 'debit' : 'credit';
    const categorie = categories.find((c) => c.sens === sens && c.re.test(ligne.libelle));
    if (categorie) { resultat.categories.push({ ligne_releve_id: ligne.id, categorie: categorie.code }); continue; }
    if (sens === 'credit') continue; // encaissement non reconnu : hors des factures fournisseurs
    const montant = mm(ligne.debit);
    const dansFenetre = (f) => !f.date_facture || (f.date_facture <= ligne.date_operation
      && ligne.date_operation <= ajouterJours(f.date_facture, fenetre));

    // 1. Numéros de facture (et d'avoir) trouvés dans le libellé. À défaut, un
    // numéro à un caractère près, pour une facture du fournisseur reconnu dans
    // le libellé (erreur de lecture probable) : proposé, jamais automatique.
    let cites = factures.filter((f) => numeroDansLibelle(f.numero, ligne.libelle));
    let lectureProbable = null;
    if (!cites.length) {
      const proches = factures.filter((f) => fournisseurDansLibelle(f.raison_sociale, ligne.libelle)
        && numeroProcheDansLibelle(f.numero, ligne.libelle));
      if (proches.length === 1) {
        cites = proches;
        plafondScore = 0.6;
        lectureProbable = `numéro « ${numeroProcheDansLibelle(proches[0].numero, ligne.libelle)} » du libellé proche du numéro lu « ${proches[0].numero} » (erreur de lecture probable)`;
      }
    }
    if (cites.length) {
      // Doublon (même numéro, même fournisseur) : la facture approuvée l'emporte.
      const groupes = new Map();
      for (const f of cites) {
        const cle = `${f.type_document}|${normaliserNumero(f.numero)}|${f.fournisseur_id ?? sansAccents(f.raison_sociale)}`;
        groupes.set(cle, [...(groupes.get(cle) ?? []), f]);
      }
      const retenues = [...groupes.values()].map((g) => g.find((f) => APPROUVES.has(f.statut)) ?? g[0]);
      const nonApprouvees = retenues.filter((f) => !APPROUVES.has(f.statut));
      for (const f of nonApprouvees) {
        signaler(ligne, 'payee_non_approuvee', `paiement de la ${f.type_document} n° ${f.numero}, au statut « ${f.statut} »`, f,
          { statut: f.statut, montant_ligne: montant / 1000, montant_ttc: f.montant_ttc });
      }
      const approuvees = retenues.filter((f) => APPROUVES.has(f.statut));
      const aRegler = approuvees.filter((f) => f.type_document === 'facture');
      const avoirs = approuvees.filter((f) => f.type_document === 'avoir');
      if (!aRegler.length) continue;
      const raisons = lectureProbable ? [lectureProbable]
        : [`numéro${aRegler.length > 1 ? 's' : ''} ${aRegler.map((f) => f.numero).join(', ')} dans le libellé`];
      // Numéro seulement approchant : jamais de confirmation automatique.
      const numero = !lectureProbable;
      if (avoirs.length && aRegler.length === 1) {
        const f = aRegler[0];
        const du = reste(f) - avoirs.reduce((s, a) => s + mm(a.montant_ttc), 0);
        proposer(ligne, 'net_avoir', [{ facture: f, montant: reste(f) }, ...avoirs.map((a) => ({ facture: a, montant: mm(a.montant_ttc), role: 'imputation_avoir' }))],
          { ecart: montant - du, raisons: [...raisons, `avoir${avoirs.length > 1 ? 's' : ''} ${avoirs.map((a) => a.numero).join(', ')} déduit${avoirs.length > 1 ? 's' : ''}`],
            score: Math.abs(montant - du) <= tolerance ? 0.9 : 0.6, numero });
        continue;
      }
      if (aRegler.length > 1) {
        const du = aRegler.reduce((s, f) => s + reste(f), 0);
        proposer(ligne, 'groupe', aRegler.map((f) => ({ facture: f, montant: reste(f) })),
          { ecart: montant - du, raisons: [...raisons, 'virement groupé'], score: Math.abs(montant - du) <= tolerance ? 0.9 : 0.6, numero });
        continue;
      }
      const f = aRegler[0];
      const du = reste(f);
      const ecart = montant - du;
      // Solde d'une facture déjà en partie payée (paiement confirmé, ou proposé
      // dans ce passage) : « partiel », jamais confirmé automatiquement.
      const dejaEntamee = mm(f.deja_paye) + (engage.get(f.id) ?? 0) > 0;
      if (ecart === 0 && dejaEntamee) {
        proposer(ligne, 'partiel', [{ facture: f, montant }], { raisons: [...raisons, `solde : ${montant / 1000} TND, après un paiement antérieur`], score: 0.85, numero });
      } else if (ecart === 0) proposer(ligne, 'exact', [{ facture: f, montant }], { raisons: [...raisons, 'montant égal au reste à payer'], score: 1, numero });
      else if (Math.abs(ecart) <= tolerance) proposer(ligne, 'ecart', [{ facture: f, montant: du }], { ecart, raisons: [...raisons, `écart de ${ecart / 1000} TND`], score: 0.8, numero });
      else if (montant < du) {
        const mot = /\bACOMPTE\b/.test(sansAccents(ligne.libelle)) ? 'acompte' : (/\bSOLDE\b/.test(sansAccents(ligne.libelle)) ? 'solde' : 'paiement partiel');
        proposer(ligne, 'partiel', [{ facture: f, montant }], { raisons: [...raisons, `${mot} : ${montant / 1000} sur ${du / 1000} TND restants`], score: 0.8, numero });
      } else proposer(ligne, 'ecart', [{ facture: f, montant: du }], { ecart, raisons: [...raisons, `montant supérieur au reste à payer de ${ecart / 1000} TND`], score: 0.5, numero });
      continue;
    }

    // 2. Sans numéro : fournisseur reconnu dans le libellé (sauf chèque), puis montant.
    const parFournisseur = factures.filter((f) => f.type_document === 'facture' && fournisseurDansLibelle(f.raison_sociale, ligne.libelle));
    const base = (parFournisseur.length ? parFournisseur : factures.filter((f) => f.type_document === 'facture')).filter(dansFenetre);
    const raisonsBase = parFournisseur.length ? [`fournisseur reconnu dans le libellé (${abreviation(parFournisseur[0].raison_sociale)})`]
      : [/^CHEQUE\b/.test(sansAccents(ligne.libelle)) ? 'chèque : ni fournisseur ni numéro dans le libellé' : 'ni fournisseur ni numéro dans le libellé'];
    const bonus = parFournisseur.length ? 0.1 : 0;
    const exacts = base.filter((f) => reste(f) === montant);
    const exactsApprouves = exacts.filter((f) => APPROUVES.has(f.statut));
    if (exactsApprouves.length) {
      // Plusieurs factures du même montant : la plus proche de son échéance, score réduit.
      const choisie = [...exactsApprouves].sort((a, b) => Math.abs(Date.parse(a.date_echeance ?? a.date_facture) - Date.parse(ligne.date_operation))
        - Math.abs(Date.parse(b.date_echeance ?? b.date_facture) - Date.parse(ligne.date_operation)))[0];
      const raisons = [...raisonsBase, 'montant égal au reste à payer'];
      if (exactsApprouves.length > 1) raisons.push(`${exactsApprouves.length} factures approuvées de même montant : la plus proche de son échéance`);
      proposer(ligne, 'exact', [{ facture: choisie, montant }], { raisons, score: 0.7 + bonus - (exactsApprouves.length > 1 ? 0.3 : 0), numero: false });
      continue;
    }
    if (exacts.length) {
      const f = exacts[0];
      signaler(ligne, 'payee_non_approuvee', `montant égal à la ${f.type_document} n° ${f.numero}, au statut « ${f.statut} »`, f,
        { statut: f.statut, montant_ligne: montant / 1000, par: 'montant' });
      continue;
    }
    const proches = base.filter((f) => APPROUVES.has(f.statut) && Math.abs(montant - reste(f)) <= tolerance);
    if (proches.length === 1) {
      const f = proches[0];
      proposer(ligne, 'ecart', [{ facture: f, montant: reste(f) }],
        { ecart: montant - reste(f), raisons: [...raisonsBase, `écart de ${(montant - reste(f)) / 1000} TND`], score: 0.5 + bonus, numero: false });
      continue;
    }
    if (parFournisseur.length) {
      // Virement groupé sans numéro : deux factures approuvées du fournisseur.
      const candidates = base.filter((f) => APPROUVES.has(f.statut) && reste(f) > 0);
      let paire = null;
      for (let i = 0; i < candidates.length && !paire; i += 1) {
        for (let j = i + 1; j < candidates.length && !paire; j += 1) {
          if (reste(candidates[i]) + reste(candidates[j]) === montant) paire = [candidates[i], candidates[j]];
        }
      }
      if (paire) {
        proposer(ligne, 'groupe', paire.map((f) => ({ facture: f, montant: reste(f) })),
          { raisons: [...raisonsBase, 'somme de deux factures du fournisseur'], score: 0.6, numero: false });
        continue;
      }
    }
    signaler(ligne, 'sortie_sans_facture', `sortie de ${montant / 1000} TND sans facture approuvée correspondante (« ${ligne.libelle} »)`,
      null, { montant: montant / 1000 });
  }
  return resultat;
}

export { APPROUVES, numeroDansLibelle, numeroProcheDansLibelle, abreviation, fournisseurDansLibelle, rapprocher };
