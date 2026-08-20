import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const configPath = new URL("../src-tauri/tauri.conf.json", import.meta.url);
const templatePath = new URL("../src-tauri/installer/lingshu-installer.nsi", import.meta.url);
const upgradeScriptPath = new URL("../scripts/test-nsis-upgrade.ps1", import.meta.url);
const config = JSON.parse(readFileSync(configPath, "utf8"));
const template = readFileSync(templatePath, "utf8");
const upgradeScript = readFileSync(upgradeScriptPath, "utf8");

test("uses the branded LingShu NSIS template without the stock language popup", () => {
  const nsis = config.bundle.windows.nsis;

  assert.equal(nsis.template, "installer/lingshu-installer.nsi");
  assert.equal(nsis.displayLanguageSelector, false);
  assert.equal(nsis.uninstallerHeaderImage, "installer-assets/nsis-header.bmp");
  assert.deepEqual(nsis.languages, ["English", "SimpChinese"]);
  assert.match(template, /MUI_CUSTOMFUNCTION_GUIINIT LingShuGuiInit/);
  assert.match(template, /MUI_PAGE_CUSTOMFUNCTION_SHOW LingShuWelcomeShow/);
  assert.match(template, /MUI_PAGE_CUSTOMFUNCTION_SHOW LingShuDirectoryShow/);
  assert.match(template, /MUI_PAGE_CUSTOMFUNCTION_SHOW LingShuProgressShow/);
  assert.match(template, /MUI_PAGE_CUSTOMFUNCTION_SHOW LingShuFinishShow/);
  assert.match(template, /LangString LingShuWelcomeTitle \$\{LANG_SIMPCHINESE\}/);
});

test("pins the MSI upgrade identity independently of future product-name changes", () => {
  assert.equal(
    config.bundle.windows.wix.upgradeCode,
    "673a218d-70ac-527c-bd61-f4ec6031cd45",
  );
});

test("resolves previous installs through every stable and legacy source", () => {
  const uninstallLocation = template.indexOf(
    'ReadRegStr $4 SHCTX "${UNINSTKEY}" "InstallLocation"',
  );
  const currentPublisher = template.indexOf(
    'ReadRegStr $4 SHCTX "${MANUPRODUCTKEY}" ""',
    uninstallLocation,
  );
  const legacyPublisher = template.indexOf(
    'ReadRegStr $4 SHCTX "${LEGACYMANUPRODUCTKEY}" ""',
    currentPublisher,
  );
  const uninstallCommand = template.indexOf(
    'ReadRegStr $4 SHCTX "${UNINSTKEY}" "UninstallString"',
    legacyPublisher,
  );

  assert.ok(uninstallLocation >= 0);
  assert.ok(currentPublisher > uninstallLocation);
  assert.ok(legacyPublisher > currentPublisher);
  assert.ok(uninstallCommand > legacyPublisher);
  assert.match(template, /!define LEGACYMANUPRODUCTKEY "Software\\royzhao\\\$\{PRODUCTNAME\}"/);
  assert.match(template, /Call ParentFromUninstallCommand/);
});

test("executes only the verified legacy uninstaller with NSIS-safe path syntax", () => {
  const pageLeaveStart = template.indexOf("Function PageLeaveReinstall");
  const pageLeaveEnd = template.indexOf("; 5. Choose install directory page", pageLeaveStart);
  const pageLeave = template.slice(pageLeaveStart, pageLeaveEnd);

  assert.match(template, /\$\{FileExists\} "\$4\\uninstall\.exe"/);
  assert.match(pageLeave, /StrCpy \$R1 "\$\\"\$4\\uninstall\.exe\$\\""/);
  assert.match(pageLeave, /StrCpy \$R1 "\$R1 _\?=\$4"/);
  assert.match(pageLeave, /\$UninstallPreviousMode = 1/);
  assert.match(pageLeave, /StrCpy \$R1 "\$R1 \/S"/);
  assert.doesNotMatch(pageLeave, /ReadRegStr \$R1 SHCTX "\$\{UNINSTKEY\}" "UninstallString"/);
  assert.match(
    template,
    /\$CMDLINE "\/UNINSTALLPREVIOUS" \$UninstallPreviousMode/,
  );
});

test("records the exact Tauri template baseline used for future synchronization", () => {
  assert.match(template, /tauri-cli-v2\.11\.4\/crates\/tauri-bundler/);
  assert.match(
    template,
    /Upstream SHA-256: 20f4ecc730defb71f1342eaeaec4021df13be3d843abba0effe88ea5835fa079/,
  );
});

test("exercises the production legacy-uninstall branch from a spaced directory", () => {
  assert.match(upgradeScript, /Nous Legacy Install With Spaces/);
  assert.match(upgradeScript, /"\/D=\$legacyInstallDirectory"/);
  assert.match(
    upgradeScript,
    /@\("\/P", "\/NS", "\/UNINSTALLPREVIOUS"\)/,
  );
  assert.match(upgradeScript, /preview\.25 ignored the custom install directory/);
});
