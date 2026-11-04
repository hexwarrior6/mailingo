# Mailingo architecture

1. [MailExtension](../MailExtension/) receives message MIME through MailKit, stores it locally, and associates the translation banner with the captured message.
2. [Shared](../Shared/) defines the message store, request handoff and paths inside the extension's container.
3. [App](../App/) opens the requested message, selects a translation engine, and renders the result in a SwiftUI window backed by WebKit.
4. [MailingoKit](../Packages/MailingoKit/) contains MIME and HTML parsing, translation engines, disk caching, and Mail selection monitoring. The HTML pipeline replaces translatable text while preserving the surrounding markup. WebKit layout adaptations operate on a rendering copy.

See the [contributor guide](../CONTRIBUTING.md) for setup, test commands and release steps.

## Design history

These documents capture earlier design decisions and investigations. Use the source code and contributor guide for the current implementation and commands.

- [Product baseline](PRODUCT.md)
- [Initial implementation plan](IMPLEMENTATION_PLAN.md)
- [MailKit feasibility investigation](S0-PROBE.md)
- [Earlier backlog and investigation notes](BACKLOG.md)
