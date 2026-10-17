#!/usr/bin/env python3
"""Check captured single-event transitions offline; this is not a production worker."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def event_key(event):
    return event['eventId'] + ':' + event['fingerprint']

def evaluate(prior, snapshot):
    result = dict(outcome='healthy-unchanged', notify=False, deliveries=[],
                  markDelivered=[], releaseLock=True, archive=False, reconcile=False)
    if snapshot['read'] != 'ok':
        result['outcome'] = 'failed-read' if snapshot['read'] == 'error' else 'unknown-read'
        result['notify'] = not any(e['kind'] == 'read-failure' and e['notified'] for e in prior['openEpisodes'])
        return result
    delivered = {event_key(e) for e in prior['delivered']}
    pending = {event_key(e): e for e in prior['pending'] if event_key(e) not in delivered}
    for key, event in pending.items():
        if event['idempotencyKey'] != key:
            raise ValueError('Pending delivery identity mismatch')
    eligible = {event_key(e): e for e in snapshot['events'] if event_key(e) not in delivered}
    active = {**pending, **eligible}
    if len(active) > 1:
        raise ValueError('This fixture demonstration accepts one event per transition')
    if not active:
        result['archive'] = True
        return result
    key, event = next(iter(active.items()))
    if key not in pending:
        result['notify'] = True
        result['deliveries'] = [dict(eventId=event['eventId'], fingerprint=event['fingerprint'], idempotencyKey=key)]
    if snapshot.get('deliveryResult') == 'ack':
        result.update(outcome='changed', markDelivered=[key], archive=True)
    else:
        result.update(outcome='delivery-uncertain', reconcile=True)
    return result

if __name__ == '__main__':
    cases = json.loads((ROOT / 'examples/scheduled-worker-fixture.json').read_text())['cases']
    for case in cases:
        actual = evaluate(case['prior'], case['snapshot'])
        if actual != case['expected']:
            raise SystemExit(f"FAIL {case['id']}: observed {actual}; expected {case['expected']}")
        print(f"PASS {case['id']}: {actual['outcome']}; notify={actual['notify']}; archive={actual['archive']}")
    print('Only captured transition outputs checked. No real scheduler, lease, state persistence, delivery or self-disposal was exercised.')
