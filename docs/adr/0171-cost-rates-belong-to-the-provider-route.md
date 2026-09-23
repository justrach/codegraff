# 0171 — Cost rates belong to the provider route

A model alias can have different prices through a gateway and a direct vendor.
A name-only overlay therefore cannot determine the cost of an actual request.

The session cost tally and billing classification resolve prices using both
provider and model. Gateway rows have a separate documented snapshot; direct
vendor cache refreshes cannot override them. Unknown gateway aliases remain
unpriced instead of silently borrowing a vendor tariff. Subscription accounting
continues to depend on the credential source.

Cache-write multipliers are explicit overrides where the route differs from
the model-family default. Long-context bands remain attached when an on-disk
price refresh supplies only flat rates. Astra receives direct and gateway
catalog fallback rows so an explicit request can route with either credential.

This remains an estimate, not an invoice: undocumented tariffs, service-tier
premiums and regional surcharges require additional billing metadata. Catalog
presence also does not establish live provider capacity.

Regression tests cover provider-specific aliases, gateway-only routing,
cache-write charges, long-context bands, unpriced and free rows, and preservation
of bands through a cached overlay reload.
