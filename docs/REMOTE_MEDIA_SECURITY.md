# Remote media security

`import_media(source.url)` treats every supplied URL as untrusted.

- The initial URL and every redirect must use HTTPS, contain no credentials, and resolve only to
  public IP addresses.
- Local hostnames plus loopback, private, link-local, carrier-grade NAT, documentation, multicast,
  reserved, and non-global IPv6 ranges are rejected.
- DNS is resolved before the request, at every redirect, and again after the transfer. A hostname is
  rejected if any answer is non-public. URLSession transaction metrics also verify that every actual
  network peer is public; a missing peer address or proxy connection fails closed.
- Redirects are limited to five hops and loops are rejected.
- One timeout and one byte ceiling apply to the whole URL session, including redirects.
- Downloaded bytes are opened as the declared media type before the project is mutated. An extension
  or MIME hint alone is never accepted as proof of content.

URLSession does not expose a supported API for selecting a pre-resolved address. The policy therefore
combines preflight and per-redirect resolution with verification of the connected peer address from
task transaction metrics and a postflight resolution. The production path rejects proxies because
their reported peer address is the proxy rather than the origin.
