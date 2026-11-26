"""Edit FSX's fsx_se.CFG in place (CRLF ini; keeps everything else as it is).

  python3 -I fsxcfg.py FILE set SECTION KEY VALUE   set KEY=VALUE in [SECTION] (adds the section or key if missing)
  python3 -I fsxcfg.py FILE trust PREFIX            set every [Trusted] entry starting with PREFIX to 1
                                                     (FSX's "trust this add-on?" prompt can be dismissed unseen in Wine)
"""
import os
import sys


def load(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding='latin-1', newline='') as f:
        return f.read().replace('\r\n', '\n').split('\n')


def save(path, lines):
    while lines and lines[-1] == '':
        lines.pop()
    with open(path, 'w', encoding='latin-1', newline='') as f:
        f.write('\r\n'.join(lines) + '\r\n')


def section_range(lines, name):
    """(start, end) of [name]'s body, or None"""
    start = None
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith('[') and s.endswith(']'):
            if start is not None:
                return start, i
            if s[1:-1].lower() == name.lower():
                start = i + 1
    return (start, len(lines)) if start is not None else None


def set_key(lines, section, key, value):
    r = section_range(lines, section)
    if r is None:
        while lines and lines[-1] == '':
            lines.pop()
        lines += ['[%s]' % section, '%s=%s' % (key, value)]
        return
    start, end = r
    for i in range(start, end):
        if lines[i].split('=', 1)[0].strip().lower() == key.lower():
            lines[i] = '%s=%s' % (key, value)
            return
    while end > start and lines[end - 1].strip() == '':
        end -= 1
    lines.insert(end, '%s=%s' % (key, value))


def trust(lines, prefix):
    r = section_range(lines, 'Trusted')
    n = 0
    if r:
        for i in range(*r):
            k = lines[i].split('=', 1)[0]
            if '=' in lines[i] and os.path.basename(k.replace('\\', '/')).lower().startswith(prefix.lower()):
                lines[i] = k + '=1'
                n += 1
    return n


def main(argv):
    if len(argv) >= 6 and argv[2] == 'set':
        lines = load(argv[1])
        set_key(lines, argv[3], argv[4], argv[5])
        save(argv[1], lines)
    elif len(argv) == 4 and argv[2] == 'trust':
        lines = load(argv[1])
        if trust(lines, argv[3]):
            save(argv[1], lines)
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main(sys.argv)
