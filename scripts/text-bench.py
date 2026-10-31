#!/usr/bin/env python3
"""Banc du texte (docs/BANC-TEXTE.md) : corpus privé, empreinte du flux, analyse et verdict.

Appelé par scripts/text-bench.sh :
  text-bench.py corpus --db <wispad.sqlite> --dir <dossier> (--correction | --flux)
  text-bench.py empreinte <arbre>
  text-bench.py verifie-flux --dir <dossier> --tree <arbre>
  text-bench.py prepare --run <dossier du commit>
  text-bench.py analyse --dir <dossier> --run <dossier du commit> --sha <sha> --base <tag> --base-sha <sha>
                        --base-tree <arbre>

Les dictées restent dans le dossier privé (0700, fichiers 0600) ; la sortie standard ne montre que des chiffres et
le verdict, jamais un texte dicté.
"""
import argparse
import datetime
import difflib
import hashlib
import json
import os
import pathlib
import random
import re
import sqlite3
import statistics
import sys
import tempfile
import unicodedata

SEED = 20261031
DELIVERED = ('inserted', 'paste_sent')
WORD = re.compile(r"\w[\w’'-]*")
LIST_ITEM = re.compile(r'^\s*(?:[-•*–]|\d+[.)])\s+')
SENTENCE_END = re.compile(r'[.?!…]')
FENCE = chr(96) * 3
# Morceaux de phrase isolés par une pause, comme « Ou pas. » ou « Quand il veut. » ; « Ou alors… » est une vraie
# phrase.
FRAGMENT_STARTS = {'Ou', 'Où', 'Quand', 'Dont', 'Avec', 'Sans', 'Sauf', 'Comme', 'Pour'}
FRAGMENT_EXCEPTIONS = {('Ou', 'alors'), ('Ou', 'est-ce'), ('Ou', 'même')}
# Corpus de l'étape correction : environ 50 dictées.
FRAGMENT_CASES, BECAUSE_CASES, OR_ELSE_CASES, RANDOM_CASES = 16, 5, 4, 25
# Étape flux : 24 à 30 audios de 6 à 45 s, 8 minutes au plus, soit 0,04 $ au plus à enregistrer (flux et fichier,
# 0,30 $ de l'heure).
STREAM_CUT_CASES, STREAM_CASES, STREAM_MIN_CASES = 13, 27, 24
STREAM_CUT_SECONDS, STREAM_SECONDS = 200, 480
# Ce qui, dans le code, décide des paramètres envoyés au flux et au fichier : s'ils changent, l'enregistrement de
# l'étape flux ne vaut plus et text-bench.sh demande --record.
FINGERPRINT_PARTS = [
    ('Sources/WispadCore/SpeechClient.swift', 'func endpoint() -> URL', 'case .openAI:'),
    ('Sources/WispadCore/SpeechClient.swift', 'private static func xai(fileURL', 'return try await textResponse('),
    ('Sources/WispadCore/Catalog.swift', 'public var defaultLiveModel', 'public var defaultCleanupModel'),
]
# Seuils du verdict (docs/BANC-TEXTE.md).
FIDELITY_MARGIN = 0.5
EXTRA_FRAGMENTS = 2
LATENCY_FACTOR, LATENCY_MARGIN_MS = 1.15, 50
TOKENS_FACTOR = 1.25
JUNCTION_POINTS = 5
RUNS = ('base-0', 'head-0', 'base-1', 'head-1')


def fail(message):
    print(f'text-bench.py : {message}', file=sys.stderr)
    sys.exit(1)


# --- Fichiers privés -------------------------------------------------------------------------------------------------

def private_dir(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path, 0o700)


def write_private(path, value):
    """Fichier lisible par son seul propriétaire, écrit d'un coup."""
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix='.' + path.name)
    with os.fdopen(descriptor, 'w', encoding='utf-8') as handle:
        if isinstance(value, str):
            handle.write(value)
        else:
            json.dump(value, handle, ensure_ascii=False, indent=1, sort_keys=True)
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def read_json(path):
    with open(path, encoding='utf-8') as handle:
        return json.load(handle)


# --- Texte -----------------------------------------------------------------------------------------------------------

def words(text):
    return WORD.findall(text or '')


def sentences(text):
    """Phrases d'un texte, hors puces de liste (une puce n'est pas une phrase)."""
    found = []
    for line in (text or '').splitlines():
        line = line.strip()
        if not line or LIST_ITEM.match(line):
            continue
        found += [piece for piece in re.split(r'(?<=[.?!…])\s+', line) if WORD.search(piece)]
    return found


def fold(text):
    lowered = unicodedata.normalize('NFKD', (text or '').lower().replace('’', "'"))
    return ''.join(c for c in lowered if not unicodedata.combining(c))


def folded_words(text):
    return WORD.findall(fold(text))


def edit_distance(left, right):
    if len(left) < len(right):
        left, right = right, left
    previous = list(range(len(right) + 1))
    for i, a in enumerate(left, 1):
        current = [i]
        for j, b in enumerate(right, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a != b)))
        previous = current
    return previous[-1]


def marks(text):
    """Mots et ponctuation, casse comprise : ce qu'un relecteur voit changer."""
    return re.findall(r"\w[\w’'-]*|[^\w\s]", text or '')


def is_fragment_case(text):
    found = sentences(text)
    if len(found) < 2:
        return False
    for sentence in found:
        spoken = words(sentence)
        if 1 <= len(spoken) <= 5 and spoken[0] in FRAGMENT_STARTS and tuple(spoken[:2]) not in FRAGMENT_EXCEPTIONS:
            return True
    return False


def short_ratio(text):
    found = sentences(text)
    return sum(1 for s in found if len(words(s)) <= 4) / len(found) if found else 0


# --- Corpus ----------------------------------------------------------------------------------------------------------

def open_history(path):
    if not path.exists():
        fail(f'historique introuvable : {path}')
    database = sqlite3.connect(f'file:{path}?mode=ro', uri=True)
    database.row_factory = sqlite3.Row
    return database


def previous_texts(record, by_bundle):
    """Les dictées précédentes que l'app joint à la correction (AppModel.recentDictationTexts) : même app, collées,
    moins de 30 minutes avant, au plus 5 et 1 500 caractères, de la plus récente à la plus ancienne."""
    bundle = record['target_bundle']
    if not bundle:
        return []
    now = record['created_at']
    recent = [r for r in by_bundle.get(bundle, ())
              if r['id'] != record['id'] and r['insertion_status'] in DELIVERED and 0 <= now - r['created_at'] < 30 * 60]
    recent.sort(key=lambda r: (r['created_at'], r['id']), reverse=True)
    chosen, used = [], 0
    for other in recent:
        if len(chosen) >= 5 or used >= 1500:
            break
        text = (other['final_text'] or '').strip()
        if not text:
            continue
        room = 1500 - used
        piece = text if len(text) <= room else text[:room].strip()
        if not piece:
            break
        chosen.append(piece)
        used += len(piece)
        if len(piece) < len(text):
            break
    return chosen


def build_corpus(args):
    database = open_history(pathlib.Path(args.db))
    rows = [dict(r) for r in database.execute('SELECT * FROM dictations ORDER BY created_at, id')]
    dictionary = [r[0] for r in database.execute('SELECT term FROM dictionary ORDER BY term COLLATE NOCASE')]
    by_bundle = {}
    for row in rows:
        by_bundle.setdefault(row['target_bundle'], []).append(row)
    directory = pathlib.Path(args.dir)
    private_dir(directory)
    rng = random.Random(SEED)

    def sample(pool, count):
        return pool if len(pool) <= count else rng.sample(pool, count)

    built = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')
    delivered = [r for r in rows if r['insertion_status'] in DELIVERED and (r['raw_text'] or '').strip()]
    if args.correction:
        chosen, seen = [], set()

        def take(group, pool, count):
            for row in sample([r for r in pool if r['id'] not in seen], count):
                chosen.append((group, row))
                seen.add(row['id'])

        take('fragment', [r for r in delivered if is_fragment_case(r['final_text'])], FRAGMENT_CASES)
        take('parce-que', [r for r in delivered if '. Parce que' in (r['final_text'] or '')], BECAUSE_CASES)
        take('ou-alors', [r for r in delivered if 'Ou alors' in (r['final_text'] or '')], OR_ELSE_CASES)
        take('hasard', [r for r in delivered if 8 <= len(words(r['raw_text'])) <= 220], RANDOM_CASES)
        cases = [{'id': row['id'], 'group': group, 'transcript': row['raw_text'].strip(), 'app': row['target_app'],
                  'previous': previous_texts(row, by_bundle)} for group, row in chosen]
        write_private(directory / 'correction.json', {'built': built, 'seed': SEED, 'dictionary': dictionary, 'cases': cases})
        groups = {g: sum(1 for c in cases if c['group'] == g) for g in ('fragment', 'parce-que', 'ou-alors', 'hasard')}
        print('Corpus correction : ' + ', '.join(f'{n} {g}' for g, n in groups.items())
              + f' ; {len(dictionary)} mots du dictionnaire')
    if args.flux:
        audio_dir = pathlib.Path(args.db).parent / 'Audio'

        def audio_path(row):
            stored = pathlib.Path(row['audio_path'] or '')
            return stored if stored.is_absolute() else audio_dir / stored.name

        traces = {}
        for dictation, payload in database.execute(
                'SELECT dictation_id, payload FROM dictation_traces WHERE dictation_id IS NOT NULL ORDER BY created_at, id'):
            traces[dictation] = payload

        def heard_stream(row):
            try:
                trace = json.loads(traces.get(row['id']) or '{}')
            except ValueError:
                return None
            if trace.get('transcriptSource') == 'stream':
                return row['raw_text']
            if trace.get('transcriptChoice') == 'diverged':
                return row['alternative_text']
            return None

        recorded = [r for r in delivered if r['provider'] == 'xai' and r['audio_path'] and 6 <= r['duration_seconds'] <= 45
                    and audio_path(r).exists()]
        cut = [r for r in recorded if short_ratio(heard_stream(r) or '') >= 0.25]
        chosen, total = [], 0.0
        for pool, count, limit in ((cut, STREAM_CUT_CASES, STREAM_CUT_SECONDS), (recorded, STREAM_CASES, STREAM_SECONDS)):
            for row in rng.sample(pool, len(pool)):
                if len(chosen) >= count:
                    break
                if row in chosen or total + row['duration_seconds'] > limit:
                    continue
                chosen.append(row)
                total += row['duration_seconds']
        if len(chosen) < STREAM_MIN_CASES:
            fail(f'{len(chosen)} audios utilisables seulement : il en faut {STREAM_MIN_CASES} (de 6 à 45 s, encore gardés).')
        cases = [{'id': r['id'], 'audio': str(audio_path(r)), 'seconds': r['duration_seconds'], 'app': r['target_app'],
                  'previous': previous_texts(r, by_bundle)} for r in chosen]
        write_private(directory / 'flux-entree.json', {'built': built, 'seed': SEED, 'dictionary': dictionary, 'cases': cases})
        print(f'Corpus flux : {len(cases)} audios dont {sum(1 for r in chosen if r in cut)} coupés par des pauses, '
              f"{round(total)} s d'audio")


# --- Empreinte du flux -----------------------------------------------------------------------------------------------

def fingerprint(tree):
    parts = []
    for relative, start, end in FINGERPRINT_PARTS:
        source = (pathlib.Path(tree) / relative).read_text(encoding='utf-8')
        begin = source.find(start)
        finish = source.find(end, begin + 1) if begin >= 0 else -1
        if begin < 0 or finish < 0:
            fail(f'paramètres du flux introuvables dans {relative} ({start}) : mets à jour FINGERPRINT_PARTS.')
        block = re.sub(r'(?m)^\s*//.*$', '', source[begin:finish])
        parts.append(' '.join(block.split()))
    return hashlib.sha256('\n'.join(parts).encode()).hexdigest()[:16]


def print_fingerprint(args):
    print(fingerprint(args.tree))


def verify_flux(args):
    path = pathlib.Path(args.dir) / 'flux.json'
    if not path.exists():
        fail('étape flux jamais enregistrée : lance scripts/text-bench.sh --record (environ 0,03 $).')
    if read_json(path).get('fingerprint') != fingerprint(args.tree):
        fail("les paramètres du flux ou du fichier ont changé depuis l'enregistrement : relance avec --record "
             '(environ 0,03 $).')


def prepare(args):
    """Dossier du commit, sans aucun résultat d'un banc précédent : un banc interrompu ne laisse aucun verdict."""
    run = pathlib.Path(args.run)
    private_dir(run)
    for name in RUNS:
        (run / f'{name}.json').unlink(missing_ok=True)
    for name in ('verdict.json', 'rapport.md'):
        (run / name).unlink(missing_ok=True)


# --- Analyse ---------------------------------------------------------------------------------------------------------

def mean(values):
    values = list(values)
    return sum(values) / len(values) if values else 0.0


def percentile(values, share):
    if not values:
        return None
    ordered = sorted(values)
    rank = (len(ordered) - 1) * share
    low = int(rank)
    high = min(low + 1, len(ordered) - 1)
    return ordered[low] + (ordered[high] - ordered[low]) * (rank - low)


def pieces(events):
    """Morceaux finaux du flux, dans l'ordre : segments finaux d'une parole, ou sa fin seule si elle n'en a pas."""
    found, in_utterance = [], 0
    for event in events:
        message = json.loads(event['json'])
        if message.get('type') != 'transcript.partial':
            continue
        text = (message.get('text') or '').strip()
        if not text:
            continue
        if message.get('is_final') and not message.get('speech_final'):
            found.append(text)
            in_utterance += 1
        elif message.get('speech_final'):
            if not in_utterance:
                found.append(text)
            in_utterance = 0
    return found


def words_and_breaks(text):
    folded = fold(text)
    matches = list(WORD.finditer(folded))
    breaks = []
    for index, match in enumerate(matches):
        following = matches[index + 1].start() if index + 1 < len(matches) else len(folded)
        breaks.append(bool(SENTENCE_END.search(folded[match.end():following])))
    return [m.group(0) for m in matches], breaks


def junction_decisions(parts, text):
    """Pour chaque jonction entre deux morceaux finaux : fin de phrase (True), suite (False), ou None si les deux mots
    de part et d'autre ne se retrouvent pas côte à côte dans le texte."""
    joined, starts = [], []
    for part in parts:
        if joined:
            starts.append(len(joined))
        joined += folded_words(part)
    found, breaks = words_and_breaks(text)
    mapping = {}
    for a, b, size in difflib.SequenceMatcher(None, joined, found, autojunk=False).get_matching_blocks():
        for offset in range(size):
            mapping[a + offset] = b + offset
    decisions = []
    for start in starts:
        left, right = mapping.get(start - 1), mapping.get(start)
        decisions.append(breaks[left] if left is not None and right == left + 1 else None)
    return decisions


def junction_agreement(cases, outcomes, field):
    agree = total = 0
    for outcome in outcomes:
        parts = cases.get(outcome['id'])
        if not parts or len(parts) < 2 or not outcome.get('file'):
            continue
        text = outcome['stream'] if field == 'stream' else ((outcome.get('correction') or {}).get('text') or '')
        if not text:
            continue
        for mine, reference in zip(junction_decisions(parts, text), junction_decisions(parts, outcome['file'])):
            if mine is None or reference is None:
                continue
            total += 1
            agree += mine == reference
    return (100 * agree / total if total else None), total


def run_metrics(items):
    """items : (entrée, correction) d'une étape dans un passage."""
    result = {'n': len(items), 'corrected': 0, 'fragments': 0, 'sentences': 0, 'words': 0, 'fidelity': [],
              'latencies': [], 'inputTokens': [], 'outputTokens': [], 'cost': 0.0}
    for source, correction in items:
        found = sentences(correction['text'])
        result['sentences'] += len(found)
        result['words'] += sum(len(words(s)) for s in found)
        if len(found) >= 2:
            result['fragments'] += sum(1 for s in found if len(words(s)) <= 4)
        result['fidelity'].append(edit_distance(folded_words(source), folded_words(correction['text'])))
        result['cost'] += correction['costUSD']
        if correction['corrected']:
            result['corrected'] += 1
            if correction.get('latencyMs') is not None:
                result['latencies'].append(correction['latencyMs'])
            result['inputTokens'].append(correction['inputTokens'] + correction['cachedTokens'])
            result['outputTokens'].append(correction['outputTokens'])
    return result


def version_metrics(first, second):
    latencies = first['latencies'] + second['latencies']
    return {
        'dictees': first['n'],
        'corrigees': (first['corrected'] + second['corrected']) / 2,
        'fragments': (first['fragments'] + second['fragments']) / 2,
        'motsParPhrase': mean([first['words'] / first['sentences'] if first['sentences'] else 0,
                               second['words'] / second['sentences'] if second['sentences'] else 0]),
        'fidelite': (mean(first['fidelity']) + mean(second['fidelity'])) / 2,
        'bruitFidelite': abs(mean(first['fidelity']) - mean(second['fidelity'])),
        'delaiMedianMs': statistics.median(latencies) if latencies else None,
        'delai90Ms': percentile(latencies, 0.9),
        'jetonsEntree': mean(first['inputTokens'] + second['inputTokens']),
        'jetonsSortie': mean(first['outputTokens'] + second['outputTokens']),
        'coutPour1000': (first['cost'] + second['cost']) / max(1, first['n'] + second['n']) * 1000,
    }


def step_items(report, step):
    if step == 'correction':
        return {o['id']: (o['input'], o['correction'], o['group']) for o in report['correction']}
    return {o['id']: (o['input'], o['correction'], o['source']) for o in report['stream'] if o.get('correction')}


def fr(value, digits=1):
    if value is None:
        return '—'
    return f'{value:.{digits}f}'.replace('.', ',')


def analyse(args):
    directory, run = pathlib.Path(args.dir), pathlib.Path(args.run)
    reports = {}
    for name in RUNS:
        path = run / f'{name}.json'
        if not path.exists():
            fail(f'passage {name} absent : banc incomplet, aucun verdict.')
        reports[name] = read_json(path)
    recording = read_json(directory / 'flux.json')
    parts = {case['id']: pieces(case['events']) for case in recording['cases'] if not case.get('error')}
    notes = []
    if args.base_tree and fingerprint(args.base_tree) != recording.get('fingerprint'):
        notes.append("Paramètres du flux différents dans la base : l'étape flux rejoue pour elle des réponses obtenues "
                     'avec ceux de HEAD.')
    metrics, reasons, lines, changes = {}, [], [], []
    for step in ('correction', 'flux'):
        items = {name: step_items(reports[name], step) for name in RUNS}
        common = sorted(set.intersection(*(set(v) for v in items.values())))
        per_run = {name: run_metrics([items[name][i][:2] for i in common]) for name in RUNS}
        versions = {v: version_metrics(per_run[f'{v}-0'], per_run[f'{v}-1']) for v in ('base', 'head')}
        for version in ('base', 'head'):
            versions[version]['bruitTextes'] = sum(
                1 for i in common if items[f'{version}-0'][i][1]['text'] != items[f'{version}-1'][i][1]['text'])
        gap = mean(sum(1 for i in common if items[f'base-{r}'][i][1]['text'] != items[f'head-{r}'][i][1]['text'])
                   for r in (0, 1))
        if step == 'flux':
            for version in ('base', 'head'):
                outcomes = {r: reports[f'{version}-{r}']['stream'] for r in (0, 1)}
                agreement = [junction_agreement(parts, outcomes[r], 'stream') for r in (0, 1)]
                final = [junction_agreement(parts, outcomes[r], 'final') for r in (0, 1)]
                values = [a for a, _ in agreement if a is not None]
                finals = [a for a, _ in final if a is not None]
                versions[version]['jonctions'] = mean(values) if values else None
                versions[version]['jonctionsComptees'] = agreement[0][1]
                versions[version]['jonctionsFinal'] = mean(finals) if finals else None
                versions[version]['gardeesDuFlux'] = sum(1 for o in outcomes[0] if o['source'] == 'flux')
                versions[version]['fragmentsDuFlux'] = sum(
                    sum(1 for s in sentences(o['stream']) if len(words(s)) <= 4)
                    for o in outcomes[0] if len(sentences(o['stream'])) >= 2)
        base, head = versions['base'], versions['head']
        metrics[step] = {'base': base, 'head': head, 'ecartTextes': gap}
        label = 'Correction' if step == 'correction' else 'Flux'
        noise = max(FIDELITY_MARGIN, base['bruitFidelite'], head['bruitFidelite'])
        if head['corrigees'] < base['corrigees'] - 1:
            reasons.append(f"{label} : {fr(head['corrigees'])} dictées corrigées contre {fr(base['corrigees'])} pour la base.")
        if head['fidelite'] - base['fidelite'] > noise:
            reasons.append(f"{label} : fidélité moins bonne, {fr(head['fidelite'], 2)} mots changés en moyenne contre "
                           f"{fr(base['fidelite'], 2)} (marge {fr(noise, 2)}).")
        if head['fragments'] > base['fragments'] + EXTRA_FRAGMENTS:
            reasons.append(f"{label} : {fr(head['fragments'])} phrases de 4 mots ou moins contre {fr(base['fragments'])}.")
        if base['delaiMedianMs'] is not None and (
                head['delaiMedianMs'] is None
                or head['delaiMedianMs'] > base['delaiMedianMs'] * LATENCY_FACTOR + LATENCY_MARGIN_MS):
            reasons.append(f"{label} : délai médian {fr(head['delaiMedianMs'], 0)} ms contre {fr(base['delaiMedianMs'], 0)} ms.")
        if base['jetonsEntree'] and head['jetonsEntree'] > base['jetonsEntree'] * TOKENS_FACTOR:
            reasons.append(f"{label} : {fr(head['jetonsEntree'], 0)} jetons d'entrée contre {fr(base['jetonsEntree'], 0)}.")
        if step == 'flux' and base.get('jonctions') is not None and (
                head.get('jonctions') is None or head['jonctions'] < base['jonctions'] - JUNCTION_POINTS):
            reasons.append(f"Flux : accord aux jonctions {fr(head.get('jonctions'))} % contre {fr(base['jonctions'])} %.")
        title = f'Étape {step} ({len(common)} dictées)'
        if step == 'flux':
            title += f", {head['gardeesDuFlux']} gardées du flux"
        lines += [
            title,
            f"  corrigées             base {fr(base['corrigees'])}  head {fr(head['corrigees'])}",
            f"  phrases ≤ 4 mots      base {fr(base['fragments'])}  head {fr(head['fragments'])}",
            f"  mots par phrase       base {fr(base['motsParPhrase'])}  head {fr(head['motsParPhrase'])}",
            f"  fidélité (mots)       base {fr(base['fidelite'], 2)}  head {fr(head['fidelite'], 2)}  "
            f"bruit {fr(base['bruitFidelite'], 2)} / {fr(head['bruitFidelite'], 2)}",
            f"  textes différents     base/head {fr(gap)}  bruit base {base['bruitTextes']}, head {head['bruitTextes']}",
            f"  délai médian          base {fr(base['delaiMedianMs'], 0)} ms  head {fr(head['delaiMedianMs'], 0)} ms ; "
            f"90e centile {fr(base['delai90Ms'], 0)} / {fr(head['delai90Ms'], 0)} ms",
            f"  jetons                entrée {fr(base['jetonsEntree'], 0)} / {fr(head['jetonsEntree'], 0)}, "
            f"sortie {fr(base['jetonsSortie'], 0)} / {fr(head['jetonsSortie'], 0)}",
            f"  coût pour 1 000       base {fr(base['coutPour1000'], 3)} $  head {fr(head['coutPour1000'], 3)} $",
        ]
        if step == 'flux':
            lines += [
                f"  accord aux jonctions  base {fr(base['jonctions'])} %  head {fr(head['jonctions'])} % "
                f"({base['jonctionsComptees']} jonctions) ; texte final {fr(base['jonctionsFinal'])} / {fr(head['jonctionsFinal'])} %",
                f"  phrases ≤ 4 mots du flux brut  base {base['fragmentsDuFlux']}  head {head['fragmentsDuFlux']}",
            ]
        for case in common:
            cross = mean(edit_distance(marks(items[f'base-{r}'][case][1]['text']), marks(items[f'head-{r}'][case][1]['text']))
                         for r in (0, 1))
            noise_marks = mean(edit_distance(marks(items[f'{v}-0'][case][1]['text']), marks(items[f'{v}-1'][case][1]['text']))
                               for v in ('base', 'head'))
            if cross > 0:
                changes.append((cross, noise_marks, step, case, items))
    cost = sum(reports[name].get('costUSD', 0) for name in RUNS)
    passed = not reasons
    date = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')
    verdict = {'sha': args.sha, 'base': args.base, 'baseSha': args.base_sha, 'date': date, 'pass': passed,
               'metriques': metrics, 'raisons': reasons, 'notes': notes, 'coutUSD': round(cost, 6),
               'enregistrementFlux': recording.get('recordedAt'), 'empreinteFlux': recording.get('fingerprint')}
    write_private(run / 'rapport.md', report_markdown(args, verdict, lines, changes))
    write_private(run / 'verdict.json', verdict)
    print('\n'.join(lines))
    print(f'Coût du banc : {fr(cost, 4)} $')
    for note in notes:
        print(f'Note : {note}')
    for reason in reasons:
        print(f'Rouge : {reason}')
    print(f"Verdict : {'vert' if passed else 'rouge'} ({args.sha[:12]} contre {args.base})")
    sys.exit(0 if passed else 2)


def report_markdown(args, verdict, lines, changes):
    out = [f'# Banc du texte : {args.sha[:12]} contre {args.base}', '',
           f"Rapport privé, jamais dans le dépôt. Date : {verdict['date']}. Coût : {fr(verdict['coutUSD'], 4)} $. "
           f"Étape flux enregistrée le {verdict['enregistrementFlux']}.", '',
           f"## Verdict : {'vert' if verdict['pass'] else 'rouge'}", '']
    out += [f'- {reason}' for reason in verdict['raisons']] or ['- Aucun seuil dépassé.']
    out += [f'- Note : {note}' for note in verdict['notes']]
    out += ['', '## Chiffres', '', FENCE, *lines, FENCE, '', '## Les 10 dictées qui changent le plus', '',
            "Écart : mots et ponctuation qui changent entre base et head (moyenne des deux passages) ; bruit : écart "
            "entre les deux passages d'une même version.", '']
    for rank, (cross, noise, step, case, items) in enumerate(sorted(changes, key=lambda c: (-c[0], c[3]))[:10], 1):
        source, base, kind = items['base-0'][case]
        head = items['head-0'][case][1]
        out += [f'### {rank}. {case[:8]} (étape {step}, {kind}) : écart {fr(cross)}, bruit {fr(noise)}', '',
                f'Entrée :\n\n> {quote(source)}', '', f"Base :\n\n> {quote(base['text'])}", '',
                f"Head :\n\n> {quote(head['text'])}", '']
        for name, label in (('base-1', 'Base, second passage'), ('head-1', 'Head, second passage')):
            other = items[name][case][1]['text']
            if other != items[name.replace('-1', '-0')][case][1]['text']:
                out += [f'{label} :\n\n> {quote(other)}', '']
    return '\n'.join(out) + '\n'


def quote(text):
    return (text or '').replace('\n', '\n> ')


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    corpus = commands.add_parser('corpus')
    corpus.add_argument('--db', required=True)
    corpus.add_argument('--dir', required=True)
    corpus.add_argument('--correction', action='store_true')
    corpus.add_argument('--flux', action='store_true')
    corpus.set_defaults(handler=build_corpus)
    stamp = commands.add_parser('empreinte')
    stamp.add_argument('tree')
    stamp.set_defaults(handler=print_fingerprint)
    verify = commands.add_parser('verifie-flux')
    verify.add_argument('--dir', required=True)
    verify.add_argument('--tree', required=True)
    verify.set_defaults(handler=verify_flux)
    ready = commands.add_parser('prepare')
    ready.add_argument('--run', required=True)
    ready.set_defaults(handler=prepare)
    report = commands.add_parser('analyse')
    for name in ('--dir', '--run', '--sha', '--base', '--base-sha'):
        report.add_argument(name, required=True)
    report.add_argument('--base-tree')
    report.set_defaults(handler=analyse)
    args = parser.parse_args()
    args.handler(args)


if __name__ == '__main__':
    main()
