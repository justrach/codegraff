"""Deterministic frontend fixtures for the model-shape benchmark."""

from model_shape_tasks import Task


TASKS = (
    Task(
        name="responsive_portfolio",
        niche="responsive_layout",
        source_name="portfolio.html",
        source="""\
<!doctype html>
<html lang="en">
<head>
  <title>Selected work</title>
  <style>
    body { margin: 0; font-family: sans-serif; }
    .projects { display: flex; width: 1200px; gap: 12px; }
    .card { width: 360px; padding: 12px; background: #eee; }
    .card img { width: 360px; height: 220px; }
    a { color: blue; }
  </style>
</head>
<body>
  <div class="nav"><a href="/">Mira</a><a href="#work">Work</a></div>
  <div id="work">
    <div class="projects">
      <div class="card"><img src="one.jpg"><h2>Transit map</h2><a href="/one">Read</a></div>
      <div class="card"><img src="two.jpg"><h2>Field notes</h2><a href="/two">Read</a></div>
      <div class="card"><img src="three.jpg"><h2>Type study</h2><a href="/three">Read</a></div>
    </div>
  </div>
</body>
</html>
""",
        visible_tests="""\
import re
import unittest
from pathlib import Path


def source():
    return Path("portfolio.html").read_text().lower()


class PortfolioTests(unittest.TestCase):
    def test_landmarks_and_project_articles(self):
        text = source()
        self.assertIn("<nav", text)
        self.assertIn("<main", text)
        self.assertGreaterEqual(text.count("<article"), 3)

    def test_fluid_grid(self):
        compact = re.sub(r"\\s+", "", source())
        self.assertIn("display:grid", compact)
        self.assertRegex(compact, r"repeat\\(auto-fit,minmax\\(")

    def test_mobile_breakpoint_removes_fixed_layout(self):
        text = source()
        self.assertRegex(text, r"@media\\s*\\([^)]*max-width")
        self.assertNotRegex(text, r"\\.projects\\s*\\{[^}]*width\\s*:\\s*1200px")

    def test_keyboard_focus_is_visible(self):
        self.assertIn(":focus-visible", source())


if __name__ == "__main__":
    unittest.main()
""",
        visible_count=4,
        hidden_grader="""\
import json
import re
from pathlib import Path

s = Path("portfolio.html").read_text().lower()
c = re.sub(r"\\s+", "", s)
results = {
    "viewport": bool(re.search(r'<meta[^>]+name=["\\']viewport["\\']', s)),
    "design_tokens": ":root" in s and "--space-" in s and "var(--" in s,
    "border_box": "box-sizing:border-box" in c,
    "reduced_motion": "@media(prefers-reduced-motion:reduce)" in c,
    "responsive_images": "max-width:100%" in c and "height:auto" in c,
}
print(json.dumps(results, sort_keys=True))
""",
        hidden_count=5,
        request="""\
Repair `portfolio.html` into a polished, responsive portfolio page without
external libraries. Keep the three projects and links. Use semantic nav/main/
article landmarks, a fluid CSS grid using `repeat(auto-fit, minmax(...))`, a
mobile max-width breakpoint, visible keyboard focus, a viewport meta tag,
border-box sizing, reusable `:root` spacing/color variables, responsive images,
and a reduced-motion media query. Avoid a fixed-width projects container.
Only edit `portfolio.html`.
""",
    ),
    Task(
        name="accessible_modal",
        niche="accessibility_interaction",
        source_name="modal.html",
        source="""\
<!doctype html>
<html lang="en">
<head>
  <meta name="viewport" content="width=device-width">
  <title>Delete project</title>
  <style>
    #modal { position: absolute; top: 30px; left: 30px; background: white; }
    .hidden { display: none; }
  </style>
</head>
<body>
  <main>
    <h1>Projects</h1>
    <button id="open">Delete project</button>
    <p>The project contains seven files.</p>
  </main>
  <div id="modal" class="hidden">
    <h2>Delete?</h2>
    <button id="cancel">Cancel</button>
    <button id="confirm">Delete</button>
  </div>
  <script>
    const modal = document.querySelector("#modal");
    document.querySelector("#open").onclick = () => modal.classList.remove("hidden");
    document.querySelector("#cancel").onclick = () => modal.classList.add("hidden");
  </script>
</body>
</html>
""",
        visible_tests="""\
import re
import unittest
from pathlib import Path


def source():
    return Path("modal.html").read_text().lower()


class ModalTests(unittest.TestCase):
    def test_dialog_relationships(self):
        text = source()
        self.assertRegex(text, r'role=["\\']dialog["\\']')
        self.assertRegex(text, r'aria-modal=["\\']true["\\']')
        self.assertRegex(text, r'aria-labelledby=["\\'][^"\\']+["\\']')

    def test_opener_announces_dialog(self):
        text = source()
        self.assertIn("aria-haspopup=\"dialog\"", text)
        self.assertRegex(text, r'aria-controls=["\\']modal["\\']')

    def test_escape_closes_and_focus_returns(self):
        compact = re.sub(r"\\s+", "", source())
        self.assertIn('key==="escape"', compact)
        self.assertRegex(compact, r"(open|opener)\\.focus\\(\\)")

    def test_tab_focus_is_trapped(self):
        text = source()
        self.assertIn("queryselectorall", text)
        self.assertIn("document.activeelement", text)
        self.assertRegex(text, r'key\\s*===?\\s*["\\']tab["\\']')


if __name__ == "__main__":
    unittest.main()
""",
        visible_count=4,
        hidden_grader="""\
import json
import re
from pathlib import Path

s = Path("modal.html").read_text().lower()
c = re.sub(r"\\s+", "", s)
label = re.search(r'aria-labelledby=["\\']([^"\\']+)["\\']', s)
results = {
    "label_target": bool(label and re.search(r'id=["\\']' + re.escape(label.group(1)) + r'["\\']', s)),
    "named_close": bool(re.search(r'<button[^>]+(aria-label=["\\'][^"\\']+["\\']|id=["\\']cancel["\\'])', s)),
    "background_inert": ".inert=true" in c and ".inert=false" in c,
    "backdrop_close": (".target===modal" in c or ".target==modal" in c),
    "scroll_lock": "body.style.overflow" in c,
}
print(json.dumps(results, sort_keys=True))
""",
        hidden_count=5,
        request="""\
Repair `modal.html` into an accessible destructive-action modal without
libraries. The opener must expose its dialog relationship. The modal needs a
programmatic label, `role=dialog`, and `aria-modal=true`; opening moves focus
inside, makes the page main inert, and locks body scrolling. Trap Tab and
Shift+Tab within the modal. Escape, Cancel, and backdrop clicks close it,
restore background state and scrolling, and return focus to the opener. Give
the close control an accessible name and center the overlay responsively.
Only edit `modal.html`.
""",
    ),
    Task(
        name="persistent_theme_form",
        niche="form_state",
        source_name="settings.html",
        source="""\
<!doctype html>
<html lang="en">
<head>
  <meta name="viewport" content="width=device-width">
  <title>Account settings</title>
  <style>
    body { font-family: sans-serif; background: white; color: black; }
    .error { color: red; }
  </style>
</head>
<body>
  <button id="theme">Theme</button>
  <form id="settings">
    <div>Email</div>
    <input id="email">
    <span class="error"></span>
    <div>Team size</div>
    <input id="size">
    <button>Save</button>
  </form>
  <script>
    document.querySelector("#theme").onclick = () => document.body.classList.toggle("dark");
    document.querySelector("#settings").onsubmit = event => event.preventDefault();
  </script>
</body>
</html>
""",
        visible_tests="""\
import re
import unittest
from pathlib import Path


def source():
    return Path("settings.html").read_text().lower()


class SettingsTests(unittest.TestCase):
    def test_inputs_have_explicit_labels(self):
        text = source()
        self.assertRegex(text, r'<label[^>]+for=["\\']email["\\']')
        self.assertRegex(text, r'<label[^>]+for=["\\']size["\\']')

    def test_errors_are_connected_and_announced(self):
        text = source()
        self.assertIn("aria-describedby", text)
        self.assertRegex(text, r'role=["\\']alert["\\']')

    def test_submit_uses_constraint_validation(self):
        text = source()
        self.assertTrue("checkvalidity" in text or "reportvalidity" in text)
        self.assertIn("setcustomvalidity", text)

    def test_theme_is_persisted_and_applied(self):
        text = source()
        self.assertIn("localstorage", text)
        self.assertIn("data-theme", text)


if __name__ == "__main__":
    unittest.main()
""",
        visible_count=4,
        hidden_grader="""\
import json
import re
from pathlib import Path

s = Path("settings.html").read_text().lower()
c = re.sub(r"\\s+", "", s)
results = {
    "system_theme": "prefers-color-scheme" in s and "matchmedia" in s,
    "pressed_state": "aria-pressed" in s and "setattribute" in s,
    "focus_visible": ":focus-visible" in s,
    "reduced_motion": "@media(prefers-reduced-motion:reduce)" in c,
    "input_hints": 'autocomplete="email"' in s and 'inputmode="numeric"' in s,
}
print(json.dumps(results, sort_keys=True))
""",
        hidden_count=5,
        request="""\
Repair `settings.html` as an accessible account-settings form without
libraries. Add explicit labels and appropriate email/numeric input hints.
Connect validation text with `aria-describedby`, announce errors, use native
constraint validation plus a positive plain-integer team-size rule, and clear
custom errors when corrected. Implement a light/dark theme toggle that updates
`data-theme` and `aria-pressed`, persists an explicit choice in localStorage,
and otherwise follows `prefers-color-scheme`. Add design tokens, visible
keyboard focus, and reduced-motion handling. Only edit `settings.html`.
""",
    ),
)
