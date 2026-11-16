#!/usr/bin/env python3
"""Stage the program date, history URL, and right-aligned documentation display."""

from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import subprocess


DISPLAY = '''<p style="text-align: right;">
  <a href="{{ site.data.program.history_url }}">{% if page.lang == 'ja' %}プログラムの最終更新日{% else %}Program last updated{% endif %}</a>{% if page.lang == 'ja' %}：{% else %}: {% endif %}<strong>{{ site.data.program.last_updated }}</strong>
</p>
'''


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def main():
    root = Path(git("rev-parse", "--show-toplevel"))
    os.chdir(root)

    if git("diff", "--cached", "--name-only", "--", "Sources/"):
        # Use the upcoming commit's committer date, including GIT_COMMITTER_DATE.
        _, timestamp, offset = git("var", "GIT_COMMITTER_IDENT").rsplit(" ", 2)
        minutes = int(offset[1:3]) * 60 + int(offset[3:5])
        zone = timezone(timedelta(minutes=minutes if offset[0] == "+" else -minutes))
        date = datetime.fromtimestamp(int(timestamp), zone).date().isoformat()
    else:
        date = git("log", "-1", "--format=%cs", "--", "Sources/")

    if not date:
        raise SystemExit("Cannot determine program date: Sources/ has no Git history.")

    content = (
        f'last_updated: "{date}"\n'
        'history_url: "https://github.com/sekika/opensftp/commits/main/Sources"\n'
    )
    outputs = {
        "docs/_data/program.yml": content,
        "docs/_includes/program-updated.html": DISPLAY,
    }
    for relative_path, generated in outputs.items():
        path = root / relative_path
        if path.exists() and path.read_text() == generated:
            continue
        if git("diff", "--name-only", "--", relative_path):
            raise SystemExit(f"Commit or stash local edits to {relative_path} before regenerating it.")
    for relative_path, generated in outputs.items():
        path = root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists() or path.read_text() != generated:
            path.write_text(generated)
    subprocess.run(["git", "add", "--", *outputs], check=True)


if __name__ == "__main__":
    main()
