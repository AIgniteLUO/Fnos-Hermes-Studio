#!/usr/bin/env python3
import os, sys, time, subprocess
from datetime import datetime

LOG = '/tmp/hermes-install-monitor.log'
TARGET = '/vol3/@appdata/hermes-studio'
APPCENTER = '/vol3/@appcenter/hermes-studio'
VAR = '/var/apps/hermes-studio'

last_target = None
last_appcenter = None
last_var = None
last_info_lines = -1
last_procs = ''
last_ports = ''

def log(msg):
    ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    line = f'[{ts}] {msg}'
    print(line, flush=True)
    with open(LOG, 'a', encoding='utf-8') as f:
        f.write(line + '\n')

def run(cmd, default=''):
    try:
        return subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT, text=True, timeout=5)
    except Exception as e:
        return f'{type(e).__name__}: {e}'

def check_dir(path, label, last):
    exists = os.path.isdir(path)
    if exists and last != 'exists':
        log(f'{label} CREATED: {path}')
        try:
            for item in sorted(os.listdir(path)):
                try:
                    st = os.stat(os.path.join(path, item))
                    log(f'  {item} {st.st_mode:o} {st.st_uid}:{st.st_gid}')
                except Exception as e:
                    log(f'  {item} (stat error: {e})')
        except Exception as e:
            log(f'  listdir error: {e}')
        return 'exists'
    elif not exists and last != 'missing':
        log(f'{label} MISSING: {path}')
        return 'missing'
    return last

if __name__ == '__main__':
    try:
        os.remove(LOG)
    except FileNotFoundError:
        pass
    log(f'Monitor started PID={os.getpid()}')
    log('PATH=' + os.environ.get('PATH', ''))

    for i in range(600):
        last_target = check_dir(TARGET, 'TARGET', last_target)
        last_appcenter = check_dir(APPCENTER, 'APPCENTER', last_appcenter)
        last_var = check_dir(VAR, 'VAR', last_var)

        if os.path.isfile(os.path.join(TARGET, 'info.log')):
            try:
                lines = sum(1 for _ in open(os.path.join(TARGET, 'info.log'), encoding='utf-8', errors='ignore'))
                if lines != last_info_lines:
                    log(f'info.log lines={lines}, last 10:')
                    log(run(f'tail -n 10 {TARGET}/info.log'))
                    last_info_lines = lines
            except Exception as e:
                log(f'info.log read error: {e}')

        procs = run("ps -ef | grep -E 'hermes|install_callback|appcenter' | grep -v grep | head -30")
        if procs != last_procs:
            log('PROCS CHANGED:')
            log(procs)
            last_procs = procs

        ports = run("ss -tlnp 2>/dev/null | grep -E '8648|9119|18081' || echo 'no ports listening'")
        if ports != last_ports:
            log('PORTS CHANGED:')
            log(ports)
            last_ports = ports

        time.sleep(0.5)

    log('Monitor ended')
