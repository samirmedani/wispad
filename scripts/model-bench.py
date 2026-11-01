#!/usr/bin/env python3
"""Analyse du banc des modèles (scripts/model-bench.sh) : qualité, vitesse et coût de chaque modèle de correction.

Qualité : mots mal entendus réparés (pièges) et mots justes gardés (témoins) de la référence privée mots.json ;
réécriture du texte dicté (distance d'édition en mots) ; accord avec le premier modèle, le modèle actuel.
Seuls des chiffres sortent, jamais un texte dicté.
"""
import importlib.util
import json
import pathlib
import sys

here = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('text_bench', here / 'text-bench.py')
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)

calls = json.loads(pathlib.Path(sys.argv[1]).read_text())
words_path = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else None
corpus = json.loads(words_path.read_text()) if words_path and words_path.exists() else {'cases': []}
models = list(dict.fromkeys(c['model'] for c in calls))
reference = models[0]
by = {(c['model'], c['set'], c['id']): c for c in calls}


def percentile(values, share):
    values = sorted(values)
    return values[min(len(values) - 1, int(share * len(values)))] if values else 0


lines = []
for model in models:
    mine = [c for c in calls if c['model'] == model]
    done = [c for c in mine if c['corrected']]
    latencies = [c['latencyMs'] for c in done if c.get('latencyMs') is not None]
    traps = kept = trap_total = kept_total = 0
    for case in corpus['cases']:
        call = by.get((model, 'mots', case['id']))
        text = call['text'] if call else ''
        for check in case['checks']:
            passed = bool(call) and bench.check_passes(check, text)
            if check['kind'] == 'piege':
                trap_total += 1
                traps += passed
            else:
                kept_total += 1
                kept += passed
    rewrite = [bench.edit_distance(bench.folded_words(c['input']), bench.folded_words(c['text'])) for c in done]
    same = None
    if model != reference:
        same = 0
        for c in done:
            ref = by.get((reference, c['set'], c['id']))
            if ref and ref['corrected'] and bench.folded_words(ref['text']) == bench.folded_words(c['text']):
                same += 1
    cost = sum(c['costUSD'] for c in mine)
    lines.append({
        'model': model, 'corrected': len(done), 'n': len(mine),
        'medianMs': percentile(latencies, 0.5), 'p90Ms': percentile(latencies, 0.9),
        'traps': traps, 'trapTotal': trap_total, 'kept': kept, 'keptTotal': kept_total,
        'rewrite': sum(rewrite) / len(rewrite) if rewrite else 0,
        'sameAsReference': same,
        'costPer1000': cost / len(mine) * 1000 if mine else 0,
    })
for line in lines:
    same = '' if line['sameAsReference'] is None else f" ; identique au modèle actuel {line['sameAsReference']}/{line['corrected']}"
    print(f"{line['model']} : corrigées {line['corrected']}/{line['n']} ; délai médian {line['medianMs']} ms, 90e centile "
          f"{line['p90Ms']} ms ; pièges réparés {line['traps']}/{line['trapTotal']}, témoins gardés {line['kept']}/{line['keptTotal']} ; "
          f"réécriture {line['rewrite']:.1f} mots ; {line['costPer1000']:.3f} $ pour 1 000 dictées{same}")
pathlib.Path(sys.argv[1]).with_name('synthese.json').write_text(json.dumps(lines, ensure_ascii=False, indent=1))
