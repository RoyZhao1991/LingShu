# RuntimeConfig

Place local runtime credentials here before packaging the app.

These files are copied into `LingShu.app/Contents/Resources/RuntimeConfig/` by the build scripts and are intentionally ignored by Git.

Current built-in provider credential:

- `datanet-gateway.token`: token for `https://model-gateway.datanet.bj.cn`.

Do not commit real tokens.
