"""Capture every phone frame of the prototype into docs/design/screenshots/.

Run from the repository root:
    uv run --with playwright python docs/design/prototype/capture.py

It drives the installed Google Chrome (no browser download) at 2x, with reduced
motion so animated frames are stable. Long screens also get a "-full" capture of
the whole scroll.
"""

import pathlib

from playwright.sync_api import sync_playwright

HERE = pathlib.Path(__file__).resolve().parent
PAGE = HERE / "index.html"
OUT = HERE.parent / "screenshots"


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome")
        page = browser.new_page(
            viewport={"width": 1300, "height": 1000},
            device_scale_factor=2,
            reduced_motion="reduce",
        )
        page.goto(PAGE.as_uri())
        page.wait_for_function("document.fonts.ready.then(() => true)")
        page.wait_for_timeout(1000)
        for el in page.query_selector_all(".phone"):
            screen = el.get_attribute("data-screen")
            theme = el.get_attribute("data-theme")
            el.evaluate("e => e.classList.add('capture')")
            el.screenshot(path=str(OUT / f"{screen}-{theme}.png"))
            if el.get_attribute("data-long"):
                el.evaluate("e => e.classList.add('full')")
                el.screenshot(path=str(OUT / f"{screen}-full-{theme}.png"))
                el.evaluate("e => e.classList.remove('full')")
            el.evaluate("e => e.classList.remove('capture')")
        browser.close()


if __name__ == "__main__":
    main()
