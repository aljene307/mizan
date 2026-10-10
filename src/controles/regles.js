// Règles de contrôle déterministes d'une facture (D-055, D-056).
// Toutes les règles s'exécutent sur chaque facture, sans s'arrêter à la
// première anomalie. Aucune ne fait appel au LLM. Le module n'importe rien
// (il est recopié dans un nœud Code, D-041) : les fonctions de montants.js,
// matricule.js et rib.js sont reçues en paramètre (« deps »).
//
// Entrée : le contexte renvoyé par la fonction SQL contexte_controles().
// Sortie : { fournisseur_id, resultats: [{ regle, version_regle, resultat,
// gravite, message, detail }] }, enregistrée par enregistrer_controles().

const VERSION_REGLES = '1';

// Statuts qui ne servent pas de référence pour les doublons (D-021) : facture
// rejetée, ou pas encore (ou jamais) extraite.
const STATUTS_HORS_DOUBLONS = new Set(['rejetee', 'erreur_extraction', 'recue', 'en_extraction']);

// Signalements de l'extraction traités par une règle dédiée.
const SIGNALEMENT_PLUSIEURS_RIB = /RIB valides dans le texte source/;
// Signalement d'entité HTML écrit par src/correctionsCode.js : chemin, valeur brute.
const ENTITE_SIGNALEE = /^(\/\S+) : entité HTML dans la réponse du modèle \(« ([\s\S]*) »\)$/;
// Bien formée : chaque « & » ouvre une entité complète (nommée ou numérique, terminée par « ; »).
const ENTITES_BIEN_FORMEES = /^(?:[^&]|&(?:#\d+|#x[0-9a-f]+|[a-z][a-z0-9]*);)*$/i;
// Champs seulement descriptifs : aucun contrôle décisif ne les utilise (D-061, D-085).
// Les désignations des lignes restent en avertissement (D-061 les range parmi les champs utilisés).
const CHAMPS_DESCRIPTIFS = /^\/(?:fournisseur\/adresse|client\/raison_sociale|client\/adresse)$/;

// Arrondi des montants : au millime en TND (3 décimales, ISO 4217) ; au
// centime pour une devise à 2 décimales (EUR, USD), soit 10 millimes.
const UNITE_ARRONDI_MILLIMES = (devise) => (devise === 'TND' ? 1 : 10);

// --- Outils ---------------------------------------------------------------------

// Règles qui ont changé depuis la version 1 du catalogue (les autres restent en 1).
const VERSIONS_PARTICULIERES = Object.freeze({ signalements_extraction: '2' });   // D-085
const resultat = (regle, res, gravite, message, detail = {}) => ({
  regle, version_regle: VERSIONS_PARTICULIERES[regle] ?? VERSION_REGLES, resultat: res, gravite, message, detail,
});
const ok = (regle, message, detail) => resultat(regle, 'ok', 'info', message, detail);
const nonApplicable = (regle, message, detail) => resultat(regle, 'non_applicable', 'info', message, detail);

/** Même normalisation que la fonction SQL normaliser_numero_facture. */
function normaliserNumero(numero) {
  return numero === null || numero === undefined ? null : String(numero).toUpperCase().replace(/\s/g, '');
}

/** Raison sociale comparable : sans accents, minuscules, ponctuation retirée. */
function normaliserNom(texte) {
  return String(texte ?? '').normalize('NFD').replace(/\p{M}/gu, '').toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
}

/** Distance d'édition (insertion, suppression, substitution). */
function distanceEdition(a, b) {
  let precedente = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i += 1) {
    const courante = [i];
    for (let j = 1; j <= b.length; j += 1) {
      courante[j] = Math.min(precedente[j] + 1, courante[j - 1] + 1, precedente[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
    precedente = courante;
  }
  return precedente[b.length];
}

/** Nombre décimal (jusqu'à 6 décimales) en millionièmes, sans flottant. */
function enMillioniemes(valeur) {
  const texte = typeof valeur === 'number' ? valeur.toFixed(6) : String(valeur).trim();
  const m = /^(-?)(\d+)(?:\.(\d+))?$/.exec(texte);
  if (!m) throw new TypeError(`nombre invalide : ${valeur}`);
  const decimales = (m[3] ?? '').replace(/0+$/, '');
  if (decimales.length > 6) throw new RangeError(`plus de 6 décimales : ${valeur}`);
  const v = BigInt(m[2]) * 1000000n + BigInt(decimales.padEnd(6, '0'));
  return m[1] === '-' ? -v : v;
}

const absent = (v) => v === null || v === undefined || v === '';

// --- Identification du fournisseur ---------------------------------------------------

/**
 * Identifie le fournisseur par trois voies indépendantes : matricule fiscal
 * (forme courte), RIB, raison sociale. Seuls le matricule reconnu, ou une
 * décision humaine (C1), rattachent la facture ; les autres voies ne font
 * que proposer.
 */
function identifier(ctx, deps) {
  const f = ctx.facture;
  const actifs = (ctx.referentiel ?? []).filter((x) => x.actif);
  const court = deps.formeCourteMatricule(f.matricule_fiscal_lu ?? '');
  const parMatricule = court ? actifs.find((x) => x.matricule_fiscal === court) ?? null : null;
  const rib = f.rib_facture ?? null;
  const parRibActif = rib ? actifs.filter((x) => x.ribs.some((r) => r.rib === rib && !r.valide_au)) : [];
  const parRibAncien = rib ? actifs.filter((x) => x.ribs.some((r) => r.rib === rib && r.valide_au)) : [];
  const nom = normaliserNom(f.raison_sociale_lue);
  const parNom = nom ? actifs.filter((x) => normaliserNom(x.raison_sociale) === nom) : [];
  const decision = f.fournisseur_source === 'decision' ? actifs.find((x) => x.id === f.fournisseur_id) ?? null : null;
  const matriculeBrut = deps.normaliserMatricule(f.matricule_fiscal_lu ?? '').split('/')[0];
  const proches = matriculeBrut
    ? actifs.filter((x) => x.matricule_fiscal !== court && distanceEdition(matriculeBrut, x.matricule_fiscal) <= 1)
    : [];
  const retenu = decision ?? parMatricule;
  // Autres fournisseurs désignés par le RIB ou par la raison sociale.
  const contradictions = retenu ? [
    ...parRibActif.filter((x) => x.id !== retenu.id).map((x) => ({ id: x.id, par: 'rib' })),
    ...parRibAncien.filter((x) => x.id !== retenu.id).map((x) => ({ id: x.id, par: 'ancien rib' })),
    ...(parNom.some((x) => x.id === retenu.id) ? [] : parNom.map((x) => ({ id: x.id, par: 'raison sociale' }))),
  ] : [];
  return { court, parMatricule, parRibActif, parNom, proches, decision, retenu, contradictions };
}

/** Fournisseurs probables, proposés à la personne qui valide (jamais rattachés). */
function fournisseursProbables(id) {
  const probables = new Map();
  const ajouter = (x, par) => {
    const p = probables.get(x.id) ?? { id: x.id, raison_sociale: x.raison_sociale, matricule_fiscal: x.matricule_fiscal, par: [] };
    p.par.push(par);
    probables.set(x.id, p);
  };
  id.parRibActif.forEach((x) => ajouter(x, 'rib'));
  id.parNom.forEach((x) => ajouter(x, 'raison sociale'));
  id.proches.forEach((x) => ajouter(x, 'matricule à un caractère près'));
  return [...probables.values()];
}

/** Clé « fournisseur » d'une autre facture : rattachement, sinon matricule lu. */
function cleFournisseurAutre(autre, ctx, deps) {
  if (autre.fournisseur_id) return `id:${autre.fournisseur_id}`;
  const court = deps.formeCourteMatricule(autre.matricule_fiscal_lu ?? '');
  if (!court) return null;
  const connu = (ctx.referentiel ?? []).find((x) => x.matricule_fiscal === court);
  return connu ? `id:${connu.id}` : `mf:${court}`;
}

// --- Règles ----------------------------------------------------------------------------

const REGLES = {
  champs_obligatoires(ctx) {
    const f = ctx.facture;
    const manquants = ['numero', 'date_facture', 'montant_ht', 'montant_tva', 'montant_ttc', 'matricule_fiscal_lu']
      .filter((c) => absent(f[c]));
    return manquants.length
      ? resultat('champs_obligatoires', 'anomalie', 'bloquant', `champs absents : ${manquants.join(', ')}`, { manquants })
      : ok('champs_obligatoires', 'champs obligatoires présents');
  },

  matricule_format(ctx, deps, id) {
    const lu = ctx.facture.matricule_fiscal_lu;
    if (absent(lu)) return nonApplicable('matricule_format', 'matricule absent (voir champs_obligatoires)');
    return id.court
      ? ok('matricule_format', 'format reconnu', { forme_courte: id.court })
      : resultat('matricule_format', 'anomalie', 'bloquant', `matricule « ${lu} » au format non reconnu (7 chiffres et une lettre attendus)`,
        { matricule_lu: lu, fournisseurs_probables: fournisseursProbables(id) });
  },

  fournisseur_inconnu(ctx, deps, id) {
    if (id.decision) return ok('fournisseur_inconnu', 'fournisseur confirmé par une décision', { fournisseur_id: id.decision.id });
    if (id.parMatricule) return ok('fournisseur_inconnu', 'fournisseur identifié par son matricule', { fournisseur_id: id.parMatricule.id });
    const probables = fournisseursProbables(id);
    return resultat('fournisseur_inconnu', 'anomalie', 'bloquant',
      probables.length
        ? `fournisseur non identifié ; probable : ${probables.map((p) => `${p.raison_sociale} (${p.par.join(', ')})`).join(' ; ')}`
        : 'fournisseur absent du référentiel : création à demander (quatre yeux)',
      { matricule_lu: ctx.facture.matricule_fiscal_lu ?? null, forme_courte: id.court, fournisseurs_probables: probables });
  },

  incoherence_identite(ctx, deps, id) {
    if (!id.retenu) return nonApplicable('incoherence_identite', 'fournisseur non identifié');
    return id.contradictions.length
      ? resultat('incoherence_identite', 'anomalie', 'bloquant',
        `le matricule désigne le fournisseur ${id.retenu.id}, mais ${id.contradictions.map((c) => `le ${c.par} désigne le fournisseur ${c.id}`).join(', ')}`,
        { fournisseur_retenu: id.retenu.id, contradictions: id.contradictions })
      : ok('incoherence_identite', 'aucune contradiction entre matricule, RIB et raison sociale');
  },

  matricule_lecture_probable(ctx, deps, id) {
    if (id.retenu) return nonApplicable('matricule_lecture_probable', 'fournisseur identifié');
    const corrobores = id.proches.filter((x) => id.parRibActif.some((y) => y.id === x.id) || id.parNom.some((y) => y.id === x.id));
    return corrobores.length
      ? resultat('matricule_lecture_probable', 'anomalie', 'avertissement',
        `matricule « ${ctx.facture.matricule_fiscal_lu} » à un caractère de ${corrobores.map((x) => x.matricule_fiscal).join(', ')}, confirmé par le RIB ou la raison sociale : lecture ou impression probablement erronée`,
        { fournisseurs_probables: corrobores.map((x) => ({ id: x.id, matricule_fiscal: x.matricule_fiscal, raison_sociale: x.raison_sociale })) })
      : ok('matricule_lecture_probable', 'aucun matricule connu très proche et corroboré');
  },

  matricule_suffixe(ctx, deps, id) {
    const lu = deps.normaliserMatricule(ctx.facture.matricule_fiscal_lu ?? '');
    const suffixe = id.court && lu.includes('/') ? lu.slice(lu.indexOf('/')) : null;
    if (!suffixe) return nonApplicable('matricule_suffixe', 'pas de suffixe lu');
    const precedents = new Set((ctx.autres_factures ?? [])
      .filter((o) => o.id < ctx.facture.id && deps.formeCourteMatricule(o.matricule_fiscal_lu ?? '') === id.court)
      .map((o) => deps.normaliserMatricule(o.matricule_fiscal_lu)).filter((m) => m.includes('/'))
      .map((m) => m.slice(m.indexOf('/'))));
    if (!precedents.size) return ok('matricule_suffixe', 'premier suffixe connu pour ce matricule', { suffixe });
    return precedents.has(suffixe)
      ? ok('matricule_suffixe', 'suffixe identique aux factures précédentes', { suffixe })
      : resultat('matricule_suffixe', 'anomalie', 'info', `suffixe « ${suffixe} » différent des factures précédentes (${[...precedents].join(', ')})`,
        { suffixe, precedents: [...precedents] });
  },

  rib_cle(ctx, deps) {
    const rib = ctx.facture.rib_facture;
    if (absent(rib)) return nonApplicable('rib_cle', 'aucun RIB sur la facture');
    return deps.ribValide(rib)
      ? ok('rib_cle', 'clé RIB valide')
      : resultat('rib_cle', 'anomalie', 'bloquant', `RIB « ${rib} » invalide (20 chiffres, clé vérifiée)`, { rib });
  },

  changement_rib(ctx, deps, id) {
    const fournisseur = id.retenu;
    if (!fournisseur) return nonApplicable('changement_rib', 'fournisseur non identifié : pas de RIB de référence');
    const actif = fournisseur.ribs.find((r) => !r.valide_au)?.rib ?? null;
    const anciens = fournisseur.ribs.filter((r) => r.valide_au).map((r) => r.rib);
    const rib = ctx.facture.rib_facture ?? null;
    const propositions = (ctx.extraction?.propositions ?? []).filter((p) => p.champ === 'fournisseur.rib');
    const ecarts = [];
    if (rib && rib !== actif) ecarts.push(anciens.includes(rib) ? `RIB « ${rib} » : ancien RIB clos du fournisseur` : `RIB « ${rib} » différent du RIB actif`);
    // Règle de Mohamed (D-053) : une proposition différente déclenche l'alerte,
    // même si le champ RIB de l'extraction est vide.
    for (const p of propositions) {
      if (p.valeur !== actif) ecarts.push(`RIB « ${p.valeur} » trouvé dans le texte, différent du RIB actif`);
    }
    const detail = { rib_facture: rib, rib_actif: actif, propositions: propositions.map((p) => p.valeur) };
    if (ecarts.length) {
      return resultat('changement_rib', 'anomalie', 'bloquant',
        `${ecarts.join(' ; ')} (RIB actif : ${actif ?? 'aucun'}) : changement à demander et vérifier (quatre yeux)`, detail);
    }
    return ok('changement_rib', rib ? 'RIB identique au RIB actif' : 'aucun RIB sur la facture : le RIB du référentiel sera utilisé', detail);
  },

  identifiants_absents_du_texte(ctx) {
    if (!ctx.extraction) return nonApplicable('identifiants_absents_du_texte', 'aucune extraction (contrôle sur données saisies)');
    const absents = (ctx.extraction.verifications_source ?? []).filter((v) => v.present === false);
    if (!absents.length) return ok('identifiants_absents_du_texte', 'identifiants présents dans le texte source');
    const rib = absents.some((v) => v.champ === 'fournisseur.rib');
    return resultat('identifiants_absents_du_texte', 'anomalie', rib ? 'bloquant' : 'avertissement',
      `absents du texte source : ${absents.map((v) => `${v.champ} « ${v.valeur} »`).join(', ')}`, { absents });
  },

  plusieurs_rib(ctx) {
    if (!ctx.extraction) return nonApplicable('plusieurs_rib', 'aucune extraction');
    const s = (ctx.extraction.signalements_code ?? []).filter((x) => SIGNALEMENT_PLUSIEURS_RIB.test(x));
    return s.length
      ? resultat('plusieurs_rib', 'anomalie', 'avertissement', `${s.join(' ; ')} : consigne possiblement insérée dans le document`, { signalements: s })
      : ok('plusieurs_rib', 'au plus un RIB valide dans le texte source');
  },

  doublon_fichier(ctx, deps, id, autres) {
    const memes = autres.filter((o) => o.fichier_sha256 === ctx.facture.fichier_sha256);
    return memes.length
      ? resultat('doublon_fichier', 'anomalie', 'bloquant', `fichier identique à la facture ${memes.map((o) => o.id).join(', ')} déjà reçue`,
        { factures: memes.map((o) => o.id) })
      : ok('doublon_fichier', 'fichier jamais reçu');
  },

  doublon_numero(ctx, deps, id, autres) {
    const f = ctx.facture;
    const cle = id.retenu ? `id:${id.retenu.id}` : (id.court ? `mf:${id.court}` : null);
    const numero = normaliserNumero(f.numero);
    if (!cle || !numero) return nonApplicable('doublon_numero', 'fournisseur ou numéro inconnu');
    const memes = autres.filter((o) => o.type_document === f.type_document && o.numero_normalise === numero
      && cleFournisseurAutre(o, ctx, deps) === cle);
    return memes.length
      ? resultat('doublon_numero', 'anomalie', 'bloquant', `${f.type_document} n° ${f.numero} déjà reçue de ce fournisseur (facture ${memes.map((o) => o.id).join(', ')})`,
        { factures: memes.map((o) => o.id) })
      : ok('doublon_numero', 'numéro jamais reçu pour ce fournisseur');
  },

  doublon_probable(ctx, deps, id, autres) {
    const f = ctx.facture;
    if (absent(f.montant_ttc) || absent(f.date_facture)) return nonApplicable('doublon_probable', 'montant ou date inconnus');
    const ttc = deps.enMillimes(f.montant_ttc);
    const cle = id.retenu ? `id:${id.retenu.id}` : (id.court ? `mf:${id.court}` : null);
    const numero = normaliserNumero(f.numero);
    const probables = autres.filter((o) => {
      if (o.fichier_sha256 === f.fichier_sha256 || absent(o.montant_ttc) || o.date_facture !== f.date_facture) return false;
      if (deps.enMillimes(o.montant_ttc) !== ttc) return false;
      const memeFournisseur = cle !== null && cleFournisseurAutre(o, ctx, deps) === cle;
      const memeNumero = numero !== null && o.numero_normalise === numero;
      return memeFournisseur !== memeNumero; // l'un sans l'autre : numéro mal lu, ou fournisseur mal identifié
    });
    return probables.length
      ? resultat('doublon_probable', 'anomalie', 'avertissement',
        `même montant TTC et même date que la facture ${probables.map((o) => `${o.id} (n° ${o.numero})`).join(', ')}`,
        { factures: probables.map((o) => o.id) })
      : ok('doublon_probable', 'aucune facture de même montant et même date');
  },

  coherence_lignes(ctx, deps) {
    const f = ctx.facture;
    const lignes = ctx.lignes ?? [];
    if (!lignes.length) return resultat('coherence_lignes', 'anomalie', 'avertissement', 'aucune ligne lue');
    if (absent(f.montant_ht)) return resultat('coherence_lignes', 'erreur', 'bloquant', 'montant HT absent');
    const tolerance = Number(ctx.parametres['tolerance.ligne_millimes']) * UNITE_ARRONDI_MILLIMES(f.devise);
    const ecarts = [];
    const toleres = [];
    let somme = 0;
    for (const l of lignes) {
      if (absent(l.montant_ht)) { ecarts.push({ ligne: l.numero_ligne, motif: 'montant absent' }); continue; }
      const montant = deps.enMillimes(l.montant_ht);
      somme += montant;
      if (absent(l.quantite) || absent(l.prix_unitaire_ht)) continue;
      const calcule = Number(deps.diviserArrondi(enMillioniemes(l.quantite) * enMillioniemes(l.prix_unitaire_ht), 1000000000n));
      const ecart = Math.abs(calcule - montant);
      if (ecart > tolerance) ecarts.push({ ligne: l.numero_ligne, calcule, imprime: montant });
      else if (ecart > 0) toleres.push({ ligne: l.numero_ligne, ecart_millimes: ecart });
    }
    const ht = deps.enMillimes(f.montant_ht);
    if (somme !== ht) ecarts.push({ motif: 'somme des lignes différente du HT', somme_lignes: somme, ht });
    const detail = { ecarts, toleres, tolerance_millimes: tolerance };
    return ecarts.length
      ? resultat('coherence_lignes', 'anomalie', 'bloquant', `${ecarts.length} écart(s) sur les lignes`, detail)
      : ok('coherence_lignes', toleres.length ? `lignes cohérentes (${toleres.length} écart(s) d'arrondi toléré(s))` : 'lignes cohérentes', detail);
  },

  coherence_tva(ctx, deps) {
    const f = ctx.facture;
    const lignes = ctx.lignes ?? [];
    if (absent(f.montant_tva)) return resultat('coherence_tva', 'erreur', 'bloquant', 'montant de TVA absent');
    if (!lignes.length || lignes.some((l) => absent(l.montant_ht) || absent(l.taux_tva))) {
      return resultat('coherence_tva', 'erreur', 'bloquant', 'lignes incomplètes : TVA impossible à recalculer');
    }
    const tauxConnus = Object.entries(ctx.config_fiscale ?? {}).filter(([cle]) => cle.startsWith('tva.')).map(([, v]) => Number(v.valeur));
    if (!tauxConnus.length) return resultat('coherence_tva', 'erreur', 'bloquant', 'aucun taux de TVA en vigueur à la date de la facture');
    const parTaux = new Map();
    for (const l of lignes) {
      const t = parTaux.get(Number(l.taux_tva)) ?? { ht: 0, lignes: 0 };
      t.ht += deps.enMillimes(l.montant_ht);
      t.lignes += 1;
      parTaux.set(Number(l.taux_tva), t);
    }
    const unite = UNITE_ARRONDI_MILLIMES(f.devise);
    const arrondir = (m) => Math.round(m / unite) * unite;
    let attendue = 0;
    let tolerance = 0;
    const detailTaux = [];
    for (const [taux, t] of parTaux) {
      const tva = arrondir(deps.montantTva(t.ht, taux));
      attendue += tva;
      tolerance += t.lignes * Number(ctx.parametres['tolerance.tva_millimes_par_ligne']) * unite;
      detailTaux.push({ taux, ht: t.ht, tva_calculee: tva, connu: tauxConnus.includes(taux) });
    }
    const imprimee = deps.enMillimes(f.montant_tva);
    const ecart = Math.abs(attendue - imprimee);
    const inconnus = detailTaux.filter((t) => !t.connu).map((t) => t.taux);
    const detail = { tva_calculee: attendue, tva_imprimee: imprimee, ecart_millimes: ecart, tolerance_millimes: tolerance, par_taux: detailTaux };
    if (ecart > tolerance) {
      return resultat('coherence_tva', 'anomalie', 'bloquant', `TVA imprimée ${imprimee / 1000} ≠ TVA recalculée ${attendue / 1000} (écart ${ecart} millimes)`, detail);
    }
    if (inconnus.length) {
      return resultat('coherence_tva', 'anomalie', 'avertissement', `taux absent(s) de la configuration fiscale : ${inconnus.join(', ')} %`, detail);
    }
    return ok('coherence_tva', ecart ? `TVA cohérente (écart d'arrondi toléré : ${ecart} millime(s))` : 'TVA cohérente', detail);
  },

  coherence_ttc(ctx, deps) {
    const f = ctx.facture;
    if ([f.montant_ht, f.montant_tva, f.montant_ttc].some(absent)) return resultat('coherence_ttc', 'erreur', 'bloquant', 'montants absents');
    const calcule = deps.enMillimes(f.montant_ht) + deps.enMillimes(f.montant_tva) + (absent(f.droit_timbre) ? 0 : deps.enMillimes(f.droit_timbre));
    const imprime = deps.enMillimes(f.montant_ttc);
    const tolerance = Number(ctx.parametres['tolerance.ttc_millimes']);
    const detail = { ttc_calcule: calcule, ttc_imprime: imprime, tolerance_millimes: tolerance };
    return Math.abs(calcule - imprime) > tolerance
      ? resultat('coherence_ttc', 'anomalie', 'bloquant', `HT + TVA + timbre = ${calcule / 1000} ≠ TTC imprimé ${imprime / 1000}`, detail)
      : ok('coherence_ttc', 'HT + TVA + timbre = TTC', detail);
  },

  droit_timbre(ctx, deps) {
    const f = ctx.facture;
    if (f.devise !== 'TND') return nonApplicable('droit_timbre', 'facture en devise étrangère (traitement fiscal hors périmètre, D-029)');
    // Exonération des avoirs non vérifiée (D-020) : aucune exigence.
    if (f.type_document === 'avoir') return nonApplicable('droit_timbre', 'avoir : exonération non vérifiée (D-020)', { droit_timbre: f.droit_timbre ?? null });
    const config = ctx.config_fiscale?.['timbre.facture'];
    if (!config) return resultat('droit_timbre', 'erreur', 'avertissement', 'droit de timbre absent de la configuration à cette date');
    const attendu = deps.enMillimes(config.valeur);
    const imprime = absent(f.droit_timbre) ? null : deps.enMillimes(f.droit_timbre);
    const detail = { attendu, imprime, a_confirmer: config.a_confirmer };
    return imprime === attendu
      ? ok('droit_timbre', 'droit de timbre conforme à la configuration (valeur à confirmer, D-020)', detail)
      : resultat('droit_timbre', 'anomalie', 'avertissement',
        imprime === null ? 'droit de timbre absent' : `droit de timbre ${imprime / 1000} ≠ ${attendu / 1000} attendu`, detail);
  },

  devise(ctx) {
    const d = ctx.facture.devise;
    return d === 'TND'
      ? ok('devise', 'facture en dinars')
      : resultat('devise', 'anomalie', 'avertissement', `facture en ${d} : montants non comparables au seuil, paiement à vérifier`, { devise: d });
  },

  dates(ctx) {
    const f = ctx.facture;
    if (absent(f.date_facture)) return nonApplicable('dates', 'date de facture absente (voir champs_obligatoires)');
    const ecarts = [];
    if (f.date_facture > ctx.aujourd_hui) ecarts.push(`date de facture ${f.date_facture} dans le futur`);
    if (!absent(f.date_echeance) && f.date_echeance < f.date_facture) ecarts.push(`échéance ${f.date_echeance} avant la date de facture`);
    return ecarts.length
      ? resultat('dates', 'anomalie', 'avertissement', ecarts.join(' ; '), { date_facture: f.date_facture, date_echeance: f.date_echeance ?? null })
      : ok('dates', 'dates plausibles');
  },

  avoir_origine(ctx, deps, id) {
    const f = ctx.facture;
    if (f.type_document !== 'avoir') return nonApplicable('avoir_origine', 'pas un avoir');
    const origine = normaliserNumero(ctx.extraction?.facture_origine_numero ?? f.facture_origine_numero ?? null);
    if (!origine) return resultat('avoir_origine', 'anomalie', 'avertissement', 'facture d\'origine non indiquée sur l\'avoir');
    const cle = id.retenu ? `id:${id.retenu.id}` : (id.court ? `mf:${id.court}` : null);
    const trouvees = (ctx.autres_factures ?? []).filter((o) => o.type_document === 'facture' && o.numero_normalise === origine
      && !STATUTS_HORS_DOUBLONS.has(o.statut) && (cle === null || cleFournisseurAutre(o, ctx, deps) === cle));
    return trouvees.length
      ? ok('avoir_origine', `facture d'origine trouvée (${trouvees.map((o) => o.id).join(', ')})`, { factures: trouvees.map((o) => o.id) })
      : resultat('avoir_origine', 'anomalie', 'avertissement', `facture d'origine n° ${origine} introuvable chez ce fournisseur`, { numero: origine });
  },

  // Version 2 (D-085, après la répétition générale, lot de développement
  // seulement) : un signalement d'entité HTML passe en « info » s'il est bien
  // formé (donc décodé exactement) et ne touche qu'un champ descriptif ; pour la
  // raison sociale du fournisseur, en plus, la valeur décodée doit figurer dans
  // le texte source (comparaison normalisée, D-050). Tout le reste (entité
  // malformée, identifiant, montant, date, autre signalement) reste un avertissement.
  signalements_extraction(ctx, deps) {
    if (!ctx.extraction) return nonApplicable('signalements_extraction', 'aucune extraction');
    const s = (ctx.extraction.signalements_code ?? []).filter((x) => !SIGNALEMENT_PLUSIEURS_RIB.test(x));
    if (!s.length) return ok('signalements_extraction', 'aucun signalement');
    const source = deps.normaliserTexte(ctx.extraction.texte_source ?? '');
    const raison = ctx.facture.raison_sociale_lue ?? '';
    const enInfo = (x) => {
      const e = ENTITE_SIGNALEE.exec(x);
      if (!e || !ENTITES_BIEN_FORMEES.test(e[2])) return false;
      if (e[1] === '/fournisseur/raison_sociale') return Boolean(raison) && source.includes(deps.normaliserTexte(raison));
      return CHAMPS_DESCRIPTIFS.test(e[1]);
    };
    const avertissements = s.filter((x) => !enInfo(x));
    return avertissements.length
      ? resultat('signalements_extraction', 'anomalie', 'avertissement', avertissements.join(' ; '),
        { signalements: s, avertissements, info: s.filter(enInfo) })
      : resultat('signalements_extraction', 'anomalie', 'info',
        `entités HTML bien formées, décodées, sur des champs descriptifs seulement : ${s.join(' ; ')}`, { signalements: s, info: s });
  },

  seuil_validation(ctx, deps) {
    const f = ctx.facture;
    if (f.devise !== 'TND') return nonApplicable('seuil_validation', 'devise étrangère : seuil non comparable (voir la règle devise)');
    if (absent(f.montant_ttc)) return nonApplicable('seuil_validation', 'TTC absent (voir champs_obligatoires)');
    const seuil = deps.enMillimes(ctx.parametres.seuil_validation_ttc);
    const ttc = deps.enMillimes(f.montant_ttc);
    return ttc > seuil
      ? resultat('seuil_validation', 'anomalie', 'validation', `TTC ${ttc / 1000} TND au-dessus du seuil de validation (${seuil / 1000} TND)`, { ttc, seuil })
      : ok('seuil_validation', 'TTC sous le seuil de validation', { ttc, seuil });
  },
};

/**
 * Exécute TOUTES les règles du catalogue sur une facture.
 * @param {object} ctx contexte de contexte_controles()
 * @param {{enMillimes, diviserArrondi, montantTva, formeCourteMatricule, normaliserMatricule, ribValide}} deps
 * @returns {{fournisseur_id: number|null, resultats: object[]}}
 */
function controlerFacture(ctx, deps) {
  const id = identifier(ctx, deps);
  const autres = (ctx.autres_factures ?? []).filter((o) => o.id < ctx.facture.id && !STATUTS_HORS_DOUBLONS.has(o.statut));
  const attendues = (ctx.regles ?? []).map((r) => r.regle);
  const inconnues = attendues.filter((r) => !REGLES[r]);
  if (inconnues.length) throw new Error(`règles du catalogue sans code : ${inconnues.join(', ')}`);
  const resultats = attendues.map((regle) => {
    try {
      return REGLES[regle](ctx, deps, id, autres);
    } catch (erreur) {
      // Une règle qui échoue ne s'arrête pas en silence : erreur bloquante.
      return resultat(regle, 'erreur', 'bloquant', `erreur pendant le contrôle : ${erreur.message}`);
    }
  });
  const certain = id.decision ?? (id.parMatricule && !id.contradictions.length ? id.parMatricule : null);
  return { fournisseur_id: certain?.id ?? null, resultats };
}

/**
 * Statut issu d'un passage : même calcul que la fonction SQL
 * enregistrer_controles (qui fait foi en base) ; sert à la mesure hors base.
 */
function statutSelonGravite(resultats) {
  const en = (g) => resultats.some((r) => (r.resultat === 'anomalie' || r.resultat === 'erreur') && r.gravite === g);
  if (en('bloquant')) return 'bloquee';
  if (en('avertissement')) return 'anomalie';
  if (en('validation')) return 'a_valider';
  return 'conforme';
}

export {
  VERSION_REGLES, REGLES, controlerFacture, statutSelonGravite, identifier, normaliserNumero, normaliserNom, distanceEdition, enMillioniemes,
};
