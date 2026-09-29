# Contributing

The NextAge Dev Kit is an opinionated standard: one shared way of working with Claude Code for us, our clients, and our development partners. It is open source under the [MIT License](LICENSE), and anyone may use or fork it.

## Proposing a change

Open a [GitHub issue](https://github.com/NextAge-Consulting/nextage-dev-kit/issues). Describe the problem you hit and the change you would make.

- **Clients and partners:** this is how a change to a kit-owned rule, hook, skill or command reaches your projects. Kit-owned files are changed only in the kit, and reach every project through `/sync-dev-kit`.
- **Everyone else:** suggestions are welcome and read. One that does not fit our way of working will not be applied here — fork the kit and adapt it; that is what the license is for.

Pull requests are not merged directly. A change the kit takes on is made by the maintainer, so it lands consistently in every project that uses the kit.

## Keep it generic

This repository is public. In an issue, describe the shape of the problem — never a client, project, person, host, database or credential. Use invented examples (`example.com`, `app_user`, `mytable.mycolumn`).
