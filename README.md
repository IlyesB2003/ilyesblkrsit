# AI Dev Transfer - Windows installer test

This branch only exists to test the Windows installer on a real Windows machine
(GitHub Actions `windows-latest`). It does not touch the website on `main`.

- `installer/` - the installer files (same as the Setup.exe package)
- `ci/` - the test scripts: they run `AI-Dev-Transfer-Setup.exe`, let the wizard
  click through its own pages, install the selected components and collect logs,
  screenshots and the verification report
- `ci-results/REPORT.md` - latest results, written back by the workflow
