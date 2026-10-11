# Render tutorial figures (inline SVG) on the tutorials dark theme, to LOOK at them before they ship:
#   python3 src/notes/scripts/render_figures.py <name> ...   reads /tmp/dg/<name>.svg, writes /tmp/dg/<name>.png
# (Playwright Chromium. The course convention: <figure><svg ... currentColor, accents via style="fill:var(--tok-*)">,
# a unique marker id per figure, one <path> per arrow - marker-end only marks a path's LAST segment.)
# Render each /tmp/dg/<name>.svg on the tutorial's dark theme, as the page will show it, into <name>.png.
import sys, pathlib
from playwright.sync_api import sync_playwright
style = ("--bg:#0a0a0a;--fg:#e8e8e8;--dim:#9aa0a8;--tok-type:#6fb6ff;--tok-num:#f5a35e;--tok-str:#9ad08a;"
         "--tok-kw:#c792ea;--tok-fn:#82d8ef")
with sync_playwright() as p:
    browser = p.chromium.launch()
    for name in sys.argv[1:]:
        svg = pathlib.Path(f"/tmp/dg/{name}.svg").read_text()
        html = (f"<html><body style='{style};background:var(--bg);color:var(--fg);margin:0;padding:10px;"
                f"width:700px;font-family:sans-serif'><figure style='margin:0'>{svg}</figure></body></html>")
        page = browser.new_page(viewport={"width": 720, "height": 200}, device_scale_factor=1.4)
        page.set_content(html)
        page.screenshot(path=f"/tmp/dg/{name}.png", full_page=True)
        page.close()
    browser.close()
print("rendered", " ".join(sys.argv[1:]))
