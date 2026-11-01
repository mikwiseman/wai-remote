#!/usr/bin/env python3
"""Acceptance from actual renderer/stamp and rate traces; no policy internals."""
import argparse
import json
import math
from pathlib import Path


def sender_to_receiver_rtp_offset(rows):
    """WebRTC adds a session RTP offset. Require one causal mapping for every entry."""
    outputs = [r for r in rows if r['stage'] == 'encode-output']
    entries = sorted((r for r in rows if r['stage'] == 'renderer-entry'), key=lambda r: r['t'])
    by_rtp = {r['rtp']: r for r in outputs}
    if not entries or len(by_rtp) != len(outputs):
        return None
    candidates = {(entries[0]['rtp'] - r['rtp']) % 2**32 for r in outputs if r['t'] <= entries[0]['t']}
    valid = [offset for offset in candidates if all(
        (r['rtp'] - offset) % 2**32 in by_rtp
        and by_rtp[(r['rtp'] - offset) % 2**32]['t'] <= r['t'] for r in entries)]
    return valid[0] if len(valid) == 1 else None


def recovery_deadline(trace, allocation, trigger):
    """Validate the latest delivered frame at +2s, never an older sharp frame."""
    finite = lambda value: isinstance(value, (int, float)) and math.isfinite(value)
    close = lambda a, b: finite(a) and finite(b) and abs(a - b) <= 1e-6
    samples = [d for d in trace['detail'] if d['phase'] == 'recovery-2s']
    sample = samples[0] if len(samples) == 1 else {}
    deadline = allocation + 2 if finite(allocation) else None
    arrival = sample.get('decodedAtSeconds')
    rtp, index = sample.get('rtp'), sample.get('index')
    entries = [r for r in trace['rows'] if r['stage'] == 'renderer-entry'
               and deadline is not None and r['t'] <= deadline]
    latest = max(entries, key=lambda r: r['t']) if entries else {}
    source = [r for r in trace['rows'] if r['stage'] == 'source' and r.get('index') == index]
    offset = sender_to_receiver_rtp_offset(trace['rows'])
    encoded = [r for r in trace['rows'] if r['stage'] == 'encode-output' and rtp is not None
               and offset is not None and (r['rtp'] + offset) % 2**32 == rtp]
    rendered = [r for r in trace['rows'] if r['stage'] == 'renderer' and rtp is not None and r.get('rtp') == rtp]
    matching_entries = [r for r in trace['rows'] if r['stage'] == 'renderer-entry' and rtp is not None and r.get('rtp') == rtp]
    native = lambda row: (row.get('width'), row.get('height')) == (3840, 2160)
    fresh_after = max(allocation, trigger if finite(trigger) else allocation) if finite(allocation) else None
    psnr, edge = sample.get('textROIPsnr'), sample.get('textEdgeMeanAbsoluteError')
    checks = {
        'uniqueCheckpoint': len(samples) == 1 and 'missing' not in sample,
        'actualAllocationAnchor': close(sample.get('allocationAtSeconds'), allocation),
        'exactTwoSecondDeadline': close(sample.get('deadlineAtSeconds'), deadline),
        'arrivedByDeadline': finite(arrival) and deadline is not None and allocation <= arrival <= deadline,
        'latestDeliveredFrame': len(matching_entries) == 1 and latest.get('rtp') == rtp and close(latest.get('t'), arrival),
        'freshUniqueSourceStamp': len(source) == 1 and index is not None and index >= 0
            and fresh_after is not None and source[0]['t'] >= fresh_after
            and finite(arrival) and source[0]['t'] <= arrival,
        'nativeEncodedAndRendered': native(sample) and native(latest)
            and len(encoded) == 1 and native(encoded[0]) and finite(arrival) and encoded[0]['t'] <= arrival
            and len(rendered) == 1 and native(rendered[0]) and rendered[0].get('index') == index,
        'causalFrameOrder': len(source) == 1 and len(encoded) == 1 and len(rendered) == 1
            and finite(arrival) and source[0]['t'] <= encoded[0]['t'] <= arrival <= rendered[0]['t'],
        'matchedTextPsnrAtLeast35dB': finite(psnr) and psnr >= 35,
        'matchedTextEdgeErrorAtMost10': finite(edge) and 0 <= edge <= 10 and sample.get('textEdgePixels', 0) > 0,
    }
    return {'pass': all(checks.values()), 'checks': checks, 'sample': sample,
            'senderToReceiverRTPOffset': offset}


def evaluate(path):
    trace = json.loads(path.read_text())
    rows = trace['rows']
    duration = trace['durationSeconds']
    recovery = next(p for p in trace['summary'] if p['phase'] == 'recovery')['startSeconds']
    recovery_cap = next((r for r in rows if r['stage'] == 'cap' and r['t'] >= 0 and r['requestedBps'] == 4000000), None)
    command_time = (recovery_cap['requestedAtUptimeSeconds'] - trace['clockAnchor']['uptimeSeconds']
                    if recovery_cap and 'requestedAtUptimeSeconds' in recovery_cap else recovery)
    rates = [r for r in rows if r['stage'] == 'encoder-rate' and r['t'] >= command_time and r['kbps'] >= 4000 and r.get('result') == 0]
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
    sharp_deadline = recovery_deadline(trace, allocation, trigger)
    checks = {
        'allSourcePhasesAtLeast55FPS': all(p['source'] / p['durationSeconds'] >= 55 for p in trace['summary']),
        'sourceNeverBunchesBelow8_33ms': all(p['sourceGapsMs']['min'] >= 1000 / 120 for p in trace['summary']),
        'everyRendererGapAtMost200ms': bool(gaps) and max(gaps) <= 200,
        'actualMediaAllocationRecovered': allocation is not None,
        'native4KWithin2SecondsOfAllocation': first_full is not None and 0 <= first_full - allocation <= 2,
        'native4KRetained': first_full is not None and all((r['width'], r['height']) == (3840, 2160) for r in rendered if r['t'] >= first_full),
        'finalMatchedTextPsnrAtLeast35dB': final_detail.get('textROIPsnr', 0) >= 35,
        'finalMatchedTextEdgeErrorAtMost10': final_detail.get('textEdgeMeanAbsoluteError', 1e9) <= 10,
        'freshSharpNativeTextByTwoSecondDeadline': sharp_deadline['pass'],
    }
    if trace.get('correctionCandidate'):
        checks['allocationPrecedesObservedTrigger'] = len(triggers) == 1 and allocation is not None and allocation <= trigger
    return {'sourceRevision': trace['sourceRevision'], 'checks': checks, 'pass': all(checks.values()),
            'allocationRecoveredAt': allocation, 'firstFull4KAt': first_full,
            'capCommandAt': command_time, 'observedTriggerAt': trigger,
            'rendererGapMaxMs': max(gaps) if gaps else None,
            'rendererGapsOver200Ms': sum(g > 200 for g in gaps),
            'sourceFPS': {p['phase']: p['source'] / p['durationSeconds'] for p in trace['summary']},
            'finalDetail': final_detail, 'sharpRecoveryDeadline': sharp_deadline}


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
