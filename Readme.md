- [English documentation](https://sekika.github.io/opensftp/)
- [日本語ドキュメント](https://sekika.github.io/opensftp/ja/)

Run `make precommit` after cloning to install the Git-managed pre-commit hook.
Before each commit, it updates the program date shown on both documentation home pages
from the latest commit affecting `Sources/` (or the new commit's date when source changes
are staged), and stages `docs/_data/program.yml`, including the source history link.
It also generates and stages `docs/_includes/program-updated.html` for the right-aligned
date display. Documentation-only changes keep the program date unchanged.
The hook requires Python 3 and runs at commit time, before pushing.
