# Third-Party Notices

LingShu is distributed under the Apache License 2.0. The following components retain their own licenses.

## Lucide Icons

Parts of the interface and the DesignKB use icons from [Lucide](https://lucide.dev/).

- License: ISC
- Bundled license: [`Resources/DesignKB/icons/lucide/LICENSE`](./Resources/DesignKB/icons/lucide/LICENSE)

## Grok Code Agent Runtime

The embedded delivery-task runtime contains modified source derived from
[xai-org/grok-build](https://github.com/xai-org/grok-build), upstream revision
`ba76b0a683fa52e4e60685017b85905451be17bc`.

- Copyright: 2023–2026 SpaceXAI
- License: Apache License 2.0
- Bundled license: [`Runtime/Grok/LICENSE`](./Runtime/Grok/LICENSE)
- Upstream dependency notices: [`Runtime/Grok/THIRD-PARTY-NOTICES`](./Runtime/Grok/THIRD-PARTY-NOTICES)
- LingShu changes include an in-process runtime entrypoint, host ABI, lifecycle integration, provider-neutral configuration, and task-event adaptation.

## Optional Runtime Components

Some optional speech, perception, document-conversion, browser, or external-agent capabilities are discovered or downloaded separately at runtime. They are not relicensed by this repository and remain subject to their respective upstream licenses and service terms.

If you find a missing attribution, please open an issue before redistribution so it can be corrected promptly.
