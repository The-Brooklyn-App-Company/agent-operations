#!/usr/bin/env python3
"""Exercise synthetic routing cases offline; no scheduler, delivery or model calls."""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
cases = json.loads((root / 'examples/scheduled-worker-fixture.json').read_text())['cases']
for case in cases:
    prior, current, expected = case['prior'], case['snapshot'], case['expected']
    if current['read'] != 'ok':
        outcome, eligible, advance, archive = 'failed-read', [], [], False
    else:
        delivered = {(e['eventId'], e['fingerprint']) for e in prior.get('delivered', [])}
        eligible = [e for e in current['events'] if (e['eventId'], e['fingerprint']) not in delivered]
        if not eligible:
            outcome, advance, archive = 'healthy-unchanged', [], True
        elif current.get('deliveryResult') == 'timeout':
            outcome, advance, archive = 'delivery-uncertain', [], False
        else:
            outcome, advance, archive = 'changed', [], False
    assert outcome == expected['outcome'], case['id']
    assert archive == expected['archive'], case['id']
    if 'markDelivered' in expected:
        assert advance == expected['markDelivered'], case['id']
    print(f"PASS {case['id']}: {outcome}; advance={advance}; archive={archive}")
print('Only fixture routing exercised; native locks, transport idempotency, delivery and self-disposal need actual capability acceptance.')
