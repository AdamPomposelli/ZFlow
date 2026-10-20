# Fills index.template's slots and writes index.html. All text is invented.
import html, os, re
here = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(here, 'index.template')).read()
svg = open(os.path.join(here, 'assets/hero-inline.svg')).read()
svg = re.sub(r'<!--.*?-->\s*', '', svg, flags=re.S).replace('<svg ', '<svg id="lockup" ', 1)

code = [
    ('c', '// Sessions live in the store; tokens refresh on use.'),
    ('k', 'import', ' { store } ', 'k', 'from', ' ', 's', '"../store"', ';'),
    ('',),
    ('k', 'export async function', ' ', 'f', 'getSession', '(id: string) {'),
    ('', '  ', 'k', 'const', ' session = ', 'k', 'await', ' store.', 'f', 'get', '(id);'),
    ('', '  ', 'k', 'if', ' (!session) ', 'k', 'return', ' null;'),
    ('', '  ', 'k', 'if', ' (session.expiresAt < Date.', 'f', 'now', '()) {'),
    ('', '    ', 'k', 'await', ' store.', 'f', 'delete', '(id);'),
    ('', '    ', 'k', 'return', ' null;'),
    ('', '  }'),
    ('', '  ', 'k', 'return', ' session;'),
    ('', '}'),
    ('',),
    ('k', 'export function', ' ', 'f', 'isExpired', '(token: Token) {'),
    ('', '  ', 'k', 'return', ' token.exp * ', 's', '1000', ' < Date.', 'f', 'now', '();'),
    ('', '}'),
]
def line(parts):
    if parts[0] == 'c':
        return f'<span class="c">{html.escape(parts[1])}</span>'
    out, i = '', 0
    while i < len(parts):
        p = parts[i]
        if p in ('k', 's', 'f') and i + 1 < len(parts):
            out += f'<span class="{p}">{html.escape(parts[i+1])}</span>'; i += 2
        else:
            out += html.escape(p); i += 1
    return out
code_html = '\n'.join(f'<span class="n">{n}</span>{line(p)}' for n, p in enumerate(code, 38))

typed = ("Refactor the session store so expired tokens refresh instead of logging people out, "
         "then add tests for the one-hour case.").split()
typed_html = ''.join(f'<span>{html.escape(w)}</span>' for w in typed)
bars = '<i></i>' * 14
out = (src.replace('__LOCKUP__', svg).replace('__CODE__', code_html).replace('__TYPED__', typed_html)
          .replace('__BARS_L__', bars).replace('__BARS_R__', bars + '<i></i>'))
open(os.path.join(here, 'index.html'), 'w').write(out)
