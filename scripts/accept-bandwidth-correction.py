#!/usr/bin/env python3
"""Acceptance from actual renderer/stamp and rate traces; no policy internals."""
import argparse
import json
from pathlib import Path


def evaluate(path):
    trace = json.loads(path.read_text())
    rows = trace['rows']
    duration = trace['durationSeconds']
    recovery = next(p for p in trace['summary'] if p['phase'] == 'recovery')['startSeconds']
    recovery_cap = next((r for r in rows if r['stage'] == 'cap' and r['t'] >= 0 and r['requestedBps'] == 4000000), None)
    command_time = (recovery_cap['requestedAtUptimeSeconds'] - trace['clockAnchor']['uptimeSeconds']
                    if recovery_cap and 'requestedAtUptimeSeconds' in recovery_cap else recovery)
    rates = [r for r in rows if r['stage'] == 'encoder-rate' and r['t'] >= command_time and r['kbps'] >= 4000]
    allocation = rates[0]['t'] if rates else None
    triggers = [r for r in rows if r['stage'] == 'resolution-trigger']
    trigger = triggers[0]['t'] if triggers else None
    all_rendered = [r for r in rows if r['stage'] == 'renderer']
    rendered = [r for r in all_rendered if 0 <= r['t'] < duration]
    source = {r['index']: r['t'] for r in rows if r['stage'] == 'source'}
    gaps = [(b['t'] - a['t']) * 1000 for a, b in zip(all_rendered, all_rendered[1:])]
    gaps += [max(0, rendered[0]['t']) * 1000, max(0, duration - rendered[-1]['t']) * 1000] if rendered else [duration * 1000]
    fresh_after = max(allocation, trigger if trigger is not None else allocation) if allocation is not None else None
    restored = [r for r in rendered if fresh_after is not None and r['t'] >= fresh_after
                and source.get(r['index'], -1) >= fresh_after and (r['width'], r['height']) == (3840, 2160)]
    first_full = restored[0]['t'] if restored else None
    final_detail = next((d for d in trace['detail'] if d['phase'] == 'recovery'), {})
    checks = {
        'allSourcePhasesAtLeast55FPS': all(p['source'] / p['durationSeconds'] >= 55 for p in trace['summary']),
        'sourceNeverBunchesBelow8_33ms': all(p['sourceGapsMs']['min'] >= 1000 / 120 for p in trace['summary']),
        'everyRendererGapAtMost200ms': bool(gaps) and max(gaps) <= 200,
        'actualMediaAllocationRecovered': allocation is not None,
        'native4KWithin2SecondsOfAllocation': first_full is not None and 0 <= first_full - allocation <= 2,
        'native4KRetained': first_full is not None and all((r['width'], r['height']) == (3840, 2160) for r in rendered if r['t'] >= first_full),
        'finalMatchedTextPsnrAtLeast35dB': final_detail.get('textROIPsnr', 0) >= 35,
        'finalMatchedTextEdgeErrorAtMost10': final_detail.get('textEdgeMeanAbsoluteError', 1e9) <= 10,
    }
    if trace.get('correctionCandidate'):
        checks['allocationPrecedesObservedTrigger'] = len(triggers) == 1 and allocation is not None and allocation <= trigger
    return {'sourceRevision': trace['sourceRevision'], 'checks': checks, 'pass': all(checks.values()),
            'allocationRecoveredAt': allocation, 'firstFull4KAt': first_full,
            'capCommandAt': command_time, 'observedTriggerAt': trigger,
            'rendererGapMaxMs': max(gaps) if gaps else None,
            'rendererGapsOver200Ms': sum(g > 200 for g in gaps),
            'sourceFPS': {p['phase']: p['source'] / p['durationSeconds'] for p in trace['summary']},
            'finalDetail': final_detail}


def compare(control_path, candidate_path):
    control = json.loads(control_path.read_text())
    candidate = json.loads(candidate_path.read_text())
    control_result, candidate_result = evaluate(control_path), evaluate(candidate_path)
    low_control = next(p for p in control['summary'] if p['phase'] == 'limited')
    low_candidate = next(p for p in candidate['summary'] if p['phase'] == 'limited')
    detail_control = next(p for p in control['detail'] if p['phase'] == 'limited')
    detail_candidate = next(p for p in candidate['detail'] if p['phase'] == 'limited')
    # The unchanged source selects scene (index // 300) % 2. Bar and stamp lie
    # outside this text ROI; independent PNG ROI readback remains a review check.
    matched_scene = (detail_control.get('index', -1) >= 0 and detail_candidate.get('index', -1) >= 0
                     and detail_control['index'] // 300 % 2 == detail_candidate['index'] // 300 % 2
                     and detail_control.get('roi') == detail_candidate.get('roi'))
    allocated = control_result['allocationRecoveredAt']
    checks = {
        'sameRevision': control['sourceRevision'] == candidate['sourceRevision'],
        'controlAndCandidateModes': control.get('correctionCandidate') is False and candidate.get('correctionCandidate') is True,
        'allSixSourcePhasesValid': all(result['checks']['allSourcePhasesAtLeast55FPS']
                                     and result['checks']['sourceNeverBunchesBelow8_33ms']
                                     for result in (control_result, candidate_result)),
        'controlReproducedDelayedNativeRecovery': allocated is not None
            and control['durationSeconds'] - allocated >= 10
            and not control_result['checks']['native4KWithin2SecondsOfAllocation'],
        'candidateAbsoluteGates': candidate_result['pass'],
        'limitedP95AgeImproved': low_candidate['sourceToRendererAgeMs']['p95'] < low_control['sourceToRendererAgeMs']['p95'],
        'limitedLongGapCountImproved': low_candidate['rendererGapsOver200Ms'] < low_control['rendererGapsOver200Ms'],
        'limitedReferenceSceneMatches': matched_scene,
        'limitedTextPsnrNotWorse': matched_scene and detail_candidate.get('textROIPsnr', 0) >= detail_control.get('textROIPsnr', float('inf')),
        'limitedTextEdgeErrorNotWorse': matched_scene and detail_candidate.get('textEdgeMeanAbsoluteError', float('inf')) <= detail_control.get('textEdgeMeanAbsoluteError', -1),
        'diagnosticsComplete': control['diagnosticInstrumentation']['valid'] and candidate['diagnosticInstrumentation']['valid'],
    }
    return {'decision': 'source-bound pass; physical validation still required' if all(checks.values()) else 'reject or inconclusive; inspect failed gates',
            'pass': all(checks.values()), 'checks': checks, 'control': control_result, 'candidate': candidate_result,
            'limitedComparison': {'control': low_control, 'candidate': low_candidate,
                                  'controlDetail': detail_control, 'candidateDetail': detail_candidate},
            'limitations': ['Known sender caps, not a shaped network or production bandwidth controller.',
                            'Same-host sequential runs are not randomized performance evidence.',
                            'Matched rendered PNG inspection and physical iPhone acceptance remain separate.']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    parser.add_argument('--control', type=Path)
    args = parser.parse_args()
    result = compare(args.control, args.trace) if args.control else evaluate(args.trace)
    print(json.dumps(result, indent=2, sort_keys=True))
    raise SystemExit(0 if result['pass'] else 1)
