"""Pricing rules layered on top of an Inventory."""

from stats import mean, median, spread


def markup_price(unit_cost, markup_pct):
    return round(unit_cost * (1.0 + markup_pct / 100.0), 2)


def typical_quantity(inventory):
    """The representative stock level, resistant to one huge outlier."""
    return median(inventory.quantities())


def average_unit_cost(inventory):
    return mean(inventory.unit_costs())


def cost_spread(inventory):
    return spread(inventory.unit_costs())


def restock_target(inventory, factor=2):
    """Restock every SKU up to `factor` x the typical quantity."""
    return int(typical_quantity(inventory) * factor)
