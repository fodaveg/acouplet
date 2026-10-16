#!/usr/bin/env python3
"""Summarize Acouplet LDAC session logs.

Reads ~/Library/Caches/LDAC Sessions/*/session.log (plus rotated session.log.N
files) or the folders given as arguments, and prints one row per session that
streamed media, followed by totals. Restore-only sessions are skipped.

Usage:
  ldac-session-stats.py [--since "2026-10-16 09:00"] [--json] [PATH ...]

PATH may be a "LDAC Sessions" folder (its subfolders are sessions), a single
session folder, or a session.log file. Several PATHs are allowed, so copies of
the logs can be read. Python 3 standard library only.

Definitions:
  streaming  from the first media READY / MEDIA_READY / LIVE_BEGIN line to
             FEED_COMPLETE, or to the last line if the log is truncated.
  cascade    a DRAIN_BREACH line with first=1 (start of a breach cascade).
  abort      COMPLETE successful=false, CONNECTION_LOST or PCM_FAILED.
  other src  evidence of a second Bluetooth source or peer in the bluetoothd
             lines the session records: ACL/A2DP events for a different address
             than the headphones, and L2CAP channels opened or closed while
             streaming. Addresses are masked in all output.
"""

import argparse
import datetime
import glob
import json
import os
import re
import sys

DEFAULT_ROOT = os.path.expanduser('~/Library/Caches/LDAC Sessions')
MAC = re.compile(r'(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}')
KV = re.compile(r'(\w+)=(\S+)')
STREAM_START = re.compile(r'\bmedia READY\b|\bMEDIA_READY\b|\bLIVE_BEGIN\b')


def mask(text):
    """Hide Bluetooth addresses in anything that reaches the output."""
    return MAC.sub('xx:xx:xx:xx:xx:xx', text)


def norm_addr(text):
    return text.lower().replace('-', ':')


def num(value, default=None):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def kv(line):
    return dict(KV.findall(line))


def log_files(session_dir):
    """session.log.N (oldest first, highest N) followed by session.log."""
    rotated = []
    for path in glob.glob(os.path.join(session_dir, 'session.log.*')):
        suffix = path.rsplit('.', 1)[-1]
        if suffix.isdigit():
            rotated.append((int(suffix), path))
    files = [path for _, path in sorted(rotated, reverse=True)]
    main = os.path.join(session_dir, 'session.log')
    if os.path.isfile(main):
        files.append(main)
    return files


def find_sessions(paths):
    """Return [(session id, [files])] for every PATH, without duplicates."""
    sessions, seen = [], set()

    def add(session_dir):
        session_dir = os.path.abspath(session_dir)
        files = log_files(session_dir)
        if files and session_dir not in seen:
            seen.add(session_dir)
            sessions.append((os.path.basename(session_dir), files))

    for path in paths:
        if os.path.isfile(path):
            name = os.path.basename(path)
            if name.startswith('session.log'):
                add(os.path.dirname(os.path.abspath(path)))
            continue
        if not os.path.isdir(path):
            print(f'warning: {path} does not exist', file=sys.stderr)
            continue
        add(path)
        for child in sorted(os.listdir(path)):
            if os.path.isdir(os.path.join(path, child)):
                add(os.path.join(path, child))
    return sessions


def read_lines(files):
    """Yield (timestamp, text) for each parsable line; tolerate truncation."""
    for path in files:
        try:
            with open(path, encoding='utf-8', errors='replace') as handle:
                for raw in handle:
                    raw = raw.rstrip('\n')
                    head, _, rest = raw.partition(' ')
                    try:
                        yield float(head), rest
                    except ValueError:
                        continue
        except OSError as error:
            print(f'warning: {path}: {error}', file=sys.stderr)


def analyze(session_id, files):
    events = sorted(read_lines(files), key=lambda item: item[0])
    if not events:
        return None
    start, end = events[0][0], events[-1][0]
    stream_start = stream_end = None
    target = None
    s = dict(
        id=session_id[:8], rate=None, bitrate_kbps=None, drain_breaches=0, cascades=0,
        pacing_breaches=0, pcm_skips=0, skipped_frames=0, pcm_failed=0, lost_percent=[],
        successful=None, connection_lost=0, queue_peak=None, queue_drops=None, max_drain=None,
        other_acl=[], other_a2dp=[], l2cap_in_stream=[], media=False)
    daemon = []  # (timestamp, kind, detail) for bluetoothd events
    for ts, text in events:
        if STREAM_START.search(text):
            s['media'] = True
            if stream_start is None:
                stream_start = ts
        if stream_start is not None and stream_end is None and ' FEED_COMPLETE' in ' ' + text:
            stream_end = ts
        if text.startswith('LAUNCH '):
            match = re.search(r'--address (\S+)', text)
            if match and target is None:
                target = norm_addr(match.group(1))
            if text.startswith('LAUNCH media'):
                s['media'] = True
                match = re.search(r'--sample-rate (\d+)', text)
                if match and s['rate'] is None:
                    s['rate'] = int(match.group(1))
            continue
        fields = kv(text)
        if text.startswith('media LIVE_SENT') or text.startswith('media PCM_ENCODER_RESET'):
            if 'rate' in fields and num(fields['rate']):
                s['rate'] = int(float(fields['rate']))
            if 'bitrateKbps' in fields and num(fields['bitrateKbps']):
                s['bitrate_kbps'] = int(float(fields['bitrateKbps']))
        elif text.startswith('media DRAIN_BREACH'):
            s['media'] = True
            s['drain_breaches'] += 1
            if fields.get('first') == '1':
                s['cascades'] += 1
        elif text.startswith('media PACING_BREACH'):
            s['pacing_breaches'] += 1
        elif text.startswith('media PCM_SKIP'):
            s['pcm_skips'] += 1
            s['skipped_frames'] += int(num(fields.get('frames'), 0))
        elif 'PCM_FAILED' in text.split(' ')[:2]:
            s['pcm_failed'] += 1
            if 'lostPercent' in fields:
                s['lost_percent'].append(num(fields['lostPercent']))
        elif text.startswith('COMPLETE '):
            if 'successful' in fields:
                s['successful'] = fields['successful'] == 'true'
        elif text.startswith('CONNECTION_LOST'):
            s['connection_lost'] += 1
        elif text.startswith('media LIVE_PROGRESS'):
            s['media'] = True
            drain = num(fields.get('maxDrain'))
            if drain is not None:
                s['max_drain'] = drain if s['max_drain'] is None else max(s['max_drain'], drain)
        elif 'QUEUE_STATS' in text.split(' ')[:2]:
            for key, value in fields.items():
                number = num(value)
                if number is None:
                    continue
                low = key.lower()
                if 'peak' in low or low.startswith('max'):
                    s['queue_peak'] = number if s['queue_peak'] is None else max(s['queue_peak'], number)
                elif 'drop' in low or 'discard' in low:
                    s['queue_drops'] = (s['queue_drops'] or 0) + number
        # bluetoothd events recorded by the daemon watcher and ACL watcher
        match = re.search(r'ACL (connected|disconnected): (\S+?),?\s', text + ' ')
        if match:
            daemon.append((ts, 'acl-' + match.group(1), norm_addr(match.group(2))))
            continue
        match = re.search(r'Received connection result for "A2DP Source" profile on device (\S+)', text)
        if match:
            daemon.append((ts, 'a2dp-source', norm_addr(match.group(1))))
            continue
        match = re.search(r'connectedCB cid:(0x\w+)', text)
        if match:
            daemon.append((ts, 'l2cap-open', match.group(1)))
            continue
        match = re.search(r'l2capDisconnected for CID: (0x\w+)(?:, reson: (0x\w+))?', text)
        if match:
            daemon.append((ts, 'l2cap-close', match.group(1) + (f' reason={match.group(2)}' if match.group(2) else '')))

    if not s['media']:
        return None  # restore-only (or otherwise silent) session
    if stream_start is None:
        stream_start = start
    if stream_end is None:
        stream_end = end
    stream_end = max(stream_end, stream_start)

    labels = {}
    for ts, kind, detail in daemon:
        if kind.startswith('acl-') or kind == 'a2dp-source':
            if target is not None and detail != target:
                label = labels.setdefault(detail, f'peer{len(labels) + 1}')
                bucket = s['other_acl'] if kind.startswith('acl-') else s['other_a2dp']
                bucket.append(f'{ts - stream_start:+.1f}s {kind} {label}')
        elif stream_start <= ts <= stream_end:
            s['l2cap_in_stream'].append(f'{ts - stream_start:+.1f}s {kind} {detail}')

    s.update(
        start=start, end=end, stream_start=stream_start, stream_end=stream_end,
        stream_seconds=stream_end - stream_start,
        aborted=(s['successful'] is False or s['connection_lost'] > 0 or s['pcm_failed'] > 0),
        complete_seen=s['successful'] is not None)
    s['other_events'] = len(s['other_acl']) + len(s['other_a2dp']) + len(s['l2cap_in_stream'])
    s['lost_percent'] = [value for value in s['lost_percent'] if value is not None]
    return s


def clock(ts):
    return datetime.datetime.fromtimestamp(ts).strftime('%m-%d %H:%M:%S')


def hms(seconds):
    seconds = int(round(seconds))
    return f'{seconds // 3600}:{seconds % 3600 // 60:02d}:{seconds % 60:02d}'


def render(sessions, totals):
    header = ['session', 'start', 'end', 'stream', 'rate/kbps', 'casc', 'pace', 'skip(n/frames)',
              'PCM_FAILED lost%', 'ok', 'maxDrain', 'queue(peak/drops)', 'other']
    rows = []
    for s in sessions:
        rate = f"{s['rate'] // 1000}k" if s['rate'] else '-'
        kbps = s['bitrate_kbps'] if s['bitrate_kbps'] else '-'
        ok = {True: 'yes', False: 'NO', None: '?'}[s['successful']]
        queue = '-' if s['queue_peak'] is None and s['queue_drops'] is None else \
            f"{s['queue_peak'] if s['queue_peak'] is not None else '-'}/{s['queue_drops'] or 0:g}"
        rows.append([
            s['id'], clock(s['start']), clock(s['end']), hms(s['stream_seconds']), f'{rate}/{kbps}',
            s['cascades'], s['pacing_breaches'], f"{s['pcm_skips']}/{s['skipped_frames']}",
            f"{s['pcm_failed']} ({','.join(f'{v:g}' for v in s['lost_percent']) or '-'})", ok,
            '-' if s['max_drain'] is None else f"{s['max_drain']:g}", queue, s['other_events']])
    widths = [max(len(str(row[i])) for row in [header] + rows) for i in range(len(header))]
    lines = ['  '.join(str(cell).ljust(widths[i]) for i, cell in enumerate(row))
             for row in [header] + rows]
    lines.append('')
    lines.append(f"Sessions with media: {totals['sessions']}  aborted: {totals['aborts']}  "
                 f"streaming: {totals['stream_hours']:.2f} h")
    lines.append(f"Aborts/hour: {totals['aborts_per_hour']:.2f}  cascades: {totals['cascades']}  "
                 f"cascades/hour: {totals['cascades_per_hour']:.2f}")
    notes = []
    for s in sessions:
        if s['aborted'] or s['other_events']:
            notes.append(f"  {s['id']}: {'ABORTED' if s['aborted'] else 'ok'}; "
                         f"other ACL/A2DP peers: {len(s['other_acl']) + len(s['other_a2dp'])}; "
                         f"L2CAP events while streaming: {len(s['l2cap_in_stream'])}")
            for item in s['other_acl'] + s['other_a2dp'] + s['l2cap_in_stream']:
                notes.append(f'      {mask(item)}')
    if notes:
        lines.append('')
        lines.append('Other-source evidence (offsets from stream start):')
        lines.extend(notes)
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('paths', nargs='*', help='"LDAC Sessions" folder(s), session folder(s) or session.log file(s)')
    parser.add_argument('--since', help='only sessions starting at or after "YYYY-MM-DD HH:MM" (local time)')
    parser.add_argument('--json', action='store_true', help='print JSON instead of a table')
    args = parser.parse_args()

    since = None
    if args.since:
        for pattern in ('%Y-%m-%d %H:%M:%S', '%Y-%m-%d %H:%M', '%Y-%m-%d'):
            try:
                since = datetime.datetime.strptime(args.since, pattern).timestamp()
                break
            except ValueError:
                pass
        if since is None:
            parser.error('--since expects "YYYY-MM-DD HH:MM"')

    sessions = []
    for session_id, files in find_sessions(args.paths or [DEFAULT_ROOT]):
        result = analyze(session_id, files)
        if result and (since is None or result['start'] >= since):
            sessions.append(result)
    sessions.sort(key=lambda item: item['start'])

    seconds = sum(s['stream_seconds'] for s in sessions)
    hours = seconds / 3600
    aborts = sum(1 for s in sessions if s['aborted'])
    cascades = sum(s['cascades'] for s in sessions)
    totals = dict(sessions=len(sessions), aborts=aborts, stream_hours=hours, cascades=cascades,
                  aborts_per_hour=aborts / hours if hours else 0.0,
                  cascades_per_hour=cascades / hours if hours else 0.0)

    if args.json:
        out = []
        for s in sessions:
            item = {k: v for k, v in s.items() if k != 'media'}
            for key in ('start', 'end', 'stream_start', 'stream_end'):
                item[key + '_local'] = datetime.datetime.fromtimestamp(s[key]).isoformat(timespec='seconds')
            for key in ('other_acl', 'other_a2dp', 'l2cap_in_stream'):
                item[key] = [mask(entry) for entry in s[key]]
            out.append(item)
        print(json.dumps({'sessions': out, 'totals': totals}, indent=2))
    else:
        print(render(sessions, totals))


if __name__ == '__main__':
    main()
