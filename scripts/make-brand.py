#!/usr/bin/env python3
"""Generate GitHub and reusable vector artwork from the app icon's shared mark."""
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent
brand = root / "Resources" / "Brand"
mark = json.loads((brand / "mark.json").read_text())

def shapes(theme):
    parts = []
    if theme in ("light", "dark"):
        parts.append(f'<rect width="104" height="104" rx="25" fill="#{mark[theme + "Background"]}"/>')
    for tile in mark["tiles"]:
        color = {"black": "151A25", "white": "FFFFFF"}.get(theme) or tile[theme]
        parts.append(f'<rect x="{tile["x"]}" y="{tile["y"]}" width="{tile["size"]}" height="{tile["size"]}" rx="{tile["radius"]}" fill="#{color}"/>')
    return "\n  ".join(parts)

for theme in ("light", "dark", "black", "white"):
    (brand / f"mark-{theme}.svg").write_text(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 104 104" width="104" height="104" role="img" aria-label="ProfileDock">\n  {shapes(theme)}\n</svg>\n')

hero = (root / "docs" / "hero.svg").read_text()
block = '<!-- brand-mark:start -->\n  <g transform="translate(548 84)">\n  ' + shapes("dark") + '\n  </g>\n  <!-- brand-mark:end -->'
if '<!-- brand-mark:start -->' in hero:
    hero = re.sub(r'<!-- brand-mark:start -->.*?<!-- brand-mark:end -->', lambda _: block, hero, flags=re.S)
else:
    hero = re.sub(r'<rect x="548".*?(?=  <text x="600" y="265")', lambda _: block + '\n', hero, flags=re.S)
(root / "docs" / "hero.svg").write_text(hero)
dark = hero.replace('#eef4ff', '#11151d').replace('#fafbfe', '#1b2331').replace('fill="#151a25"', 'fill="#f1f5ff"').replace('fill="#536176"', 'fill="#acb9ce"').replace('fill="#7c8798"', 'fill="#8fa1bd"')
(root / "docs" / "hero-dark.svg").write_text(dark)
