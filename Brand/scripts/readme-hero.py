# Draws the README hero (Brand/readme/hero-dark.svg and hero-light.svg) in the
# HyperFrames layout: the suite name, the product name under it, the app icon
# top right. Everything comes from the Zippy brand kit, a sibling checkout.
#
#   python3 Brand/scripts/readme-hero.py [brand-kit dir]
#
# Needs fontTools and brotli (pip install fonttools brotli).

import os, re, sys
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.boundsPen import BoundsPen
HERE = os.path.dirname(os.path.abspath(__file__))
KIT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, '../../../brand-kit')
OUT = os.path.join(HERE, '../readme')
font = TTFont(f'{KIT}/fonts/PlusJakartaSans-800.woff2')
gs, cmap, hmtx = font.getGlyphSet(), font.getBestCmap(), font['hmtx']

def word(text, scale, x0=0.0, y0=0.0):
    pen, bp, x = SVGPathPen(gs), BoundsPen(gs), x0
    track = -0.02 * 1000 * scale   # the Zippy wordmark's tracking
    for ch in text:
        g = cmap[ord(ch)]
        t = (scale, 0, 0, -scale, x, y0)
        gs[g].draw(TransformPen(pen, t)); gs[g].draw(TransformPen(bp, t))
        x += hmtx[g][0] * scale + track
    return pen.getCommands(), bp.bounds

# The kit's app icon, recoloured to ZFlow's violet (the download button's).
icon = open(f'{KIT}/apps/zpay/zpay-icon.svg').read()
icon = icon.replace('zpay-', 'zflow-')
for a, b in {'#AE76FC': '#A78BFA', '#8544FA': '#7C3AED', '#6B1EFA': '#5B21B6', '#DDCEF9': '#DDD6FE'}.items():
    icon = icon.replace(a, b)
defs = re.search(r'<defs>.*</defs>', icon, re.S).group(0)
body = icon[icon.index('</defs>') + 7: icon.rindex('</svg>')]

SMALL, BIG = 0.2, 0.42
cap_s, cap_b = 745 * SMALL, 745 * BIG
gap = 0.48 * cap_s                       # Zippy baseline to ZFlow cap top
zippy_d, zb = word('Zippy', SMALL, 0, cap_s)
zflow_d, fb = word('ZFlow', BIG, 0, cap_s + gap + cap_b)
left = min(zb[0], fb[0]); right = fb[2]
icon_size = 1.22 * cap_s + gap * 0.62
icon_x = right - icon_size
icon_y = -0.3 * cap_s
top = min(icon_y, 0); bottom = max(fb[3], zb[3])
pad = 4
W = right - left + 2 * pad; H = bottom - top + 2 * pad
for theme, ink in (('dark', '#FFFFFF'), ('light', '#0A1024')):
    svg = f'''<!-- README hero, {theme} mode. Built from the Zippy brand kit: the
     wordmarks are Plus Jakarta Sans 800 outlines, the tile is the kit's app
     icon in ZFlow's violet. Regenerate rather than hand-edit. -->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="{left - pad:.1f} {top - pad:.1f} {W:.1f} {H:.1f}" width="{W:.0f}" height="{H:.0f}" fill="none" role="img" aria-label="Zippy ZFlow">
  {defs}
  <path d="{zippy_d}" fill="{ink}"/>
  <path d="{zflow_d}" fill="{ink}"/>
  <g transform="translate({icon_x:.2f} {icon_y:.2f}) scale({icon_size / 1024:.5f})">{body}</g>
</svg>
'''
    open(f'{OUT}/hero-{theme}.svg', 'w').write(svg)
